// 指令第 7 条：大响应 gzip。
//
// 会话直播首屏实测 175~253 KB 明文，走隧道往返 1~2.4 秒。gzip 之后通常只剩
// 1/3。只压 ≥4 KB 的响应：几百字节的东西压完可能更大，白烧 CPU。
//
// 这里用 `node:http` 而不是 `fetch`：undici 的 fetch 会自己解压并吞掉
// `content-encoding`，拿不到线上真实的字节数。
import test from 'node:test';
import assert from 'node:assert/strict';
import { request } from 'node:http';
import { gunzipSync } from 'node:zlib';

import { createRelayHttpServer } from '../lib/server.js';

const silent = () => {};

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

/** 造一个几百 KB 的假 feed：每条事件带一段中文，重复度不高，压缩率真实。 */
function bigFeed() {
  const events = [];
  for (let i = 0; i < 800; i += 1) {
    events.push({
      seq: i + 1,
      kind: i % 3 === 0 ? 'tool-call' : 'assistant',
      text: `第 ${i} 条：这段文字用来把响应撑到几百 KB，好验证压缩率与解压一致性。`,
      at: 1760000000000 + i,
    });
  }
  return { sessionId: 's1', running: true, lastSeq: 800, events, chat: events.slice(0, 12) };
}

async function startServer(feed = bigFeed()) {
  const server = createRelayHttpServer({
    hub: stubHub(),
    version: 'test',
    log: silent,
    pageContext: {
      desktopSessionEvents: () => feed,
    },
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  return { server, port: server.address().port, feed };
}

/** 发一个请求，原样拿回 status / headers / 未解压的 body。 */
function rawGet(port, path, headers = {}) {
  return new Promise((resolve, reject) => {
    const req = request(
      { host: '127.0.0.1', port, path, method: 'GET', headers: { authorization: 'Bearer t', ...headers } },
      (res) => {
        const chunks = [];
        res.on('data', (chunk) => chunks.push(chunk));
        res.on('end', () =>
          resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks) }),
        );
      },
    );
    req.on('error', reject);
    req.end();
  });
}

test('带 Accept-Encoding: gzip → content-encoding: gzip，字节数 < 明文一半', async () => {
  const { server, port, feed } = await startServer();
  try {
    const res = await rawGet(port, '/api/v1/desktop/sessions/s1/events', {
      'accept-encoding': 'gzip',
    });
    assert.equal(res.status, 200);
    assert.equal(res.headers['content-encoding'], 'gzip');
    assert.equal(res.headers.vary, 'accept-encoding');
    const plain = Buffer.from(JSON.stringify(feed), 'utf8');
    assert.ok(
      res.body.length < plain.length / 2,
      `压缩后 ${res.body.length} B 应小于明文 ${plain.length} B 的一半`,
    );
    // 解压后必须和明文逐字节一致
    assert.deepEqual(gunzipSync(res.body), plain);
  } finally {
    server.close();
  }
});

test('不带 Accept-Encoding → 不压缩，body 是明文 JSON', async () => {
  const { server, port, feed } = await startServer();
  try {
    const res = await rawGet(port, '/api/v1/desktop/sessions/s1/events');
    assert.equal(res.status, 200);
    assert.equal(res.headers['content-encoding'], undefined);
    assert.equal(res.body.length, Buffer.from(JSON.stringify(feed), 'utf8').length);
    assert.deepEqual(JSON.parse(res.body.toString('utf8')), feed);
  } finally {
    server.close();
  }
});

test('小响应即使带 gzip 也不压缩（4 KB 阈值）', async () => {
  const { server, port } = await startServer();
  try {
    const res = await rawGet(port, '/api/v1/health', { 'accept-encoding': 'gzip' });
    assert.equal(res.status, 200);
    assert.equal(res.headers['content-encoding'], undefined);
    assert.equal(JSON.parse(res.body.toString('utf8')).status, 'ok');
  } finally {
    server.close();
  }
});

test('压缩后的 content-length 与真实字节数一致（没被截断）', async () => {
  const { server, port } = await startServer();
  try {
    const res = await rawGet(port, '/api/v1/desktop/sessions/s1/events', {
      'accept-encoding': 'gzip, deflate, br',
    });
    assert.equal(res.headers['content-encoding'], 'gzip');
    assert.equal(Number(res.headers['content-length']), res.body.length);
    assert.ok(gunzipSync(res.body).length > 0);
  } finally {
    server.close();
  }
});
