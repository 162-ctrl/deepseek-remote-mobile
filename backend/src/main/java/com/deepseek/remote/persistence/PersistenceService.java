package com.deepseek.remote.persistence;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import jakarta.annotation.PreDestroy;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.dao.EmptyResultDataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Persistence side-car for the relay (contracts: {@code docs/design/M1_1_DELTA.md} section 4 and
 * {@code docs/design/M2_1_DELTA.md} sections 2-3).
 *
 * <p>Design rules:
 * <ul>
 *   <li>the relay always forwards first; the actual row writes run on one background worker thread
 *       so a slow/unavailable database can never stall the WebSocket path (failures are only
 *       logged);</li>
 *   <li>the worker is single threaded, therefore the order of persisted events equals the order in
 *       which the relay received them (prompt before its task.state/running, tool_call before its
 *       tool_call_update, ...);</li>
 *   <li>M2.1: the relay allocates the conversation-level {@code seq} synchronously through
 *       {@link #allocateSeq(String)} ({@code conversations.next_seq} atomic UPDATE ... RETURNING)
 *       before forwarding an App-visible event; the same number is used for the websocket envelope
 *       and for the {@code task_events} row (and for the message derived from that event). Every
 *       allocated seq gets exactly one {@code task_events} row, which keeps the per-conversation
 *       seq space gapless;</li>
 *   <li>{@code thinking} events are written to {@code task_events} only (never to messages);
 *       assistant output is aggregated in memory per conversation and written as one message when
 *       the task reaches a terminal state (max 8000 chars, failed/cancelled keep the partial text
 *       with {@code metadata.partial=true}).</li>
 * </ul>
 */
@Component
public class PersistenceService {

    private static final Logger log = LoggerFactory.getLogger(PersistenceService.class);

    /** DELTA section 4: assistant output aggregation cap. */
    private static final int MAX_OUTPUT_CHARS = 8000;
    /** Hard memory cap for the in-memory aggregator (the DB write still truncates to 8000). */
    private static final int MAX_OUTPUT_BUFFER_CHARS = 32_000;
    private static final int MAX_TOOL_RESULT_CHARS = 8000;
    private static final int MAX_TOOL_INPUT_CHARS = 4000;

    private final JdbcTemplate jdbc;
    private final ObjectMapper mapper;
    private final ExecutorService worker;
    private final boolean enabled;

    /** Lazily resolved seed user id ({@code u_self} inserted by V2__seed.sql). */
    private volatile String seedUserId;
    private volatile boolean seedUserLookupFailed;

    /** conversationId -> current (unfinished) task id. */
    private final Map<String, String> currentTaskByConversation = new ConcurrentHashMap<>();
    /** conversationId -> assistant output aggregation buffer for the current task. */
    private final Map<String, StringBuilder> outputByConversation = new ConcurrentHashMap<>();
    /** conversationId + '|' + callId -> persisted tool_call message. */
    private final Map<String, ToolCall> toolCalls = new ConcurrentHashMap<>();
    /**
     * conversationId -> last seq handed to the relay. Normally the database is the allocator
     * ({@code conversations.next_seq}); this counter is the floor used when the database write
     * fails so the forwarding path always gets a monotonically increasing number.
     */
    private final Map<String, AtomicLong> relaySeqFloor = new ConcurrentHashMap<>();

    private record ToolCall(String messageId, String toolName, long startedAtNanos) {
    }

    public PersistenceService(JdbcTemplate jdbc,
                              ObjectMapper mapper,
                              @Value("${m1.db.persist-enabled:true}") boolean enabled) {
        this.jdbc = jdbc;
        this.mapper = mapper;
        this.enabled = enabled;
        this.worker = Executors.newSingleThreadExecutor(runnable -> {
            Thread thread = new Thread(runnable, "m1-persist");
            thread.setDaemon(false);
            return thread;
        });
        log.info("persistence ready: enabled={}", enabled);
    }

    public boolean isEnabled() {
        return enabled;
    }

    // ------------------------------------------------------------------
    // M2.1: conversation-level seq + task_events
    // ------------------------------------------------------------------

    /**
     * Allocates the next conversation-level {@code seq} (M2.1 DELTA section 2).
     *
     * <p>Called synchronously from the relay <b>before</b> an App-visible event is forwarded:
     * {@code UPDATE conversations SET next_seq = GREATEST(next_seq, <relay floor>) + 1 RETURNING
     * next_seq}. The database row lock makes this the single allocator, also when an app prompt and
     * an agent event race. When the conversation row is missing or the database is unavailable the
     * relay-local counter keeps the stream monotonic and the relay keeps forwarding (only WARN).
     */
    public long allocateSeq(String conversationId) {
        if (conversationId == null || conversationId.isBlank()) {
            return 0L;
        }
        AtomicLong local = relaySeqFloor.computeIfAbsent(conversationId, key -> new AtomicLong());
        long floor = local.get();
        if (!enabled) {
            return local.incrementAndGet();
        }
        try {
            Long next = jdbc.queryForObject(
                    "UPDATE conversations SET next_seq = GREATEST(next_seq, ?) + 1, updated_at = now() "
                            + "WHERE id = ? RETURNING next_seq",
                    Long.class, floor, conversationId);
            if (next != null) {
                local.accumulateAndGet(next, Math::max);
                return next;
            }
        } catch (EmptyResultDataAccessException e) {
            log.warn("persist seq: conversation {} has no row yet, relay-local seq is used", conversationId);
        } catch (Exception e) {
            log.warn("persist seq allocation failed conversation={} (relay continues): {}",
                    conversationId, e.toString());
        }
        return local.incrementAndGet();
    }

    /**
     * Persists one App-visible conversation event in {@code task_events} (M2.1 DELTA section 2).
     *
     * <p>The task id is captured when the relay calls this method (not on the worker thread) so an
     * event that belongs to the current turn is attributed correctly even if the terminal
     * {@code task.state} is processed right after it. Writing runs on the single-threaded FIFO
     * worker; failures are logged only.
     */
    public void onTaskEvent(String conversationId, long seq, String type, String kind, JsonNode payload) {
        if (!enabled || conversationId == null || seq <= 0) {
            return;
        }
        JsonNode copy = payload == null || payload.isNull()
                ? mapper.createObjectNode()
                : payload.deepCopy();
        String taskId = currentTaskByConversation.get(conversationId);
        submit("task_event/" + type, () -> doTaskEvent(conversationId, seq, type, kind, copy, taskId));
    }

    private void doTaskEvent(String conversationId, long seq, String type, String kind,
                             JsonNode payload, String taskId) {
        insertTaskEvent(conversationId, seq, type, kind, payload, taskId);
        log.info("persist task_event conversation={} seq={} type={} kind={} task={}",
                conversationId, seq, type, kind, taskId);
    }

    /** Inserts one task_events row; the unique (conversation_id, seq) constraint makes it idempotent. */
    private void insertTaskEvent(String conversationId, long seq, String type, String kind,
                                 JsonNode payload, String taskId) {
        jdbc.update("INSERT INTO task_events (id, conversation_id, task_id, seq, type, kind, payload, "
                        + "created_at) VALUES (?, ?, ?, ?, ?, ?, CAST(? AS jsonb), now()) "
                        + "ON CONFLICT (conversation_id, seq) DO NOTHING",
                Ulid.newId(), conversationId, taskId, seq, cut(type, 48), cut(kind, 32),
                payload == null ? "{}" : payload.toString());
    }

    // ------------------------------------------------------------------
    // pairing / device
    // ------------------------------------------------------------------

    /**
     * Resolves the stable 26-char device id for the single-user agent (DELTA section 2).
     *
     * <p>Called synchronously from {@code /auth/pair}: it reuses the existing device row so a
     * reconnect does not create a new id. On any database problem it falls back to a fresh ULID so
     * pairing itself never fails because of persistence.
     */
    public String resolveAgentDevice(String clientName) {
        String fallback = Ulid.newId();
        if (!enabled) {
            return fallback;
        }
        try {
            String userId = seedUserId();
            String name = cut(blankToNull(clientName) == null ? "remote-agent" : clientName.trim(), 64);
            List<String> ids = jdbc.queryForList(
                    "SELECT id FROM devices WHERE device_name = ? ORDER BY created_at DESC LIMIT 1",
                    String.class, name);
            if (ids.isEmpty()) {
                // Single-user mode: if the agent machine got renamed, keep reusing the one device row.
                ids = jdbc.queryForList("SELECT id FROM devices ORDER BY created_at DESC LIMIT 1", String.class);
            }
            if (!ids.isEmpty()) {
                String id = ids.get(0);
                if (userId != null) {
                    jdbc.update("UPDATE devices SET device_name = ?, user_id = COALESCE(user_id, ?), "
                                    + "device_status = 'active', last_online_at = now() WHERE id = ?",
                            name, userId, id);
                } else {
                    jdbc.update("UPDATE devices SET device_name = ?, device_status = 'active', "
                            + "last_online_at = now() WHERE id = ?", name, id);
                }
                log.info("persist device reused id={} name={}", id, name);
                return id;
            }
            String id = Ulid.newId();
            jdbc.update("INSERT INTO devices (id, user_id, device_name, operating_system, agent_version, "
                            + "device_status, last_online_at, capabilities, remote_enabled, created_at, updated_at) "
                            + "VALUES (?, ?, ?, 'unknown', 'unknown', 'active', now(), '{}'::jsonb, true, now(), now())",
                    id, userId, name);
            log.info("persist device inserted id={} name={}", id, name);
            return id;
        } catch (Exception e) {
            log.warn("persist device resolve failed, pair falls back to in-memory id: {}", e.toString());
            return fallback;
        }
    }

    /** Applies an Agent {@code device.status} payload to the device row. */
    public void onDeviceStatus(String deviceId, JsonNode payload) {
        if (!enabled || payload == null || !payload.isObject()) {
            return;
        }
        submit("device.status", () -> doDeviceStatus(deviceId, payload));
    }

    private void doDeviceStatus(String deviceId, JsonNode payload) {
        if (!Ulid.isValid(deviceId)) {
            log.debug("persist device.status skipped: not a persisted deviceId={}", deviceId);
            return;
        }
        String name = cut(textOf(payload, "deviceName"), 64);
        String agentVersion = cut(textOf(payload, "agentVersion"), 32);
        String harnessVersion = cut(textOf(payload, "harnessVersion"), 64);
        JsonNode capabilities = payload.get("capabilities");
        String capabilitiesJson = capabilities != null && capabilities.isObject() ? capabilities.toString() : "{}";
        ensureDevice(deviceId, name == null ? "remote-agent" : name);
        jdbc.update("UPDATE devices SET device_name = COALESCE(?, device_name), "
                        + "agent_version = COALESCE(?, agent_version), "
                        + "harness_version = COALESCE(?, harness_version), "
                        + "capabilities = CAST(? AS jsonb), last_online_at = now(), "
                        + "device_status = 'active', updated_at = now() WHERE id = ?",
                name, agentVersion, harnessVersion, capabilitiesJson, deviceId);
        log.info("persist device.status deviceId={} agentVersion={} harnessVersion={}",
                deviceId, agentVersion, harnessVersion);
    }

    // ------------------------------------------------------------------
    // conversation / prompt
    // ------------------------------------------------------------------

    /**
     * Persists the conversation row when the agent acknowledged {@code conversation.create}.
     *
     * <p>M2.1: runs synchronously because the relay must allocate the first {@code seq} of the
     * conversation right after it (a missing row would push the seq allocation into the fallback
     * path). It is a single small upsert and never throws: failures are logged, forwarding goes on.
     */
    public void onConversationCreated(String conversationId,
                                      String sessionId,
                                      String workspacePath,
                                      String title,
                                      String deviceId) {
        if (!enabled) {
            return;
        }
        try {
            doConversationCreated(conversationId, sessionId, workspacePath, title, deviceId);
        } catch (Exception e) {
            log.warn("persist conversation.created failed (relay unaffected): {}", e.toString());
        }
    }

    private void doConversationCreated(String conversationId, String sessionId, String workspacePath,
                                       String title, String deviceId) {
        if (!Ulid.isValid(conversationId)) {
            log.warn("persist conversation skipped: invalid conversationId={}", conversationId);
            return;
        }
        String userId = seedUserId();
        if (userId == null) {
            log.warn("persist conversation skipped: seed user u_self is missing");
            return;
        }
        if (!Ulid.isValid(deviceId)) {
            log.warn("persist conversation {} skipped: no persisted deviceId", conversationId);
            return;
        }
        ensureDevice(deviceId, "remote-agent");
        String workspace = cut(blankToNull(workspacePath), 1024);
        String effectiveTitle = blankToNull(title) == null ? defaultTitle(workspacePath) : title.trim();
        effectiveTitle = cut(effectiveTitle, 120);
        jdbc.update("INSERT INTO conversations (id, user_id, device_id, harness_session_id, title, "
                        + "workspace_path, session_state, message_count, created_at, updated_at) "
                        + "VALUES (?, ?, ?, ?, ?, ?, 'active', 0, now(), now()) "
                        + "ON CONFLICT (id) DO UPDATE SET harness_session_id = EXCLUDED.harness_session_id, "
                        + "workspace_path = EXCLUDED.workspace_path, title = EXCLUDED.title, updated_at = now()",
                conversationId, userId, deviceId, cut(blankToNull(sessionId), 128), effectiveTitle, workspace);
        log.info("persist conversation id={} title={} workspace={}", conversationId, effectiveTitle, workspace);
    }

    /**
     * Persists an app {@code prompt.send}: one user message, one queued task and the matching
     * {@code prompt.send} task_events row, all using the conversation-level {@code seq} that the
     * relay already put into the forwarded envelope (M2.1 DELTA section 2).
     *
     * <p>Runs synchronously: later agent events must find the new current task id in
     * {@link #currentTaskByConversation} so their {@code task_events.task_id} attribution is
     * race-free. It is a few small statements and never throws; failures are logged only.
     */
    public void onPromptSend(String conversationId, String text, long seq) {
        if (!enabled) {
            return;
        }
        try {
            doPromptSend(conversationId, text, seq);
        } catch (Exception e) {
            log.warn("persist prompt.send failed (relay unaffected): {}", e.toString());
        }
    }

    private void doPromptSend(String conversationId, String text, long seq) {
        if (!Ulid.isValid(conversationId)) {
            log.warn("persist prompt.send skipped: invalid conversationId={}", conversationId);
            return;
        }
        if (seq <= 0) {
            log.warn("persist prompt.send skipped: no seq allocated for conversation={}", conversationId);
        }
        String prompt = text == null ? "" : text;
        insertMessage(conversationId, "user", prompt, "text", seq, null, "{}");

        List<Map<String, Object>> rows = jdbc.queryForList(
                "SELECT user_id, device_id FROM conversations WHERE id = ?", conversationId);
        if (rows.isEmpty()) {
            log.warn("persist prompt.send: conversation {} disappeared", conversationId);
            return;
        }
        String userId = asText(rows.get(0).get("user_id"));
        String deviceId = asText(rows.get(0).get("device_id"));

        String taskId = Ulid.newId();
        String taskName = cutCodePoints(prompt.strip(), 40);
        if (taskName.isBlank()) {
            taskName = "新任务";
        }
        ObjectNode payload = mapper.createObjectNode();
        payload.put("prompt", cutCodePoints(prompt, 4000));
        jdbc.update("INSERT INTO tasks (id, user_id, device_id, conversation_id, task_name, task_type, "
                        + "task_status, progress, payload, permission_level, created_at, updated_at) "
                        + "VALUES (?, ?, ?, ?, ?, 'chat', 'queued', 0, CAST(? AS jsonb), 2, now(), now())",
                taskId, userId, deviceId, conversationId, taskName, payload.toString());
        currentTaskByConversation.put(conversationId, taskId);
        outputByConversation.put(conversationId, new StringBuilder());
        clearToolCalls(conversationId);

        // M2.1: every conversation-level seq must have exactly one task_events row (no holes).
        // The user prompt is forwarded to the App, so it is a first-class timeline event.
        if (seq > 0) {
            ObjectNode event = mapper.createObjectNode();
            event.put("seq", seq);
            event.put("text", cutCodePoints(prompt, 4000));
            if (taskId != null) {
                event.put("taskId", taskId);
            }
            insertTaskEvent(conversationId, seq, "prompt.send", null, event, taskId);
        }
        log.info("persist prompt conversation={} task={} userMessageSeq={}", conversationId, taskId, seq);
    }

    /**
     * Marks the task created for a prompt as failed when the relay cannot reach the Agent.
     *
     * <p>The {@code prompt.send} event row was written before forwarding, so the conversation-level
     * seq space stays gapless; only the turn itself never starts.
     */
    public void onPromptForwardFailed(String conversationId, long seq, String message) {
        if (!enabled || conversationId == null) {
            return;
        }
        submit("prompt.forward_failed", () -> doPromptForwardFailed(conversationId, seq, message));
    }

    private void doPromptForwardFailed(String conversationId, long seq, String message) {
        String taskId = currentTaskByConversation.get(conversationId);
        if (taskId == null) {
            log.warn("persist prompt forward failure ignored: no active task for conversation {}", conversationId);
            return;
        }
        String errorMessage = blankToNull(message) == null ? "prompt forward failed" : message;
        jdbc.update("UPDATE tasks SET task_status = 'failed', finished_at = now(), error_code = ?, "
                        + "error_message = ?, updated_at = now() WHERE id = ?",
                "INTERNAL", cut(errorMessage, 4000), taskId);
        clearTurn(conversationId);
        log.warn("persist prompt forward failed conversation={} seq={} task={}", conversationId, seq, taskId);
    }

    // ------------------------------------------------------------------
    // agent session events
    // ------------------------------------------------------------------

    /**
     * Handles one Agent {@code session.update}. {@code output} feeds the in-memory aggregator,
     * tool events become messages keyed by the event seq; {@code thinking}/{@code usage} reach only
     * {@code task_events} (written by the relay via {@link #onTaskEvent}).
     */
    public void onSessionUpdate(String conversationId, String kind, long seq, JsonNode payload) {
        if (!enabled || kind == null) {
            return;
        }
        switch (kind) {
            case "output" -> submit("session.update/output", () -> doOutput(conversationId, payload));
            case "tool_call" ->
                    submit("session.update/tool_call", () -> doToolCall(conversationId, payload, seq));
            case "tool_call_update" -> submit("session.update/tool_call_update",
                    () -> doToolCallUpdate(conversationId, payload, seq));
            default -> {
                // thinking / usage: task_events only (no messages row).
            }
        }
    }

    private void doOutput(String conversationId, JsonNode payload) {
        String text = textOf(payload, "text");
        if (text == null || !Ulid.isValid(conversationId)) {
            return;
        }
        StringBuilder buffer = outputByConversation.computeIfAbsent(conversationId, key -> new StringBuilder());
        buffer.append(text);
        if (buffer.length() > MAX_OUTPUT_BUFFER_CHARS) {
            buffer.setLength(MAX_OUTPUT_BUFFER_CHARS);
        }
    }

    private void doToolCall(String conversationId, JsonNode payload, long seq) {
        if (!Ulid.isValid(conversationId)) {
            return;
        }
        String callId = textOf(payload, "callId");
        String tool = cut(textOf(payload, "tool"), 64);
        String inputText = cut(toolInputText(payload.get("input")), MAX_TOOL_INPUT_CHARS);
        ObjectNode content = mapper.createObjectNode();
        content.put("tool", tool == null ? "tool" : tool);
        content.put("input", inputText);
        ObjectNode metadata = mapper.createObjectNode();
        if (callId != null) {
            metadata.put("callId", callId);
        }
        metadata.put("status", "pending");
        String messageId = insertMessage(conversationId, "tool", content.toString(), "tool_call", seq,
                tool, metadata.toString());
        if (callId != null) {
            toolCalls.put(toolKey(conversationId, callId), new ToolCall(messageId, tool, System.nanoTime()));
        }
        log.info("persist tool_call conversation={} tool={} callId={} seq={}",
                conversationId, tool, callId, seq);
    }

    private void doToolCallUpdate(String conversationId, JsonNode payload, long seq) {
        if (!Ulid.isValid(conversationId)) {
            return;
        }
        String callId = textOf(payload, "callId");
        if (callId == null) {
            return;
        }
        ToolCall call = toolCalls.get(toolKey(conversationId, callId));
        if (call == null) {
            log.debug("persist tool_call_update without matching tool_call conversation={} callId={}",
                    conversationId, callId);
            return;
        }
        String status = textOf(payload, "status");
        String resultExcerpt = textOf(payload, "resultExcerpt");
        ObjectNode metadata = mapper.createObjectNode();
        if (status != null) {
            metadata.put("status", status);
        }
        metadata.put("durationMs", (System.nanoTime() - call.startedAtNanos()) / 1_000_000L);
        jdbc.update("UPDATE messages SET metadata = metadata || CAST(? AS jsonb) WHERE id = ?",
                metadata.toString(), call.messageId());
        if (("completed".equals(status) || "failed".equals(status))) {
            if (resultExcerpt != null && !resultExcerpt.isBlank()) {
                ObjectNode resultMetadata = mapper.createObjectNode();
                resultMetadata.put("callId", callId);
                resultMetadata.put("status", status);
                insertMessage(conversationId, "tool", cutCodePoints(resultExcerpt, MAX_TOOL_RESULT_CHARS),
                        "tool_result", seq, call.toolName(), resultMetadata.toString());
            }
            toolCalls.remove(toolKey(conversationId, callId));
        }
        log.info("persist tool_call_update conversation={} callId={} status={} seq={}",
                conversationId, callId, status, seq);
    }

    // ------------------------------------------------------------------
    // task state machine + assistant output flush
    // ------------------------------------------------------------------

    /**
     * Applies an Agent {@code task.state} event to the current task of the conversation.
     *
     * @param seq the conversation-level seq already allocated for this terminal event; the assistant
     *            message written on {@code completed} reuses it (M2.1: derived message shares the
     *            seq of the event it belongs to)
     */
    public void onTaskState(String conversationId, String state, String detailCode, String detailMessage,
                            long seq) {
        if (!enabled || state == null) {
            return;
        }
        submit("task.state/" + state,
                () -> doTaskState(conversationId, state, detailCode, detailMessage, seq));
    }

    private void doTaskState(String conversationId, String state, String detailCode, String detailMessage,
                             long seq) {
        String taskId = currentTaskByConversation.get(conversationId);
        if (taskId == null) {
            log.warn("persist task.state {} ignored: no active task for conversation {}", state, conversationId);
            return;
        }
        StringBuilder buffer = outputByConversation.get(conversationId);
        String aggregated = buffer == null ? "" : buffer.toString();
        switch (state) {
            case "queued" -> jdbc.update(
                    "UPDATE tasks SET task_status = 'queued', updated_at = now() WHERE id = ?", taskId);
            case "running" -> jdbc.update(
                    "UPDATE tasks SET task_status = 'running', progress = GREATEST(progress, 10), "
                            + "started_at = COALESCE(started_at, now()), updated_at = now() WHERE id = ?", taskId);
            case "waiting_approval" -> jdbc.update(
                    "UPDATE tasks SET task_status = 'waiting_approval', progress = GREATEST(progress, 50), "
                            + "updated_at = now() WHERE id = ?", taskId);
            case "paused" -> jdbc.update(
                    "UPDATE tasks SET task_status = 'paused', updated_at = now() WHERE id = ?", taskId);
            case "completed" -> {
                jdbc.update("UPDATE tasks SET task_status = 'completed', progress = 100, "
                                + "started_at = COALESCE(started_at, now()), finished_at = now(), "
                                + "result = CAST(? AS jsonb), error_code = NULL, error_message = NULL, "
                                + "updated_at = now() WHERE id = ?",
                        resultNode(summaryOf(aggregated), false).toString(), taskId);
                appendAssistantMessage(conversationId, aggregated, false, seq);
                clearTurn(conversationId);
                log.info("persist task completed id={} outputChars={}", taskId, aggregated.length());
            }
            case "failed" -> {
                boolean hasOutput = !aggregated.isBlank();
                jdbc.update("UPDATE tasks SET task_status = 'failed', "
                                + "started_at = COALESCE(started_at, now()), finished_at = now(), "
                                + "result = CAST(? AS jsonb), error_code = ?, error_message = ?, "
                                + "updated_at = now() WHERE id = ?",
                        hasOutput ? resultNode(summaryOf(aggregated), true).toString() : null,
                        cut(detailCode, 32),
                        cut(blankToNull(detailMessage) == null ? "task failed" : detailMessage, 4000),
                        taskId);
                if (hasOutput) {
                    appendAssistantMessage(conversationId, aggregated, true, seq);
                }
                clearTurn(conversationId);
                log.info("persist task failed id={} code={} outputChars={}", taskId, detailCode, aggregated.length());
            }
            case "cancelled" -> {
                boolean hasOutput = !aggregated.isBlank();
                jdbc.update("UPDATE tasks SET task_status = 'cancelled', "
                                + "started_at = COALESCE(started_at, now()), finished_at = now(), "
                                + "result = CAST(? AS jsonb), error_code = ?, error_message = ?, "
                                + "updated_at = now() WHERE id = ?",
                        hasOutput ? resultNode(summaryOf(aggregated), true).toString() : null,
                        blankToNull(detailCode) == null ? "CANCELLED" : cut(detailCode, 32),
                        cut(blankToNull(detailMessage) == null ? "task cancelled" : detailMessage, 4000),
                        taskId);
                if (hasOutput) {
                    appendAssistantMessage(conversationId, aggregated, true, seq);
                }
                clearTurn(conversationId);
                log.info("persist task cancelled id={} outputChars={}", taskId, aggregated.length());
            }
            default -> log.warn("persist unknown task.state state={} conversation={}", state, conversationId);
        }
    }

    private void appendAssistantMessage(String conversationId, String aggregated, boolean partial, long seq) {
        String content = cutCodePoints(aggregated == null ? "" : aggregated.strip(), MAX_OUTPUT_CHARS);
        if (partial && content.isBlank()) {
            return;
        }
        if (seq <= 0) {
            log.warn("persist assistant message skipped: no seq for conversation {}", conversationId);
            return;
        }
        ObjectNode metadata = mapper.createObjectNode();
        metadata.put("partial", partial);
        insertMessage(conversationId, "assistant", content, "text", seq, null, metadata.toString());
        log.info("persist assistant message conversation={} seq={} chars={} partial={}",
                conversationId, seq, content.length(), partial);
    }

    private void clearTurn(String conversationId) {
        currentTaskByConversation.remove(conversationId);
        outputByConversation.remove(conversationId);
        clearToolCalls(conversationId);
    }

    // ------------------------------------------------------------------
    // audit
    // ------------------------------------------------------------------

    /** Records an app {@code approval.decide} in {@code audit_logs} (DELTA section 4, P-4). */
    public void onApprovalDecide(String conversationId, String approvalId, String decision,
                                 String decidedBy, String deviceId) {
        if (!enabled) {
            return;
        }
        submit("approval.decision",
                () -> doApprovalDecide(conversationId, approvalId, decision, decidedBy, deviceId));
    }

    private void doApprovalDecide(String conversationId, String approvalId, String decision,
                                  String decidedBy, String deviceId) {
        String actionResult = switch (decision == null ? "" : decision) {
            case "approved" -> "success";
            case "denied" -> "denied";
            default -> "failed";
        };
        ObjectNode detail = mapper.createObjectNode();
        if (approvalId != null) {
            detail.put("approvalId", approvalId);
        }
        if (decision != null) {
            detail.put("decision", decision);
        }
        if (decidedBy != null) {
            detail.put("decidedBy", decidedBy);
        }
        if (conversationId != null) {
            detail.put("conversationId", conversationId);
        }
        jdbc.update("INSERT INTO audit_logs (id, user_id, device_id, action_type, action_result, "
                        + "target_type, target_id, action_detail, severity, created_at) "
                        + "VALUES (?, ?, ?, 'approval.decision', ?, 'approval', ?, CAST(? AS jsonb), 'info', now())",
                Ulid.newId(), seedUserId(), Ulid.isValid(deviceId) ? deviceId : null,
                actionResult, cut(approvalId, 64), detail.toString());
        log.info("persist audit approval.decision approvalId={} decision={} result={}",
                approvalId, decision, actionResult);
    }

    // ------------------------------------------------------------------
    // low level helpers (worker thread only)
    // ------------------------------------------------------------------

    private String insertMessage(String conversationId, String role, String content, String contentType,
                                 long seq, String toolName, String metadataJson) {
        String messageId = Ulid.newId();
        jdbc.update("INSERT INTO messages (id, conversation_id, role, content, content_type, "
                        + "seq_in_conversation, tool_name, metadata, created_at) "
                        + "VALUES (?, ?, ?, ?, ?, ?, ?, CAST(? AS jsonb), now())",
                messageId, conversationId, role, content == null ? "" : content, contentType, seq,
                toolName, metadataJson == null ? "{}" : metadataJson);
        // M2.1: seq is allocated from conversations.next_seq; this statement only maintains the
        // convenience counters used by GET /conversations.
        jdbc.update("UPDATE conversations SET message_count = message_count + 1, "
                + "last_message_at = now(), updated_at = now() WHERE id = ?", conversationId);
        return messageId;
    }

    private void ensureDevice(String deviceId, String deviceName) {
        if (!Ulid.isValid(deviceId)) {
            return;
        }
        jdbc.update("INSERT INTO devices (id, user_id, device_name, operating_system, agent_version, "
                        + "device_status, last_online_at, capabilities, remote_enabled, created_at, updated_at) "
                        + "VALUES (?, ?, ?, 'unknown', 'unknown', 'active', now(), '{}'::jsonb, true, now(), now()) "
                        + "ON CONFLICT (id) DO NOTHING",
                deviceId, seedUserId(), cut(deviceName, 64));
    }

    /** Resolves (and caches) the M1.1 seed user id; {@code null} when V2__seed.sql is missing. */
    private String seedUserId() {
        String cached = seedUserId;
        if (cached != null) {
            return cached;
        }
        synchronized (this) {
            if (seedUserId != null) {
                return seedUserId;
            }
            if (seedUserLookupFailed && seedUserId == null) {
                // do not hammer the DB on every event; a restart re-applies migrations anyway
                return null;
            }
            try {
                List<String> ids = jdbc.queryForList(
                        "SELECT id FROM users WHERE username = 'u_self' LIMIT 1", String.class);
                if (ids.isEmpty()) {
                    seedUserLookupFailed = true;
                    log.warn("persist seed user 'u_self' not found; have Flyway migrations run?");
                    return null;
                }
                seedUserId = ids.get(0);
                log.info("persist seed user resolved id={}", seedUserId);
                return seedUserId;
            } catch (Exception e) {
                seedUserLookupFailed = true;
                log.warn("persist seed user lookup failed: {}", e.toString());
                return null;
            }
        }
    }

    private void clearToolCalls(String conversationId) {
        String prefix = conversationId + "|";
        toolCalls.keySet().removeIf(key -> key.startsWith(prefix));
    }

    private void submit(String what, Runnable action) {
        if (!enabled) {
            return;
        }
        try {
            worker.execute(() -> {
                try {
                    action.run();
                } catch (Exception e) {
                    log.warn("persist {} failed (relay unaffected): {}", what, e.toString());
                }
            });
        } catch (RejectedExecutionException e) {
            log.warn("persist {} dropped (worker shutting down)", what);
        }
    }

    @PreDestroy
    public void shutdown() {
        worker.shutdown();
        try {
            if (!worker.awaitTermination(5, TimeUnit.SECONDS)) {
                worker.shutdownNow();
                log.warn("persist worker did not drain within 5s");
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            worker.shutdownNow();
        }
        log.info("persistence stopped");
    }

    // ------------------------------------------------------------------
    // tiny utils
    // ------------------------------------------------------------------

    private static String toolKey(String conversationId, String callId) {
        return conversationId + "|" + callId;
    }

    private static String toolInputText(JsonNode input) {
        if (input == null || input.isNull()) {
            return "";
        }
        if (input.isTextual()) {
            return input.asText();
        }
        JsonNode command = input.get("command");
        if (command != null && command.isTextual() && !command.asText().isBlank()) {
            return command.asText();
        }
        return input.toString();
    }

    private String summaryOf(String text) {
        if (text == null || text.isBlank()) {
            return "";
        }
        return cutCodePoints(text.strip().replaceAll("\\s+", " "), 200);
    }

    private ObjectNode resultNode(String summary, boolean partial) {
        ObjectNode result = mapper.createObjectNode();
        result.put("summary", summary == null ? "" : summary);
        if (partial) {
            result.put("partial", true);
        }
        return result;
    }

    private static String defaultTitle(String workspacePath) {
        if (workspacePath == null || workspacePath.isBlank()) {
            return "新对话";
        }
        String path = workspacePath.trim();
        int end = path.length();
        while (end > 0 && (path.charAt(end - 1) == '/' || path.charAt(end - 1) == '\\')) {
            end--;
        }
        if (end == 0) {
            return "新对话";
        }
        int slash = Math.max(path.lastIndexOf('/', end - 1), path.lastIndexOf('\\', end - 1));
        String base = slash >= 0 ? path.substring(slash + 1, end) : path.substring(0, end);
        return base.isBlank() ? "新对话" : cut(base, 120);
    }

    private static String textOf(JsonNode node, String field) {
        if (node == null || !node.isObject()) {
            return null;
        }
        JsonNode value = node.get(field);
        if (value == null || value.isNull()) {
            return null;
        }
        String text = value.asText();
        return text == null || text.isBlank() ? null : text;
    }

    private static String blankToNull(String value) {
        return value == null || value.isBlank() ? null : value;
    }

    private static String asText(Object value) {
        return value == null ? null : value.toString();
    }

    /** Truncates by UTF-16 chars, never splitting a surrogate pair. */
    private static String cut(String value, int max) {
        if (value == null || value.length() <= max) {
            return value;
        }
        int end = max;
        if (Character.isHighSurrogate(value.charAt(end - 1))) {
            end--;
        }
        return value.substring(0, end);
    }

    /** Truncates by Unicode code points (used where the contract says "N 字"). */
    private static String cutCodePoints(String value, int maxCodePoints) {
        if (value == null) {
            return null;
        }
        if (value.codePointCount(0, value.length()) <= maxCodePoints) {
            return value;
        }
        int end = value.offsetByCodePoints(0, maxCodePoints);
        return value.substring(0, end);
    }
}
