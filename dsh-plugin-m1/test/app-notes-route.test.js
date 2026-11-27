// M4.66：`GET /api/v1/app/notes` 的路由行为。
//
// 这条路由给手机「功能 → 更新日志」用：认 app token，把 `docs/UPDATE_NOTES.md`
// 拆好的数组原样带回；插件太旧（没有 appNotes）时给空数组，让 App 退回随包那份。
import test from 'node:test';
import assert from 'node:assert/strict';

import { createRelayHttpServer } from '../lib/server.js';

const NOTES = [
  { version: '0.4.60', date: '2026-11-28', title: '充值页与更新日志', body: '功能页多了更新日志。' },
];

function fakeHub() {
  const tokens = new Map([
    ['agent-token', 'agent'],
    ['app-token', 'app'],
  ]);
  return {
    pairingCode: '000000',
    agentOnline: true,
    appCount: 1,
    authorizeToken(token, role = 'app') {
      const actual = tokens.get(String(token ?? ''));
      return actual !== undefined && actual === role;
    },
  };
}

async function withServer(pageContext, run) {
  const server = createRelayHttpServer({
    hub: fakeHub(),
    version: '0.2.69-test',
    pageContext: { port: 8787, ...pageContext },
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address();
  try {
    await run(`http://127.0.0.1:${port}`);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
}

const get = (base, path, token) =>
  fetch(`${base}${path}`, { headers: token ? { authorization: `Bearer ${token}` } : {} });

test('M4.66 app token 读到更新日志列表', async () => {
  await withServer({ appNotes: () => NOTES }, async (base) => {
    const response = await get(base, '/api/v1/app/notes', 'app-token');
    assert.equal(response.status, 200);
    const body = await response.json();
    assert.equal(body.notes.length, 1);
    assert.equal(body.notes[0].version, '0.4.60');
    assert.equal(body.notes[0].title, '充值页与更新日志');
  });
});

test('M4.66 不带 token 或 agent token 读不到', async () => {
  await withServer({ appNotes: () => NOTES }, async (base) => {
    assert.equal((await get(base, '/api/v1/app/notes')).status, 401);
    const asAgent = await get(base, '/api/v1/app/notes', 'agent-token');
    assert.equal(asAgent.status, 401);
    assert.equal((await asAgent.json()).code, 'AUTH_FAILED');
  });
});

test('M4.66 旧插件没有 appNotes 时回空数组', async () => {
  await withServer({}, async (base) => {
    const response = await get(base, '/api/v1/app/notes', 'app-token');
    assert.equal(response.status, 200);
    assert.deepEqual((await response.json()).notes, []);
  });
});
