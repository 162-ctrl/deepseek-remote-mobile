// M4.57：接收文件目录的读法（列表顺序、隐藏文件、目录穿越）。
//
// 这里直接拿出 index.js 里的三个小函数跑，不启动 HTTP；
// 路由层在 `received-files-route.test.js`。
import test from 'node:test';
import assert from 'node:assert/strict';
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  statSync,
  unlinkSync,
  utimesSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const source = readFileSync(
  fileURLToPath(new URL('../lib/index.js', import.meta.url)),
  'utf8',
);

const grabArrow = (name) => {
  const start = source.indexOf(`const ${name} = (`);
  assert.ok(start >= 0, `找不到函数 ${name}`);
  const bodyStart = source.indexOf('{', source.indexOf('=>', start));
  if (bodyStart < 0) {
    const end = source.indexOf(';', start);
    return source.slice(start, end + 1);
  }
  let depth = 0;
  for (let i = bodyStart; i < source.length; i += 1) {
    const ch = source[i];
    if (ch === '{') depth += 1;
    else if (ch === '}') {
      depth -= 1;
      if (depth === 0) return source.slice(start, i + 2);
    }
  }
  throw new Error(`函数 ${name} 花括号不配平`);
};

const buildList = (receivedDir) => {
  const factory = new Function(
    'receivedDir',
    'readdirSync',
    'statSync',
    'join',
    'RECEIVED_LIST_LIMIT',
    `${grabArrow('listReceivedFiles')}; return listReceivedFiles;`,
  );
  return factory(receivedDir, readdirSync, statSync, join, 200);
};

const buildResolve = (receivedDir) => {
  const factory = new Function(
    'receivedDir',
    'basename',
    'statSync',
    'join',
    `${grabArrow('resolveReceivedFile')}; return resolveReceivedFile;`,
  );
  return factory(receivedDir, basename, statSync, join);
};

const buildDelete = (resolveReceivedFile) => {
  const factory = new Function(
    'resolveReceivedFile',
    'unlinkSync',
    `${grabArrow('deleteReceivedFile')}; return deleteReceivedFile;`,
  );
  return factory(resolveReceivedFile, unlinkSync);
};

const fixture = () => {
  const dir = mkdtempSync(join(tmpdir(), 'm1-received-'));
  writeFileSync(join(dir, '旧文件.md'), 'old', 'utf8');
  writeFileSync(join(dir, '新文件.md'), 'new', 'utf8');
  writeFileSync(join(dir, '.hidden.md'), 'secret', 'utf8');
  mkdirSync(join(dir, '子目录'));
  // 让「旧文件」确实更旧：utimes 在部分文件系统上精度是秒。
  utimesSync(join(dir, '旧文件.md'), new Date('2020-01-01T00:00:00Z'), new Date('2020-01-01T00:00:00Z'));
  utimesSync(join(dir, '新文件.md'), new Date('2024-01-01T00:00:00Z'), new Date('2024-01-01T00:00:00Z'));
  return dir;
};

test('M4.57 列表按修改时间倒序，跳过隐藏文件与子目录', () => {
  const dir = fixture();
  const list = buildList(dir);
  const files = list();
  assert.deepEqual(files.map((item) => item.name), ['新文件.md', '旧文件.md']);
  assert.ok(files.every((item) => typeof item.updatedAt === 'number'));
});

test('M4.57 列表最多 200 条', () => {
  const dir = fixture();
  const factory = new Function(
    'receivedDir',
    'readdirSync',
    'statSync',
    'join',
    'RECEIVED_LIST_LIMIT',
    `${grabArrow('listReceivedFiles')}; return listReceivedFiles;`,
  );
  const list = factory(dir, readdirSync, statSync, join, 1);
  assert.equal(list().length, 1);
});

test('M4.57 解析文件名只认最后一段，不许穿越', () => {
  const dir = fixture();
  const resolve = buildResolve(dir);
  const hit = resolve('新文件.md');
  assert.equal(hit.name, '新文件.md');
  assert.equal(resolve('../secret.md'), null);
  assert.equal(resolve('..'), null);
  assert.equal(resolve('.hidden.md'), null);
  assert.equal(resolve('子目录'), null);
});

test('M4.57 删除只动解析得到的那个文件', () => {
  const dir = fixture();
  const resolve = buildResolve(dir);
  const remove = buildDelete(resolve);
  assert.equal(remove('新文件.md'), true);
  assert.equal(remove('新文件.md'), false);
  assert.ok(!readdirSync(dir).includes('新文件.md'));
  assert.ok(readdirSync(dir).includes('旧文件.md'));
});
