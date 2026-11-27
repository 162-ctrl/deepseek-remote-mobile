-- M1.1 core schema: users / devices / conversations / messages / tasks / audit_logs.
-- Base contract: docs/design/DATA_MODEL.md (column names/types kept; M2-only tables left to M2).
-- M1.1 deltas: conversations.workspace_path and users.nickname are appended columns
-- (no renames), both required by docs/design/M1_1_DELTA.md sections 2/3.
--
-- All business ids are 26-character uppercase Crockford Base32 (ULID style) generated
-- by the backend; no client ever generates one (M1_1_DELTA section 2).

-- Trigger function used by every table that has an updated_at column.
CREATE OR REPLACE FUNCTION set_updated_at()
    RETURNS trigger
    LANGUAGE plpgsql
AS
$$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- users
-- ---------------------------------------------------------------------------
CREATE TABLE users
(
    id                 CHAR(26)     PRIMARY KEY CHECK (char_length(id) = 26),
    username           VARCHAR(32)  NOT NULL UNIQUE,
    password_hash      VARCHAR(255) NOT NULL,
    nickname           VARCHAR(64),
    email              VARCHAR(255),
    email_normalized   VARCHAR(255),
    phone              VARCHAR(32),
    avatar             TEXT,
    status             VARCHAR(16)  NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'locked', 'deleted')),
    failed_login_count SMALLINT     NOT NULL DEFAULT 0 CHECK (failed_login_count >= 0),
    locked_until       TIMESTAMPTZ,
    last_login_at      TIMESTAMPTZ,
    created_at         TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at         TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX ux_users_email_norm ON users (email_normalized)
    WHERE email_normalized IS NOT NULL;
CREATE INDEX ix_users_phone ON users (phone) WHERE phone IS NOT NULL;
CREATE TRIGGER trg_users_updated
    BEFORE UPDATE
    ON users
    FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- devices
-- ---------------------------------------------------------------------------
CREATE TABLE devices
(
    id                  CHAR(26)     PRIMARY KEY CHECK (char_length(id) = 26),
    user_id             CHAR(26)     REFERENCES users (id) ON DELETE SET NULL,
    device_name         VARCHAR(64)  NOT NULL,
    operating_system    VARCHAR(64)  NOT NULL,
    agent_version       VARCHAR(32)  NOT NULL,
    harness_version     VARCHAR(64),
    device_status       VARCHAR(16)  NOT NULL DEFAULT 'pending'
        CHECK (device_status IN ('pending', 'active', 'revoked')),
    last_online_at      TIMESTAMPTZ,
    last_seq            BIGINT       NOT NULL DEFAULT 0,
    device_token_hash   VARCHAR(64),
    device_public_key   TEXT,
    capabilities        JSONB        NOT NULL DEFAULT '{}'::jsonb,
    app_version         VARCHAR(32),
    revoked_at          TIMESTAMPTZ,
    remote_enabled      BOOLEAN      NOT NULL DEFAULT true,
    emergency_stopped_at TIMESTAMPTZ,
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT ck_devices_pending_without_user CHECK (device_status <> 'pending' OR user_id IS NULL)
);

CREATE INDEX ix_devices_user ON devices (user_id, created_at DESC);
CREATE UNIQUE INDEX ux_devices_token_hash ON devices (device_token_hash)
    WHERE device_token_hash IS NOT NULL;
CREATE TRIGGER trg_devices_updated
    BEFORE UPDATE
    ON devices
    FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- conversations
