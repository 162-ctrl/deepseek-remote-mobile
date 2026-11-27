package com.deepseek.remote.api;

import com.deepseek.remote.auth.TokenStore;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.dao.DataAccessException;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * Read-only history REST endpoints (contracts: {@code docs/design/M1_1_DELTA.md} section 3 and
 * {@code docs/design/M2_1_DELTA.md} section 3).
 *
 * <ul>
 *   <li>{@code GET /api/v1/conversations}</li>
 *   <li>{@code GET /api/v1/conversations/{conversationId}/messages?afterSeq&limit}</li>
 *   <li>{@code GET /api/v1/conversations/{conversationId}/events?afterSeq&limit} (M2.1 catch-up)</li>
 *   <li>{@code GET /api/v1/tasks?limit&status}</li>
 *   <li>{@code GET /api/v1/tasks/{taskId}} (events timeline read from {@code task_events})</li>
 * </ul>
 *
 * <p>Auth reuses the M1 {@code /auth/pair} bearer token; errors use {@code {error:{code,message}}}.
 */
@RestController
@RequestMapping("/api/v1")
public class HistoryController {

    private static final Logger log = LoggerFactory.getLogger(HistoryController.class);

    private static final DateTimeFormatter TS_FORMAT =
            DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'").withZone(ZoneOffset.UTC);
    private static final Set<String> TASK_STATUSES = Set.of(
            "queued", "running", "waiting_approval", "paused", "completed", "failed", "cancelled");
    private static final int MAX_DETAIL_CHARS = 300;
    private static final int MAX_TASK_EVENTS = 500;

    private final JdbcTemplate jdbc;
    private final ObjectMapper mapper;
    private final TokenStore tokenStore;
    private final int defaultLimit;
    private final int maxLimit;
    private final int eventsDefaultLimit;
    private final int eventsMaxLimit;

    public HistoryController(JdbcTemplate jdbc,
                             ObjectMapper mapper,
                             TokenStore tokenStore,
                             @Value("${m1.history.default-limit:50}") int defaultLimit,
                             @Value("${m1.history.max-limit:200}") int maxLimit,
                             @Value("${m1.events.default-limit:200}") int eventsDefaultLimit,
                             @Value("${m1.events.max-limit:500}") int eventsMaxLimit) {
        this.jdbc = jdbc;
        this.mapper = mapper;
        this.tokenStore = tokenStore;
        this.defaultLimit = defaultLimit;
        this.maxLimit = maxLimit;
        this.eventsDefaultLimit = eventsDefaultLimit;
        this.eventsMaxLimit = eventsMaxLimit;
        log.info("history endpoints ready: defaultLimit={} maxLimit={} eventsDefaultLimit={} eventsMaxLimit={}",
                defaultLimit, maxLimit, eventsDefaultLimit, eventsMaxLimit);
    }

    // ------------------------------------------------------------------
    // conversations
    // ------------------------------------------------------------------

    @GetMapping("/conversations")
    public ResponseEntity<Map<String, Object>> conversations(
            @RequestHeader(value = "Authorization", required = false) String authorization,
            @RequestParam(value = "limit", required = false) Integer limit) {
        if (authenticate(authorization) == null) {
            return unauthorized();
        }
        int effectiveLimit = effectiveLimit(limit);
        List<Map<String, Object>> conversations = jdbc.query(
                "SELECT id, title, workspace_path, harness_session_id, last_message_at, message_count, created_at "
                        + "FROM conversations "
                        + "WHERE user_id = (SELECT id FROM users WHERE username = 'u_self') "
                        + "ORDER BY COALESCE(last_message_at, created_at) DESC LIMIT ?",
                conversationRowMapper(), effectiveLimit);
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("conversations", conversations);
        log.info("history conversations count={} limit={}", conversations.size(), effectiveLimit);
        return ResponseEntity.ok(body);
    }

    private RowMapper<Map<String, Object>> conversationRowMapper() {
        return (rs, rowNum) -> {
            Map<String, Object> conversation = new LinkedHashMap<>();
            conversation.put("conversationId", rs.getString("id"));
            conversation.put("title", rs.getString("title"));
            conversation.put("workspacePath", rs.getString("workspace_path"));
            conversation.put("sessionId", rs.getString("harness_session_id"));
            conversation.put("lastMessageAt", ts(rs, "last_message_at"));
            conversation.put("messageCount", rs.getInt("message_count"));
            conversation.put("createdAt", ts(rs, "created_at"));
            return conversation;
        };
    }

