package com.deepseek.remote.auth;

import com.deepseek.remote.persistence.Ulid;
import jakarta.annotation.PreDestroy;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.security.SecureRandom;
import java.sql.Timestamp;
import java.time.Duration;
import java.time.Instant;
import java.util.HexFormat;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

/**
 * Database-first token store for M2 (contract: {@code docs/design/M2_DELTA.md} section 1.2).
 *
 * <p>Tokens are 32 random bytes rendered as 64 lowercase hex chars. Only their
 * SHA-256 digest is persisted in {@code auth_tokens}; the plaintext token exists only
 * in the pairing response and in the client's storage. Validation therefore survives
 * a backend restart (M2 acceptance item M2-A4): a restart only clears the in-memory
 * cache, which is reloaded from PostgreSQL on the next request.
 *
 * <p>Validation path: memory cache first, then a database lookup
 * ({@code token_hash = sha256(token) AND revoked_at IS NULL AND expires_at > now()}).
 * Successful validations refresh {@code last_seen_at} asynchronously; failures there
 * only log and never affect the request (same fire-and-forget rule as M1.1 persistence).
 *
 * <p>The cache has a very short TTL (default 1s, env {@code M1_TOKEN_CACHE_TTL_SECONDS})
 * so a manual {@code revoked_at} flip in the database is picked up almost immediately
 * (M2-A5 auto re-pair). It is only a burst accelerator for back-to-back handshake/REST
 * checks, never a stale authorization source.
 */
@Component
public class TokenStore {

    private static final Logger log = LoggerFactory.getLogger(TokenStore.class);

    /** Issued token. */
    public record IssuedToken(String token, String role, String deviceId, String clientName, Instant expiresAt) {
    }

    /** Validated token view (never expose the token itself in logs). */
    public record TokenInfo(String role, String deviceId, String clientName, Instant expiresAt) {
    }

    private record CacheEntry(TokenInfo info, Instant loadedAt) {
    }

    private final JdbcTemplate jdbc;
    private final SecureRandom random = new SecureRandom();
    private final Duration ttl;
    private final Duration cacheTtl;
    private final Map<String, CacheEntry> cache = new ConcurrentHashMap<>();
    private final ExecutorService touchExecutor;

    public TokenStore(JdbcTemplate jdbc,
                      @Value("${m1.token-ttl-days:30}") long ttlDays,
                      @Value("${m1.token-cache-ttl-seconds:1}") long cacheTtlSeconds) {
        this.jdbc = jdbc;
        long days = ttlDays > 0 ? ttlDays : 30;
        this.ttl = Duration.ofDays(days);
        this.cacheTtl = Duration.ofSeconds(Math.max(0, cacheTtlSeconds));
        this.touchExecutor = Executors.newSingleThreadExecutor(runnable -> {
            Thread thread = new Thread(runnable, "m1-token-touch");
            thread.setDaemon(false);
            return thread;
        });
        log.info("token store ready (database-first): ttl={}d cacheTtl={}s", days, this.cacheTtl.toSeconds());
    }

    public IssuedToken issue(String role, String deviceId, String clientName) {
        byte[] raw = new byte[32];
        random.nextBytes(raw);
        String token = HexFormat.of().formatHex(raw);
        Instant issuedAt = Instant.now();
        Instant expiresAt = issuedAt.plus(ttl);
        String hash = sha256(token);
        try {
            jdbc.update("""
                            INSERT INTO auth_tokens
                                (id, token_hash, role, device_id, client_name, issued_at, expires_at)
                            VALUES (?, ?, ?, ?, ?, ?, ?)
                            """,
                    Ulid.newId(), hash, role, deviceId, clientName,
                    Timestamp.from(issuedAt), Timestamp.from(expiresAt));
        } catch (RuntimeException exception) {
            // A failed INSERT must not break pairing: fall back to a memory-only token so
            // the relay keeps working, and surface the problem in the log only.
            log.warn("token persist failed role={} deviceId={} reason={} (memory-only fallback)",
                    role, deviceId, exception.getMessage());
        }
        cache.put(hash, new CacheEntry(new TokenInfo(role, deviceId, clientName, expiresAt), Instant.now()));
        return new IssuedToken(token, role, deviceId, clientName, expiresAt);
    }

