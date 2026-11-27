// M4.20：Agent 专用的授权目录核对接口。
//
// 背景：插件在 DSH 刚启动、工作区注册表还没就绪时就把 Agent 拉起来了，那时只能把
// `homedir()` 递进去；手机上「工作区」整页因此只剩一个 `C:\Users\…`，项目卡和会话
// 全都不见了，而且直到进程重启都不会自愈。修法是 Agent 定时来 `GET
// /api/v1/agent/workspaces` 要一次真实目录。这里守住三件事：
//   1) agent token 能读到（200 + workspaces）；
//   2) 手机端的 app token 读不到（401，避免把机器目录结构暴露给 App 之外的东西）；
//   3) 手机端自己的 `/api/v1/desktop/workspaces` 原样可用（不被这次拆分影响）。
import test from 'node:test';
import assert from 'node:assert/strict';

import { createRelayHttpServer } from '../lib/server.js';

const WORKSPACES = [
  { name: 'deepseek手机端', path: '<项目根>', parent: 'D:\\Projects\\项目', sessions: 3, tasks: 1 },
  { name: '示例项目D', path: 'D:\\Projects\\示例项目D', parent: 'D:\\Projects\\项目', sessions: 0, tasks: 0 },
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

function fakePageContext() {
  return {
    port: 8787,
    desktopWorkspaces: () => WORKSPACES,
    publicEndpoint: { status: () => ({ enabled: false, running: false, url: null, error: null }) },
  };
}

async function withServer(run) {
  const server = createRelayHttpServer({
    hub: fakeHub(),
    version: '0.2.25-test',
    pageContext: fakePageContext(),
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
  fetch(`${base}${path}`, {
    headers: token ? { authorization: `Bearer ${token}` } : {},
  });

test('M4.20 agent token 能读到授权目录', async () => {
  await withServer(async (base) => {
    const response = await get(base, '/api/v1/agent/workspaces', 'agent-token');
    assert.equal(response.status, 200);
    const body = await response.json();
    assert.equal(body.workspaces.length, 2);
    assert.equal(body.workspaces[0].path, WORKSPACES[0].path);
  });
});

test('M4.20 app token / 无 token 读不到 agent 接口', async () => {
  await withServer(async (base) => {
    const asApp = await get(base, '/api/v1/agent/workspaces', 'app-token');
    assert.equal(asApp.status, 401);
    assert.equal((await asApp.json()).code, 'AUTH_FAILED');

    const anonymous = await get(base, '/api/v1/agent/workspaces');
    assert.equal(anonymous.status, 401);
  });
});

test('M4.20 手机端自己的 workspaces 接口照旧只认 app token', async () => {
  await withServer(async (base) => {
    const asApp = await get(base, '/api/v1/desktop/workspaces', 'app-token');
    assert.equal(asApp.status, 200);
    assert.equal((await asApp.json()).workspaces.length, 2);

    const asAgent = await get(base, '/api/v1/desktop/workspaces', 'agent-token');
    assert.equal(asAgent.status, 401);
  });
});
