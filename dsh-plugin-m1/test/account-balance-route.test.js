// M4.25：`GET /api/v1/desktop/account/balance` 的路由行为。
//
// 这条路由只做三件事：认手机 token、把 Host 的余额原样透给 App、插件太旧时给
// 一个可区分的 501。余额本身（钱包合并、未登录判定）在 `account-balance.test.js`
// 里盯着，这里只守路由边界。
import test from 'node:test';
import assert from 'node:assert/strict';

import { createRelayHttpServer } from '../lib/server.js';

const BALANCE = {
  supported: true,
  signedIn: true,
  failed: false,
  wallets: [{ currency: 'CNY', balance: '12.34' }],
  bonusWallets: [{ currency: 'CNY', balance: '3.00' }],
  error: '',
};

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
    version: '0.2.29-test',
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

test('M4.25 app token 读到余额并原样带回', async () => {
  await withServer({ accountBalance: async () => BALANCE }, async (base) => {
    const response = await get(base, '/api/v1/desktop/account/balance', 'app-token');
    assert.equal(response.status, 200);
    const body = await response.json();
    assert.deepEqual(body.wallets, BALANCE.wallets);
    assert.deepEqual(body.bonusWallets, BALANCE.bonusWallets);
    assert.equal(body.signedIn, true);
  });
});

test('M4.25 不带 token 或 agent token 读不到余额', async () => {
  await withServer({ accountBalance: async () => BALANCE }, async (base) => {
    const anonymous = await get(base, '/api/v1/desktop/account/balance');
    assert.equal(anonymous.status, 401);

    const asAgent = await get(base, '/api/v1/desktop/account/balance', 'agent-token');
    assert.equal(asAgent.status, 401);
    assert.equal((await asAgent.json()).code, 'AUTH_FAILED');
  });
});

test('M4.25 插件太旧（没有 accountBalance）时回 501', async () => {
  await withServer({}, async (base) => {
    const response = await get(base, '/api/v1/desktop/account/balance', 'app-token');
    assert.equal(response.status, 501);
    const body = await response.json();
    assert.equal(body.code, 'ACCOUNT_BALANCE_UNAVAILABLE');
    assert.equal(body.message, '这台电脑的插件版本太旧，读不到账户余额');
  });
});

test('M4.25 未登录时的 null 结构也能透传', async () => {
  const signedOut = { supported: true, signedIn: false, failed: false, wallets: [], bonusWallets: [], error: '' };
  await withServer({ accountBalance: async () => signedOut }, async (base) => {
    const response = await get(base, '/api/v1/desktop/account/balance', 'app-token');
    assert.equal(response.status, 200);
    const body = await response.json();
    assert.equal(body.signedIn, false);
    assert.deepEqual(body.wallets, []);
  });
});
