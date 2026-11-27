// M4.43：agent 在任务进行中掉线，会让那个会话永久锁死。
//
// 背景：hub 的 `busy` 只在两处变动——
//   · `prompt.send` 时置 true（lib/hub.js）；
//   · 收到 `task.state` 的 completed/failed/cancelled 时置 false。
// 如果 agent 在任务跑到一半时断线（插件重载、DSH 重启、网络抖动），终态事件永远不会来，
// `busy` 就一直停在 true。之后用户在这个会话里发任何指令都被 `SESSION_BUSY` 顶回来，
// 手机上表现为「发不出去、只能重启插件」。
//
// 修复：`#attachAgent` 的 close 回调里放掉所有会话的 busy。
// 这个测试用真实 WebSocket 走一遍完整链路，确保：
//   1. agent 断线 → 会话可继续使用（不再永久锁死）；
//   2. 正常完成流程不受影响；
//   3. busy 期间的并发互斥没有被削弱。
import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { connect } from 'node:net';
import { randomBytes } from 'node:crypto';

import { M1Hub } from '../lib/hub.js';

const PAIRING_CODE = '246810';

/** 零依赖最小 WebSocket 客户端（与插件自身实现对齐，不引入 ws 包）。 */
function wsConnect(port, role, token) {
  return new Promise((resolve, reject) => {
    const key = randomBytes(16).toString('base64');
    const sock = connect(port, '127.0.0.1', () => {
      sock.write(
        `GET /ws?role=${role}&token=${token} HTTP/1.1\r\n` +
          `Host: 127.0.0.1:${port}\r\n` +
          'Upgrade: websocket\r\nConnection: Upgrade\r\n' +
          `Sec-WebSocket-Key: ${key}\r\nSec-WebSocket-Version: 13\r\n\r\n`,
      );
    });
    const client = { msgs: [], close: () => sock.destroy() };
    let handshook = false;
    let buf = Buffer.alloc(0);
    sock.on('data', (chunk) => {
      buf = Buffer.concat([buf, chunk]);
      if (!handshook) {
        const end = buf.indexOf('\r\n\r\n');
        if (end < 0) return;
        handshook = true;
        buf = buf.subarray(end + 4);
        resolve(client);
      }
      while (buf.length >= 2) {
        const len0 = buf[1] & 0x7f;
        let offset = 2;
        let len = len0;
        if (len0 === 126) {
          if (buf.length < 4) return;
          len = buf.readUInt16BE(2);
          offset = 4;
        } else if (len0 === 127) {
          if (buf.length < 10) return;
          len = Number(buf.readBigUInt64BE(2));
          offset = 10;
        }
        if (buf.length < offset + len) return;
        const payload = buf.subarray(offset, offset + len);
        buf = buf.subarray(offset + len);
        try {
          client.msgs.push(JSON.parse(payload.toString('utf8')));
        } catch {
          /* 控制帧忽略 */
        }
      }
    });
    sock.on('error', reject);
    client.send = (obj) => {
      const data = Buffer.from(JSON.stringify(obj), 'utf8');
      const mask = randomBytes(4);
      let header;
      if (data.length < 126) {
        header = Buffer.from([0x81, 0x80 | data.length]);
      } else {
        header = Buffer.alloc(4);
        header[0] = 0x81;
        header[1] = 0x80 | 126;
        header.writeUInt16BE(data.length, 2);
      }
      const masked = Buffer.from(data);
      for (let i = 0; i < masked.length; i += 1) masked[i] ^= mask[i % 4];
      sock.write(Buffer.concat([header, mask, masked]));
    };
  });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** 起一个只用 hub 的 ws 服务，返回 { port, agentTok, appTok, close }。 */
async function startRelay() {
  const hub = new M1Hub({ pairingCode: PAIRING_CODE, version: 'test', log: () => {} });
  const server = createServer((req, res) => {
    res.writeHead(404);
    res.end();
  });
  server.on('upgrade', (req, socket) => {
    hub.acceptUpgrade(req, socket);
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const port = server.address().port;
  const token = (role) => hub.pair({ pairingCode: PAIRING_CODE, clientName: role, role }).token;
  return {
    port,
    agentTok: token('agent'),
    appTok: token('app'),
    close: () => {
      server.close();
    },
  };
}

/**
 * 跑一个用例并保证收尾：断言失败时也要把 socket / server 关掉，
 * 否则 node:test 进程会因为残留 handle 挂在那里不退出。
 */
async function withRelay(fn) {
  const relay = await startRelay();
  const peers = [];
  const open = async (role, token) => {
    const peer = await wsConnect(relay.port, role, token);
    peers.push(peer);
    return peer;
  };
  try {
    await fn({ ...relay, open });
  } finally {
    for (const peer of peers) {
      try {
        peer.close();
      } catch {
        /* 已断开 */
      }
    }
    relay.close();
  }
}

const hasBusyError = (msgs) =>
  msgs.some((m) => m.type === 'error' && m.payload?.code === 'SESSION_BUSY');

test('agent 任务中途断线后，同一会话仍可继续发指令（不再永久 SESSION_BUSY）', async () => {
  await withRelay(async ({ open, agentTok, appTok }) => {
    const convId = 'conv-drop';

    let agent = await open('agent', agentTok);
    const app = await open('app', appTok);
    await sleep(150);

    app.send({ type: 'conversation.create', payload: { conversationId: convId } });
    await sleep(100);
    app.send({ type: 'prompt.send', payload: { conversationId: convId, text: '第一句' } });
    await sleep(150);
    assert.ok(
      agent.msgs.some((m) => m.type === 'prompt.send'),
      '前提：第一句应当转发给 agent（busy 已置 true）',
    );

    // agent 断线，且不发任何 task.state 终态
    agent.close();
    await sleep(250);

    // 重连后立刻再发 —— 修复前这里必然收到 SESSION_BUSY
    agent = await open('agent', agentTok);
    await sleep(150);
    app.msgs.length = 0;
    agent.msgs.length = 0;
    app.send({ type: 'prompt.send', payload: { conversationId: convId, text: '第二句' } });
    await sleep(300);

    assert.equal(hasBusyError(app.msgs), false, 'agent 重连后不应再返回 SESSION_BUSY');
    assert.ok(
      agent.msgs.some((m) => m.type === 'prompt.send'),
      '第二句应当真的转发给 agent，而不是被静默丢弃',
    );
  });
});

test('正常完成流程照旧解锁：task.state completed 后可以接着发', async () => {
  await withRelay(async ({ open, agentTok, appTok }) => {
    const convId = 'conv-normal';

    const agent = await open('agent', agentTok);
    const app = await open('app', appTok);
    await sleep(150);

    app.send({ type: 'conversation.create', payload: { conversationId: convId } });
    await sleep(100);
    app.send({ type: 'prompt.send', payload: { conversationId: convId, text: '第一次' } });
    await sleep(150);
    agent.send({ type: 'task.state', payload: { conversationId: convId, state: 'completed' } });
    await sleep(150);

    agent.msgs.length = 0;
    app.send({ type: 'prompt.send', payload: { conversationId: convId, text: '第二次' } });
    await sleep(250);

    assert.equal(hasBusyError(app.msgs), false);
    assert.ok(agent.msgs.some((m) => m.type === 'prompt.send'));
  });
});

test('busy 期间仍然拒绝并发（修复不削弱互斥）', async () => {
  await withRelay(async ({ open, agentTok, appTok }) => {
    const convId = 'conv-mutex';

    const agent = await open('agent', agentTok);
    const app = await open('app', appTok);
    await sleep(150);

    app.send({ type: 'conversation.create', payload: { conversationId: convId } });
    await sleep(100);
    app.send({ type: 'prompt.send', payload: { conversationId: convId, text: '占用中' } });
    await sleep(150);
    assert.ok(agent.msgs.some((m) => m.type === 'prompt.send'));

    app.msgs.length = 0;
    app.send({ type: 'prompt.send', payload: { conversationId: convId, text: '并发插队' } });
    await sleep(250);

    assert.equal(hasBusyError(app.msgs), true, '任务进行中必须返回 SESSION_BUSY');
  });
});