-- ---------------------------------------------------------------------------
CREATE TABLE conversations
(
    id                 CHAR(26)     PRIMARY KEY CHECK (char_length(id) = 26),
    user_id            CHAR(26)     NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    device_id          CHAR(26)     NOT NULL REFERENCES devices (id) ON DELETE CASCADE,
    harness_session_id VARCHAR(128),
    title              VARCHAR(120) NOT NULL DEFAULT '新对话',
    workspace_path     VARCHAR(1024),
    session_state      VARCHAR(16)  NOT NULL DEFAULT 'active'
        CHECK (session_state IN ('active', 'closed', 'error')),
    last_message_at    TIMESTAMPTZ,
    message_count      INTEGER      NOT NULL DEFAULT 0 CHECK (message_count >= 0),
    archived_at        TIMESTAMPTZ,
    created_at         TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at         TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX ix_conv_user_updated ON conversations (user_id, COALESCE(last_message_at, created_at) DESC);
CREATE INDEX ix_conv_device ON conversations (device_id);
CREATE UNIQUE INDEX ux_conv_harness_session ON conversations (device_id, harness_session_id)
    WHERE harness_session_id IS NOT NULL;
CREATE TRIGGER trg_conversations_updated
    BEFORE UPDATE
    ON conversations
    FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- messages
-- ---------------------------------------------------------------------------
CREATE TABLE messages
(
    id                  CHAR(26)    PRIMARY KEY CHECK (char_length(id) = 26),
    conversation_id     CHAR(26)    NOT NULL REFERENCES conversations (id) ON DELETE CASCADE,
    role                VARCHAR(16) NOT NULL CHECK (role IN ('user', 'assistant', 'system', 'tool')),
    content             TEXT        NOT NULL DEFAULT '',
    content_type        VARCHAR(16) NOT NULL DEFAULT 'text'
        CHECK (content_type IN ('text', 'markdown', 'code', 'image', 'file', 'audio', 'json',
                                'tool_call', 'tool_result')),
    seq_in_conversation BIGINT      NOT NULL CHECK (seq_in_conversation > 0),
    client_msg_id       VARCHAR(64),
    tool_name           VARCHAR(64),
    metadata            JSONB       NOT NULL DEFAULT '{}'::jsonb,
    token_count         INTEGER,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX ux_msg_seq ON messages (conversation_id, seq_in_conversation);
CREATE UNIQUE INDEX ux_msg_client ON messages (conversation_id, client_msg_id)
    WHERE client_msg_id IS NOT NULL;
CREATE INDEX ix_msg_conv_created ON messages (conversation_id, created_at);

-- ---------------------------------------------------------------------------
-- tasks
-- ---------------------------------------------------------------------------
CREATE TABLE tasks
(
    id                  CHAR(26)     PRIMARY KEY CHECK (char_length(id) = 26),
    user_id             CHAR(26)     NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    device_id           CHAR(26)     NOT NULL REFERENCES devices (id) ON DELETE CASCADE,
    conversation_id     CHAR(26)     REFERENCES conversations (id) ON DELETE SET NULL,
    task_name           VARCHAR(200) NOT NULL,
    task_type           VARCHAR(32)  NOT NULL DEFAULT 'chat'
        CHECK (task_type IN ('chat', 'code_analysis', 'file_operation', 'terminal', 'desktop', 'custom')),
    task_status         VARCHAR(20)  NOT NULL DEFAULT 'queued'
        CHECK (task_status IN ('queued', 'running', 'waiting_approval', 'paused', 'completed',
                               'failed', 'cancelled')),
    progress            SMALLINT     NOT NULL DEFAULT 0 CHECK (progress BETWEEN 0 AND 100),
    payload             JSONB        NOT NULL DEFAULT '{}'::jsonb,
    result              JSONB,
    error_message       TEXT,
    error_code          VARCHAR(32),
    harness_task_ref    VARCHAR(128),
    permission_level    SMALLINT     NOT NULL DEFAULT 2 CHECK (permission_level BETWEEN 1 AND 6),
    idempotency_key     VARCHAR(64),
    cancel_requested_at TIMESTAMPTZ,
    started_at          TIMESTAMPTZ,
    finished_at         TIMESTAMPTZ,
    last_event_seq      BIGINT,
    version             INTEGER      NOT NULL DEFAULT 0,
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT ck_tasks_time_order CHECK (finished_at IS NULL OR started_at IS NULL OR finished_at >= started_at)
);

CREATE INDEX ix_tasks_user_created ON tasks (user_id, created_at DESC);
CREATE INDEX ix_tasks_device_status ON tasks (device_id, task_status);
CREATE INDEX ix_tasks_conv ON tasks (conversation_id, created_at DESC);
CREATE UNIQUE INDEX ux_tasks_idem ON tasks (idempotency_key) WHERE idempotency_key IS NOT NULL;
CREATE TRIGGER trg_tasks_updated
    BEFORE UPDATE
    ON tasks
    FOR EACH ROW
EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------------
-- audit_logs (M1.1 keeps it as a plain table; monthly partitioning is an M2 concern)
-- ---------------------------------------------------------------------------
CREATE TABLE audit_logs
(
    id               CHAR(26)    PRIMARY KEY CHECK (char_length(id) = 26),
    user_id          CHAR(26),
    device_id        CHAR(26),
    action_type      VARCHAR(64) NOT NULL,
    action_result    VARCHAR(16) NOT NULL CHECK (action_result IN ('success', 'denied', 'failed')),
    permission_level SMALLINT CHECK (permission_level BETWEEN 1 AND 6),
    target_type      VARCHAR(32),
    target_id        VARCHAR(64),
    action_detail    JSONB       NOT NULL DEFAULT '{}'::jsonb,
    ip               INET,
    user_agent       VARCHAR(255),
    trace_id         VARCHAR(64),
    severity         VARCHAR(8)  NOT NULL DEFAULT 'info' CHECK (severity IN ('info', 'warn', 'critical')),
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX ix_audit_user_time ON audit_logs (user_id, created_at DESC);
CREATE INDEX ix_audit_device_time ON audit_logs (device_id, created_at DESC);
CREATE INDEX ix_audit_action ON audit_logs (action_type, created_at DESC);
CREATE INDEX ix_audit_target ON audit_logs (target_type, target_id);
