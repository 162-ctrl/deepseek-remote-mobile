// M4.44 / 用户三阶段计划第 1 阶段第 3 条：tokens.json 的 Windows ACL。
//
// `writeFileSync(..., { mode: 0o600 })` 在 Windows 上不生效，文件会继承父目录权限。
// 这里既测纯解析/判定，也在 Windows 上真的对一个临时文件收紧 ACL 再读回来。
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import {
  foreignPrincipals,
  hardenPath,
  isCurrentUser,
  isSystemPrincipal,
  parsePrincipals,
  resolveIdentity,
} from '../lib/token-acl.js';

test('parsePrincipals 剥掉 icacls 打在同一行里的文件路径，并去重、转大写', () => {
  const target = 'C:\\Users\\user\\.dsh\\dsh-plugin-m1\\tokens.json';
  const stdout = [
    'C:\\Users\\user\\.dsh\\dsh-plugin-m1\\tokens.json DESKTOP-1\\user:(F)',
    '                                          BUILTIN\\Administrators:(F)',
    '                                          NT AUTHORITY\\SYSTEM:(F)',
    '',
    '已成功处理 1 个文件；处理 0 个文件时失败',
  ].join('\r\n');

  const principals = parsePrincipals(stdout, { target });
  assert.deepEqual(principals, [
    'DESKTOP-1\\user',
    'BUILTIN\\ADMINISTRATORS',
    'NT AUTHORITY\\SYSTEM',
  ]);

  // 不传 target 时也要能解析，只是首条会带上路径
  assert.equal(parsePrincipals(stdout).length, 3);
});

test('foreignPrincipals 只放过当前用户与系统主体', () => {
  const ok = ['DESKTOP-1\\user', 'NT AUTHORITY\\SYSTEM', 'BUILTIN\\Administrators'];
  assert.deepEqual(foreignPrincipals(ok, 'user'), []);
  assert.equal(isCurrentUser('DESKTOP-1\\user', 'user'), true);
  assert.equal(isSystemPrincipal('BUILTIN\\Administrators'), true);

  // BUILTIN\Users 是真正的风险项：同机任何登录用户都能读
  const risky = [...ok, 'BUILTIN\\USERS', 'EVERYONE'];
  assert.deepEqual(foreignPrincipals(risky, 'user'), ['BUILTIN\\USERS', 'EVERYONE']);
});

test('非 Windows 直接跳过（不假装成功）', () => {
  const result = hardenPath('C:\\whatever.json', { platform: 'darwin' });
  assert.equal(result.supported, false);
  assert.deepEqual(result.principals, []);
});

test('先授权再断继承——顺序反了会把文件锁死（2026-11-23 真实事故）', () => {
  const calls = [];
  const fakeRun = (args) => {
    calls.push(args);
    if (args[0].includes('inheritance')) return '';
    return 'C:\\tmp\\a.json DESKTOP-1\\user:(F)';
  };

  const result = hardenPath('C:\\tmp\\a.json', {
    run: fakeRun,
    identity: { username: 'user', sid: 'S-1-5-21-1-2-3-1001' },
    probe: () => true,
  });

  const inheritIndex = calls.findIndex((args) => args.includes('/inheritance:r'));
  assert.ok(inheritIndex > 0, '应该有断继承这一步');
  const grantBefore = calls
    .slice(0, inheritIndex)
    .filter((args) => args.includes('/grant:r'));
  assert.ok(grantBefore.length >= 2, `断继承之前必须先授权，实际只有 ${grantBefore.length} 条`);
  // 至少一条用的是当前用户、一条用的是 SID（SID 授权不怕中文系统组名）
  assert.ok(
    grantBefore.some((args) => String(args[2]).includes('user:(F)')),
    '要按账户名授权',
  );
  assert.ok(
    grantBefore.some((args) => String(args[2]).startsWith('*S-1-5-21-')),
    '要按 SID 授权',
  );
  assert.equal(result.locked, false);
  assert.equal(result.supported, true);
});

test('收紧后读不了就回退继承，绝不把文件锁成死文件', () => {
  const calls = [];
  const fakeRun = (args) => {
    calls.push(args);
    return 'C:\\tmp\\a.json DESKTOP-1\\user:(F)';
  };

  const result = hardenPath('C:\\tmp\\a.json', {
    run: fakeRun,
    identity: { username: 'user', sid: '' },
    probe: () => false,
  });

  assert.equal(result.locked, true, '读不了必须报 locked');
  assert.equal(result.supported, false);
  assert.ok(
    calls.some((args) => args.includes('/inheritance:e')),
    '必须把继承放回去',
  );
  assert.ok(
    calls.some((args) => args.includes('Everyone:(R)')),
    '兜底要给 Everyone 只读，保证文件还能用',
  );
});

test('resolveIdentity 从 whoami 的 CSV 里取 SID', () => {
  const fakeWho = (args) => {
    assert.deepEqual(args, ['/user', '/fo', 'csv', '/nh']);
    return '"DESKTOP-XXXXXXX\\user","S-1-5-21-93721788-984687858-4124935623-1001"\r\n';
  };
  const identity = resolveIdentity({ run: fakeWho });
  assert.equal(identity.sid, 'S-1-5-21-93721788-984687858-4124935623-1001');
  assert.equal(identity.username, process.env.USERNAME ?? '');
});

test('Windows 上真的收紧临时文件的 ACL，收紧后没有外部主体', (t) => {
  if (process.platform !== 'win32') {
    t.skip('只在 Windows 上验证真实 ACL');
    return;
  }
  const dir = mkdtempSync(join(tmpdir(), 'dsh-acl-'));
  const file = join(dir, 'tokens.json');
  writeFileSync(file, '[]', { encoding: 'utf8' });
  try {
    const result = hardenPath(file);
    assert.equal(result.supported, true, 'icacls 应该可用');
    assert.ok(result.principals.length > 0, '收紧后至少要能读回主体列表');
    assert.ok(
      result.principals.some((principal) => isCurrentUser(principal)),
      `当前用户应在授权列表里：${result.principals.join(', ')}`,
    );
    assert.deepEqual(
      foreignPrincipals(result.principals),
      [],
      `不该留下外部主体：${result.principals.join(', ')}`,
    );
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
