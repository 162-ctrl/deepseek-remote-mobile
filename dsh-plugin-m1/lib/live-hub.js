import { createHash } from 'node:crypto';

// M4.62：给手机开一条「直播推送」WebSocket，把 DSH 远程事件里的会话活动
// 直接推到 App，省掉 1.5–5 秒的轮询等待。
//
// 协议极简：服务端只往下发 `{"type":"ready"}` 与 `{"type":"session"|"question",…}`；
// 客户端发过来的帧只处理 ping / close（其它忽略）。

const WS_MAGIC = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
const OP_TEXT = 0x1;
const OP_CLOSE = 0x8;
const OP_PING = 0x9;
const OP_PONG = 0xa;

export const LIVE_PATH = '/api/v1/desktop/live';

function acceptKey(key) {
  return createHash('sha1').update(`${key}${WS_MAGIC}`).digest('base64');
}

function frame(opcode, payload = Buffer.alloc(0)) {
  const length = payload.length;
  let header;
  if (length < 126) {
    header = Buffer.from([0x80 | opcode, length]);
  } else if (length < 65536) {
    header = Buffer.alloc(4);
    header[0] = 0x80 | opcode;
    header[1] = 126;
    header.writeUInt16BE(length, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x80 | opcode;
    header[1] = 127;
    header.writeUInt32BE(0, 2);
    header.writeUInt32BE(length, 6);
  }
  return Buffer.concat([header, payload]);
}

function textFrame(text) {
  return frame(OP_TEXT, Buffer.from(text, 'utf8'));
}

// 只解析「客户端发来的控制帧」，这是浏览器/App 的常规行为（ping、close）。
function readControlFrames(buffer, onControl) {
  let offset = 0;
  while (offset + 2 <= buffer.length) {
    const first = buffer[offset];
    const second = buffer[offset + 1];
    const opcode = first & 0x0f;
    const masked = (second & 0x80) !== 0;
    let length = second & 0x7f;
    let cursor = offset + 2;
    if (length === 126) {
      if (cursor + 2 > buffer.length) break;
      length = buffer.readUInt16BE(cursor);
      cursor += 2;
    } else if (length === 127) {
      if (cursor + 8 > buffer.length) break;
      length = Number(buffer.readBigUInt64BE(cursor));
      cursor += 8;
    }
    const mask = masked ? buffer.subarray(cursor, cursor + 4) : null;
    if (masked) cursor += 4;
    if (cursor + length > buffer.length) break;
    const payload = Buffer.from(buffer.subarray(cursor, cursor + length));
    if (mask) {
      for (let i = 0; i < payload.length; i += 1) payload[i] ^= mask[i % 4];
    }
    onControl(opcode, payload);
    offset = cursor + length;
  }
  return offset;
}

export function createLiveHub({ authorize, log = () => {} } = {}) {
  const clients = new Set();
  let sent = 0;

  function drop(client) {
    clients.delete(client);
    try { client.socket.destroy(); } catch { /* 已经断了 */ }
  }

  function send(client, payload) {
    try {
      client.socket.write(textFrame(JSON.stringify(payload)));
      return true;
    } catch {
      drop(client);
      return false;
    }
  }

  function handleUpgrade(request, socket) {
    const url = new URL(request.url ?? '/', 'http://localhost');
    const token = url.searchParams.get('token') ?? '';
    if (typeof authorize !== 'function' || !authorize(token)) {
      socket.write('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n');
      socket.destroy();
      return;
    }
    const key = request.headers['sec-websocket-key'];
    if (typeof key !== 'string' || key.length === 0) {
      socket.write('HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n');
      socket.destroy();
      return;
    }
    socket.write([
      'HTTP/1.1 101 Switching Protocols',
      'Upgrade: websocket',
      'Connection: Upgrade',
      `Sec-WebSocket-Accept: ${acceptKey(key)}`,
      '',
      '',
    ].join('\r\n'));
    socket.setNoDelay?.(true);

    const client = { socket };
    clients.add(client);
    send(client, { type: 'ready' });
    log(`直播推送已接入（当前 ${clients.size} 个连接）`);

    socket.on('data', (chunk) => {
      readControlFrames(chunk, (opcode, payload) => {
        if (opcode === OP_PING) {
          try { socket.write(frame(OP_PONG, payload)); } catch { drop(client); }
          return;
        }
        if (opcode === OP_CLOSE) drop(client);
      });
    });
    socket.on('close', () => drop(client));
    socket.on('error', () => drop(client));
  }

  function broadcast(payload) {
    if (clients.size === 0) return 0;
    const data = JSON.stringify(payload);
    const bytes = Buffer.from(data, 'utf8');
    let delivered = 0;
    for (const client of [...clients]) {
      try {
        client.socket.write(frame(OP_TEXT, bytes));
        delivered += 1;
      } catch {
        drop(client);
      }
    }
    sent += delivered;
    return delivered;
  }

  return {
    handleUpgrade,
    broadcast,
    get size() { return clients.size; },
    get sent() { return sent; },
    closeAll() { for (const client of [...clients]) drop(client); },
  };
}

