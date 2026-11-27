package com.deepseek.remote.ws;

import com.deepseek.remote.persistence.PersistenceService;
import com.deepseek.remote.persistence.Ulid;
import com.deepseek.remote.protocol.CloseCodes;
import com.deepseek.remote.protocol.Envelope;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Central relay state (protocol section 4):
 *
 * <ul>
 *   <li>at most one agent connection (a new one replaces the old one);</li>
 *   <li>any number of app connections, relayed messages are broadcast to all of them;</li>
 *   <li>conversation registry allocating 26-char ULID conversation ids;</li>
 *   <li>cached {@code device.status} snapshot plus {@code agent.online}/{@code agent.offline} events.</li>
 * </ul>
 *
 * <p>Relay state is in memory (restarting clears it); durable history is mirrored to PostgreSQL by
 * {@link PersistenceService} without ever blocking or failing the forwarding path.
 */
@Component
public class RelayHub {

    private static final Logger log = LoggerFactory.getLogger(RelayHub.class);

    /** App -> relay messages forwarded verbatim to the agent (conversation.create gains an id). */
    private static final Set<String> APP_FORWARD_TYPES = Set.of(
            "conversation.create", "prompt.send", "task.cancel", "approval.decide",
            // M2.6 项目同步：工作区浏览 / 文件预览（请求-响应，不落库）
            // M2.8 手机端写入：带 sha256 乐观锁的文件保存
            "workspace.list", "file.read", "file.write");

    /** Agent -> relay messages broadcast to every app connection. */
    private static final Set<String> AGENT_BROADCAST_TYPES = Set.of(
            "conversation.created", "session.update", "task.state", "approval.request",
            "approval.resolved", "device.status", "error",
            // M2.6/M2.8 项目同步：请求-响应结果，仅广播，不分配 seq
            "workspace.list.result", "file.read.result", "file.write.result");

    private static final TypeReference<LinkedHashMap<String, Object>> MAP_TYPE = new TypeReference<>() {
    };

    private final ObjectMapper mapper;
    private final PersistenceService persistence;

    private final Map<String, RelaySession> sessionsById = new ConcurrentHashMap<>();
    private final Map<String, RelaySession> apps = new ConcurrentHashMap<>();
    private final Map<String, Conversation> conversations = new ConcurrentHashMap<>();

    private volatile RelaySession agent;
    private volatile LinkedHashMap<String, Object> cachedDeviceStatus;

    public RelayHub(ObjectMapper mapper, PersistenceService persistence) {
        this.mapper = mapper;
        this.persistence = persistence;
    }

    /** Conversation metadata tracked by the relay (authoritative sessionId lives in the agent). */
    public static final class Conversation {
        public final String conversationId;
        public volatile String sessionId;
        public volatile String workspacePath;
        public volatile String title;
        public final AtomicBoolean busy = new AtomicBoolean(false);

        Conversation(String conversationId, String workspacePath, String title) {
            this.conversationId = conversationId;
            this.workspacePath = workspacePath;
            this.title = title;
        }
    }

    // ------------------------------------------------------------------
    // session bookkeeping
    // ------------------------------------------------------------------

    /** Registers a freshly authenticated websocket connection. */
    public synchronized void register(RelaySession session) {
        sessionsById.put(session.sessionId(), session);
        if ("agent".equals(session.role())) {
            registerAgent(session);
        } else {
            registerApp(session);
        }
    }

    /** Looks up the relay session for a raw websocket session id. */
    public RelaySession bySessionId(String sessionId) {
        return sessionsById.get(sessionId);
    }

    /** Detaches a closed websocket connection and notifies apps when the agent went away. */
    public synchronized void unregister(String sessionId) {
        RelaySession session = sessionsById.remove(sessionId);
        if (session == null) {
            return;
        }
        if ("agent".equals(session.role())) {
            agentOffline(session);
        } else {
            apps.remove(sessionId);
            log.info("app disconnected sessionId={} deviceId={} appsLeft={}",
                    sessionId, session.deviceId(), apps.size());
        }
    }

    private void registerAgent(RelaySession session) {
        RelaySession previous = agent;
        agent = session;
        if (previous != null && !previous.sessionId().equals(session.sessionId())) {
            sessionsById.remove(previous.sessionId());
            log.info("agent replaced oldSessionId={} oldDeviceId={} newSessionId={} newDeviceId={}",
                    previous.sessionId(), previous.deviceId(), session.sessionId(), session.deviceId());
            previous.close(CloseCodes.AGENT_REPLACED);
        }
        log.info("agent connected deviceId={} clientName={}", session.deviceId(), session.clientName());
        broadcast(deviceStatusMessage(true), agentEventMessage("agent.online", session));
    }

