import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { HarnessError, mapJsonRpcError, toHarnessError } from '../../src/harness/errors.ts';

describe('mapJsonRpcError', () => {
  it('同会话 in-flight → SESSION_BUSY', () => {
    const error = mapJsonRpcError({ code: -32602, message: 'a prompt is already in flight for this session' }, 'session/prompt');
    assert.equal(error.code, 'SESSION_BUSY');
    assert.equal(error.retryable, false);
  });

  it('登录/凭证类错误 → HARNESS_NOT_LOGGED_IN', () => {
    for (const message of ['not authenticated', 'invalid credential', 'please login first']) {
      assert.equal(mapJsonRpcError({ code: -32000, message }, 'initialize').code, 'HARNESS_NOT_LOGGED_IN');
    }
  });

  it('未知会话 → SESSION_NOT_FOUND', () => {
    assert.equal(mapJsonRpcError({ code: -32602, message: 'session not found' }, 'session/prompt').code, 'SESSION_NOT_FOUND');
  });

  it('其它错误统一 ACP_PROTOCOL_ERROR，保留 rpc 细节', () => {
    const error = mapJsonRpcError({ code: -32603, message: 'boom', data: { x: 1 } }, 'session/new');
    assert.equal(error.code, 'ACP_PROTOCOL_ERROR');
    assert.equal(error.details['rpcCode'], -32603);
    assert.equal(error.details['method'], 'session/new');
  });
});

describe('toHarnessError', () => {
  it('透传已有 HarnessError', () => {
    const original = new HarnessError('TIMEOUT', 'slow');
    assert.equal(toHarnessError(original), original);
  });

  it('普通异常包成 INTERNAL 并保留 cause', () => {
    const cause = new Error('boom');
    const error = toHarnessError(cause);
    assert.equal(error.code, 'INTERNAL');
    assert.equal(error.message, 'boom');
    assert.equal(error.cause, cause);
  });

  it('可重试性按 code 默认值判定', () => {
    assert.equal(new HarnessError('ACP_PROCESS_EXIT', 'x').retryable, true);
    assert.equal(new HarnessError('SESSION_BUSY', 'x').retryable, false);
    assert.equal(new HarnessError('INTERNAL', 'x', { retryable: false }).retryable, false);
  });
});
