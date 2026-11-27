// 零依赖 WebSocket 服务端：只实现 M1 中继用得到的部分（RFC 6455 文本帧 + 关闭帧 + ping/pong）。
// 帧编解码规则与项目内 `agent/tools/fake-relay-server.ts` 保持一致，便于对照排错。
import { createHash } from 'node:crypto';
import { EventEmitter } from 'node:events';

export const WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
export const MAX_FRAME_BYTES = 8 * 1024 * 1024;

/** 组一个服务端 → 客户端的帧（不加掩码）。 */
export function encodeFrame(opcode, payload) {
  const length = payload.length;
  let header;
  if (length < 126) {
    header = Buffer.alloc(2);
    header[1] = length;
  } else if (length < 65_536) {
    header = Buffer.alloc(4);
    header[1] = 126;
    header.writeUInt16BE(length, 2);
  } else {
    header = Buffer.alloc(10);
    header[1] = 127;
    header.writeBigUInt64BE(BigInt(length), 2);
  }
  header[0] = 0x80 | opcode;
  return Buffer.concat([header, payload]);
}

/** 关闭帧负载：2 字节状态码 + 最多 123 字节原因。 */
export function encodeClosePayload(code, reason) {
  const reasonBytes = Buffer.from(reason ?? '', 'utf8').subarray(0, 123);
  const payload = Buffer.alloc(2 + reasonBytes.length);
  payload.writeUInt16BE(code, 0);
  reasonBytes.copy(payload, 2);
  return payload;
}

/** Sec-WebSocket-Accept = base64(sha1(key + GUID))。 */
export function acceptKeyFor(key) {
  return createHash('sha1').update(`${key}${WS_GUID}`, 'utf8').digest('base64');
}

/** 消费 buffer 中已完整的帧，返回剩余未消费的字节。 */
export function parseFrames(buffer, onFrame, maxFrameBytes = MAX_FRAME_BYTES) {
  let offset = 0;
  while (buffer.length - offset >= 2) {
    const first = buffer[offset];
    const second = buffer[offset + 1];
    const fin = (first & 0x80) !== 0;
    const opcode = first & 0x0f;
    const masked = (second & 0x80) !== 0;
    let length = second & 0x7f;
    let cursor = offset + 2;
    if (length === 126) {
      if (buffer.length - cursor < 2) break;
      length = buffer.readUInt16BE(cursor);
      cursor += 2;
    } else if (length === 127) {
      if (buffer.length - cursor < 8) break;
      const bigLength = buffer.readBigUInt64BE(cursor);
      if (bigLength > BigInt(maxFrameBytes)) {
        throw new Error(`WebSocket 帧过大：${bigLength.toString()}`);
      }
      length = Number(bigLength);
      cursor += 8;
    }
    if (length > maxFrameBytes) throw new Error(`WebSocket 帧过大：${length}`);
    let maskKey = null;
    if (masked) {
      if (buffer.length - cursor < 4) break;
      maskKey = buffer.subarray(cursor, cursor + 4);
      cursor += 4;
    }
    if (buffer.length - cursor < length) break;
    const payload = Buffer.from(buffer.subarray(cursor, cursor + length));
    if (maskKey !== null) {
      for (let index = 0; index < payload.length; index += 1) {
        payload[index] ^= maskKey[index % 4];
      }
    }
    offset = cursor + length;
    onFrame(fin, opcode, payload);
  }
  return buffer.subarray(offset);
}

/**
 * 一条已握手的连接。事件：
 *   'text'  (string)   收到完整文本帧
 *   'close' (code, reason) 连接结束（对端关闭 / 出错 / 本地 close）
 */
export class WsPeer extends EventEmitter {
  #socket;
  #buffer = Buffer.alloc(0);
  #closed = false;
  #fragments = [];
  #closing = false;

  constructor(socket) {
    super();
    this.#socket = socket;
    socket.on('data', (chunk) => this.#onData(chunk));
    socket.on('error', (error) => this.#finish(1006, `socket error: ${error?.message ?? error}`));
    socket.on('close', () => this.#finish(1006, 'socket closed'));
  }

  /** 完成 HTTP → WS 握手；失败返回 null。 */
  static accept(request, socket) {
    const key = request.headers['sec-websocket-key'];
    const upgrade = String(request.headers.upgrade ?? '').toLowerCase();
    if (upgrade !== 'websocket' || typeof key !== 'string' || key.length === 0) {
      socket.end('HTTP/1.1 400 Bad Request\r\n\r\n');
      return null;
    }
    const lines = [
      'HTTP/1.1 101 Switching Protocols',
      'Upgrade: websocket',
      'Connection: Upgrade',
      `Sec-WebSocket-Accept: ${acceptKeyFor(key)}`,
      '\r\n',
    ];
    socket.write(lines.join('\r\n'));
    socket.setNoDelay?.(true);
    return new WsPeer(socket);
  }

  get closed() {
    return this.#closed;
  }

  sendText(text) {
    if (this.#closed || this.#closing) return false;
    this.#socket.write(encodeFrame(0x1, Buffer.from(text, 'utf8')));
    return true;
  }

  close(code = 1000, reason = '') {
    if (this.#closed) return;
    this.#closing = true;
    try {
      this.#socket.write(encodeFrame(0x8, encodeClosePayload(code, reason)));
    } catch {
      /* 对端已断开 */
    }
    this.#finish(code, reason);
    this.#socket.end();
  }

  #finish(code, reason) {
    if (this.#closed) return;
    this.#closed = true;
    this.emit('close', code, reason);
  }

  #onData(chunk) {
    this.#buffer = Buffer.concat([this.#buffer, chunk]);
    try {
      this.#buffer = parseFrames(this.#buffer, (fin, opcode, payload) => {
        this.#handleFrame(fin, opcode, payload);
      });
    } catch (error) {
      this.close(1009, `frame rejected: ${error?.message ?? error}`);
    }
  }

  #handleFrame(fin, opcode, payload) {
    if (this.#closed) return;
    switch (opcode) {
      case 0x0:
        this.#fragments.push(payload);
        if (fin) {
          const text = Buffer.concat(this.#fragments).toString('utf8');
          this.#fragments = [];
          this.emit('text', text);
        }
        break;
      case 0x1:
      case 0x2:
        if (fin) {
          this.emit('text', payload.toString('utf8'));
        } else {
          this.#fragments = [payload];
        }
        break;
      case 0x8: {
        const code = payload.length >= 2 ? payload.readUInt16BE(0) : 1005;
        this.#finish(code, payload.length > 2 ? payload.subarray(2).toString('utf8') : '');
        this.#closing = true;
        try {
          this.#socket.write(encodeFrame(0x8, encodeClosePayload(code, '')));
        } catch {
          /* ignore */
        }
        this.#socket.end();
        break;
      }
      case 0x9:
        if (!this.#closing) this.#socket.write(encodeFrame(0xa, payload));
        break;
      default:
        break; // 0xA pong 及保留 opcode 忽略
    }
  }
}