    // ------------------------------------------------------------------
    // messages
    // ------------------------------------------------------------------

    @GetMapping("/conversations/{conversationId}/messages")
    public ResponseEntity<Map<String, Object>> messages(
            @RequestHeader(value = "Authorization", required = false) String authorization,
            @PathVariable("conversationId") String conversationId,
            @RequestParam(value = "afterSeq", required = false) Long afterSeq,
            @RequestParam(value = "limit", required = false) Integer limit) {
        if (authenticate(authorization) == null) {
            return unauthorized();
        }
        long effectiveAfterSeq = afterSeq == null ? 0L : Math.max(0L, afterSeq);
        int effectiveLimit = effectiveLimit(limit);
        Integer exists = jdbc.queryForObject(
                "SELECT count(*) FROM conversations WHERE id = ?", Integer.class, conversationId);
        if (exists == null || exists == 0) {
            return error(HttpStatus.NOT_FOUND, "CONVERSATION_NOT_FOUND",
                    "unknown conversationId: " + conversationId);
        }
        List<Map<String, Object>> messages = jdbc.query(
                "SELECT id, seq_in_conversation, role, content_type, content, tool_name, metadata, created_at "
                        + "FROM messages WHERE conversation_id = ? AND seq_in_conversation > ? "
                        + "ORDER BY seq_in_conversation LIMIT ?",
                (rs, rowNum) -> {
                    Map<String, Object> message = new LinkedHashMap<>();
                    message.put("messageId", rs.getString("id"));
                    message.put("seq", rs.getLong("seq_in_conversation"));
                    message.put("role", rs.getString("role"));
                    message.put("kind", rs.getString("content_type"));
                    message.put("text", rs.getString("content"));
                    message.put("toolName", rs.getString("tool_name"));
                    message.put("metadata", json(rs.getString("metadata")));
                    message.put("createdAt", ts(rs, "created_at"));
                    return message;
                },
                conversationId, effectiveAfterSeq, effectiveLimit);
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("conversationId", conversationId);
        body.put("messages", messages);
        log.info("history messages conversation={} afterSeq={} count={}", conversationId,
                effectiveAfterSeq, messages.size());
        return ResponseEntity.ok(body);
    }

    // ------------------------------------------------------------------
    // conversation events (M2.1 cap-up / A2)
    // ------------------------------------------------------------------

    /**
     * M2.1-A2 catch-up endpoint: incremental conversation events ordered by the shared
     * conversation-level {@code seq}. {@code type='backfill'} rows (synthesized from M1 history by
     * V4) are internal and never returned.
     */
    @GetMapping("/conversations/{conversationId}/events")
    public ResponseEntity<Map<String, Object>> events(
            @RequestHeader(value = "Authorization", required = false) String authorization,
            @PathVariable("conversationId") String conversationId,
            @RequestParam(value = "afterSeq", required = false) Long afterSeq,
            @RequestParam(value = "limit", required = false) Integer limit) {
        if (authenticate(authorization) == null) {
            return unauthorized();
        }
        if (afterSeq != null && afterSeq < 0) {
            return error(HttpStatus.BAD_REQUEST, "BAD_REQUEST", "afterSeq must be >= 0");
        }
        int effectiveLimit = limit == null ? eventsDefaultLimit : limit;
        if (effectiveLimit <= 0 || effectiveLimit > eventsMaxLimit) {
            return error(HttpStatus.BAD_REQUEST, "BAD_REQUEST",
                    "limit must be between 1 and " + eventsMaxLimit);
        }
        long effectiveAfterSeq = afterSeq == null ? 0L : afterSeq;
        Integer exists = jdbc.queryForObject(
                "SELECT count(*) FROM conversations WHERE id = ?", Integer.class, conversationId);
        if (exists == null || exists == 0) {
            return error(HttpStatus.NOT_FOUND, "CONVERSATION_NOT_FOUND",
                    "unknown conversationId: " + conversationId);
        }
        List<Map<String, Object>> events = jdbc.query(
                "SELECT seq, type, kind, payload, created_at FROM task_events "
                        + "WHERE conversation_id = ? AND seq > ? AND type <> 'backfill' "
                        + "ORDER BY seq ASC LIMIT ?",
                (rs, rowNum) -> eventJson(rs, false), conversationId, effectiveAfterSeq, effectiveLimit);
        long nextSeq = effectiveAfterSeq;
        if (!events.isEmpty()) {
            nextSeq = ((Number) events.get(events.size() - 1).get("seq")).longValue() + 1L;
        }
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("events", events);
        body.put("nextSeq", nextSeq);
        log.info("history events conversation={} afterSeq={} count={} nextSeq={}",
                conversationId, effectiveAfterSeq, events.size(), nextSeq);
        return ResponseEntity.ok(body);
    }

