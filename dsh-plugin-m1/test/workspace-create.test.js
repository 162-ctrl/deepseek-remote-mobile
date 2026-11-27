// M4.13：新建工作区「指定父目录」的回归测试。
//
// 背景：`createDesktopWorkspace(name)` 以前只会建在**第一个**授权根下，手机端
// 想「新项目都放到 D:\Projects\项目 里」时，实际落点取决于授权根顺序，甚至会落到
// `homedir()`。这里把父目录判定与新建逻辑抽出来跑，断言：
//   1. 指定 parentDir 时建在它下面；
//   2. parentDir 不在授权根下、但自己是个目录时也放行（用户显式指定）；
//   3. 没指定 parentDir 时行为不变（第一个授权根）；
//   4. 非法名字要被拒。
//
// 插件主文件会拉起中继服务器，不适合直接 import，所以按函数名从源码截取并注入依赖。
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const source = readFileSync(join(here, '..', 'lib', 'index.js'), 'utf8');

/** 按函数名从源码里截出 `function name(...) { ... }` 或 `const name = (...) => {...}`（花括号配平）。 */
const grabFunction = (name) => {
  const arrow = source.indexOf(`\n  const ${name} = async (`);
  const arrowSync = source.indexOf(`\n  const ${name} = (`);
  const decl = source.indexOf(`\nfunction ${name}(`);
  const start = arrow >= 0 ? arrow : arrowSync >= 0 ? arrowSync : decl;
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

const canonicalPathSrc = grabFunction('canonicalPath');
const resolveParentSrc = grabFunction('resolveParentDir');
const createSrc = grabFunction('createDesktopWorkspace');
const registerSrc = grabFunction('registerDesktopWorkspace');
const projectParentSrc = grabFunction('projectParentPath');
assert.match(canonicalPathSrc, /toLowerCase\(\)/);
assert.match(resolveParentSrc, /workspaceRootsNow/);
assert.match(createSrc, /parentDir/);
assert.match(createSrc, /registerDesktopWorkspace/);
assert.match(registerSrc, /workspaceRegistry/);
assert.match(projectParentSrc, /DEFAULT_PROJECT_PARENT/);

/** 用假的文件系统拼一份可执行的模块，避免真的建目录。 */
const build = ({ roots = [], dirs = [], registerFails = false } = {}) => {
  const created = [];
  const registered = [];
  const existing = new Set(dirs);
  const code = `
${canonicalPathSrc}
const sep = '\\\\';
const DEFAULT_PROJECT_PARENT = 'D:\\\\\\\\用户\\\\\\\\项目';
const join = (...parts) => parts.filter(Boolean).join('\\\\');
const dirname = (p) => {
  const idx = p.lastIndexOf('\\\\');
  return idx <= 0 ? p : p.slice(0, idx);
};
const existsSync = (p) => __existing.has(p);
const statSync = (p) => ({ isDirectory: () => true });
const mkdirSync = (p) => { __created.push(p); __existing.add(p); };
const workspaceRootsNow = () => __roots;
const resolveUploadDir = () => '';
const __logs = [];
const log = (line) => { __logs.push(String(line)); };
const ctx = {
  get: (name) =>
    name === 'workspaceRegistry'
      ? {
          create: async (p, title) => {
            if (__registerFails) throw new Error('registry locked');
            __registered.push([p, title]);
          },
        }
      : undefined,
};
${resolveParentSrc}
${projectParentSrc}
${registerSrc}
${createSrc}
export { resolveParentDir, projectParentPath, createDesktopWorkspace, DEFAULT_PROJECT_PARENT };
`;
  const factory = new Function(
    '__roots',
    '__existing',
    '__created',
    '__registered',
    '__registerFails',
    `${code}`.replace(/export \{[^}]*\};/, 'return { resolveParentDir, projectParentPath, createDesktopWorkspace, DEFAULT_PROJECT_PARENT, __logs };'),
  );
  const api = factory(roots, existing, created, registered, registerFails);
  return { ...api, created, registered, logs: api.__logs };
};

