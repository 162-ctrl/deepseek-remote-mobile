package com.deepseek.remote.protocol;

import org.springframework.web.socket.CloseStatus;

/**
 * M1 close codes used by the relay (protocol section 2.3).
 */
public final class CloseCodes {

    /** Invalid/missing token or role mismatch during the websocket handshake. */
    public static final CloseStatus UNAUTHORIZED = new CloseStatus(4401, "invalid token or role");

    /** A newer agent connection replaced the previous one (single agent policy). */
    public static final CloseStatus AGENT_REPLACED = new CloseStatus(4409, "replaced by newer agent connection");

    private CloseCodes() {
    }
}
