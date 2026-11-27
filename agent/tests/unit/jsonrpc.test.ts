import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { NdjsonDecoder, JsonRpcPeer } from '../../src/harness/acp/jsonrpc.ts';
import { HarnessError } from '../../src/harness/errors.ts';

describe('NdjsonDecoder', () => {
  it('跨 chunk 切分的行能正确拼回', () => {
    const decoder = new NdjsonDecoder();
    assert.deepEqual(decoder.push('{"a":'), []);
    assert.deepEqual(decoder.push('1}\n{"b":2}\n'), ['{"a":1}', '{"b":2}']);
  });

  it('忽略空行与 CRLF', () => {
    const decoder = new NdjsonDecoder();
    assert.deepEqual(decoder.push('\r\n\n{"x":1}\r\n'), ['{"x":1}']);
  });

  it('超长行抛 ACP_PROTOCOL_ERROR 并清空缓冲', () => {
    const decoder = new NdjsonDecoder(16);
    assert.throws(
      () => decoder.push('x'.repeat(32)),
      (error: unknown) => error instanceof HarnessError && error.code === 'ACP_PROTOCOL_ERROR',
    );
    assert.deepEqual(decoder.push('{"ok":1}\n'), ['{"ok":1}']);
  });

  it('flush 返回无换行的残留行', () => {
    const decoder = new NdjsonDecoder();
    decoder.push('{"tail":true}');
    assert.deepEqual(decoder.flush(), ['{"tail":true}']);
    assert.deepEqual(decoder.flush(), []);
  });
});

describe('JsonRpcPeer', () => {
  it('响应按 id 关联请求', async () => {
    const peer = new JsonRpcPeer();
    const promise = peer.sendRequest<{ value: string }>('test/echo', { x: 1 });
    peer.handleLine('{"jsonrpc":"2.0","id":1,"result":{"value":"ok"}}');
    assert.deepEqual(await promise, { value: 'ok' });
  });

  it('error 响应映射为 HarnessError', async () => {
    const peer = new JsonRpcPeer();
    const promise = peer.sendRequest('session/prompt', {});
    peer.handleLine('{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"a prompt is already in flight for this session"}}');
    await assert.rejects(promise, (error: unknown) => error instanceof HarnessError && error.code === 'SESSION_BUSY');
  });

  it('通知分发给所有订阅者，取消订阅后不再收到', () => {
    const peer = new JsonRpcPeer();
    const seen: string[] = [];
    const unsubscribe = peer.onNotification((method) => seen.push(method));
    peer.handleLine('{"jsonrpc":"2.0","method":"session/update","params":{}}');
    unsubscribe();
    peer.handleLine('{"jsonrpc":"2.0","method":"session/update","params":{}}');
    assert.deepEqual(seen, ['session/update']);
  });

  it('服务端请求交给 handler 并把结果写回', async () => {
    const written: string[] = [];
    const peer = new JsonRpcPeer({ writeLine: (line) => written.push(line) });
    peer.onRequest('session/request_permission', async (params) => {
      const record = params as { sessionId: string };
      return { outcome: { outcome: 'selected', optionId: 'allow-once' }, echoed: record.sessionId };
    });
    peer.handleLine(
      '{"jsonrpc":"2.0","id":7,"method":"session/request_permission","params":{"sessionId":"s1","toolCall":{"toolCallId":"t1"}}}',
    );
    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(written.length, 1);
    const parsed = JSON.parse(written[0] ?? '{}') as { id: number; result: { echoed: string } };
    assert.equal(parsed.id, 7);
    assert.equal(parsed.result.echoed, 's1');
  });

  it('未知服务端请求回 -32601', async () => {
    const written: string[] = [];
    const peer = new JsonRpcPeer({ writeLine: (line) => written.push(line) });
    peer.handleLine('{"jsonrpc":"2.0","id":9,"method":"unknown/method","params":{}}');
    await new Promise((resolve) => setImmediate(resolve));
    const parsed = JSON.parse(written[0] ?? '{}') as { error: { code: number } };
    assert.equal(parsed.error.code, -32601);
  });

  it('close 会拒绝所有 pending 请求', async () => {
    const peer = new JsonRpcPeer();
    const promise = peer.sendRequest('session/prompt', {});
    peer.close('test close');
    await assert.rejects(promise, (error: unknown) => error instanceof HarnessError && error.code === 'ACP_PROCESS_EXIT');
  });

  it('请求超时得到 TIMEOUT', async () => {
    const peer = new JsonRpcPeer();
    await assert.rejects(
      peer.sendRequest('slow', {}, 30),
      (error: unknown) => error instanceof HarnessError && error.code === 'TIMEOUT',
    );
  });

  it('非 JSON 行抛协议错误', () => {
    const peer = new JsonRpcPeer();
    assert.throws(
      () => peer.handleLine('not-json'),
      (error: unknown) => error instanceof HarnessError && error.code === 'ACP_PROTOCOL_ERROR',
    );
  });
});