    private void registerApp(RelaySession session) {
        apps.put(session.sessionId(), session);
        log.info("app connected sessionId={} deviceId={} clientName={} apps={}",
                session.sessionId(), session.deviceId(), session.clientName(), apps.size());
        // Protocol 4.3: an app receives the current device snapshot immediately after connecting.
        send(session, deviceStatusMessage(isAgentOnline()));
    }

    private void agentOffline(RelaySession session) {
        if (agent == null || !agent.sessionId().equals(session.sessionId())) {
            log.debug("stale agent session closed sessionId={}", session.sessionId());
            return;
        }
        agent = null;
        conversations.values().forEach(conversation -> conversation.busy.set(false));
        log.info("agent disconnected deviceId={} conversations={}", session.deviceId(), conversations.size());
        broadcast(deviceStatusMessage(false), agentEventMessage("agent.offline", session));
    }

    // ------------------------------------------------------------------
    // message dispatch
    // ------------------------------------------------------------------

    /** Dispatches one parsed text frame coming from either role. */
    public void dispatch(RelaySession session, String type, JsonNode root, int bytes) {
        JsonNode payload = root.get("payload");
        String conversationId = textOf(payload, "conversationId");
        log.info("recv role={} type={} conversationId={} bytes={}",
                session.role(), type, dash(conversationId), bytes);
        if ("agent".equals(session.role())) {
            handleAgentMessage(session, type, root, conversationId);
        } else {
            handleAppMessage(session, type, root, conversationId);
        }
    }

    private void handleAppMessage(RelaySession session, String type, JsonNode root, String conversationId) {
        JsonNode payload = root.get("payload");
        if (!APP_FORWARD_TYPES.contains(type)) {
            log.warn("ignoring unknown app message type={} sessionId={}", type, session.sessionId());
            return;
        }
        if (payload == null || !payload.isObject()) {
            sendError(session, "BAD_REQUEST", "payload must be a JSON object", conversationId);
            return;
        }
        switch (type) {
            case "conversation.create" -> handleConversationCreate(session, root, payload);
            case "prompt.send" -> handlePromptSend(session, root);
            case "task.cancel", "approval.decide" -> {
                if (!isAgentOnline()) {
                    sendError(session, "DEVICE_OFFLINE", "agent is not connected", conversationId);
                    return;
                }
                if (forwardToAgent(session, root, conversationId) && "approval.decide".equals(type)) {
                    // DELTA section 4: every phone approval decision is written to audit_logs.
                    persistence.onApprovalDecide(conversationId,
                            textOf(payload, "approvalId"),
                            textOf(payload, "decision"),
                            "phone",
                            session.deviceId());
                }
            }
            case "workspace.list", "file.read", "file.write" -> {
                // M2.6/M2.8: request/response, no seq allocation and no task_events row.
                if (!isAgentOnline()) {
                    sendError(session, "DEVICE_OFFLINE", "agent is not connected", conversationId);
                    return;
                }
                forwardToAgent(session, root, conversationId);
            }
            default -> log.warn("ignoring app message type={}", type);
        }
    }

    private void handleConversationCreate(RelaySession session, JsonNode root, JsonNode payload) {
        if (!isAgentOnline()) {
            sendError(session, "DEVICE_OFFLINE", "agent is not connected", null);
            return;
        }
        String conversationId = newConversationId();
        ObjectNode forwarded = copyEnvelope(root);
        ObjectNode forwardedPayload = ((ObjectNode) payload).deepCopy();
        forwardedPayload.put("conversationId", conversationId);
        forwarded.set("payload", forwardedPayload);

        Conversation conversation = new Conversation(
                conversationId, textOf(payload, "workspacePath"), textOf(payload, "title"));
        conversations.put(conversationId, conversation);

        if (!forwardToAgent(session, forwarded, conversationId)) {
            conversations.remove(conversationId);
            return;
        }
        log.info("conversation registered id={} workspacePath={} title={}",
                conversationId, dash(conversation.workspacePath), dash(conversation.title));
    }

