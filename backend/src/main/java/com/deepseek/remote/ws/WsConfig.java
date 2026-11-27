package com.deepseek.remote.ws;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.web.socket.config.annotation.EnableWebSocket;
import org.springframework.web.socket.config.annotation.WebSocketConfigurer;
import org.springframework.web.socket.config.annotation.WebSocketHandlerRegistry;
import org.springframework.web.socket.server.standard.ServletServerContainerFactoryBean;

/**
 * Registers the single relay endpoint {@code /ws} and raises the container buffer sizes so
 * approval payloads and long prompts fit comfortably.
 */
@Configuration
@EnableWebSocket
public class WsConfig implements WebSocketConfigurer {

    private static final Logger log = LoggerFactory.getLogger(WsConfig.class);

    /** Text frames beyond this size are rejected by the container (bigger than any M1 message). */
    private static final int MAX_TEXT_MESSAGE_BYTES = 4 * 1024 * 1024;

    private final RelayWebSocketHandler relayWebSocketHandler;

    public WsConfig(RelayWebSocketHandler relayWebSocketHandler) {
        this.relayWebSocketHandler = relayWebSocketHandler;
    }

    @Override
    public void registerWebSocketHandlers(WebSocketHandlerRegistry registry) {
        registry.addHandler(relayWebSocketHandler, "/ws").setAllowedOriginPatterns("*");
        log.info("websocket endpoint registered: /ws");
    }

    @Bean
    public ServletServerContainerFactoryBean createWebSocketContainer() {
        ServletServerContainerFactoryBean container = new ServletServerContainerFactoryBean();
        container.setMaxTextMessageBufferSize(MAX_TEXT_MESSAGE_BYTES);
        container.setMaxBinaryMessageBufferSize(MAX_TEXT_MESSAGE_BYTES);
        // 0 = no server side idle timeout; heartbeat liveness is an agent concern in M1.
        container.setMaxSessionIdleTimeout(0L);
        return container;
    }
}
