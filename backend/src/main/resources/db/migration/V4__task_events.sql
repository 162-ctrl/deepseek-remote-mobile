-- M2.1 (docs/design/M2_1_DELTA.md section 2): append-only conversation event log plus the
-- single conversation-level seq counter shared by `messages.seq_in_conversation` and
-- `task_events.seq`. After this migration the backend is the only seq allocator:
-- every App-visible conversation event and every prompt message takes one number from
-- `conversations.next_seq` (UPDATE ... RETURNING) and that same number is used both in the
-- forwarded websocket envelope and in the rows written to messages / task_events.

CREATE TABLE task_events
(
    id              CHAR(26)    NOT NULL PRIMARY KEY,
    conversation_id CHAR(26)    NOT NULL REFERENCES conversations (id) ON DELETE CASCADE,
    task_id         CHAR(26)    NULL REFERENCES tasks (id) ON DELETE SET NULL,
    seq             BIGINT      NOT NULL CHECK (seq > 0),
    type            VARCHAR(48) NOT NULL,
    kind            VARCHAR(32),
    payload         JSONB       NOT NULL DEFAULT '{}'::jsonb,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ux_task_events_conv_seq UNIQUE (conversation_id, seq)
);

CREATE INDEX idx_task_events_conv_seq ON task_events (conversation_id, seq);
CREATE INDEX idx_task_events_task ON task_events (task_id);

-- Conversation-level seq counter (M2.1: backend is the only allocator).
ALTER TABLE conversations
    ADD COLUMN next_seq BIGINT NOT NULL DEFAULT 0 CHECK (next_seq >= 0);

-- Start every existing conversation after the seq it already used for its messages. The next
-- event therefore continues the historical message numbering instead of restarting at 1.
UPDATE conversations c
SET next_seq = COALESCE(
        (SELECT max(m.seq_in_conversation) FROM messages m WHERE m.conversation_id = c.id),
        0);

-- One-time backfill so old timelines stay available to clients that only know the backfill
-- type (`GET /conversations/{id}/events` never returns type='backfill'). The synthetic id keeps
-- the CHAR(26) Crockford-Base32 shape: '01JBF' + 21 zero-padded digits.
INSERT INTO task_events (id, conversation_id, task_id, seq, type, kind, payload, created_at)
SELECT '01JBF' || lpad(row_number() OVER (ORDER BY m.conversation_id, m.seq_in_conversation)::text, 21, '0'),
       m.conversation_id,
       NULL,
       m.seq_in_conversation,
       'backfill',
       m.content_type,
       jsonb_build_object('role', m.role, 'contentType', m.content_type, 'text', left(m.content, 2000)),
       m.created_at
FROM messages m
ORDER BY m.conversation_id, m.seq_in_conversation
ON CONFLICT (conversation_id, seq) DO NOTHING;

-- Best-effort task attribution of the backfilled rows (M2.1-A1: GET /tasks/{id} events must come
-- from task_events; old tasks still get their historical timeline). `now()` is the transaction
-- timestamp, so rows of still-running tasks are attributed as well.
UPDATE task_events te
SET task_id = (SELECT t.id
               FROM tasks t
               WHERE t.conversation_id = te.conversation_id
                 AND te.created_at >= t.created_at
                 AND te.created_at <= COALESCE(t.finished_at, now())
               ORDER BY t.created_at DESC
               LIMIT 1)
WHERE te.type = 'backfill'
  AND te.task_id IS NULL;

COMMENT ON TABLE task_events IS
    'M2.1 append-only conversation event log; seq shares one space with messages.seq_in_conversation';
COMMENT ON COLUMN task_events.type IS
    'conversation.created | prompt.send | session.update | task.state | approval.request | approval.resolved | backfill';
COMMENT ON COLUMN task_events.kind IS 'session.update kind: output | thinking | tool_call | tool_call_update | usage';
COMMENT ON COLUMN conversations.next_seq IS
    'M2.1 conversation-level seq counter; backend allocates seq here before forwarding/appending';
