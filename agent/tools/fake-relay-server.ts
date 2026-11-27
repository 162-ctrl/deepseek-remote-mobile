/**
 * 本地假后端（零第三方依赖）：HTTP 配对/健康检查 + 最小 WebSocket 服务端。
 *
 * 目的：在没有 Java 后端时也能自测 relay 链路（配对、连接、心跳、重连、队列），
 * 并可作为联调替身手动观察 Agent 行为。真实链路仍以 docs/design/M1_PROTOCOL.md 为准。
 *
 * 用法：
 *   node tools/fake-relay-server.ts [--port 18080] [--host 127.0.0.1] [--pairing-code 824613]
 *
 * CLI 启动后打印一行机器可读 JSON：
 *   {"fakeRelayServer":{"serverUrl":"http://127.0.0.1:18080","wsUrl":"ws://127.0.0.1:18080/ws","pairingCode":"824613"}}
 * 然后：stdin 每行一个信封 JSON（含 type）→ 广播给所有已连接客户端；
 *       收到 agent 的 ping 自动回 pong；收到其它信封打印日志。
 *
 * 也可被自测脚本 import：`const server = await startFakeRelayServer();`
 */
import { createHash, randomBytes } from 'node:crypto';
import { createServer } from 'node:http';
import type { IncomingMessage, Server, ServerResponse } from 'node:http';
import type { Duplex } from 'node:stream';
import { createInterface } from 'node:readline';

import { Logger } from '../src/infra/logger.ts';
import type { RelayEnvelope } from '../src/relay/protocol.ts';
import {
  RELAY_PROTOCOL_VERSION,
  createEnvelope,
  isRecord,
  readString,
} from '../src/relay/protocol.ts';

const WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
const MAX_FRAME_BYTES = 4 * 1024 * 1024;

export interface FakeRelayConnection {
  readonly id: number;
  readonly role: string;
  readonly token: string;
  readonly clientName: string;
  readonly remoteAddress: string;
  /** 连接是否仍然打开。 */
  isOpen(): boolean;
  /** 发送一个信封（服务端→客户端，不掩码）。 */
  sendEnvelope(envelope: RelayEnvelope): void;
  /** type + payload 便捷发送。 */
  send(type: string, payload?: unknown): void;
  /** 主动关闭（带关闭码）。 */
  close(code?: number, reason?: string): void;
  /** 订阅该连接收到的信封。 */
  onMessage(listener: (envelope: RelayEnvelope, raw: string) => void): () => void;
  /** 订阅连接关闭。 */
  onClose(listener: (code: number, reason: string) => void): () => void;
}

export interface FakeRelayServerOptions {
  host?: string;
  /** 0 = 随机空闲端口。 */
  port?: number;
  pairingCode?: string;
  logger?: Logger;
}

export interface FakeRelayServer {
  readonly serverUrl: string;
  readonly wsUrl: string;
  readonly host: string;
  readonly port: number;
  readonly pairingCode: string;
  readonly connections: ReadonlyArray<FakeRelayConnection>;
  /** 已签发的 token → 分配信息。 */
  readonly issuedTokens: ReadonlyMap<string, { role: string; clientName: string; deviceId: string }>;
  /** 等待某个角色的连接出现（含已存在的）。 */
  waitForConnection(role?: string, timeoutMs?: number): Promise<FakeRelayConnection>;
  /** 向所有打开连接广播。 */
  broadcast(type: string, payload?: unknown): number;
  /** 向指定角色广播。 */
  broadcastToRole(role: string, type: string, payload?: unknown): number;
  close(): Promise<void>;
}

interface ConnectionRecord {
  id: number;
  socket: Duplex;
  role: string;
  token: string;
  clientName: string;
  remoteAddress: string;
  open: boolean;
  messageListeners: Set<(envelope: RelayEnvelope, raw: string) => void>;
  closeListeners: Set<(code: number, reason: string) => void>;
  fragmentOpcode: number;
  fragmentChunks: Buffer[];
  incoming: Buffer;
}

