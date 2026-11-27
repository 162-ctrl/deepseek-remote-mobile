// 第 2 条：token 卫生——agent 复用、按设备去重、过期回写、主动撤销。
// 第 3 条：磁盘上只存 sha256(token)，不存明文；老明文文件加载时一次性迁移。
//
// 背景：agent 每次重启都 `POST /auth/pair` 拿新 token，而 `hub.pair()` 以前无条件
// 生成新记录、旧记录永不清理、agent 的 deviceId 还是每次新生成的 ulid()。
// 结果 tokens.json 涨到 223 条（agent 189 条），任何一条泄漏都是完整 agent 权限。
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';

import { M1Hub } from '../lib/hub.js';

const silent = () => {};
const hash = (token) => createHash('sha256').update(String(token)).digest('hex');

/** 内存版 token 存储，接口与 lib/index.js 里传给 M1Hub 的 tokenStore 一致。 */
function memoryStore(rows = []) {
  let current = rows.map((row) => ({ ...row }));
  return {
    get rows() {
      return current;
    },
    load: () => current.map((row) => ({ ...row })),
    save: (next) => {
      current = next.map((row) => ({ ...row }));
    },
  };
}

function newHub(store) {
  return new M1Hub({ pairingCode: '246810', version: 'test', log: silent, tokenStore: store });
}

function agentRows(store) {
  return store.rows.filter((row) => row.role === 'agent');
}

test('同一台电脑连 pair 5 次，agent 记录最多留 2 条', () => {
  const store = memoryStore();
  const hub = newHub(store);
  for (let index = 0; index < 5; index += 1) {
    hub.pair({ pairingCode: '246810', clientName: 'my-desktop', role: 'agent' });
  }
  const rows = agentRows(store);
  assert.ok(rows.length <= 2, `期望 ≤ 2 条，实际 ${rows.length}`);
  // 留下的必须是最新两条：都认得出是同一台设备
  for (const row of rows) {
    assert.equal(row.deviceId, 'agent:my-desktop');
  }
});

test('两台不同电脑各 pair 3 次，各自 ≤ 2 条且互不影响', () => {
  const store = memoryStore();
  const hub = newHub(store);
  for (const name of ['desk-a', 'desk-a', 'desk-a', 'desk-b', 'desk-b', 'desk-b']) {
    hub.pair({ pairingCode: '246810', clientName: name, role: 'agent' });
  }
  const a = agentRows(store).filter((row) => row.deviceId === 'agent:desk-a');
  const b = agentRows(store).filter((row) => row.deviceId === 'agent:desk-b');
  assert.ok(a.length <= 2, `desk-a 期望 ≤ 2 条，实际 ${a.length}`);
  assert.ok(b.length <= 2, `desk-b 期望 ≤ 2 条，实际 ${b.length}`);
  assert.equal(a.length + b.length, agentRows(store).length, '不该混入其它设备');
});

test('过期记录在启动恢复时被剔除并写回盘', () => {
  const yesterday = new Date(Date.now() - 24 * 3600_000).toISOString();
  const tomorrow = new Date(Date.now() + 24 * 3600_000).toISOString();
  const store = memoryStore([
    { tokenHash: hash('old-expired'), role: 'agent', clientName: 'desk', deviceId: 'agent:desk', expiresAt: yesterday },
    { tokenHash: hash('still-good'), role: 'agent', clientName: 'desk', deviceId: 'agent:desk', expiresAt: tomorrow },
  ]);

  const hub = newHub(store);

  assert.equal(hub.authorizeToken('old-expired', 'agent'), false, '过期 token 不该通过鉴权');
  assert.equal(hub.authorizeToken('still-good', 'agent'), true);
  const hashes = store.rows.map((row) => row.tokenHash);
  assert.ok(!hashes.includes(hash('old-expired')), `过期记录应已回写剔除，实际剩：${hashes.join(', ')}`);
  assert.ok(hashes.includes(hash('still-good')));
});

test('revokeToken 之后 authorizeToken 立刻返回 false，且从盘上消失', () => {
  const store = memoryStore();
  const hub = newHub(store);
  const paired = hub.pair({ pairingCode: '246810', clientName: 'DeepSeek Remote 手机', role: 'app' });

  assert.equal(hub.authorizeToken(paired.token, 'app'), true);
  assert.equal(hub.revokeToken(paired.token), true);
  assert.equal(hub.authorizeToken(paired.token, 'app'), false);
  assert.ok(
    !store.rows.some((row) => row.tokenHash === hash(paired.token)),
    '撤销后不该还留在 tokens.json',
  );

  // 再撤销一次就是「已经没有这条了」
  assert.equal(hub.revokeToken(paired.token), false);
});

test('app token 不按设备去重（同一台手机会话过期后需要新 token）', () => {
  const store = memoryStore();
  const hub = newHub(store);
  const first = hub.pair({ pairingCode: '246810', clientName: 'DeepSeek Remote 手机', role: 'app' });
  const second = hub.pair({ pairingCode: '246810', clientName: 'DeepSeek Remote 手机', role: 'app' });
  assert.equal(hub.authorizeToken(first.token, 'app'), true);
  assert.equal(hub.authorizeToken(second.token, 'app'), true);
  assert.equal(store.rows.filter((row) => row.role === 'app').length, 2);
});

test('磁盘上没有明文 token，只有它的 sha256', () => {
  const store = memoryStore();
  const hub = newHub(store);
  const paired = hub.pair({ pairingCode: '246810', clientName: 'my-desktop', role: 'agent' });

  const row = store.rows.find((item) => item.tokenHash === hash(paired.token));
  assert.ok(row, '应该有这条记录（按哈希索引）');
  assert.equal(row.token, undefined, '行里不该有 token 字段');

  const raw = JSON.stringify(store.rows);
  assert.ok(!raw.includes(paired.token), `文件内容里不该出现明文 token：${raw.slice(0, 200)}`);
  assert.ok(raw.includes(hash(paired.token)), '应该能按哈希查到');

  // 明文仍然能用：服务端只做哈希查找
  assert.equal(hub.authorizeToken(paired.token, 'agent'), true);
});

test('老的明文 tokens.json 加载时一次性迁移成哈希，且仍然可用', () => {
  const tomorrow = new Date(Date.now() + 24 * 3600_000).toISOString();
  const store = memoryStore([
    { token: 'legacy-agent-token', role: 'agent', clientName: 'desk', deviceId: 'agent:desk', expiresAt: tomorrow },
  ]);

  const hub = newHub(store);

  assert.equal(hub.authorizeToken('legacy-agent-token', 'agent'), true, '迁移后老 token 仍要能连');
  const rows = store.rows;
  assert.equal(rows.length, 1);
  assert.equal(rows[0].token, undefined, '迁移后不该再有明文');
  assert.equal(rows[0].tokenHash, hash('legacy-agent-token'));
  assert.equal(rows[0].deviceId, 'agent:desk', '其余元数据要保留');
});
