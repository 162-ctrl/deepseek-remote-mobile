-- M1.1 seed: the single local "自用" user (M1_1_DELTA section 2).
-- ID is a fixed 26-char Crockford Base32 value (valid ULID alphabet); the
-- password hash is a disabled placeholder because M1.1 has no password login.
INSERT INTO users (id, username, password_hash, nickname, status, created_at, updated_at)
VALUES ('01JSEED0000000000000000000', 'u_self', '!disabled', '自用', 'active', now(), now())
ON CONFLICT (id) DO NOTHING;