    private void handlePromptSend(RelaySession session, JsonNode root) {
        JsonNode payload = root.get("payload");
        String conversationId = textOf(payload, "conversationId");
        if (conversationId == null) {
            sendError(session, "BAD_REQUEST", "payload.conversationId is required", null);
            return;
        }
        Conversation conversation = conversations.get(conversationId);
        if (conversation == null) {
            sendError(session, "CONVERSATION_NOT_FOUND",
                    "unknown conversationId: " + conversationId, conversationId);
            return;
        }
        if (!isAgentOnline()) {
            sendError(session, "DEVICE_OFFLINE", "agent is not connected", conversationId);
            return;
        }
        if (conversation.busy.get()) {
            sendError(session, "SESSION_BUSY", "a turn is already running for this conversation", conversationId);
            return;
        }
        // M2.1: allocate the conversation-level seq before forwarding and persist the user message,
        // the queued task and the matching prompt.send task_events row synchronously, so the current
        // task id is always visible before any Agent event that references it (a fast Agent sends
        // task.state/running within milliseconds).
        long seq = persistence.allocateSeq(conversationId);
        ObjectNode forwarded = copyEnvelope(root);
        ObjectNode forwardedPayload = ((ObjectNode) payload).deepCopy();
        forwardedPayload.put("conversationId", conversationId);
        if (seq > 0) {
            forwardedPayload.put("seq", seq);
            forwarded.put("seq", seq);
        }
        forwarded.set("payload", forwardedPayload);
        persistence.onPromptSend(conversationId, textOf(payload, "text"), seq);
        if (forwardToAgent(session, forwarded, conversationId)) {
            conversation.busy.set(true);
        } else {
            // The prompt.send event row already exists (gapless seq), only the turn cannot start.
            persistence.onPromptForwardFailed(conversationId, seq, "prompt did not reach the agent");
        }
    }

    private void handleAgentMessage(RelaySession session, String type, JsonNode root, String conversationId) {
        RelaySession current = agent;
        if (current == null || !current.sessionId().equals(session.sessionId())) {
            log.warn("ignoring message from stale agent sessionId={} type={}", session.sessionId(), type);
            return;
        }
        if (!AGENT_BROADCAST_TYPES.contains(type)) {
            log.warn("ignoring unknown agent message type={}", type);
            return;
        }
        JsonNode payload = root.get("payload");
        switch (type) {
            case "conversation.created" -> {
                registerCreatedConversation(conversationId, payload);
                persistence.onConversationCreated(conversationId,
                        textOf(payload, "sessionId"),
                        textOf(payload, "workspacePath"),
                        textOf(payload, "title"),
                        session.deviceId());
                long seq = journal(root, "conversation.created", null, conversationId);
                broadcastMessage(root, conversationId);
            }
            case "task.state" -> {
                String state = textOf(payload, "state");
                JsonNode detail = payload == null ? null : payload.get("detail");
                long seq = journal(root, "task.state", null, conversationId);
                persistence.onTaskState(conversationId, state,
                        textOf(detail, "code"), textOf(detail, "message"), seq);
                updateBusyState(conversationId, state);
                broadcastMessage(root, conversationId);
            }
            case "device.status" -> {
                cacheDeviceStatus(payload);
                persistence.onDeviceStatus(session.deviceId(), payload);
                broadcastMessage(root, conversationId);
            }
            case "session.update", "approval.request", "approval.resolved" -> {
                String kind = "session.update".equals(type) ? textOf(payload, "kind") : null;
                long seq = journal(root, type, kind, conversationId);
                if ("session.update".equals(type)) {
                    persistence.onSessionUpdate(conversationId, kind, seq, root.get("payload"));
                }
                broadcastMessage(root, conversationId);
            }
            case "error" -> {
                // Agent-side errors (e.g. PATH_NOT_ALLOWED, SESSION_BUSY on the agent) must reach the app.
                log.info("agent reported error payload={}", payload == null ? "null" : payload.toString());
                broadcastMessage(root, conversationId);
            }
            case "workspace.list.result", "file.read.result" -> {
                // M2.6: request/response payloads are stateless; broadcast so the asking app gets it.
                broadcastMessage(root, conversationId);
            }
            default -> log.warn("ignoring agent message type={}", type);
        }
    }

    // ------------------------------------------------------------------
    // M2.1 seq journal
    // ------------------------------------------------------------------

