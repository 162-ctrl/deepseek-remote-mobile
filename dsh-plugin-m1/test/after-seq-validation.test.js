// 第 4 条：`afterSeq` / `limit` 传非法值时要报错，不能静默当成「没传」。
//
// 背景：插件把 `afterSeq=abc` 变成 `NaN`，`index.js` 里 `Number.isFinite(NaN)` 为假，
// 于是走「全量尾部回扫」，回最多 600 条 / 实测 253 KB —— 调用方以为在做增量补齐，
// 结果等于每次重新拉一遍，弱网直接超时。`limit=abc` 同理（变 NaN）。
import test from 'node:test';
import assert from 'node:assert/strict';

import { createRelayHttpServer } from '../lib/server.js';

const silent = () => {};

/** 起一个最小 hub 桩，只为让路由通过鉴权；记录桌面事件被调用时的参数。 */
function stubHub(calls) {
  return {
    authorizeToken: () => true,
    agentOnline: true,
    pairingCode: '135790',
    appCount: 0,
    version: 'test',
    pair: () => ({ token: 't', role: 'app', deviceId: 'd1', expiresAt: '2099-01-01T00:00:00Z' }),
    revokeToken: () => true,
    rotatePairingCode: () => '135790',
    acceptUpgrade: () => null,
    isLocalRequest: () => true,
  };
}

async function startServer(calls = []) {
  const server = createRelayHttpServer({
    hub: stubHub(),
    version: 'test',
    log: silent,
    pageContext: {
      desktopSessionEvents: (sessionId, options) => {
        calls.push({ sessionId, options });
        return { sessionId, events: [], chat: 0, lastSeq: 0 };
      },
    },
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  return { server, port: server.address().port };
}

async function get(port, path) {
  const res = await fetch(`http://127.0.0.1:${port}${path}`, {
    headers: { authorization: 'Bearer t' },
  });
  return { status: res.status, body: await res.json() };
}

test('afterSeq=abc → 400 BAD_REQUEST（不再静默返回全量）', async () => {
  const calls = [];
  const { server, port } = await startServer(calls);
  try {
    const { status, body } = await get(port, '/api/v1/desktop/sessions/s1/events?afterSeq=abc');
    assert.equal(status, 400, JSON.stringify(body));
    assert.equal(body.code, 'BAD_REQUEST');
    assert.equal(calls.length, 0, '非法参数不该走到 desktopSessionEvents');
  } finally {
    server.close();
  }
});

test('afterSeq=-5 → 400（负数不是合法的「已经看到第几条」）', async () => {
  const { server, port } = await startServer();
  try {
    const { status, body } = await get(port, '/api/v1/desktop/sessions/s1/events?afterSeq=-5');
    assert.equal(status, 400, JSON.stringify(body));
    assert.equal(body.code, 'BAD_REQUEST');
  } finally {
    server.close();
  }
});

test('afterSeq=1.5 → 400（非整数）', async () => {
  const { server, port } = await startServer();
  try {
    const { status, body } = await get(port, '/api/v1/desktop/sessions/s1/events?afterSeq=1.5');
    assert.equal(status, 400, JSON.stringify(body));
    assert.equal(body.code, 'BAD_REQUEST');
  } finally {
    server.close();
  }
});

test('afterSeq=0 / 100 → 200，且原样传到桌面事件', async () => {
  const calls = [];
  const { server, port } = await startServer(calls);
  try {
    for (const value of [0, 100]) {
      const { status } = await get(port, `/api/v1/desktop/sessions/s1/events?afterSeq=${value}`);
      assert.equal(status, 200);
    }
    assert.deepEqual(
      calls.map((call) => call.options.afterSeq),
      [0, 100],
    );
  } finally {
    server.close();
  }
});

test('不带 afterSeq → 200（全量尾部的老行为不变）', async () => {
  const calls = [];
  const { server, port } = await startServer(calls);
  try {
    const { status } = await get(port, '/api/v1/desktop/sessions/s1/events');
    assert.equal(status, 200);
    assert.equal(calls[0].options.afterSeq, undefined);
  } finally {
    server.close();
  }
});

test('limit=abc → 400；limit=20 → 200 并夹到 1..600', async () => {
  const calls = [];
  const { server, port } = await startServer(calls);
  try {
    const bad = await get(port, '/api/v1/desktop/sessions/s1/events?limit=abc');
    assert.equal(bad.status, 400, JSON.stringify(bad.body));
    assert.equal(bad.body.code, 'BAD_REQUEST');

    const ok = await get(port, '/api/v1/desktop/sessions/s1/events?limit=20');
    assert.equal(ok.status, 200);
    assert.equal(calls[0].options.limit, 20);

    const huge = await get(port, '/api/v1/desktop/sessions/s1/events?limit=99999');
    assert.equal(huge.status, 200);
    assert.equal(calls[1].options.limit, 600);
  } finally {
    server.close();
  }
});
