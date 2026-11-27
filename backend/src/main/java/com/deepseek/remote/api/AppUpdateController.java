package com.deepseek.remote.api;

import jakarta.servlet.http.HttpServletRequest;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.core.io.FileSystemResource;
import org.springframework.core.io.Resource;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestMethod;
import org.springframework.web.bind.annotation.RestController;

import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.security.DigestInputStream;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.Instant;
import java.time.ZoneId;
import java.time.format.DateTimeFormatter;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * M2.5 in-app self-update endpoints.
 *
 * <p>Contract: {@code docs/design/M2_5_UPDATE_DELTA.md} sections 2 / B1-B3.
 *
 * <p>Both endpoints are intentionally public (no Bearer): a phone with an expired or missing
 * token must still be able to discover and download an update, and the APK itself is not a
 * secret. The file is streamed from disk, never loaded into memory as a whole.
 */
@RestController
@RequestMapping("/api/v1/app")
public class AppUpdateController {

    private static final Logger log = LoggerFactory.getLogger(AppUpdateController.class);

    private static final MediaType APK_MEDIA_TYPE =
            MediaType.parseMediaType("application/vnd.android.package-archive");
    private static final String APK_FILENAME = "DeepSeek-Remote-latest.apk";
    private static final String APK_URL = "/api/v1/app/apk";
    private static final DateTimeFormatter PUBLISHED_AT_FORMAT =
            DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ssXXX");
    private static final int SHA256_BUFFER_BYTES = 64 * 1024;

    private final boolean enabled;
    private final Path apkPath;
    private final int versionCode;
    private final String versionName;
    private final String notes;

    /** sha256 cache keyed by (lastModified, size): recomputed only when the file changes. */
    private volatile CachedApk cachedApk;

    public AppUpdateController(
            @Value("${app.update.enabled:true}") boolean enabled,
            @Value("${app.update.apk-path:../dist/DeepSeek-Remote-latest.apk}") String apkPath,
            @Value("${app.update.version-code:7}") int versionCode,
            @Value("${app.update.version-name:0.1.6-m2.5}") String versionName,
            @Value("${app.update.notes:}") String notes) {
        this.enabled = enabled;
        this.apkPath = Paths.get(apkPath).toAbsolutePath().normalize();
        this.versionCode = versionCode;
        this.versionName = versionName == null ? "" : versionName;
        this.notes = notes == null ? "" : notes;
        log.info("app update configured enabled={} apkPath={} versionCode={} versionName={}",
                enabled, this.apkPath, versionCode, this.versionName);
    }

    /**
     * {@code GET /api/v1/app/version} - update descriptor consumed by the Android app.
     *
     * <p>404 with {@code {"code":"APP_UPDATE_UNAVAILABLE","message":"..."}} when the feature is
     * disabled or the APK file is not present on this server.
     */
    @GetMapping("/version")
    public ResponseEntity<Map<String, Object>> version() {
        CachedApk apk = currentApk();
        if (apk == null) {
            return unavailable();
        }
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("versionCode", versionCode);
        body.put("versionName", versionName);
        body.put("size", apk.size());
        body.put("sha256", apk.sha256());
        body.put("notes", notes);
        body.put("url", APK_URL);
        body.put("publishedAt", publishedAt(apk.lastModified()));
        log.info("app update check versionCode={} size={}", versionCode, apk.size());
        return ResponseEntity.ok(body);
    }

    /**
     * {@code GET /api/v1/app/apk} (HEAD supported) - streamed APK download.
     *
     * <p>HEAD answers with the same headers (including {@code Content-Length}) and no body, so
     * the phone can size-check the download before starting it.
     */
    @RequestMapping(value = "/apk", method = {RequestMethod.GET, RequestMethod.HEAD})
    public ResponseEntity<?> apk(HttpServletRequest request) {
        CachedApk apk = currentApk();
        if (apk == null) {
            return unavailable();
        }
        HttpHeaders headers = new HttpHeaders();
        headers.setContentType(APK_MEDIA_TYPE);
        headers.setContentLength(apk.size());
        headers.set(HttpHeaders.CONTENT_DISPOSITION, "attachment; filename=\"" + APK_FILENAME + "\"");
        if ("HEAD".equalsIgnoreCase(request.getMethod())) {
            return new ResponseEntity<>(headers, HttpStatus.OK);
        }
        Resource resource = new FileSystemResource(apkPath);
        log.info("app update apk download size={} sha256Prefix={}", apk.size(),
                apk.sha256().substring(0, 12));
        return new ResponseEntity<>(resource, headers, HttpStatus.OK);
    }

    /** Returns the current APK metadata, or {@code null} when the feature is unavailable. */
    private CachedApk currentApk() {
        if (!enabled) {
            return null;
        }
        try {
            if (!Files.isRegularFile(apkPath)) {
                return null;
            }
            long size = Files.size(apkPath);
            long lastModified = Files.getLastModifiedTime(apkPath).toMillis();
            CachedApk current = cachedApk;
            if (current != null && current.lastModified() == lastModified && current.size() == size) {
                return current;
            }
            CachedApk fresh = new CachedApk(lastModified, size, sha256(apkPath));
            cachedApk = fresh;
            return fresh;
        } catch (IOException e) {
            log.warn("app update apk unreadable path={}: {}", apkPath, e.toString());
            return null;
        }
    }

    private ResponseEntity<Map<String, Object>> unavailable() {
        if (!enabled) {
            log.info("app update unavailable: disabled by configuration");
        } else {
            log.warn("app update unavailable: apk not found at {}", apkPath);
        }
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("code", "APP_UPDATE_UNAVAILABLE");
        body.put("message", enabled
                ? "update package is not available on this server"
                : "app update is disabled on this server");
        return ResponseEntity.status(HttpStatus.NOT_FOUND).body(body);
    }

    private String publishedAt(long lastModifiedMillis) {
        return PUBLISHED_AT_FORMAT.format(
                Instant.ofEpochMilli(lastModifiedMillis).atZone(ZoneId.systemDefault()));
    }

    /** Lowercase hex SHA-256 of the APK, streamed from disk with a 64 KiB buffer. */
    private static String sha256(Path file) throws IOException {
        MessageDigest digest;
        try {
            digest = MessageDigest.getInstance("SHA-256");
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException("SHA-256 not available", e);
        }
        try (InputStream in = new DigestInputStream(Files.newInputStream(file), digest)) {
            byte[] buffer = new byte[SHA256_BUFFER_BYTES];
            while (in.read(buffer) != -1) {
                // digest is updated by DigestInputStream
            }
        }
        return HexFormat.of().formatHex(digest.digest());
    }

    private record CachedApk(long lastModified, long size, String sha256) {
    }
}