function encodeWebSocketFrame(opcode: number, payload: Buffer): Buffer {
  const length = payload.length;
  let header: Buffer;
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

function encodeClosePayload(code: number, reason: string): Buffer {
  const reasonBytes = Buffer.from(reason, 'utf8').subarray(0, 123);
  const payload = Buffer.alloc(2 + reasonBytes.length);
  payload.writeUInt16BE(code, 0);
  reasonBytes.copy(payload, 2);
  return payload;
}

/** Sec-WebSocket-Accept = base64(sha1(key + GUID))。 */
function acceptKeyFor(key: string): string {
  return createHash('sha1')
    .update(`${key}${WS_GUID}`, 'utf8')
    .digest('base64');
}

/** 把 buffer 中已完整的帧交给 onFrame，返回剩余未消费字节。 */
function parseWebSocketFrames(
  buffer: Buffer,
  onFrame: (fin: boolean, opcode: number, payload: Buffer) => void,
): Buffer {
  let offset = 0;
  while (buffer.length - offset >= 2) {
    const first = buffer[offset] as number;
    const second = buffer[offset + 1] as number;
    const fin = (first & 0x80) !== 0;
    const opcode = first & 0x0f;
    const masked = (second & 0x80) !== 0;
    let length = second & 0x7f;
    let cursor = offset + 2;
    if (length === 126) {
      if (buffer.length - cursor < 2) {
        break;
      }
      length = buffer.readUInt16BE(cursor);
      cursor += 2;
    } else if (length === 127) {
      if (buffer.length - cursor < 8) {
        break;
      }
      const bigLength = buffer.readBigUInt64BE(cursor);
      if (bigLength > BigInt(MAX_FRAME_BYTES)) {
        throw new Error(`WebSocket 帧过大：${bigLength.toString()}`);
      }
      length = Number(bigLength);
      cursor += 8;
    }
    if (length > MAX_FRAME_BYTES) {
      throw new Error(`WebSocket 帧过大：${length}`);
    }
    let maskKey: Buffer | null = null;
    if (masked) {
      if (buffer.length - cursor < 4) {
        break;
      }
      maskKey = buffer.subarray(cursor, cursor + 4);
      cursor += 4;
    }
    if (buffer.length - cursor < length) {
      break;
    }
    const payload = Buffer.from(buffer.subarray(cursor, cursor + length));
    if (maskKey !== null) {
      for (let index = 0; index < payload.length; index += 1) {
        payload[index] = (payload[index] as number) ^ (maskKey[index % 4] as number);
      }
    }
    offset = cursor + length;
    onFrame(fin, opcode, payload);
  }
  return buffer.subarray(offset);
}

export async function startFakeRelayServer(
  options: FakeRelayServerOptions = {},
): Promise<FakeRelayServer> {
  const host = options.host ?? '127.0.0.1';
  const pairingCode = options.pairingCode ?? '824613';
  const logger = options.logger ?? new Logger({ level: 'warn', scope: 'fake-relay' });

  const issuedTokens = new Map<string, { role: string; clientName: string; deviceId: string }>();
  const connections: ConnectionRecord[] = [];
  const waiters: Array<{ role: string | undefined; resolve: (connection: FakeRelayConnection) => void; timer: NodeJS.Timeout }> = [];
  let nextConnectionId = 1;
  let nextDeviceId = 1;

  const connectionView = (record: ConnectionRecord): FakeRelayConnection => ({
    id: record.id,
    role: record.role,
    token: record.token,
    clientName: record.clientName,
    remoteAddress: record.remoteAddress,
    isOpen: () => record.open,
    sendEnvelope: (envelope) => {
      writeEnvelope(record, envelope);
    },
    send: (type, payload) => {
      writeEnvelope(record, createEnvelope(type, payload) as RelayEnvelope);
    },
    close: (code, reason) => {
      closeRecord(record, code ?? 1000, reason ?? '');
    },
    onMessage: (listener) => {
      record.messageListeners.add(listener);
      return () => {
        record.messageListeners.delete(listener);
      };
    },
    onClose: (listener) => {
      record.closeListeners.add(listener);
      return () => {
        record.closeListeners.delete(listener);
      };
    },
  });

  function writeEnvelope(record: ConnectionRecord, envelope: RelayEnvelope): void {
    if (!record.open) {
      return;
    }
    const text = JSON.stringify(envelope);
    record.socket.write(encodeWebSocketFrame(0x1, Buffer.from(text, 'utf8')));
  }

  function closeRecord(record: ConnectionRecord, code: number, reason: string): void {
    if (!record.open) {
      return;
    }
    record.open = false;
    try {
      record.socket.write(encodeWebSocketFrame(0x8, encodeClosePayload(code, reason)));
    } catch {
      // 连接可能已断开
    }
    try {
      record.socket.end();
    } catch {
      // ignore
    }
    try {
      record.socket.destroySoon?.();
    } catch {
      record.socket.destroy();
    }
    for (const listener of record.closeListeners) {
      listener(code, reason);
    }
    record.closeListeners.clear();
    const index = connections.indexOf(record);
    if (index >= 0) {
      connections.splice(index, 1);
    }
    logger.debug('fake.relay.connection.closed', { id: record.id, code, reason });
  }

  function dispatchEnvelope(record: ConnectionRecord, text: string): void {
    let parsed: unknown;
    try {
      parsed = JSON.parse(text) as unknown;
    } catch {
      logger.warn('fake.relay.frame.invalid_json', { id: record.id });
      return;
    }
    if (!isRecord(parsed)) {
      return;
    }
    const envelope = parsed as unknown as RelayEnvelope;
    if (envelope.v !== RELAY_PROTOCOL_VERSION) {
      logger.warn('fake.relay.frame.invalid_version', { id: record.id, v: envelope.v });
      return;
    }
    if (envelope.type === 'ping') {
      // 协议心跳：后端回 pong 信封（同时回 WS 控制帧 pong 以兼容探测）。
      writeEnvelope(record, { v: RELAY_PROTOCOL_VERSION, type: 'pong' } as RelayEnvelope);
      try {
        record.socket.write(encodeWebSocketFrame(0xA, Buffer.from('', 'utf8')));
      } catch {
        // ignore
      }
    }
    logger.debug('fake.relay.recv', { id: record.id, type: envelope.type });
    for (const listener of record.messageListeners) {
      listener(envelope, text);
    }
  }

  function onSocketData(record: ConnectionRecord, chunk: Buffer): void {
    record.incoming = record.incoming.length === 0
      ? chunk
      : Buffer.concat([record.incoming, chunk]);
    try {
      record.incoming = parseWebSocketFrames(record.incoming, (fin, opcode, payload) => {
        if (opcode === 0x0) {
          // continuation
          if (record.fragmentOpcode === 0) {
            return;
          }
          record.fragmentChunks.push(payload);
          if (fin) {
            const full = Buffer.concat(record.fragmentChunks);
            record.fragmentChunks = [];
            const fragmentOpcode = record.fragmentOpcode;
            record.fragmentOpcode = 0;
            handleFrame(record, fragmentOpcode, full);
          }
          return;
        }
        if (opcode === 0x1 || opcode === 0x2) {
          if (!fin) {
            record.fragmentOpcode = opcode;
            record.fragmentChunks = [payload];
            return;
          }
          handleFrame(record, opcode, payload);
          return;
        }
        handleFrame(record, opcode, payload);
      });
    } catch (error) {
      logger.warn('fake.relay.frame.failed', {
        id: record.id,
        message: error instanceof Error ? error.message : String(error),
      });
      closeRecord(record, 1002, 'protocol error');
    }
  }

  function handleFrame(record: ConnectionRecord, opcode: number, payload: Buffer): void {
    if (opcode === 0x1) {
      dispatchEnvelope(record, payload.toString('utf8'));
      return;
    }
    if (opcode === 0x8) {
      const code = payload.length >= 2 ? payload.readUInt16BE(0) : 1005;
      const reason = payload.length > 2 ? payload.subarray(2).toString('utf8') : '';
      closeRecord(record, code, reason);
      return;
    }
    if (opcode === 0x9) {
      try {
        record.socket.write(encodeWebSocketFrame(0xA, payload));
      } catch {
        // ignore
      }
    }
    // 0xA (pong) 忽略
  }

  function registerConnection(record: ConnectionRecord): void {
    connections.push(record);
    logger.info('fake.relay.connection.open', {
      id: record.id,
      role: record.role,
      clientName: record.clientName,
    });
    const view = connectionView(record);
    for (let index = waiters.length - 1; index >= 0; index -= 1) {
      const waiter = waiters[index] as (typeof waiters)[number];
      if (waiter.role === undefined || waiter.role === record.role) {
        waiters.splice(index, 1);
        clearTimeout(waiter.timer);
        waiter.resolve(view);
      }
    }
  }

  const httpServer: Server = createServer((request: IncomingMessage, response: ServerResponse) => {
    const method = request.method ?? 'GET';
    const url = new URL(request.url ?? '/', `http://${host}`);
    if (method === 'POST' && url.pathname === '/api/v1/auth/pair') {
      void handlePair(request, response);
      return;
    }
    if (method === 'GET' && url.pathname === '/api/v1/health') {
      const agentOnline = connections.some((record) => record.open && record.role === 'agent');
      sendJson(response, 200, {
        status: 'ok',
        version: '0.0.0-fake',
        agentOnline,
        apps: connections.filter((record) => record.open && record.role === 'app').length,
      });
      return;
    }
    sendJson(response, 404, { code: 'NOT_FOUND', message: `未知路由 ${method} ${url.pathname}` });
  });

  async function handlePair(request: IncomingMessage, response: ServerResponse): Promise<void> {
    const body = await readRequestBody(request);
    if (body === null) {
      sendJson(response, 400, { code: 'BAD_REQUEST', message: '请求体不是合法 JSON' });
      return;
    }
    const pairing = readString(body, 'pairingCode');
    const role = readString(body, 'role');
    const clientName = readString(body, 'clientName') ?? '';
    if (pairing !== pairingCode || (role !== 'agent' && role !== 'app')) {
      sendJson(response, 401, { code: 'AUTH_FAILED', message: 'pairing code invalid' });
      return;
    }
    const token = randomBytes(32).toString('hex');
    const deviceId = `${role}-fake-${nextDeviceId}`;
    nextDeviceId += 1;
    issuedTokens.set(token, { role, clientName, deviceId });
    logger.info('fake.relay.pair.ok', { role, clientName, deviceId });
    sendJson(response, 200, {
      token,
      role,
      deviceId,
      expiresAt: new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString(),
    });
  }

  httpServer.on('upgrade', (request: IncomingMessage, socket: Duplex, head: Buffer) => {
    const url = new URL(request.url ?? '/', `http://${host}`);
    const key = request.headers['sec-websocket-key'];
    const upgrade = request.headers.upgrade;
    if (url.pathname !== '/ws' || typeof key !== 'string' || (upgrade ?? '').toLowerCase() !== 'websocket') {
      socket.write('HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n');
      socket.destroy();
      return;
    }
    const role = url.searchParams.get('role') ?? '';
    const token = url.searchParams.get('token') ?? '';
    const issued = issuedTokens.get(token);
    if (role !== 'agent' && role !== 'app') {
      rejectUpgrade(socket, 4401, 'role invalid');
      return;
    }
    if (issued === undefined || issued.role !== role) {
      rejectUpgrade(socket, 4401, 'token invalid');
      return;
    }
    const accept = acceptKeyFor(key);
    socket.write(
      'HTTP/1.1 101 Switching Protocols\r\n' +
        'Upgrade: websocket\r\n' +
        'Connection: Upgrade\r\n' +
        `Sec-WebSocket-Accept: ${accept}\r\n` +
        '\r\n',
    );
    const record: ConnectionRecord = {
      id: nextConnectionId,
      socket,
      role,
      token,
      clientName: issued.clientName,
      remoteAddress: `${socket.remoteAddress ?? 'unknown'}:${socket.remotePort ?? 0}`,
      open: true,
      messageListeners: new Set(),
      closeListeners: new Set(),
      fragmentOpcode: 0,
      fragmentChunks: [],
      incoming: head.length > 0 ? head : Buffer.alloc(0),
    };
    nextConnectionId += 1;
    socket.on('data', (chunk: Buffer) => {
      onSocketData(record, chunk);
    });
    socket.on('close', () => {
      if (record.open) {
        record.open = false;
        for (const listener of record.closeListeners) {
          listener(1006, 'socket closed');
        }
        record.closeListeners.clear();
        const index = connections.indexOf(record);
        if (index >= 0) {
          connections.splice(index, 1);
        }
      }
    });
    socket.on('error', (error: Error) => {
      logger.debug('fake.relay.socket.error', { id: record.id, message: error.message });
    });
    registerConnection(record);
    if (record.incoming.length > 0) {
      onSocketData(record, Buffer.alloc(0));
    }
  });

  function rejectUpgrade(socket: Duplex, code: number, reason: string): void {
    // 模拟“握手失败关闭码 4401”：先完成 WS 握手再立即发关闭帧，客户端可读到 code。
    const key = 'dGhlIHNhbXBsZSBub25jZQ==';
    socket.write(
      'HTTP/1.1 101 Switching Protocols\r\n' +
        'Upgrade: websocket\r\n' +
        'Connection: Upgrade\r\n' +
        `Sec-WebSocket-Accept: ${acceptKeyFor(key)}\r\n` +
        '\r\n',
    );
    try {
      socket.write(encodeWebSocketFrame(0x8, encodeClosePayload(code, reason)));
    } catch {
      // ignore
    }
    socket.end();
    socket.destroy();
  }

  await new Promise<void>((resolveListen, rejectListen) => {
    httpServer.once('error', rejectListen);
    httpServer.listen(options.port ?? 0, host, () => {
      httpServer.off('error', rejectListen);
      resolveListen();
    });
  });

  const address = httpServer.address();
  const port = typeof address === 'object' && address !== null ? address.port : (options.port ?? 0);

  const server: FakeRelayServer = {
    serverUrl: `http://${host}:${port}`,
    wsUrl: `ws://${host}:${port}/ws`,
    host,
    port,
    pairingCode,
    get connections() {
      return connections.map((record) => connectionView(record));
    },
    issuedTokens,
    waitForConnection(role, timeoutMs = 10_000) {
      const existing = connections.find((record) => record.open && (role === undefined || record.role === role));
      if (existing !== undefined) {
        return Promise.resolve(connectionView(existing));
      }
      return new Promise<FakeRelayConnection>((resolveWait, rejectWait) => {
        const timer = setTimeout(() => {
          const index = waiters.findIndex((waiter) => waiter.timer === timer);
          if (index >= 0) {
            waiters.splice(index, 1);
          }
          rejectWait(new Error(`等待 ${role ?? '任意'} 连接超时（${timeoutMs}ms）`));
        }, timeoutMs);
        timer.unref?.();
        waiters.push({ role, resolve: resolveWait, timer });
      });
    },
    broadcast(type, payload) {
      return broadcastTo(true, undefined, type, payload);
    },
    broadcastToRole(role, type, payload) {
      return broadcastTo(true, role, type, payload);
    },
    async close() {
      for (const record of [...connections]) {
        closeRecord(record, 1001, 'server shutdown');
      }
      await new Promise<void>((resolveClose) => {
        httpServer.close(() => {
          resolveClose();
        });
        // close() 只停止接收新连接；已升级 socket 已在上面关闭。
      });
    },
  };

  function broadcastTo(openOnly: boolean, role: string | undefined, type: string, payload?: unknown): number {
    const envelope = createEnvelope(type, payload) as RelayEnvelope;
    let count = 0;
    for (const record of connections) {
      if (openOnly && !record.open) {
        continue;
      }
      if (role !== undefined && record.role !== role) {
        continue;
      }
      writeEnvelope(record, envelope);
      count += 1;
    }
    return count;
  }

  return server;
}

async function readRequestBody(request: IncomingMessage): Promise<Record<string, unknown> | null> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of request) {
    const buffer = typeof chunk === 'string' ? Buffer.from(chunk, 'utf8') : (chunk as Buffer);
    size += buffer.length;
    if (size > MAX_FRAME_BYTES) {
      return null;
    }
    chunks.push(buffer);
  }
  const text = Buffer.concat(chunks).toString('utf8');
  if (text.trim().length === 0) {
    return null;
  }
  try {
    const parsed = JSON.parse(text) as unknown;
    return isRecord(parsed) ? parsed : null;
  } catch {
    return null;
  }
}

