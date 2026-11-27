// M4.49：便携版 DSH 的「父进程兜底」——agent 由 Harness 主进程 spawn 时，
// 父进程 exe 就是 `<安装根>\DeepSeek Harness.exe`，据此推出安装根。
//
// 现场见 lib/dsh-install.js 顶部注释：2026-11-23 22:13 手机端「工作区怎么没有了」。
// 这一层是 agent 侧的自救，插件侧还会主动注入 DSH_INSTALL_ROOT（双保险）。
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { installRootFromParentExe } from '../agent/src/harness/acp/launcher.ts';

const here = dirname(fileURLToPath(import.meta.url));
const launcherSource = readFileSync(join(here, '..', 'agent', 'src', 'harness', 'acp', 'launcher.ts'), 'utf8');

test('父进程不是 Harness 时返回 null，不误判', () => {
  assert.equal(installRootFromParentExe('win32', process.ppid), null);
});

test('非 Windows 直接返回 null', () => {
  assert.equal(installRootFromParentExe('linux', 1), null);
  assert.equal(installRootFromParentExe('darwin', 4242), null);
});

test('非法父进程号不触发探测', () => {
  assert.equal(installRootFromParentExe('win32', 0), null);
  assert.equal(installRootFromParentExe('win32', -1), null);
});

test('discoverDshInstall 里父进程兜底排在抛错之前', () => {
  const parentCall = launcherSource.indexOf('const parentRoot = installRootFromParentExe();');
  const throwAt = launcherSource.indexOf("throw new HarnessError('HARNESS_NOT_INSTALLED'");
  assert.ok(parentCall > 0, '没找到父进程兜底调用');
  assert.ok(throwAt > parentCall, '兜底必须在抛错之前');
  assert.match(launcherSource, /installFromRoot\(parentRoot, 'parent'\)/);
  assert.match(launcherSource, /readonly source: 'env_override' \| 'path' \| 'default' \| 'root_override' \| 'parent';/);
});
