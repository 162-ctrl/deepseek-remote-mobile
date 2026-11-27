// 指令第 6 条：`/api/v1/desktop/file/raw` 支持 Range。
//
// 以前无条件 200 + 全量，PDF 阅读器想跳页、弱网想续传都没法发 Range 请求。
// 注意 `/api/v1/app/apk` 是**有意**不支持 Range 的（App 每次整包拉取），
// 所以这里只盯 file/raw 一条路由。
import test from 'node:test';
import assert from 'node:assert/strict';

import { createRelayHttpServer } from '../lib/server.js';

const silent = () => {};
const SIZE = 1000;
const PAYLOAD = Buffer.from(Array.from({ length: SIZE }, (_, i) => i % 251));

function stubHub() {
  return {
    authorizeToken: () => true,
    agentOnline: true,
    pairingCode: '135790',
    appCount: 0,
    version: 'test',
    pair: () => ({ token: 't', role: 'app', deviceId: 'd1', expiresAt: '2099-01-01T00:00:00Z' }),
    revokeToken: () => true,
    rotatePairingCode: () => '135790',
    acceptUpgrade: () => null,
    isLocalRequest: () => true,
  };
}

async function startServer() {
  const server = createRelayHttpServer({
    hub: stubHub(),
    version: 'test',
    log: silent,
    pageContext: {
      readWorkspaceFileBytes: async () => ({
        absPath: 'D:/proj/demo.bin',
        size: SIZE,
        buffer: PAYLOAD,
      }),
    },
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  return { server, port: server.address().port };
}

async function getRaw(port, range) {
  const headers = { authorization: 'Bearer t' };
  if (range !== undefined) headers.range = range;
  const res = await fetch(
    `http://127.0.0.1:${port}/api/v1/desktop/file/raw?workspace=D%3A%2Fproj&path=demo.bin`,
    { headers },
  );
  const body = Buffer.from(await res.arrayBuffer());
  return { res, body };
}

test('Range: bytes=0-9 → 206，10 字节，带 content-range', async () => {
  const { server, port } = await startServer();
  try {
    const { res, body } = await getRaw(port, 'bytes=0-9');
    assert.equal(res.status, 206);
    assert.equal(res.headers.get('content-range'), `bytes 0-9/${SIZE}`);
    assert.equal(res.headers.get('accept-ranges'), 'bytes');
    assert.equal(body.length, 10);
    assert.deepEqual(body, PAYLOAD.subarray(0, 10));
  } finally {
    server.close();
  }
});

test('Range: bytes=10- → 206，剩下全部', async () => {
  const { server, port } = await startServer();
  try {
    const { res, body } = await getRaw(port, 'bytes=10-');
    assert.equal(res.status, 206);
    assert.equal(body.length, SIZE - 10);
    assert.deepEqual(body, PAYLOAD.subarray(10));
  } finally {
    server.close();
  }
});

test('Range: bytes=-5 → 206，最后 5 字节', async () => {
  const { server, port } = await startServer();
  try {
    const { res, body } = await getRaw(port, 'bytes=-5');
    assert.equal(res.status, 206);
    assert.equal(body.length, 5);
    assert.deepEqual(body, PAYLOAD.subarray(SIZE - 5));
  } finally {
    server.close();
  }
});

test('Range 超出文件大小 → 416 + content-range: bytes */size', async () => {
  const { server, port } = await startServer();
  try {
    const { res } = await getRaw(port, 'bytes=99999-');
    assert.equal(res.status, 416);
    assert.equal(res.headers.get('content-range'), `bytes */${SIZE}`);
  } finally {
    server.close();
  }
});

test('不带 Range → 200 全量，带 accept-ranges', async () => {
  const { server, port } = await startServer();
  try {
    const { res, body } = await getRaw(port);
    assert.equal(res.status, 200);
    assert.equal(res.headers.get('accept-ranges'), 'bytes');
    assert.equal(body.length, SIZE);
    assert.deepEqual(body, PAYLOAD);
  } finally {
    server.close();
  }
});

test('Range 是离谱字符串 → 退回 200 全量（不能 500）', async () => {
  const { server, port } = await startServer();
  try {
    const { res, body } = await getRaw(port, 'chapters=1-2');
    assert.equal(res.status, 200);
    assert.deepEqual(body, PAYLOAD);
  } finally {
    server.close();
  }
});