    // ------------------------------------------------------------------
    // tasks
    // ------------------------------------------------------------------

    @GetMapping("/tasks")
    public ResponseEntity<Map<String, Object>> tasks(
            @RequestHeader(value = "Authorization", required = false) String authorization,
            @RequestParam(value = "limit", required = false) Integer limit,
            @RequestParam(value = "status", required = false) String status) {
        if (authenticate(authorization) == null) {
            return unauthorized();
        }
        int effectiveLimit = effectiveLimit(limit);
        List<String> statuses = parseStatuses(status);
        if (statuses == null) {
            return error(HttpStatus.BAD_REQUEST, "BAD_REQUEST",
                    "status must be one of " + TASK_STATUSES);
        }
        StringBuilder sql = new StringBuilder(
                "SELECT t.id, t.conversation_id, t.task_name, t.task_status, t.progress, t.result, "
                        + "t.error_code, t.error_message, t.created_at, t.started_at, t.finished_at, "
                        + "c.workspace_path FROM tasks t LEFT JOIN conversations c ON c.id = t.conversation_id "
                        + "WHERE t.user_id = (SELECT id FROM users WHERE username = 'u_self')");
        List<Object> args = new ArrayList<>();
        if (!statuses.isEmpty()) {
            sql.append(" AND t.task_status IN (");
            for (int i = 0; i < statuses.size(); i++) {
                sql.append(i == 0 ? "?" : ", ?");
                args.add(statuses.get(i));
            }
            sql.append(')');
        }
        sql.append(" ORDER BY t.created_at DESC LIMIT ?");
        args.add(effectiveLimit);

        List<Map<String, Object>> tasks = new ArrayList<>();
        for (TaskRow task : jdbc.query(sql.toString(), taskRowMapper(), args.toArray())) {
            tasks.add(taskJson(task, null));
        }
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("tasks", tasks);
        log.info("history tasks count={} statuses={} limit={}", tasks.size(), statuses, effectiveLimit);
        return ResponseEntity.ok(body);
    }

    @GetMapping("/tasks/{taskId}")
    public ResponseEntity<Map<String, Object>> task(
            @RequestHeader(value = "Authorization", required = false) String authorization,
            @PathVariable("taskId") String taskId) {
        if (authenticate(authorization) == null) {
            return unauthorized();
        }
        List<TaskRow> rows = jdbc.query(
                "SELECT t.id, t.conversation_id, t.task_name, t.task_status, t.progress, t.result, "
                        + "t.error_code, t.error_message, t.created_at, t.started_at, t.finished_at, "
                        + "c.workspace_path FROM tasks t LEFT JOIN conversations c ON c.id = t.conversation_id "
                        + "WHERE t.id = ?",
                taskRowMapper(), taskId);
        if (rows.isEmpty()) {
            return error(HttpStatus.NOT_FOUND, "NOT_FOUND", "unknown taskId: " + taskId);
        }
        TaskRow row = rows.get(0);
        Map<String, Object> body = taskJson(row, buildEvents(row));
        log.info("history task detail id={} events={}", taskId, ((List<?>) body.get("events")).size());
        return ResponseEntity.ok(body);
    }

    private Map<String, Object> taskJson(TaskRow task, List<Map<String, Object>> events) {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("taskId", task.id());
        body.put("conversationId", task.conversationId());
        body.put("taskName", task.taskName());
        body.put("status", task.status());
        body.put("progress", task.progress());
        body.put("workspacePath", task.workspacePath());
        body.put("result", json(task.resultJson()));
        body.put("errorCode", task.errorCode());
        body.put("errorMessage", task.errorMessage());
        body.put("createdAt", ts(task.createdAt()));
        body.put("startedAt", ts(task.startedAt()));
        body.put("finishedAt", ts(task.finishedAt()));
        if (events != null) {
            body.put("events", events);
        }
        return body;
    }

