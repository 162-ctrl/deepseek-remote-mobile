package com.deepseek.remote.api;

import com.deepseek.remote.auth.TokenStore;
import com.deepseek.remote.persistence.PersistenceService;
import com.deepseek.remote.ws.RelayHub;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.http.converter.HttpMessageNotReadableException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Health + pairing endpoints (protocol sections 2.1, 2.2, 2.4).
 */
@RestController
@RequestMapping("/api/v1")
public class PairingController {

    private static final Logger log = LoggerFactory.getLogger(PairingController.class);
    private static final DateTimeFormatter EXPIRES_FORMAT =
            DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'").withZone(ZoneOffset.UTC);

    private final TokenStore tokenStore;
    private final RelayHub relayHub;
    private final PersistenceService persistence;
    private final String pairingCode;
    private final String version;
    private final AtomicLong deviceSequence = new AtomicLong();

    public PairingController(TokenStore tokenStore,
                             RelayHub relayHub,
                             PersistenceService persistence,
                             @Value("${m1.pairing-code:824613}") String pairingCode,
                             @Value("${m1.version:0.1.1-m2}") String version) {
        this.tokenStore = tokenStore;
        this.relayHub = relayHub;
        this.persistence = persistence;
        this.pairingCode = pairingCode;
        this.version = version;
        log.info("pairing configured version={} codeLength={} codeIsDefault={}",
                version, pairingCode.length(), "824613".equals(pairingCode));
    }

    /** {@code POST /api/v1/auth/pair} request body. */
    public record PairRequest(String pairingCode, String clientName, String role) {
    }

    @GetMapping("/health")
    public Map<String, Object> health() {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("status", "ok");
        body.put("version", version);
        body.put("agentOnline", relayHub.isAgentOnline());
        body.put("apps", relayHub.appCount());
        return body;
    }

    @PostMapping("/auth/pair")
    public ResponseEntity<Map<String, Object>> pair(@RequestBody(required = false) PairRequest request) {
        if (request == null) {
            log.info("pair rejected reason=missing body");
            return failure(HttpStatus.BAD_REQUEST, "BAD_REQUEST", "request body required");
        }
        String role = request.role();
        if (!"app".equals(role) && !"agent".equals(role)) {
            log.info("pair rejected reason=invalid role");
            return failure(HttpStatus.UNAUTHORIZED, "AUTH_FAILED", "role must be 'app' or 'agent'");
        }
        String providedCode = request.pairingCode();
        if (providedCode == null || !pairingCode.equals(providedCode.trim())) {
            log.info("pair rejected role={} reason=pairing code invalid", role);
            return failure(HttpStatus.UNAUTHORIZED, "AUTH_FAILED", "pairing code invalid");
        }

        tokenStore.purgeExpired();
        String clientName = (request.clientName() == null || request.clientName().isBlank())
                ? role
                : request.clientName().trim();
        // DELTA section 2/4: the agent device id is a stable 26-char ULID persisted in devices.
        String deviceId = "agent".equals(role)
                ? persistence.resolveAgentDevice(clientName)
                : "dev_" + deviceSequence.incrementAndGet();
        TokenStore.IssuedToken issued = tokenStore.issue(role, deviceId, clientName);

        Map<String, Object> body = new LinkedHashMap<>();
        body.put("token", issued.token());
        body.put("role", issued.role());
        body.put("deviceId", issued.deviceId());
        body.put("expiresAt", EXPIRES_FORMAT.format(issued.expiresAt()));
        log.info("pair ok role={} deviceId={} clientName={} expiresAt={}",
                role, deviceId, clientName, body.get("expiresAt"));
        return ResponseEntity.ok(body);
    }

    @ExceptionHandler(HttpMessageNotReadableException.class)
    public ResponseEntity<Map<String, Object>> badJson(HttpMessageNotReadableException exception) {
        log.info("pair rejected reason=invalid json body");
        return failure(HttpStatus.BAD_REQUEST, "BAD_REQUEST", "invalid JSON body");
    }

    private ResponseEntity<Map<String, Object>> failure(HttpStatus status, String code, String message) {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("code", code);
        body.put("message", message);
        return ResponseEntity.status(status).body(body);
    }
}
