package com.deepseek.remote.ws;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.web.socket.CloseStatus;
import org.springframework.web.socket.TextMessage;
import org.springframework.web.socket.WebSocketSession;

import java.io.IOException;
import java.time.Instant;

/**
 * One authenticated websocket connection, either role {@code app} or {@code agent}.
 *
 * <p>The wrapped {@link WebSocketSession} is a concurrent decorator, so {@link #sendText(String)}
 * is safe to call from any thread.
 */
public final class RelaySession {

    private static final Logger log = LoggerFactory.getLogger(RelaySession.class);

    private final WebSocketSession session;
    private final String role;
    private final String deviceId;
    private final String clientName;
    private final Instant connectedAt = Instant.now();

    public RelaySession(WebSocketSession session, String role, String deviceId, String clientName) {
        this.session = session;
        this.role = role;
        this.deviceId = deviceId;
        this.clientName = clientName;
    }

    public String sessionId() {
        return session.getId();
    }

    public String role() {
        return role;
    }

    public String deviceId() {
        return deviceId;
    }

    public String clientName() {
        return clientName;
    }

    public Instant connectedAt() {
        return connectedAt;
    }

    public boolean isOpen() {
        return session.isOpen();
    }

    public void sendText(String text) throws IOException {
        if (!session.isOpen()) {
            throw new IOException("websocket session is closed");
        }
        session.sendMessage(new TextMessage(text));
    }

    public void close(CloseStatus status) {
        try {
            if (session.isOpen()) {
                session.close(status);
            }
        } catch (IOException e) {
            log.debug("close failed sessionId={} err={}", session.getId(), e.getMessage());
        }
    }
}
