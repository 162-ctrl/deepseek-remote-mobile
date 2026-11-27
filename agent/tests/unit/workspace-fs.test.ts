/**
 * M2.6 工作区文件系统单测（node --test，Node 24 直接跑 .ts）。
 * 覆盖：列目录排序/忽略项、路径越界、读文件 sha256、缺失文件、二进制拒绝、截断。
 */
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtempSync, mkdirSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, before, test } from 'node:test';

import {
  MAX_WRITE_BYTES,
  WorkspaceFsError,
  listDirectory,
  readTextFile,
  resolveWorkspacePath,
  writeTextFile,
} from '../../src/relay/workspace-fs.ts';

let root = '';

before(() => {
  root = mkdtempSync(join(tmpdir(), 'm26-ws-'));
  mkdirSync(join(root, 'app', 'lib'), { recursive: true });
  mkdirSync(join(root, 'node_modules', 'x'), { recursive: true });
  mkdirSync(join(root, '.git'), { recursive: true });
  writeFileSync(join(root, 'README.md'), '# demo\nhello project\n', 'utf8');
  writeFileSync(join(root, 'app', 'pubspec.yaml'), 'name: demo\nversion: 0.1.0+1\n', 'utf8');
  writeFileSync(join(root, 'app', 'lib', 'main.dart'), 'void main() {}\n', 'utf8');
  writeFileSync(join(root, 'blob.bin'), Buffer.from([0x00, 0x01, 0x02, 0x00]));
  writeFileSync(join(root, 'big.txt'), 'x'.repeat(2048), 'utf8');
});

after(() => {
  if (root.length > 0) rmSync(root, { recursive: true, force: true });
});

test('listDirectory 根目录：目录在前、忽略 node_modules/.git', async () => {
  const listing = await listDirectory(root, root, '');
  assert.equal(listing.relativePath, '');
  assert.deepEqual(
    listing.entries.map((entry) => entry.name),
    ['app', 'big.txt', 'blob.bin', 'README.md'],
  );
  assert.equal(listing.entries[0]?.isDir, true);
  assert.equal(listing.ignoredCount, 2);
  assert.equal(listing.truncated, false);
});

test('listDirectory 子目录：path 用 / 分隔且带前缀', async () => {
  const listing = await listDirectory(root, root, 'app');
  assert.deepEqual(listing.entries.map((entry) => entry.name), ['lib', 'pubspec.yaml']);
  assert.equal(listing.entries[0]?.path, 'app/lib');
  assert.equal(listing.entries[1]?.path, 'app/pubspec.yaml');
});

test('listDirectory：不存在的目录 → DIR_NOT_FOUND', async () => {
  await assert.rejects(
    () => listDirectory(root, root, 'nope'),
    (error: unknown) => error instanceof WorkspaceFsError && error.code === 'DIR_NOT_FOUND',
  );
});

test('路径越界 → PATH_NOT_ALLOWED', async () => {
  await assert.rejects(
    () => listDirectory(root, root, '..'),
    (error: unknown) => error instanceof WorkspaceFsError && error.code === 'PATH_NOT_ALLOWED',
  );
  assert.throws(
    () => resolveWorkspacePath(root, join(root, '..', 'elsewhere'), ''),
    (error: unknown) => error instanceof WorkspaceFsError && error.code === 'PATH_NOT_ALLOWED',
  );
  assert.throws(
    () => resolveWorkspacePath(root, root, 'C:\\Windows\\win.ini'),
    (error: unknown) => error instanceof WorkspaceFsError && error.code === 'PATH_NOT_ALLOWED',
  );
});

test('readTextFile：内容与 sha256 正确', async () => {
  const file = await readTextFile(root, root, 'app/pubspec.yaml');
  assert.equal(file.relativePath, 'app/pubspec.yaml');
  assert.match(file.content, /name: demo/);
  assert.equal(file.size, 28);
  assert.equal(file.sha256, createHash('sha256').update(file.content).digest('hex'));
  assert.equal(file.truncated, false);
  assert.equal(file.binary, false);
});

