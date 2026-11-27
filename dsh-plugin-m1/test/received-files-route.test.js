// M4.57：手机「功能 → 接收文件」的路由边界。
//
// 三件事：①`GET /api/v1/received` 吐列表；②`GET /api/v1/received/<name>`
// 吐字节；③删除与鉴权别漏。列表内容本身（按 mtime 倒序、跳过隐藏文件）
// 在 `received-files.test.js` 里盯着。
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { createRelayHttpServer } from '../lib/server.js';

const source = readFileSync(
  fileURLToPath(new URL('../lib/index.js', import.meta.url)),
  'utf8',
);

function fakeHub() {
  const tokens = new Map([
    ['agent-token', 'agent'],
    ['app-token', 'app'],
  ]);
  return {
    pairingCode: '000000',
    agentOnline: true,
    appCount: 1,
    authorizeToken(token, role = 'app') {
      const actual = tokens.get(String(token ?? ''));
      return actual !== undefined && actual === role;
    },
  };
}

async function withServer(pageContext, run) {
  const server = createRelayHttpServer({
    hub: fakeHub(),
    version: '0.2.42-test',
    pageContext: { port: 8787, ...pageContext },
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address();
  try {
    await run(`http://127.0.0.1:${port}`);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
}

const get = (base, path, token) =>
  fetch(`${base}${path}`, { headers: token ? { authorization: `Bearer ${token}` } : {} });

test('M4.57 有 token 时返回接收文件列表', async () => {
  const files = [{ name: '报告.md', size: 12, updatedAt: 1_700_000_000_000 }];
  await withServer({ receivedFiles: () => files }, async (base) => {
    const response = await get(base, '/api/v1/received', 'app-token');
    assert.equal(response.status, 200);
    const body = await response.json();
    assert.deepEqual(body.files, files);
  });
});

test('M4.57 没 token 时 401', async () => {
  await withServer({ receivedFiles: () => [] }, async (base) => {
    const response = await get(base, '/api/v1/received');
    assert.equal(response.status, 401);
    const body = await response.json();
    assert.equal(body.code, 'AUTH_FAILED');
  });
});

test('M4.57 下载一个文件时原样吐字节', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'm1-received-'));
  const path = join(dir, '报告.md');
  const content = '# 报告\n正文\n';
  writeFileSync(path, content, 'utf8');
  const file = { name: '报告.md', path, size: Buffer.byteLength(content) };
  await withServer({ receivedFile: (name) => (name === '报告.md' ? file : null) }, async (base) => {
    const response = await get(base, `/api/v1/received/${encodeURIComponent('报告.md')}`, 'app-token');
    assert.equal(response.status, 200);
    assert.match(response.headers.get('content-type') ?? '', /application\/octet-stream/);
    assert.equal(await response.text(), content);
  });
});

test('M4.57 不存在的文件 404', async () => {
  await withServer({ receivedFile: () => null }, async (base) => {
    const response = await get(base, '/api/v1/received/missing.md', 'app-token');
    assert.equal(response.status, 404);
    const body = await response.json();
    assert.equal(body.code, 'NOT_FOUND');
  });
});

test('M4.57 删除文件走 pageContext.deleteReceivedFile', async () => {
  const removed = [];
  await withServer(
    {
      deleteReceivedFile: (name) => {
        removed.push(name);
        return name === 'old.md';
      },
    },
    async (base) => {
      const ok = await fetch(`${base}/api/v1/received/old.md`, {
        method: 'DELETE',
        headers: { authorization: 'Bearer app-token' },
      });
      assert.equal(ok.status, 200);

      const missing = await fetch(`${base}/api/v1/received/other.md`, {
        method: 'DELETE',
        headers: { authorization: 'Bearer app-token' },
      });
      assert.equal(missing.status, 404);
      assert.deepEqual(removed, ['old.md', 'other.md']);
    },
  );
});

test('M4.57 index.js 把接收文件接进 pageContext', () => {
  assert.match(source, /const receivedDir = join\(stateDir, 'received'\);/);
  assert.match(source, /receivedFiles: \(\) => listReceivedFiles\(\)/);
  assert.match(source, /receivedFile: \(name\) => resolveReceivedFile\(name\)/);
  assert.match(source, /deleteReceivedFile: \(name\) => deleteReceivedFile\(name\)/);
  // 防目录穿越：解析时只认最后一段文件名。
  assert.match(source, /const safe = basename\(String\(name \?\? ''\)\.trim\(\)\);/);
});
