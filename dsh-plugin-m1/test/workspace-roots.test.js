// M4.11：授权根解析与路径比较的回归测试。
//
// 背景：`workspaceRoots` 以前只认 `ctx.get('workspaceRegistry').list()` 且只读
// `item.path`，注册表在 `apply` 时没就绪（或实体结构不同）就会静默退回
// `homedir()`；而手机上的工作区列表是「授权根 ∪ 会话 cwd」，于是在手机上
// 出现「列表里有这个目录，点开却说 workspace not authorized」。
//
// 这里把两个纯函数从 lib/index.js 里取出来跑（插件主文件会拉起中继服务器，
// 不适合直接 import），覆盖注册表的几种形态和路径归一化。
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const source = readFileSync(join(here, '..', 'lib', 'index.js'), 'utf8');

/** 按函数名从源码里截出 `function name(...) { ... }`（花括号配平）。 */
const grabFunction = (name) => {
  // `resolveWorkspaceFile` / `liveWorkspacePaths` 是 `const name = (...) => {...}` 写法，
  // 两种声明都要认。
  const arrow = source.indexOf(`\n  const ${name} = (`);
  const decl = source.indexOf(`\nfunction ${name}(`);
  const start = arrow >= 0 ? arrow : decl;
  assert.ok(start >= 0, `找不到函数 ${name}`);
  let depth = 0;
  let begun = false;
  for (let i = start + 1; i < source.length; i += 1) {
    const ch = source[i];
    if (ch === '{') {
      depth += 1;
      begun = true;
    } else if (ch === '}') {
      depth -= 1;
      if (begun && depth === 0) return source.slice(start + 1, i + 1);
    }
  }
  throw new Error(`函数 ${name} 花括号不配平`);
};

const module = await import(
  `data:text/javascript,${encodeURIComponent(
    `${grabFunction('canonicalPath')}\n${grabFunction('rootsFromRegistry')}\nexport { canonicalPath, rootsFromRegistry };`,
  )}`
);
const { canonicalPath, rootsFromRegistry } = module;

test('canonicalPath 忽略大小写、斜杠方向和末尾分隔符', () => {
  assert.equal(canonicalPath('D:\\Work\\项目\\'), canonicalPath('d:/work/项目'));
  assert.equal(canonicalPath('  C:\\Users\\user  '), 'c:\\users\\user');
  assert.equal(canonicalPath(''), '');
  assert.equal(canonicalPath(null), '');
});

test('rootsFromRegistry 认得 list() 返回的实体对象', () => {
  const roots = rootsFromRegistry({ list: () => [{ path: 'D:\\a\\项目' }, { path: 'D:\\b' }] });
  assert.deepEqual(roots, ['D:\\a\\项目', 'D:\\b']);
});

test('rootsFromRegistry 认得字符串数组与 root/cwd 字段', () => {
  assert.deepEqual(rootsFromRegistry({ list: () => ['D:\\a'] }), ['D:\\a']);
  assert.deepEqual(rootsFromRegistry({ list: () => [{ root: 'D:\\r' }, { cwd: 'D:\\c' }] }), ['D:\\r', 'D:\\c']);
});

test('rootsFromRegistry 兼容 all()/snapshot() 包一层以及 entities Map', () => {
  assert.deepEqual(rootsFromRegistry({ all: () => ({ workspaces: [{ path: 'D:\\x' }] }) }), ['D:\\x']);
  assert.deepEqual(rootsFromRegistry({ snapshot: () => ({ entries: [{ path: 'D:\\y' }] }) }), ['D:\\y']);
  const entities = new Map([['1', { path: 'D:\\m' }]]);
  assert.deepEqual(rootsFromRegistry({ entities }), ['D:\\m']);
});

test('rootsFromRegistry 对空/异常注册表返回空数组，让调用方回退', () => {
  assert.deepEqual(rootsFromRegistry(undefined), []);
  assert.deepEqual(rootsFromRegistry(null), []);
  assert.deepEqual(rootsFromRegistry({}), []);
  assert.deepEqual(
    rootsFromRegistry({
      list: () => {
        throw new Error('domain not ready');
      },
    }),
    [],
  );
});

test('源码里 resolveWorkspaceFile 用归一化比较并额外接受会话 cwd', () => {
  const fn = grabFunction('resolveWorkspaceFile');
  assert.match(fn, /canonicalPath\(item\) === wanted/);
  assert.match(fn, /liveWorkspacePaths\(\)/);
  assert.match(fn, /workspace not authorized/);
  const helper = grabFunction('liveWorkspacePaths');
  assert.match(helper, /header\?\.cwd/);
  assert.match(helper, /rootsFromRegistry/);
});
