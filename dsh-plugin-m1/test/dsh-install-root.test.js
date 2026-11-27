// M4.49：Agent 在便携版 DSH 下必须知道安装目录，否则 `dsh --profile acp` 起不来。
//
// 现场：2026-11-23 22:13 手机端「工作区怎么没有了」——主机 agentOnline=false，
// agent 日志 `未找到 DeepSeek Harness 安装（可通过 DSH_INSTALL_ROOT 指定）`。
// 便携版装在 <DSH 安装目录>，五条发现路径全落空。
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

import { looksLikeDshRoot, resolveDshInstallRoot } from '../lib/dsh-install.js';

const here = dirname(fileURLToPath(import.meta.url));
const lib = join(here, '..', 'lib');
const supervisorSource = readFileSync(join(lib, 'supervisor.js'), 'utf8');
const indexSource = readFileSync(join(lib, 'index.js'), 'utf8');

/** 只认安装根下的 resources/app.asar。 */
const existsOnly = (root) => (candidate) => candidate === join(root, 'resources', 'app.asar');

test('从 Electron 主进程路径推出安装根（便携版 <DSH 安装目录>）', () => {
  const root = '<DSH 安装目录>';
  assert.equal(
    resolveDshInstallRoot({ env: {}, execPath: join(root, 'DeepSeek Harness.exe'), exists: existsOnly(root) }),
    root,
  );
});

test('用 node 跑起来的开发态不乱猜', () => {
  assert.equal(resolveDshInstallRoot({ env: {}, execPath: 'D:\\soft\\nodejs\\node.exe', exists: () => true }), '');
});

test('目录不像 Harness 安装根时返回空串', () => {
  assert.equal(
    resolveDshInstallRoot({ env: {}, execPath: 'D:\\somewhere\\DeepSeek Harness.exe', exists: () => false }),
    '',
  );
});

test('显式 DSH_INSTALL_ROOT 优先，且不做目录校验', () => {
  assert.equal(
    resolveDshInstallRoot({ env: { DSH_INSTALL_ROOT: 'E:\\custom\\harness' }, execPath: '', exists: () => false }),
    'E:\\custom\\harness',
  );
  assert.equal(resolveDshInstallRoot({ env: { DSH_INSTALL_ROOT: '   ' }, execPath: '', exists: () => false }), '');
});

test('looksLikeDshRoot 只认 resources/app.asar', () => {
  const root = '<DSH 安装目录>';
  assert.equal(looksLikeDshRoot(root, existsOnly(root)), true);
  assert.equal(looksLikeDshRoot(root, () => false), false);
  assert.equal(looksLikeDshRoot('', () => true), false);
  assert.equal(looksLikeDshRoot(undefined, () => true), false);
  assert.ok(join(root, 'resources', 'app.asar').includes(`${sep}resources${sep}app.asar`));
});

test('supervisor 把安装根塞进子进程环境', () => {
  assert.match(supervisorSource, /dshInstallRoot/);
  assert.match(supervisorSource, /\.\.\.\(dshInstallRoot\.length > 0 \? \{ DSH_INSTALL_ROOT: dshInstallRoot \} : \{\}\)/);
});

test('插件 apply 时把解析结果交给 supervisor', () => {
  assert.match(indexSource, /import \{ resolveDshInstallRoot \} from '\.\/dsh-install\.js';/);
  assert.match(indexSource, /dshInstallRoot: resolveDshInstallRoot\(\),/);
});
