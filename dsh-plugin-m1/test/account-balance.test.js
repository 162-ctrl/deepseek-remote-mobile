// M4.25：手机「我的」页要显示账户余额。
//
// Host 的 `deepseekAccount.getBalance(client)` 明确写着「only Host consumers can
// obtain a request credential」，所以只能由插件代理一次，手机端只拿钱包数字。
// 这里验证插件这层的三种结局：
//   1. ready  → wallets / bonusWallets 压成 { currency, balance }，空条目丢掉；
//   2. null   → 未登录（不是错误，页面显示「未登录」）；
//   3. failed → 登录着但查询失败，给 failed 标记；
//   4. 没有这个服务 / 调用抛异常 → supported 或 error 可区分。
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const source = readFileSync(join(here, '..', 'lib', 'index.js'), 'utf8');

/** 截出 `const name = (async) (…` 的完整箭头函数源码（从 `{` 配平）。 */
const grabArrow = (name) => {
  const asyncHit = source.indexOf(`\n  const ${name} = async (`);
  const start = asyncHit >= 0 ? asyncHit : source.indexOf(`\n  const ${name} = (`);
  assert.ok(start >= 0, `找不到函数 ${name}`);
  const bodyStart = source.indexOf('{', source.indexOf('=>', start));
  let depth = 0;
  for (let i = bodyStart; i < source.length; i += 1) {
    const ch = source[i];
    if (ch === '{') depth += 1;
    else if (ch === '}') {
      depth -= 1;
      if (depth === 0) return source.slice(start + 1, i + 1);
    }
  }
  throw new Error(`函数 ${name} 花括号不配平`);
};

const readSrc = grabArrow('readAccountBalance');

const build = (ctx, version = '0.2.29-test') => {
  const factory = new Function(
    'ctx',
    'pluginVersion',
    `
    ${readSrc}
    return { readAccountBalance };
    `,
  );
  return factory(ctx, () => version);
};

const accountWith = (getBalance) => ({ get: (key) => (key === 'deepseekAccount' ? { getBalance } : undefined) });

test('ready：充值与赠送钱包都压成 { currency, balance }', async () => {
  const seen = [];
  const { readAccountBalance } = build(
    accountWith(async (client) => {
      seen.push(client);
      return {
        status: 'ready',
        value: [
          { currency: 'CNY', balance: '12.34' },
          { currency: 'USD', balance: '0.00' },
        ],
        bonusWallets: [{ currency: 'CNY', balance: '3.00' }],
      };
    }),
  );
  const result = await readAccountBalance();
  assert.equal(result.supported, true);
  assert.equal(result.signedIn, true);
  assert.equal(result.failed, false);
  assert.deepEqual(result.wallets, [
    { currency: 'CNY', balance: '12.34' },
    { currency: 'USD', balance: '0.00' },
  ]);
  assert.deepEqual(result.bonusWallets, [{ currency: 'CNY', balance: '3.00' }]);
  // 客户端元信息要带版本号与时区偏移（东八区 = +28800）。
  assert.equal(seen.length, 1);
  assert.equal(seen[0].version, '0.2.29-test');
  assert.equal(seen[0].locale, 'zh-CN');
  assert.equal(seen[0].timezoneOffsetSeconds, -new Date().getTimezoneOffset() * 60);
});

test('钱包里的空条目被丢掉', async () => {
  const { readAccountBalance } = build(
    accountWith(async () => ({
      status: 'ready',
      value: [{ currency: '', balance: '' }, { currency: 'CNY', balance: '' }],
      bonusWallets: 'nope',
    })),
  );
  const result = await readAccountBalance();
  assert.deepEqual(result.wallets, [{ currency: 'CNY', balance: '' }]);
  assert.deepEqual(result.bonusWallets, []);
});

test('null：未登录不是错误', async () => {
  const { readAccountBalance } = build(accountWith(async () => null));
  const result = await readAccountBalance();
  assert.equal(result.supported, true);
  assert.equal(result.signedIn, false);
  assert.equal(result.failed, false);
  assert.equal(result.error, '');
});

test('failed：登录着但查询失败要标出来', async () => {
  const { readAccountBalance } = build(accountWith(async () => ({ status: 'failed' })));
  const result = await readAccountBalance();
  assert.equal(result.supported, true);
  assert.equal(result.signedIn, true);
  assert.equal(result.failed, true);
  assert.equal(result.error, '账户余额查询失败');
});

test('没有 deepseekAccount 服务时 supported=false', async () => {
  const { readAccountBalance } = build({ get: () => undefined });
  const result = await readAccountBalance();
  assert.equal(result.supported, false);
  assert.equal(result.error, '这台电脑的 Harness 没有暴露账户服务');
});

test('getBalance 抛异常时把错误码带回去', async () => {
  const { readAccountBalance } = build(
    accountWith(async () => {
      const error = new Error('network down');
      error.code = 'account/network';
      throw error;
    }),
  );
  const result = await readAccountBalance();
  assert.equal(result.supported, true);
  assert.equal(result.error, 'account/network');
});