test('readTextFile：缺失 → FILE_NOT_FOUND，目录 → IS_A_DIRECTORY', async () => {
  await assert.rejects(
    () => readTextFile(root, root, 'missing.txt'),
    (error: unknown) => error instanceof WorkspaceFsError && error.code === 'FILE_NOT_FOUND',
  );
  await assert.rejects(
    () => readTextFile(root, root, 'app'),
    (error: unknown) => error instanceof WorkspaceFsError && error.code === 'IS_A_DIRECTORY',
  );
});

test('readTextFile：二进制 → BINARY_FILE', async () => {
  await assert.rejects(
    () => readTextFile(root, root, 'blob.bin'),
    (error: unknown) => error instanceof WorkspaceFsError && error.code === 'BINARY_FILE',
  );
});

test('readTextFile：超过 maxBytes 截断并标 truncated', async () => {
  const file = await readTextFile(root, root, 'big.txt', 100);
  assert.equal(file.truncated, true);
  assert.equal(file.content.length, 100);
  assert.equal(file.size, 2048);
});

test('readTextFile：maxBytes 超过硬上限 → TOO_LARGE', async () => {
  await assert.rejects(
    () => readTextFile(root, root, 'README.md', 4 * 1024 * 1024),
    (error: unknown) => error instanceof WorkspaceFsError && error.code === 'TOO_LARGE',
  );
});

test('多授权根：可访问第二个根，缺省仍用第一个根', async () => {
  const second = mkdtempSync(join(tmpdir(), 'm26-ws2-'));
  try {
    mkdirSync(join(second, 'notes'), { recursive: true });
    writeFileSync(join(second, 'plan.md'), '# plan\n', 'utf8');

    const listing = await listDirectory([root, second], second, '');
    assert.deepEqual(listing.entries.map((entry) => entry.name), ['notes', 'plan.md']);
    const file = await readTextFile([root, second], second, 'plan.md');
    assert.equal(file.content, '# plan\n');

    // 不给 workspacePath 时回退到第一个根
    const fallback = await listDirectory([root, second], null, 'app');
    assert.deepEqual(fallback.entries.map((entry) => entry.name), ['lib', 'pubspec.yaml']);

    // 不在任何授权根内 → PATH_NOT_ALLOWED
    assert.throws(
      () => resolveWorkspacePath([root, second], join(tmpdir(), 'outside-dir'), ''),
      (error: unknown) => error instanceof WorkspaceFsError && error.code === 'PATH_NOT_ALLOWED',
    );
  } finally {
    rmSync(second, { recursive: true, force: true });
  }
});

/* -------------------------------------------------------------------------- */
/* M2.8 写入                                                                  */
/* -------------------------------------------------------------------------- */

function sha256(text: string): string {
  return createHash('sha256').update(text, 'utf8').digest('hex');
}

function assertWorkspaceError(code: string) {
  return (error: unknown) => error instanceof WorkspaceFsError && error.code === code;
}

