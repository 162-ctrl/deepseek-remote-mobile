// 指令第 2 条第 4 点：`tools/prune-tokens.mjs` 的纯函数部分。
//
// 规则要和 `hub.js` 的按设备去重一致：过期删掉，同一 role + deviceId 只留
// expiresAt 最新的 2 条（留 2 条是容错：旧连接可能还握着上一条）。
import test from 'node:test';
import assert from 'node:assert/strict';

import { pruneTokens } from '../tools/prune-tokens.mjs';

const NOW = Date.parse('2026-11-22T12:00:00Z');

function token(overrides = {}) {
  return {
    token: Math.random().toString(16).slice(2),
    role: 'agent',
    clientName: 'DESKTOP',
    deviceId: 'agent:DESKTOP',
    expiresAt: new Date(NOW + 30 * 24 * 3600 * 1000).toISOString(),
    ...overrides,
  };
}

test('同一设备 5 条只留最新 2 条', () => {
  const records = [];
  for (let i = 0; i < 5; i += 1) {
    records.push(token({ expiresAt: new Date(NOW + (i + 1) * 1000).toISOString() }));
  }
  const { kept, stats } = pruneTokens(records, { now: NOW });
  assert.equal(kept.length, 2);
  assert.equal(stats.dropped, 3);
  // 留下的是最晚过期的两条
  assert.deepEqual(
    kept.map((item) => Date.parse(item.expiresAt)).sort(),
    [NOW + 4000, NOW + 5000].sort(),
  );
});

test('已过期的记录被删掉，且不算在「同设备多余」里', () => {
  const records = [
    token({ expiresAt: new Date(NOW - 86_400_000).toISOString() }), // 昨天过期
    token({ expiresAt: new Date(NOW + 1000).toISOString() }),
  ];
  const { kept, stats } = pruneTokens(records, { now: NOW });
  assert.equal(kept.length, 1);
  assert.equal(stats.expired, 1);
  assert.equal(stats.dropped, 0);
});

test('不同设备互不影响，app 与 agent 分开算', () => {
  const records = [
    token({ deviceId: 'agent:A' }),
    token({ deviceId: 'agent:A' }),
    token({ deviceId: 'agent:A' }),
    token({ deviceId: 'agent:B' }),
    token({ role: 'app', deviceId: 'dev_1' }),
    token({ role: 'app', deviceId: 'dev_2' }),
  ];
  const { kept, stats } = pruneTokens(records, { now: NOW });
  // A 留 2 条、B 留 1 条、两个 app 各 1 条 = 5
  assert.equal(kept.length, 5);
  assert.deepEqual(stats.byRole, { agent: 3, app: 2 });
  assert.equal(stats.groups, 4);
});

test('空表 / 坏记录不炸', () => {
  const { kept, stats } = pruneTokens(
    [null, {}, { token: '' }, token()],
    { now: NOW },
  );
  assert.equal(kept.length, 1);
  assert.equal(stats.total, 4);
});

test('M4.44：只认 tokenHash 的新文件也能清理，且原样保留哈希', () => {
  const hashed = (hash, deviceId, offset) => ({
    tokenHash: hash,
    role: 'agent',
    clientName: 'DESKTOP',
    deviceId,
    expiresAt: new Date(NOW + offset * 1000).toISOString(),
  });
  const records = [
    hashed('a'.repeat(64), 'agent:A', 1),
    hashed('b'.repeat(64), 'agent:A', 2),
    hashed('c'.repeat(64), 'agent:A', 3),
    hashed('d'.repeat(64), 'agent:B', 1),
    // 既没有 token 也没有 tokenHash：身份不明的行必须扔掉
    { role: 'agent', deviceId: 'agent:C', expiresAt: new Date(NOW + 1000).toISOString() },
  ];

  const { kept } = pruneTokens(records, { now: NOW });
  assert.equal(kept.length, 3, 'A 留 2 条 + B 留 1 条');
  assert.ok(kept.every((row) => typeof row.tokenHash === 'string' && row.tokenHash.length === 64));
  assert.deepEqual(
    kept.filter((row) => row.deviceId === 'agent:A').map((row) => row.tokenHash),
    ['c'.repeat(64), 'b'.repeat(64)],
  );
  assert.ok(!kept.some((row) => row.token !== undefined), '清理结果里不该冒出明文 token');
});

