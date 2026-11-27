// M4.11：附件落盘目录 resolveUploadDir 的判定（末段名 / 子目录名 / 完整路径 / 回退）
//
// 源码里的 resolveUploadDir 依赖 workspaceRootsNow()、ctx.get('sessions')、stateDir。
// 这里按花括号从 lib/index.js 截出函数体，替换成注入的实现后动态 import，
// 用真实临时目录验证四种"工作区名"写法都落到该工作区的「手机附件」下。

import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, join } from 'node:path';
import { test } from 'node:test';

const SOURCE_URL = new URL('../lib/index.js', import.meta.url);
const source = readFileSync(SOURCE_URL, 'utf8');

/** 按花括号配平截出 `const name = (...) => {...}` 或 `function name(...) {...}` 的函数体。 */
function grabFunction(name) {
  let start = source.indexOf(`\n  const ${name} = `);
  if (start < 0) start = source.indexOf(`\nfunction ${name}(`);
  if (start < 0) throw new Error(`找不到函数 ${name}`);
  let depth = 0;
  let begun = false;
  for (let i = start; i < source.length; i += 1) {
    const ch = source[i];
    if (ch === '{') {
      depth += 1;
      begun = true;
    } else if (ch === '}') {
      depth -= 1;
      if (begun && depth === 0) return source.slice(start + 1, i + 1);
    }
  }
  throw new Error(`函数 ${name} 的花括号没配平`);
}

const canonicalPath = (value) =>
  String(value ?? '')
    .trim()
    .replace(/\//g, '\\')
    .replace(/\\+$/, '')
    .toLowerCase();

test('resolveUploadDir 认得末段名、子目录名与完整路径，未知名字退回状态目录', async () => {
  const base = mkdtempSync(join(tmpdir(), 'dsh-upload-'));
  try {
    const rootA = join(base, 'deepseek手机端');
    const rootB = join(base, '项目');
    mkdirSync(rootA, { recursive: true });
    mkdirSync(rootB, { recursive: true });
    let sessionCwd = '';
    const fakeState = join(base, 'state');

    const body = grabFunction('resolveUploadDir')
      .replaceAll('findWorkspaceByName(', 'globalThis.__find(')
      .replace("ctx.get('sessions')", 'globalThis.__sessions');
    globalThis.__roots = () => [rootA, rootB];
    // M4.12：工作区名匹配走 findWorkspaceByName（优先「工作区」列表，再退回授权根）。
    globalThis.__find = (wanted) =>
      [rootA, rootB].find((root) => basename(root) === wanted || canonicalPath(root) === canonicalPath(wanted));
    globalThis.__sessions = { current: () => ({ header: { cwd: sessionCwd } }) };

    const factory = new Function(
      'canonicalPath',
      'join',
      'basename',
      'statSync',
      'mkdirSync',
      'UPLOAD_DIR_NAME',
      'stateDir',
      `return ${body.trim().replace(/^const resolveUploadDir =\s*/, '')};`,
    );
    const resolveUploadDir = factory(canonicalPath, join, basename, statSync, mkdirSync, '手机附件', fakeState);

    const expect = (wanted, dir) =>
      assert.equal(canonicalPath(resolveUploadDir(wanted)), canonicalPath(join(dir, '手机附件')), `wanted=${wanted}`);

    // 手机端传的就是工作区名（路径末段）：工作区恰好是授权根本身时也要认。
    expect('deepseek手机端', rootA);
    expect('项目', rootB);
    expect(rootA, rootA);
    expect(rootA.toLowerCase(), rootA);
    // 认不出来时退回状态目录，不抛异常。
    assert.equal(canonicalPath(resolveUploadDir('不存在的名字')), canonicalPath(join(fakeState, 'uploads')));
    assert.equal(canonicalPath(resolveUploadDir('')), canonicalPath(join(fakeState, 'uploads')));
    // 第 7 条：没有工作区名但有会话 cwd 时，落到会话目录下的「手机附件」。
    sessionCwd = rootB;
    assert.equal(canonicalPath(resolveUploadDir('')), canonicalPath(join(rootB, '手机附件')));
    // 目录是 resolveUploadDir 自己建出来的（不是测试提前建的）。
    assert.equal(statSync(join(rootB, '手机附件')).isDirectory(), true);
  } finally {
    delete globalThis.__roots;
    delete globalThis.__find;
    delete globalThis.__sessions;
    rmSync(base, { recursive: true, force: true });
  }
});

test('源码里 resolveUploadDir 用 canonicalPath 比较并接受授权根本身', () => {
  const body = grabFunction('resolveUploadDir');
  assert.match(body, /findWorkspaceByName\(wanted\)/, '工作区名应交给 findWorkspaceByName 匹配（M4.12）');
  assert.match(body, /canonicalPath\(hit\) === wantedKey/, '应按归一化路径比较（大小写/分隔符差异）');
  assert.match(body, /basename\(hit\) === wanted/, '应接受「末段名 == 工作区目录名」');
  assert.match(body, /mkdirSync\(target, \{ recursive: true \}\)/, '应自己建出「手机附件」目录');
});

test('findWorkspaceByName 优先认「工作区」列表里的目录（授权根不可靠时也能落对地方）', async () => {
  // M4.12：实测 DSH 刚重开时 workspaceRootsNow() 一度只剩 homedir()/顺序漂移，
  // 只按授权根匹配会让附件悄悄落回状态目录。这里让授权根只剩一个无关目录，
  // 而「工作区」列表里有目标目录，确认仍能命中。
  const base = mkdtempSync(join(tmpdir(), 'dsh-upload-'));
  try {
    const wanted = join(base, 'deepseek手机端');
    const other = join(base, '无关目录');
    const home = join(base, 'home');
    for (const dir of [wanted, other, home]) mkdirSync(dir, { recursive: true });

    const helpers = grabHelpers();
    const listWorkspaces = () => [{ path: wanted, name: 'deepseek手机端', sessions: 0, running: 0 }];
    const roots = () => [home];
    const body = grabFunction('findWorkspaceByName')
      .replaceAll('knownWorkspacePaths()', 'globalThis.__known()')
      .replace(/^\s*\{\s*$/, '{');
    globalThis.__known = () => {
      const paths = [];
      listWorkspaces().forEach((entry) => paths.push(entry.path));
      roots().forEach((root) => paths.push(root));
      return [...new Set(paths)];
    };
    const factory = new Function('canonicalPath', 'join', 'basename', 'statSync', `return ${body.trim().replace(/^const findWorkspaceByName =\s*/, '')};`);
    const findWorkspaceByName = factory(canonicalPath, join, basename, statSync);

    assert.equal(canonicalPath(findWorkspaceByName('deepseek手机端')), canonicalPath(wanted), '末段名');
    assert.equal(canonicalPath(findWorkspaceByName(wanted)), canonicalPath(wanted), '完整路径');
    assert.equal(findWorkspaceByName('不存在的名字'), undefined);
    // knownWorkspacePaths 自己也接上了「工作区列表 → 授权根」两条来源。
    assert.match(helpers.known, /listDesktopWorkspaces\(\)/);
    assert.match(helpers.known, /workspaceRootsNow\(\)/);
  } finally {
    delete globalThis.__known;
    rmSync(base, { recursive: true, force: true });
  }
});

function grabHelpers() {
  return {
    known: grabFunction('knownWorkspacePaths'),
  };
}