    /**
     * M2.1-A1: the task timeline is built from {@code task_events} rows attributed to the task
     * (ordered by the conversation-level seq), not from a message-window heuristic anymore.
     */
    private List<Map<String, Object>> buildEvents(TaskRow task) {
        return jdbc.query(
                "SELECT seq, type, kind, payload, created_at FROM task_events "
                        + "WHERE task_id = ? ORDER BY seq ASC LIMIT ?",
                (rs, rowNum) -> eventJson(rs, true), task.id(), MAX_TASK_EVENTS);
    }

    /**
     * Maps one {@code task_events} row. {@code forTimeline} adds the display fields used by
     * {@code GET /tasks/{id}} ({@code title/detail/tool}) while both variants always expose the
     * M2.1 catch-up shape ({@code seq/type/kind/payload/createdAt}).
     */
    private Map<String, Object> eventJson(ResultSet rs, boolean forTimeline) throws SQLException {
        Map<String, Object> event = new LinkedHashMap<>();
        String type = rs.getString("type");
        String kind = rs.getString("kind");
        JsonNode payload = json(rs.getString("payload"));
        String createdAt = ts(rs, "created_at");
        event.put("seq", rs.getLong("seq"));
        event.put("type", type);
        event.put("kind", kind);
        event.put("payload", payload == null ? mapper.createObjectNode() : payload);
        if (forTimeline) {
            event.put("title", titleOf(type, kind, payload));
            event.put("tool", toolOf(type, payload));
            event.put("detail", detailOf(type, kind, payload));
            event.put("at", createdAt);
        }
        event.put("createdAt", createdAt);
        return event;
    }

    private String titleOf(String type, String kind, JsonNode payload) {
        String state = textOf(payload, "state");
        String tool = textOf(payload, "tool");
        return switch (type == null ? "" : type) {
            case "prompt.send" -> "用户指令";
            case "conversation.created" -> "会话创建";
            case "task.state" -> switch (state == null ? "" : state) {
                case "queued" -> "排队中";
                case "running" -> "执行中";
                case "waiting_approval" -> "等待审批";
                case "paused" -> "已暂停";
                case "completed" -> "任务完成";
                case "failed" -> "任务失败";
                case "cancelled" -> "任务已取消";
                default -> "任务状态";
            };
            case "approval.request" -> "审批请求";
            case "approval.resolved" -> "审批结果";
            case "backfill" -> "历史消息";
            case "session.update" -> switch (kind == null ? "" : kind) {
                case "tool_call" -> tool == null || tool.isBlank() ? "工具调用" : tool;
                case "tool_call_update" -> "工具结果";
                case "output" -> "输出";
                case "thinking" -> "思考";
                case "usage" -> "上下文用量";
                default -> "会话更新";
            };
            default -> type;
        };
    }

    private String toolOf(String type, JsonNode payload) {
        if ("session.update".equals(type) || "approval.request".equals(type)) {
            return cut(textOf(payload, "tool"));
        }
        return null;
    }

    private String detailOf(String type, String kind, JsonNode payload) {
        if (payload == null || !payload.isObject()) {
            return null;
        }
        switch (type == null ? "" : type) {
            case "prompt.send", "backfill":
                return cut(textOf(payload, "text"));
            case "conversation.created":
                return cut(textOf(payload, "title"));
            case "task.state":
                return cut(joinNonBlank(textOf(payload.get("detail"), "code"),
                        textOf(payload.get("detail"), "message")));
            case "approval.request":
                return cut(joinNonBlank(textOf(payload, "tool"), commandOf(payload.get("input"))));
            case "approval.resolved":
                return cut(joinNonBlank(textOf(payload, "decision"), textOf(payload, "decidedBy")));
            case "session.update":
                return switch (kind == null ? "" : kind) {
                    case "tool_call" -> cut(commandOf(payload.get("input")));
                    case "tool_call_update" -> cut(joinNonBlank(textOf(payload, "status"),
                            textOf(payload, "resultExcerpt")));
                    case "output", "thinking" -> cut(textOf(payload, "text"));
                    default -> null;
                };
            default:
                return null;
        }
    }

