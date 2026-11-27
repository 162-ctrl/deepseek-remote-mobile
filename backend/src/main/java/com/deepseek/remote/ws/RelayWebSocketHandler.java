package com.deepseek.remote.ws;

import com.deepseek.remote.auth.TokenStore;
import com.deepseek.remote.protocol.CloseCodes;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;
import org.springframework.web.socket.CloseStatus;
import org.springframework.web.socket.TextMessage;
import org.springframework.web.socket.WebSocketSession;
import org.springframework.web.socket.handler.ConcurrentWebSocketSessionDecorator;
import org.springframework.web.socket.handler.TextWebSocketHandler;

import java.io.IOException;
import java.net.URI;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;

/**
 * {@code /ws?role=app|agent&token=...} handler.
 *
 * <p>The upgrade itself is accepted, then token/role are validated and invalid connections are
 * closed with {@link CloseCodes#UNAUTHORIZED} (4401) so native clients can observe a websocket
 * close code instead of a bare HTTP 403.
 */
@Component
public class RelayWebSocketHandler extends TextWebSocketHandler {

    private static final Logger log = LoggerFactory.getLogger(RelayWebSocketHandler.class);

    private static final int SEND_TIME_LIMIT_MS = 10_000;
    private static final int SEND_BUFFER_SIZE_BYTES = 8 * 1024 * 1024;

    private final RelayHub hub;
    private final TokenStore tokenStore;
    private final ObjectMapper mapper;

    public RelayWebSocketHandler(RelayHub hub, TokenStore tokenStore, ObjectMapper mapper) {
        this.hub = hub;
        this.tokenStore = tokenStore;
        this.mapper = mapper;
    }

    @Override
    public void afterConnectionEstablished(WebSocketSession session) {
        Map<String, String> query = parseQuery(session.getUri());
        String role = query.get("role");
        String token = query.get("token");

        boolean roleValid = "app".equals(role) || "agent".equals(role);
        TokenStore.TokenInfo tokenInfo = roleValid ? tokenStore.validate(token) : null;
        boolean valid = roleValid && tokenInfo != null && tokenInfo.role().equals(role);

        if (!valid) {
            log.info("ws handshake rejected role={} sessionId={} reason=invalid token or role -> close 4401",
                    role, session.getId());
            try {
                session.close(CloseCodes.UNAUTHORIZED);
            } catch (IOException e) {
                log.debug("closing rejected session failed sessionId={} err={}", session.getId(), e.getMessage());
            }
            return;
        }

        RelaySession relaySession = new RelaySession(
                new ConcurrentWebSocketSessionDecorator(session, SEND_TIME_LIMIT_MS, SEND_BUFFER_SIZE_BYTES),
                role,
                tokenInfo.deviceId(),
                tokenInfo.clientName());
        hub.register(relaySession);
    }

    @Override
    protected void handleTextMessage(WebSocketSession session, TextMessage message) {
        RelaySession relaySession = hub.bySessionId(session.getId());
        if (relaySession == null) {
            log.warn("dropping message from unregistered websocket sessionId={}", session.getId());
            return;
        }
        String text = message.getPayload();
        int bytes = text.getBytes(StandardCharsets.UTF_8).length;

        JsonNode root;
        try {
            root = mapper.readTree(text);
        } catch (Exception e) {
            log.warn("invalid json role={} sessionId={} bytes={} err={}",
                    relaySession.role(), session.getId(), bytes, e.getMessage());
            hub.sendError(relaySession, "BAD_REQUEST", "invalid JSON message", null);
            return;
        }
        if (root == null || !root.isObject()) {
            log.warn("invalid envelope role={} sessionId={} bytes={}",
                    relaySession.role(), session.getId(), bytes);
            hub.sendError(relaySession, "BAD_REQUEST", "message must be a JSON object", null);
            return;
        }

        String type = root.path("type").asText("");
        if (type.isEmpty()) {
            log.warn("missing type role={} sessionId={} bytes={}",
                    relaySession.role(), session.getId(), bytes);
            hub.sendError(relaySession, "BAD_REQUEST", "message.type is required", null);
            return;
        }
        if ("ping".equals(type)) {
            log.info("recv role={} type=ping bytes={}", relaySession.role(), bytes);
            hub.sendPong(relaySession);
            return;
        }
        hub.dispatch(relaySession, type, root, bytes);
    }

    @Override
    public void afterConnectionClosed(WebSocketSession session, CloseStatus status) {
        hub.unregister(session.getId());
    }

    @Override
    public void handleTransportError(WebSocketSession session, Throwable exception) {
        log.warn("ws transport error sessionId={} err={}", session.getId(), exception.getMessage());
    }

    private static Map<String, String> parseQuery(URI uri) {
        Map<String, String> params = new HashMap<>();
        if (uri == null || uri.getRawQuery() == null || uri.getRawQuery().isEmpty()) {
            return params;
        }
        for (String pair : uri.getRawQuery().split("&")) {
            int separator = pair.indexOf('=');
            if (separator <= 0) {
                continue;
            }
            String key = URLDecoder.decode(pair.substring(0, separator), StandardCharsets.UTF_8);
            String value = URLDecoder.decode(pair.substring(separator + 1), StandardCharsets.UTF_8);
            params.put(key, value);
        }
        return params;
    }
}
