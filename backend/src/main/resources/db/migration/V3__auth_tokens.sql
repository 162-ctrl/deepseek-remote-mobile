-- M2-alpha: persisted pairing tokens (contract: docs/design/M2_DELTA.md section 1.1).
--
-- Only the SHA-256 hex digest of a token is stored. Plaintext tokens never reach the
-- database (not even in logs). A token stays valid after a backend restart as long as
-- revoked_at IS NULL AND expires_at > now(), which is M2 acceptance item M2-A4.
--
-- Default lifetime is 30 days and is applied by the backend from env M1_TOKEN_TTL_DAYS
-- (the DB default is only a safety net for manual inserts).

CREATE TABLE auth_tokens
(
    id           CHAR(26)    PRIMARY KEY CHECK (char_length(id) = 26),
    token_hash   CHAR(64)    NOT NULL UNIQUE,
    role         VARCHAR(8)  NOT NULL CHECK (role IN ('app', 'agent')),
    device_id    VARCHAR(32) NOT NULL,
    client_name  VARCHAR(64) NOT NULL,
    issued_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at   TIMESTAMPTZ NOT NULL DEFAULT now() + INTERVAL '30 days',
    revoked_at   TIMESTAMPTZ,
    last_seen_at TIMESTAMPTZ
);

-- Lookup patterns: by hash (unique index above), by device/role and by expiry purge.
CREATE INDEX ix_auth_tokens_device_role ON auth_tokens (device_id, role);
CREATE INDEX ix_auth_tokens_expires ON auth_tokens (expires_at);

COMMENT ON TABLE auth_tokens IS 'M2-alpha persisted tokens (sha256 only); survives backend restarts';
COMMENT ON COLUMN auth_tokens.token_hash IS 'sha256(token) lowercase hex, 64 chars; plaintext tokens are never stored';