    /** Summarizes a tool input: prefer {@code command}, then the raw text/JSON. */
    private String commandOf(JsonNode input) {
        if (input == null || input.isNull()) {
            return null;
        }
        JsonNode command = input.get("command");
        if (command != null && !command.isNull()) {
            return command.isTextual() ? command.asText() : command.toString();
        }
        return input.isTextual() ? input.asText() : input.toString();
    }

    private static String joinNonBlank(String first, String second) {
        String a = first == null ? "" : first;
        String b = second == null ? "" : second;
        if (a.isBlank()) {
            return b.isBlank() ? null : b;
        }
        return b.isBlank() ? a : a + ": " + b;
    }

    private static String textOf(JsonNode node, String field) {
        if (node == null || !node.isObject()) {
            return null;
        }
        JsonNode value = node.get(field);
        if (value == null || value.isNull()) {
            return null;
        }
        return value.isValueNode() ? value.asText() : value.toString();
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------

    private record TaskRow(String id, String conversationId, String taskName, String status, int progress,
                           String workspacePath, String resultJson, String errorCode, String errorMessage,
                           OffsetDateTime createdAt, OffsetDateTime startedAt, OffsetDateTime finishedAt) {
    }

    private RowMapper<TaskRow> taskRowMapper() {
        return (rs, rowNum) -> new TaskRow(
                rs.getString("id"),
                rs.getString("conversation_id"),
                rs.getString("task_name"),
                rs.getString("task_status"),
                rs.getInt("progress"),
                rs.getString("workspace_path"),
                rs.getString("result"),
                rs.getString("error_code"),
                rs.getString("error_message"),
                rs.getObject("created_at", OffsetDateTime.class),
                rs.getObject("started_at", OffsetDateTime.class),
                rs.getObject("finished_at", OffsetDateTime.class));
    }

    private TokenStore.TokenInfo authenticate(String authorization) {
        if (authorization == null || !authorization.regionMatches(true, 0, "Bearer ", 0, 7)) {
            return null;
        }
        return tokenStore.validate(authorization.substring(7).trim());
    }

    private List<String> parseStatuses(String status) {
        if (status == null || status.isBlank()) {
            return List.of();
        }
        List<String> statuses = new ArrayList<>();
        for (String part : status.split(",")) {
            String value = part.trim();
            if (value.isEmpty()) {
                continue;
            }
            if (!TASK_STATUSES.contains(value)) {
                return null;
            }
            statuses.add(value);
        }
        return statuses;
    }

    private int effectiveLimit(Integer limit) {
        int value = limit == null ? defaultLimit : limit;
        if (value <= 0) {
            value = defaultLimit;
        }
        return Math.min(value, maxLimit);
    }

    private JsonNode json(String raw) {
        if (raw == null || raw.isBlank()) {
            return null;
        }
        try {
            return mapper.readTree(raw);
        } catch (Exception e) {
            log.debug("history json parse failed: {}", e.toString());
            return null;
        }
    }

    private static String ts(ResultSet rs, String column) throws SQLException {
        return ts(rs.getObject(column, OffsetDateTime.class));
    }

    private static String ts(OffsetDateTime value) {
        return value == null ? null : TS_FORMAT.format(value.toInstant());
    }

    private static String cut(String value) {
        if (value == null) {
            return null;
        }
        return value.length() <= MAX_DETAIL_CHARS ? value : value.substring(0, MAX_DETAIL_CHARS);
    }

    private static ResponseEntity<Map<String, Object>> unauthorized() {
        return error(HttpStatus.UNAUTHORIZED, "AUTH_FAILED", "missing or invalid bearer token");
    }

    private static ResponseEntity<Map<String, Object>> error(HttpStatus status, String code, String message) {
        Map<String, Object> error = new LinkedHashMap<>();
        error.put("code", code);
        error.put("message", message);
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("error", error);
        log.info("history error status={} code={} message={}", status.value(), code, message);
        return ResponseEntity.status(status).body(body);
    }

    @ExceptionHandler(DataAccessException.class)
    public ResponseEntity<Map<String, Object>> databaseUnavailable(DataAccessException exception) {
        log.warn("history database error: {}", exception.toString());
        return error(HttpStatus.INTERNAL_SERVER_ERROR, "INTERNAL", "database unavailable");
    }
}
