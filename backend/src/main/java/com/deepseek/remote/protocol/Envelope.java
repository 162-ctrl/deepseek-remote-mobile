package com.deepseek.remote.protocol;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;

import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;

/**
 * M1 message envelope (protocol section 3):
 *
 * <pre>{"v":1,"type":"prompt.send","id":"msg_ab12","ts":"...","payload":{}}</pre>
 */
public final class Envelope {

    public static final int V = 1;

    private static final DateTimeFormatter TS_FORMAT =
            DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'").withZone(ZoneOffset.UTC);

    private Envelope() {
    }

    /** ISO-8601 UTC timestamp with millisecond precision, e.g. 2026-10-31T13:00:00.000Z. */
    public static String nowTs() {
        return TS_FORMAT.format(Instant.now());
    }

    public static ObjectNode of(ObjectMapper mapper, String type, String id, JsonNode payload) {
        ObjectNode node = mapper.createObjectNode();
        node.put("v", V);
        node.put("type", type);
        if (id != null && !id.isBlank()) {
            node.put("id", id);
        }
        node.put("ts", nowTs());
        if (payload != null && !payload.isNull()) {
            node.set("payload", payload);
        }
        return node;
    }
}