function sendJson(response: ServerResponse, status: number, payload: unknown): void {
  const text = JSON.stringify(payload);
  response.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(text),
    connection: 'close',
  });
  response.end(text);
}

// ---------------------------------------------------------------------------
// CLI：node tools/fake-relay-server.ts
// ---------------------------------------------------------------------------

function parseCliArgs(argv: ReadonlyArray<string>): { port: number; host: string; pairingCode: string } {
  const result = { port: 18080, host: '127.0.0.1', pairingCode: '824613' };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const next = argv[index + 1];
    if (arg === '--port' && next !== undefined) {
      result.port = Number.parseInt(next, 10);
      index += 1;
    } else if (arg === '--host' && next !== undefined) {
      result.host = next;
      index += 1;
    } else if (arg === '--pairing-code' && next !== undefined) {
      result.pairingCode = next;
      index += 1;
    }
  }
  return result;
}

async function runCli(): Promise<void> {
  const cli = parseCliArgs(process.argv.slice(2));
  const logger = new Logger({ level: process.env.LOG_LEVEL === 'debug' ? 'debug' : 'info', scope: 'fake-relay' });
  const server = await startFakeRelayServer({
    host: cli.host,
    port: cli.port,
    pairingCode: cli.pairingCode,
    logger,
  });
  console.log(
    JSON.stringify({
      fakeRelayServer: {
        serverUrl: server.serverUrl,
        wsUrl: server.wsUrl,
        pairingCode: server.pairingCode,
      },
    }),
  );
  const shutdown = async (): Promise<void> => {
    await server.close();
    process.exit(0);
  };
  process.on('SIGINT', () => {
    void shutdown();
  });
  process.on('SIGTERM', () => {
    void shutdown();
  });
  // stdin：每行一个信封 JSON → 广播（手动联调时模拟后端下行）。
  const rl = createInterface({ input: process.stdin });
  rl.on('line', (line) => {
    const trimmed = line.trim();
    if (trimmed.length === 0) {
      return;
    }
    try {
      const parsed = JSON.parse(trimmed) as unknown;
      if (!isRecord(parsed) || typeof parsed.type !== 'string') {
        logger.warn('fake.relay.stdin.invalid', { line: trimmed.slice(0, 120) });
        return;
      }
      const envelope = createEnvelope(parsed.type as string, parsed.payload);
      const count = server.broadcast(envelope.type, envelope.payload);
      logger.info('fake.relay.stdin.broadcast', { type: envelope.type, count });
    } catch {
      logger.warn('fake.relay.stdin.invalid', { line: trimmed.slice(0, 120) });
    }
  });
  await new Promise<void>(() => {
    // 保持运行直到信号退出
  });
}

if (process.argv[1] !== undefined && import.meta.filename === process.argv[1]) {
  runCli().catch((error: unknown) => {
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(1);
  });
}