const PROJECT = 'D:\\Projects\\项目';
const ROOTS = [PROJECT, '<项目根>', 'D:\\Projects\\课程\\上册\\计算方法实验'];

test('resolveParentDir 认出授权根下的目录', () => {
  const { resolveParentDir } = build({ roots: ROOTS, dirs: [PROJECT] });
  assert.equal(resolveParentDir(PROJECT), PROJECT);
  // 末尾分隔符 / 斜杠方向 / 大小写都不影响。
  assert.equal(resolveParentDir('d:/用户/项目/'), PROJECT);
});

test('projectParentPath 优先用 D:\\Projects\\项目', () => {
  const { projectParentPath } = build({ roots: ROOTS, dirs: [PROJECT] });
  assert.equal(projectParentPath(), PROJECT);
});

test('没指定 parentDir 时退回第一个授权根（老行为不变）', async () => {
  const env = build({ roots: ROOTS, dirs: [] });
  const result = await env.createDesktopWorkspace('新项目');
  assert.equal(result.parent, ROOTS[0]);
  assert.equal(result.path, join(ROOTS[0], '新项目'));
  assert.deepEqual(env.created, [join(ROOTS[0], '新项目')]);
});

test('指定 parentDir 时建在它下面', async () => {
  const env = build({ roots: ROOTS, dirs: [PROJECT] });
  const result = await env.createDesktopWorkspace('新项目', PROJECT);
  assert.equal(result.path, join(PROJECT, '新项目'));
  assert.equal(result.name, '新项目');
  assert.equal(result.parent, PROJECT);
});

test('parentDir 不在授权根下但目录真实存在时也放行', async () => {
  const outside = 'E:\\别的地方';
  const env = build({ roots: ROOTS, dirs: [outside] });
  const result = await env.createDesktopWorkspace('新项目', outside);
  assert.equal(result.path, join(outside, '新项目'));
});

test('已存在的子目录直接复用，不重复 mkdir', async () => {
  const env = build({ roots: ROOTS, dirs: [PROJECT, join(PROJECT, '旧项目')] });
  const result = await env.createDesktopWorkspace('旧项目', PROJECT);
  assert.equal(result.path, join(PROJECT, '旧项目'));
  assert.deepEqual(env.created, []);
});

test('非法名字被拒（空、点、含非法字符会被替换）', async () => {
  const env = build({ roots: ROOTS, dirs: [PROJECT] });
  await assert.rejects(() => env.createDesktopWorkspace('  ', PROJECT), /invalid workspace name/);
  await assert.rejects(() => env.createDesktopWorkspace('..', PROJECT), /invalid workspace name/);
  const cleaned = await env.createDesktopWorkspace('新/项目:1', PROJECT);
  assert.equal(cleaned.name, '新-项目-1');
});

test('新建后把目录注册进 DSH 的 workspaceRegistry', async () => {
  const env = build({ roots: ROOTS, dirs: [PROJECT] });
  const result = await env.createDesktopWorkspace('新项目', PROJECT);
  assert.equal(result.registered, true);
  assert.deepEqual(env.registered, [[join(PROJECT, '新项目'), '新项目']]);
});

test('复用已存在的目录时也补一次注册（幂等）', async () => {
  const env = build({ roots: ROOTS, dirs: [PROJECT, join(PROJECT, '旧项目')] });
  const result = await env.createDesktopWorkspace('旧项目', PROJECT);
  assert.equal(result.registered, true);
  assert.deepEqual(env.created, []);
  assert.deepEqual(env.registered, [[join(PROJECT, '旧项目'), '旧项目']]);
});

test('注册失败不挡建目录，但要留日志', async () => {
  const env = build({ roots: ROOTS, dirs: [PROJECT], registerFails: true });
  const result = await env.createDesktopWorkspace('新项目', PROJECT);
  assert.equal(result.registered, false);
  assert.deepEqual(env.created, [join(PROJECT, '新项目')]);
  assert.match(env.logs.join('\n'), /工作区注册失败/);
});

test('一个授权根都没有时明确报错', async () => {
  const env = build({ roots: [], dirs: [] });
  await assert.rejects(() => env.createDesktopWorkspace('新项目'), /no workspace root/);
});
