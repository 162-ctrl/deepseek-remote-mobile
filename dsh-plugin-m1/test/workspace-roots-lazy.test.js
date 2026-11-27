// M4.11：授权目录必须「懒解析」，不能在 apply 时定死。
//
// 现象：手机上「工作区」列表里有 D:\… 的项目，点开文件却
// `workspace not authorized`；`/deepseek-remote/api/status` 的
// `workspaces` 只剩 `["C:\\Users\\user"]`。
// 根因：`workspaceRegistry` 是 async Service（init 等 storageDomain +
// sessionPersistence），插件 apply 时它还是 undefined，于是
// `resolveWorkspaceRoots` 退到 homedir 并被永久缓存。
//
// 这里守住两件事：① 源码顶层不再有 `const workspaceRoots = resolve…`；
// ② 所有读取点走 `workspaceRootsNow()`。
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const source = readFileSync(join(here, '..', 'lib', 'index.js'), 'utf8');

test('授权目录在 apply 里是懒解析（带 TTL），不是一次性常量', () => {
  assert.doesNotMatch(source, /const workspaceRoots = resolveWorkspaceRoots\(/);
  assert.match(source, /const workspaceRootsNow = \(\) => \{/);
  assert.match(source, /ROOTS_TTL_MS/);
  assert.match(source, /rootsCache = resolveWorkspaceRoots\(config, ctx\)/);
});

test('所有 workspaceRoots 读取点都走 workspaceRootsNow()', () => {
  const uses = [...source.matchAll(/workspaceRoots(?!Now)/g)].map((m) => m.index);
  const allowed = new Set();
  for (const m of source.matchAll(/config\?\.workspaceRoots\b/g)) allowed.add(m.index + m[0].indexOf('workspaceRoots'));
  for (const m of source.matchAll(/workspaceRoots: workspaceRootsNow\(\)/g)) allowed.add(m.index + m[0].indexOf('workspaceRoots'));
  const stray = uses.filter((at) => !allowed.has(at));
  assert.deepEqual(stray, [], `这些位置的 workspaceRoots 没走懒解析：${stray.map((at) => source.slice(at - 60, at + 60)).join(' | ')}`);
});

test('配置里仍然可以显式指定 workspaceRoots（不被懒解析覆盖）', () => {
  assert.match(source, /function resolveWorkspaceRoots\(config, ctx\) \{/);
  assert.match(source, /const explicit = normalizeRoots\(config\?\.workspaceRoots\);/);
  assert.match(source, /if \(explicit\.length > 0\) return explicit;/);
});