    /**
     * Allocates the conversation-level seq and enqueues the matching {@code task_events} row.
     *
     * <p>Must run <b>before</b> {@link #broadcastMessage(JsonNode, String)}: the hub skips the
     * broadcast when no app is connected, but the event row has to be written anyway so a phone that
     * reconnects later can catch up from {@code GET /conversations/{id}/events}.
     */
    private long journal(JsonNode root, String type, String kind, String conversationId) {
        if (conversationId == null || conversationId.isBlank()) {
            return 0L;
        }
        long seq = persistence.allocateSeq(conversationId);
        if (seq > 0) {
            // Stamp the seq into the forwarded envelope before journaling: live clients and the
            // catch-up endpoint must see exactly the same payload (payload.seq = backend seq).
            withSeq(root, seq);
            persistence.onTaskEvent(conversationId, seq, type, kind, root.get("payload"));
        }
        return seq;
    }

    /**
     * Puts the allocated seq into {@code payload.seq} (the field clients use to dedupe live events
     * against the catch-up endpoint) and also at the envelope root for forward compatibility.
     */
    private void withSeq(JsonNode root, long seq) {
        if (seq <= 0 || !(root instanceof ObjectNode envelope)) {
            return;
        }
        envelope.put("seq", seq);
        JsonNode payload = envelope.get("payload");
        if (payload instanceof ObjectNode payloadObject) {
            payloadObject.put("seq", seq);
        }
    }

    // ------------------------------------------------------------------
    // conversation bookkeeping
    // ------------------------------------------------------------------

    private String newConversationId() {
        for (int attempt = 0; attempt < 1000; attempt++) {
            String candidate = Ulid.newId();
            if (!conversations.containsKey(candidate)) {
                return candidate;
            }
        }
        throw new IllegalStateException("unable to allocate a conversationId");
    }

    private void registerCreatedConversation(String conversationId, JsonNode payload) {
        if (conversationId == null) {
            log.warn("conversation.created without conversationId payload");
            return;
        }
        Conversation conversation = conversations.computeIfAbsent(conversationId,
                id -> new Conversation(id, null, null));
        String sessionId = textOf(payload, "sessionId");
        if (sessionId != null) {
            conversation.sessionId = sessionId;
        }
        String workspacePath = textOf(payload, "workspacePath");
        if (workspacePath != null) {
            conversation.workspacePath = workspacePath;
        }
        String title = textOf(payload, "title");
        if (title != null) {
            conversation.title = title;
        }
        conversation.busy.set(false);
        log.info("conversation created id={} sessionId={} workspacePath={}",
                conversationId, dash(conversation.sessionId), dash(conversation.workspacePath));
    }

    private void updateBusyState(String conversationId, String state) {
        if (conversationId == null || state == null) {
            return;
        }
        Conversation conversation = conversations.get(conversationId);
        if (conversation == null) {
            return;
        }
        switch (state) {
            case "queued", "running" -> conversation.busy.set(true);
            case "completed", "failed", "cancelled" -> conversation.busy.set(false);
            default -> log.warn("unknown task.state state={} conversationId={}", state, conversationId);
        }
    }

    private void cacheDeviceStatus(JsonNode payload) {
        if (payload == null || !payload.isObject()) {
            log.warn("device.status without JSON object payload");
            return;
        }
        try {
            cachedDeviceStatus = mapper.convertValue(payload, MAP_TYPE);
            log.info("device.status cached deviceName={} harnessVersion={} online={}",
                    cachedDeviceStatus.get("deviceName"),
                    cachedDeviceStatus.get("harnessVersion"),
                    cachedDeviceStatus.get("online"));
        } catch (IllegalArgumentException e) {
            log.warn("device.status payload not cacheable: {}", e.getMessage());
        }
    }

    // ------------------------------------------------------------------
    // outbound helpers
    // ------------------------------------------------------------------

    /** Sends an envelope to one connection (never logs tokens, only type/bytes). */
    public void send(RelaySession session, JsonNode node) {
        try {
            String text = mapper.writeValueAsString(node);
            session.sendText(text);
            log.info("send role={} type={} conversationId={} bytes={}",
                    session.role(), node.path("type").asText(),
                    dash(textOf(node.get("payload"), "conversationId")),
                    text.getBytes(StandardCharsets.UTF_8).length);
        } catch (IOException e) {
            log.warn("send failed role={} sessionId={} type={} err={}",
                    session.role(), session.sessionId(), node.path("type").asText(), e.getMessage());
        }
    }

    public void sendError(RelaySession session, String code, String message, String conversationId) {
        ObjectNode payload = mapper.createObjectNode();
        payload.put("code", code);
        payload.put("message", message);
        if (conversationId != null && !conversationId.isBlank()) {
            payload.put("conversationId", conversationId);
        }
        log.info("error reply code={} conversationId={}", code, dash(conversationId));
        send(session, Envelope.of(mapper, "error", null, payload));
    }