    /** Returns the token info when valid (not revoked, not expired), otherwise {@code null}. */
    public TokenInfo validate(String token) {
        if (token == null || token.isBlank()) {
            return null;
        }
        String hash = sha256(token);
        Instant now = Instant.now();
        CacheEntry cached = cache.get(hash);
        if (cached != null
                && cached.info().expiresAt().isAfter(now)
                && Duration.between(cached.loadedAt(), now).compareTo(cacheTtl) <= 0) {
            touchAsync(hash);
            return cached.info();
        }

        TokenInfo info = loadFromDatabase(hash);
        if (info == null) {
            cache.remove(hash);
            return null;
        }
        cache.put(hash, new CacheEntry(info, now));
        touchAsync(hash);
        return info;
    }

    private TokenInfo loadFromDatabase(String hash) {
        try {
            return jdbc.query(
                    """
                            SELECT role, device_id, client_name, expires_at
                            FROM auth_tokens
                            WHERE token_hash = ? AND revoked_at IS NULL AND expires_at > now()
                            """,
                    resultSet -> {
                        if (!resultSet.next()) {
                            return null;
                        }
                        Timestamp expiresAt = resultSet.getTimestamp("expires_at");
                        return new TokenInfo(
                                resultSet.getString("role"),
                                resultSet.getString("device_id"),
                                resultSet.getString("client_name"),
                                expiresAt == null ? null : expiresAt.toInstant());
                    },
                    hash);
        } catch (DataAccessException exception) {
            // Database unavailable: keep serving from cache if we still have a fresh entry,
            // otherwise reject (401 semantics stay identical).
            log.warn("token validation query failed (falling back to cache): {}", exception.getMessage());
            return null;
        }
    }

    private void touchAsync(String hash) {
        try {
            touchExecutor.execute(() -> {
                try {
                    jdbc.update("UPDATE auth_tokens SET last_seen_at = now() WHERE token_hash = ?", hash);
                } catch (RuntimeException ignored) {
                    // last_seen_at is best-effort by contract (M2_DELTA section 1.1).
                }
            });
        } catch (RuntimeException ignored) {
            // Executor shutting down: nothing to do, last_seen_at is optional.
        }
    }

    /**
     * Deletes expired token rows and evicts their cache entries. Called opportunistically
     * before pairing; a database failure is logged but never blocks pairing.
     */
    public void purgeExpired() {
        Instant now = Instant.now();
        cache.entrySet().removeIf(entry -> !entry.getValue().info().expiresAt().isAfter(now));
        try {
            int deleted = jdbc.update("DELETE FROM auth_tokens WHERE expires_at < now()");
            if (deleted > 0) {
                log.info("purged {} expired auth token row(s)", deleted);
            }
        } catch (RuntimeException exception) {
            log.warn("purge expired tokens failed: {}", exception.getMessage());
        }
    }

    public Duration ttl() {
        return ttl;
    }

    static String sha256(String token) {
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            return HexFormat.of().formatHex(digest.digest(token.getBytes(java.nio.charset.StandardCharsets.UTF_8)));
        } catch (NoSuchAlgorithmException exception) {
            // SHA-256 is mandatory on every JVM, so this cannot happen in practice.
            throw new IllegalStateException("SHA-256 not available", exception);
        }
    }

    @PreDestroy
    void shutdown() {
        touchExecutor.shutdown();
        try {
            if (!touchExecutor.awaitTermination(2, TimeUnit.SECONDS)) {
                touchExecutor.shutdownNow();
            }
        } catch (InterruptedException exception) {
            Thread.currentThread().interrupt();
            touchExecutor.shutdownNow();
        }
    }
}
