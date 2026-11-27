package com.deepseek.remote;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

/**
 * M1 relay backend entry point.
 *
 * <p>Topology: phone app (Flutter) --HTTPS/WSS--> this relay --WSS--> PC agent (Node/TS).
 */
@SpringBootApplication
public class RemoteApplication {

    public static void main(String[] args) {
        SpringApplication.run(RemoteApplication.class, args);
    }
}