    /** Replies {@code {"v":1,"type":"pong","ts":...}} to a heartbeat ping. */
    public void sendPong(RelaySession session) {
        send(session, Envelope.of(mapper, "pong", null, null));
    }

    private boolean forwardToAgent(RelaySession requester, JsonNode message, String conversationId) {
        RelaySession target = agent;
        if (target == null || !target.isOpen()) {
            sendError(requester, "DEVICE_OFFLINE", "agent is not connected", conversationId);
            return false;
        }
        try {
            String text = mapper.writeValueAsString(message);
            target.sendText(text);
            log.info("send role=agent type={} conversationId={} bytes={}",
                    message.path("type").asText(), dash(conversationId),
                    text.getBytes(StandardCharsets.UTF_8).length);
            return true;
        } catch (IOException e) {
            log.warn("forward to agent failed type={} err={}", message.path("type").asText(), e.getMessage());
            sendError(requester, "INTERNAL", "failed to forward message to agent", conversationId);
            return false;
        }
    }

    private void broadcast(ObjectNode... messages) {
        for (ObjectNode message : messages) {
            broadcastMessage(message, textOf(message.get("payload"), "conversationId"));
        }
    }

    private void broadcastMessage(JsonNode root, String conversationId) {
        String type = root.path("type").asText();
        if (apps.isEmpty()) {
            log.info("broadcast type={} conversationId={} apps=0 (no app connected)", type, dash(conversationId));
            return;
        }
        String text;
        try {
            text = mapper.writeValueAsString(root);
        } catch (JsonProcessingException e) {
            log.warn("broadcast serialization failed type={} err={}", type, e.getMessage());
            return;
        }
        int bytes = text.getBytes(StandardCharsets.UTF_8).length;
        int sent = 0;
        for (RelaySession app : apps.values()) {
            try {
                app.sendText(text);
                sent++;
            } catch (IOException e) {
                log.warn("broadcast to app failed sessionId={} type={} err={}",
                        app.sessionId(), type, e.getMessage());
            }
        }
        log.info("broadcast type={} conversationId={} bytes={} apps={}/{}",
                type, dash(conversationId), bytes, sent, apps.size());
    }

    private ObjectNode deviceStatusMessage(boolean online) {
        LinkedHashMap<String, Object> cached = cachedDeviceStatus;
        ObjectNode payload = cached == null ? mapper.createObjectNode() : mapper.valueToTree(cached);
        payload.put("online", online);
        payload.put("lastSeen", Envelope.nowTs());
        return Envelope.of(mapper, "device.status", null, payload);
    }

    private ObjectNode agentEventMessage(String type, RelaySession session) {
        ObjectNode payload = mapper.createObjectNode();
        payload.put("deviceId", session.deviceId());
        if (session.clientName() != null && !session.clientName().isBlank()) {
            payload.put("deviceName", session.clientName());
        }
        return Envelope.of(mapper, type, null, payload);
    }

    /** Rebuilds the envelope keeping client generated id/ts, used to inject conversationId. */
    private ObjectNode copyEnvelope(JsonNode root) {
        ObjectNode out = mapper.createObjectNode();
        int v = root.path("v").asInt(Envelope.V);
        out.put("v", v <= 0 ? Envelope.V : v);
        out.put("type", root.path("type").asText(""));
        JsonNode id = root.get("id");
        if (id != null && !id.isNull()) {
            out.set("id", id.deepCopy());
        }
        JsonNode ts = root.get("ts");
        if (ts != null && !ts.isNull()) {
            out.set("ts", ts.deepCopy());
        }
        JsonNode payload = root.get("payload");
        if (payload != null) {
            out.set("payload", payload.deepCopy());
        }
        return out;
    }

    // ------------------------------------------------------------------
    // health accessors
    // ------------------------------------------------------------------

    public boolean isAgentOnline() {
        RelaySession current = agent;
        return current != null && current.isOpen();
    }

    public int appCount() {
        return apps.size();
    }

    public int conversationCount() {
        return conversations.size();
    }

    // ------------------------------------------------------------------
    // small helpers
    // ------------------------------------------------------------------

    private static String textOf(JsonNode node, String field) {
        if (node == null || !node.isObject()) {
            return null;
        }
        JsonNode value = node.get(field);
        if (value == null || value.isNull()) {
            return null;
        }
        String text = value.asText();
        return (text == null || text.isBlank()) ? null : text;
    }

    private static String dash(String value) {
        return value == null ? "-" : value;
    }
}
