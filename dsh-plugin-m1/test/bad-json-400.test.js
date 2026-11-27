// 坏请求体应当回 400，而不是 500。
//
// 背景：`readJsonBody` 在解析失败时抛 `HubError('BAD_REQUEST', …, 400)`，但各路由是
// 在 try 之外 `await` 它的，异常直接冒到 `createServer` 的 catch，被一律当成 500
// 回 `INTERNAL`。客户端（手机端）于是把「我发错了」显示成「服务器炸了」。
import test from 'node:test';
import assert from 'node:assert/strict';

import { createRelayHttpServer } from '../lib/server.js';

const silent = () => {};

/** 起一个最小 hub 桩，只为让路由通过鉴权。 */
function stubHub() {
  return {
    authorizeToken: () => true,
    agentOnline: true,
    pairingCode: '135790',
    appCount: 0,
    version: 'test',
    pair: () => ({ token: 't', role: 'app', deviceId: 'd1', expiresAt: '2099-01-01T00:00:00Z' }),
    revokeToken: (token) => token === 't',
    rotatePairingCode: () => '135790',
    acceptUpgrade: () => null,
    isLocalRequest: () => true,
  };
}

async function startServer() {
  const server = createRelayHttpServer({
    hub: stubHub(),
    version: 'test',
    log: silent,
    pageContext: {
      desktopPrompt: async () => ({ ok: true }),
    },
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  return { server, port: server.address().port };
}

test('POST 会话 prompt 带坏 JSON → 400 BAD_REQUEST（不是 500）', async () => {
  const { server, port } = await startServer();
  try {
    const res = await fetch(`http://127.0.0.1:${port}/api/v1/desktop/sessions/s1/prompt`, {
      method: 'POST',
      headers: { authorization: 'Bearer t', 'content-type': 'application/json' },
      body: '{ this is not json',
    });
    const body = await res.json();
    assert.equal(res.status, 400, `期望 400，实际 ${res.status}（${JSON.stringify(body)}）`);
    assert.equal(body.code, 'BAD_REQUEST');
  } finally {
    server.close();
  }
});

test('POST 新建工作区带坏 JSON → 400（同一条修复覆盖多个路由）', async () => {
  const { server, port } = await startServer();
  try {
    const res = await fetch(`http://127.0.0.1:${port}/api/v1/desktop/workspaces`, {
      method: 'POST',
      headers: { authorization: 'Bearer t', 'content-type': 'application/json' },
      body: '<<<not json>>>',
    });
    const body = await res.json();
    assert.equal(res.status, 400, `期望 400，实际 ${res.status}（${JSON.stringify(body)}）`);
    assert.equal(body.code, 'BAD_REQUEST');
  } finally {
    server.close();
  }
});

test('未知路由 → 404 且 code 是 NOT_FOUND（不是 BAD_REQUEST）', async () => {
  // 第 5 条：状态码一直是对的，但 code 写成 BAD_REQUEST，
  // 客户端按 code 分流时会把「接口不存在」误判成「我的参数错了」。
  const { server, port } = await startServer();
  try {
    const res = await fetch(`http://127.0.0.1:${port}/api/v1/nope`, {
      headers: { authorization: 'Bearer t' },
    });
    const body = await res.json();
    assert.equal(res.status, 404);
    assert.equal(body.code, 'NOT_FOUND');
  } finally {
    server.close();
  }
});

test('POST /auth/revoke：有这条 token → 200，没有 → 404 TOKEN_NOT_FOUND', async () => {
  const { server, port } = await startServer();
  try {
    const ok = await fetch(`http://127.0.0.1:${port}/api/v1/auth/revoke`, {
      method: 'POST',
      headers: { authorization: 'Bearer t' },
    });
    assert.equal(ok.status, 200);
    assert.deepEqual(await ok.json(), { ok: true });

    const missing = await fetch(`http://127.0.0.1:${port}/api/v1/auth/revoke`, { method: 'POST' });
    assert.equal(missing.status, 404);
    assert.equal((await missing.json()).code, 'TOKEN_NOT_FOUND');
  } finally {
    server.close();
  }
});