test('writeTextFile：新建文件 → created=true，内容与 sha256 正确', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'm28-ws-'));
  try {
    mkdirSync(join(dir, 'notes'), { recursive: true });
    const result = await writeTextFile(dir, dir, 'notes/today.md', '# 今天\n写点东西\n');
    assert.equal(result.created, true);
    assert.equal(result.relativePath, 'notes/today.md');
    assert.equal(result.size, Buffer.byteLength('# 今天\n写点东西\n', 'utf8'));
    assert.equal(result.sha256, sha256('# 今天\n写点东西\n'));
    assert.match(result.modifiedAt, /^\d{4}-\d{2}-\d{2}T/);
    assert.equal(await readTextFile(dir, dir, 'notes/today.md').then((f) => f.content), '# 今天\n写点东西\n');
    // 不留下临时文件
    assert.deepEqual(readdirSync(join(dir, 'notes')), ['today.md']);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('writeTextFile：文件已存在但未带 baseSha256 → FILE_EXISTS 且原文件不变', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'm28-ws-'));
  try {
    writeFileSync(join(dir, 'a.txt'), 'old', 'utf8');
    await assert.rejects(() => writeTextFile(dir, dir, 'a.txt', 'new'), assertWorkspaceError('FILE_EXISTS'));
    assert.equal(await readTextFile(dir, dir, 'a.txt').then((f) => f.content), 'old');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('writeTextFile：baseSha256 一致 → 覆盖成功，created=false', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'm28-ws-'));
  try {
    writeFileSync(join(dir, 'a.txt'), 'old', 'utf8');
    const result = await writeTextFile(dir, dir, 'a.txt', 'new', { baseSha256: sha256('old') });
    assert.equal(result.created, false);
    assert.equal(result.sha256, sha256('new'));
    assert.equal(await readTextFile(dir, dir, 'a.txt').then((f) => f.content), 'new');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('writeTextFile：baseSha256 过期 → CONFLICT，原文件不变', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'm28-ws-'));
  try {
    writeFileSync(join(dir, 'a.txt'), 'changed-on-desktop', 'utf8');
    await assert.rejects(
      () => writeTextFile(dir, dir, 'a.txt', 'from-phone', { baseSha256: sha256('old') }),
      assertWorkspaceError('CONFLICT'),
    );
    assert.equal(
      await readTextFile(dir, dir, 'a.txt').then((f) => f.content),
      'changed-on-desktop',
    );
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('writeTextFile：带 baseSha256 但文件已不在 → FILE_NOT_FOUND', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'm28-ws-'));
  try {
    await assert.rejects(
      () => writeTextFile(dir, dir, 'gone.txt', 'x', { baseSha256: sha256('x') }),
      assertWorkspaceError('FILE_NOT_FOUND'),
    );
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('writeTextFile：force 跳过存在性检查但原文件被覆盖', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'm28-ws-'));
  try {
    writeFileSync(join(dir, 'a.txt'), 'old', 'utf8');
    const result = await writeTextFile(dir, dir, 'a.txt', 'forced', { force: true });
    assert.equal(result.created, false);
    assert.equal(await readTextFile(dir, dir, 'a.txt').then((f) => f.content), 'forced');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('writeTextFile：忽略目录内 → PATH_NOT_ALLOWED', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'm28-ws-'));
  try {
    mkdirSync(join(dir, 'node_modules'), { recursive: true });
    await assert.rejects(
      () => writeTextFile(dir, dir, 'node_modules/x/index.js', 'x'),
      assertWorkspaceError('PATH_NOT_ALLOWED'),
    );
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('writeTextFile：父目录不存在 → DIR_NOT_FOUND；目标越界 → PATH_NOT_ALLOWED', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'm28-ws-'));
  try {
    await assert.rejects(() => writeTextFile(dir, dir, 'no/dir/a.txt', 'x'), assertWorkspaceError('DIR_NOT_FOUND'));
    await assert.rejects(() => writeTextFile(dir, dir, '../escape.txt', 'x'), assertWorkspaceError('PATH_NOT_ALLOWED'));
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('writeTextFile：目标是目录 → IS_A_DIRECTORY', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'm28-ws-'));
  try {
    mkdirSync(join(dir, 'folder'), { recursive: true });
    await assert.rejects(() => writeTextFile(dir, dir, 'folder', 'x'), assertWorkspaceError('IS_A_DIRECTORY'));
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('writeTextFile：超过 512KiB → TOO_LARGE；含 NUL → BINARY_FILE', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'm28-ws-'));
  try {
    await assert.rejects(
      () => writeTextFile(dir, dir, 'big.txt', 'x'.repeat(MAX_WRITE_BYTES + 1)),
      assertWorkspaceError('TOO_LARGE'),
    );
    await assert.rejects(
      () => writeTextFile(dir, dir, 'bin.txt', 'a\u0000b'),
      assertWorkspaceError('BINARY_FILE'),
    );
    assert.deepEqual(readdirSync(dir), []);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
