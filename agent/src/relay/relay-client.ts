/**
 * RelayClient —— M1 WSS 客户端（唯一契约 docs/design/M1_PROTOCOL.md §3/§5）。
 *
 * 职责：
 *  - 使用 Node 24 内置全局 `WebSocket`（不引入 ws 等第三方依赖）连接
 *    `wss://<host>/ws?role=agent&token=...`；
 *  - 每 30s 发送一次 `{"v":1,"type":"ping"}` 心跳信封；
 *  - 断线后指数退避重连：1s 起、×2、30s 封顶、±20% 抖动；握手失败（关闭码 4401）
 *    时可通过注入的 urlRefresher 重新配对换 token 后重连；
 *  - 未连接期间的发送进入队列，上限 100 条，超出丢最旧；
 *  - 收到的文本帧解析为协议信封后回调 onMessage。
 *
 * 本类只做传输，不做业务编排（业务见 relay-agent.ts）。
 */
import { Logger } from '../infra/logger.ts';
import { safeErrorMessage } from '../infra/redact.ts';
import { createEnvelope, envelopeByteSize, parseEnvelope } from './protocol.ts';
import type { RelayEnvelope, RelayTransport, RelayUnsubscribe } from './protocol.ts';

/** 心跳间隔（§3：Agent 每 30s 发 ping）。 */
export const RELAY_HEARTBEAT_INTERVAL_MS = 30_000;
/** 重连退避初始值。 */
export const RELAY_RECONNECT_BASE_MS = 1_000;
/** 重连退避封顶值。 */
export const RELAY_RECONNECT_MAX_MS = 30_000;
/** 未连接时发送队列上限（§5：缓存最近 100 条）。 */
export const RELAY_SEND_QUEUE_LIMIT = 100;
/** AUTH_FAILED 握手失败的关闭码（§3）。 */
export const RELAY_HANDSHAKE_AUTH_CLOSE_CODE = 4401;

/** 连接状态。 */
export type RelayConnectionStatus = 'idle' | 'connecting' | 'open' | 'closed';

/** 关闭信息。 */
export interface RelayCloseInfo {
  code: number | null;
  reason: string | null;
}

/** 仅使用全局 WebSocket 暴露的最小表面，避免依赖 DOM lib 类型。 */
export interface RelayWebSocketLike {
  readonly readyState: number;
  send(data: string): void;
  close(code?: number, reason?: string): void;
  addEventListener(type: 'open', listener: () => void): void;
  addEventListener(type: 'message', listener: (event: { data: unknown }) => void): void;
  addEventListener(type: 'close', listener: (event: { code?: number; reason?: string }) => void): void;
  addEventListener(type: 'error', listener: (event: unknown) => void): void;
}

/** 统计快照，便于自测与诊断。 */
export interface RelayClientStats {
  /** 成功写入 socket 的信封数。 */
  sent: number;
  /** 当前排队数。 */
  queued: number;
  /** 因队列溢出被丢弃的最旧信封数。 */
  dropped: number;
  /** 解析成功并已分发的下行信封数。 */
  received: number;
  /** 重建连接次数（首次连接之后）。 */
  reconnects: number;
  /** 最近一次 pong 时间（ISO），无则 null。 */
  lastPongAt: string | null;
}

export interface RelayClientOptions {
  /** 完整 wss/ws url（含 role=agent&token=...）。 */
  readonly url: string;
  readonly logger?: Logger;
  /** 心跳间隔，默认 30s。 */
  readonly heartbeatIntervalMs?: number;
  /** 重连退避初始值，默认 1s。 */
  readonly reconnectBaseMs?: number;
  /** 重连退避封顶，默认 30s。 */
  readonly reconnectMaxMs?: number;
  /** 发送队列上限，默认 100。 */
  readonly maxQueueSize?: number;
  /** 是否自动重连，默认 true。 */
  readonly autoReconnect?: boolean;
  /** WebSocket 构造器注入点（默认取 globalThis.WebSocket）。 */
  readonly webSocketFactory?: (url: string) => unknown;
  /** 关闭码 4401 时重新配对并返回新 url。 */
  readonly urlRefresher?: () => Promise<string>;
  /** 抖动随机源（测试注入）。 */
  readonly random?: () => number;
}

interface OpenWaiter {
  resolve: () => void;
  reject: (error: Error) => void;
  timer: ReturnType<typeof setTimeout> | null;
}

/** 只使用全局 WebSocket 的默认工厂。 */
function defaultWebSocketFactory(url: string): unknown {
  const ctor = (globalThis as unknown as { WebSocket?: new (url: string) => unknown }).WebSocket;
  if (typeof ctor !== 'function') {
    throw new Error('全局 WebSocket 不可用：需要 Node >= 22（推荐 Node 24）');
  }
  return new ctor(url);
}

/** 日志脱敏：把 url 里的 token 换成 ***。 */
export function maskRelayUrl(url: string): string {
  try {
    const parsed = new URL(url);
    if (parsed.searchParams.has('token')) {
      parsed.searchParams.set('token', '***');
    }
    return parsed.toString();
  } catch {
    return url;
  }
}

/**
 * 由后端 HTTP(S) 基址构造 Agent 侧 WSS url。
 * 例：`http://127.0.0.1:8080` + agent + token → `ws://127.0.0.1:8080/ws?role=agent&token=...`
 */
export function buildRelayWebSocketUrl(
  httpBaseUrl: string,
  role: 'agent' | 'app',
  token: string,
): string {
  const url = new URL(httpBaseUrl);
  url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';
  url.pathname = '/ws';
  url.search = '';
  url.searchParams.set('role', role);
  url.searchParams.set('token', token);
  return url.toString();
}

/** 单调递增的随机量取整，避免测试里出现 0 延迟。 */
function jitterDelay(baseMs: number, random: () => number): number {
  const factor = 0.8 + random() * 0.4; // ±20%
  return Math.max(1, Math.round(baseMs * factor));
}

function toWebSocketLike(value: unknown): RelayWebSocketLike {
  return value as RelayWebSocketLike;
}

function describeSocketError(event: unknown): string {
  if (typeof event === 'object' && event !== null) {
    const maybeMessage = (event as { message?: unknown }).message;
    if (typeof maybeMessage === 'string' && maybeMessage.length > 0) {
      return maybeMessage;
    }
    const maybeError = (event as { error?: unknown }).error;
    if (maybeError !== undefined) {
      return safeErrorMessage(maybeError);
    }
  }
  return 'WebSocket error';
}

export class RelayClient implements RelayTransport {
  private url: string;
  private readonly logger: Logger;
  private readonly heartbeatIntervalMs: number;
  private readonly reconnectBaseMs: number;
  private readonly reconnectMaxMs: number;
  private readonly maxQueueSize: number;
  private readonly autoReconnect: boolean;
  private readonly webSocketFactory: (url: string) => unknown;
  private readonly urlRefresher: (() => Promise<string>) | undefined;
  private readonly random: () => number;

  private socket: RelayWebSocketLike | null = null;
  private status: RelayConnectionStatus = 'idle';
  private readonly queue: RelayEnvelope<unknown>[] = [];
  private readonly messageListeners = new Set<(envelope: RelayEnvelope<unknown>) => void>();
  private readonly openListeners = new Set<() => void>();
  private readonly closeListeners = new Set<(info: RelayCloseInfo) => void>();
  private readonly openWaiters: OpenWaiter[] = [];

  private heartbeatTimer: ReturnType<typeof setInterval> | null = null;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private reconnectAttempt = 0;
  private openCount = 0;
  private generation = 0;
  private disposed = false;
  private needsUrlRefresh = false;

  private readonly counters = { sent: 0, dropped: 0, received: 0 };
  private lastPongAt: string | null = null;

  constructor(options: RelayClientOptions) {
    this.url = options.url;
    this.logger = options.logger ?? new Logger({ scope: 'relay-client' });
    this.heartbeatIntervalMs = options.heartbeatIntervalMs ?? RELAY_HEARTBEAT_INTERVAL_MS;
    this.reconnectBaseMs = options.reconnectBaseMs ?? RELAY_RECONNECT_BASE_MS;
    this.reconnectMaxMs = options.reconnectMaxMs ?? RELAY_RECONNECT_MAX_MS;
    this.maxQueueSize = Math.max(1, options.maxQueueSize ?? RELAY_SEND_QUEUE_LIMIT);
    this.autoReconnect = options.autoReconnect ?? true;
    this.webSocketFactory = options.webSocketFactory ?? defaultWebSocketFactory;
    this.urlRefresher = options.urlRefresher;
    this.random = options.random ?? Math.random;
  }

  /* ---------------------------------------------------------------------- */
  /* 公开 API                                                                */
  /* ---------------------------------------------------------------------- */

  /** 启动连接（不等待握手完成；需要等待用 waitForOpen）。 */
  connect(): void {
    if (this.disposed) {
      this.logger.warn('relay.client.connect.ignored', { reason: '已关闭，需要新建实例' });
      return;
    }
    this.openSocket();
  }

  /** 等待连接进入 open（自动重连期间也可用）。超时 reject。 */
  waitForOpen(timeoutMs = 15_000): Promise<void> {
    if (this.status === 'open') {
      return Promise.resolve();
    }
    if (this.disposed) {
      return Promise.reject(new Error('RelayClient 已关闭'));
    }
    return new Promise<void>((resolve, reject) => {
      const waiter: OpenWaiter = { resolve, reject, timer: null };
      waiter.timer = setTimeout(() => {
        this.removeOpenWaiter(waiter);
        reject(new Error(`等待 relay 连接超时（${timeoutMs}ms）`));
      }, timeoutMs);
      if (typeof waiter.timer.unref === 'function') {
        waiter.timer.unref();
      }
      this.openWaiters.push(waiter);
    });
  }

  /** 发送信封：已连接直接写 socket；否则进入队列（上限 maxQueueSize，丢最旧）。 */
  send(envelope: RelayEnvelope<unknown>): void {
    if (this.disposed) {
      this.logger.debug('relay.client.send.dropped', { type: envelope.type, reason: 'closed' });
      return;
    }
    if (this.writeToSocket(envelope)) {
      return;
    }
    this.enqueue(envelope);
  }

  /** 订阅下行信封；返回注销函数。 */
  onMessage(listener: (envelope: RelayEnvelope<unknown>) => void): RelayUnsubscribe {
    this.messageListeners.add(listener);
    return () => {
      this.messageListeners.delete(listener);
    };
  }

  /** 每次连接建立时回调（serve.ts 用它重发 device.status）。 */
  onOpen(listener: () => void): RelayUnsubscribe {
    this.openListeners.add(listener);
    return () => {
      this.openListeners.delete(listener);
    };
  }

  /** 连接断开时回调（不含主动 close()）。 */
  onClose(listener: (info: RelayCloseInfo) => void): RelayUnsubscribe {
    this.closeListeners.add(listener);
    return () => {
      this.closeListeners.delete(listener);
    };
  }

  isConnected(): boolean {
    return this.status === 'open';
  }

  getStatus(): RelayConnectionStatus {
    return this.status;
  }

  getQueueSize(): number {
    return this.queue.length;
  }

  getStats(): RelayClientStats {
    return {
      sent: this.counters.sent,
      queued: this.queue.length,
      dropped: this.counters.dropped,
      received: this.counters.received,
      reconnects: Math.max(0, this.openCount - 1),
      lastPongAt: this.lastPongAt,
    };
  }

  /** 主动关闭：停止重连、清空队列与等待者、1000 正常关闭。 */
  async close(): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.generation += 1;
    this.clearTimers();
    this.queue.length = 0;
    this.rejectOpenWaiters(new Error('RelayClient 已关闭'));
    const socket = this.socket;
    this.socket = null;
    this.status = 'closed';
    if (socket !== null) {
      try {
        socket.close(1000, 'client closing');
      } catch {
        // 关闭失败不影响退出
      }
    }
    this.logger.info('relay.client.closed', { stats: this.getStats() });
  }

  /* ---------------------------------------------------------------------- */
  /* 连接建立 / 重连                                                          */
  /* ---------------------------------------------------------------------- */

  private openSocket(): void {
    if (this.disposed || this.socket !== null || this.status === 'connecting') {
      return;
    }
    if (this.reconnectTimer !== null) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    this.status = 'connecting';
    const generation = this.generation;
    void this.openSocketAsync(generation);
  }

  private async openSocketAsync(generation: number): Promise<void> {
    let url = this.url;
    if (this.needsUrlRefresh && this.urlRefresher !== undefined) {
      this.needsUrlRefresh = false;
      try {
        url = await this.urlRefresher();
        this.url = url;
        this.logger.info('relay.client.auth.refreshed', { url: maskRelayUrl(url) });
      } catch (error) {
        this.logger.warn('relay.client.auth.refresh.failed', {
          message: safeErrorMessage(error),
        });
        if (!this.disposed && generation === this.generation) {
          this.status = 'closed';
          this.scheduleReconnect();
        }
        return;
      }
    }
    if (this.disposed || generation !== this.generation) {
      return;
    }

    let socket: RelayWebSocketLike;
    try {
      socket = toWebSocketLike(this.webSocketFactory(url));
    } catch (error) {
      this.logger.warn('relay.client.connect.failed', {
        url: maskRelayUrl(url),
        message: safeErrorMessage(error),
      });
      this.status = 'closed';
      this.scheduleReconnect();
      return;
    }

    this.logger.info('relay.client.connecting', {
      url: maskRelayUrl(url),
      attempt: this.reconnectAttempt + 1,
    });
    this.socket = socket;

    socket.addEventListener('open', () => {
      if (this.socket !== socket || this.disposed) {
        return;
      }
      this.handleOpen();
    });
    socket.addEventListener('message', (event) => {
      if (this.socket !== socket || this.disposed) {
        return;
      }
      this.handleMessageEvent(event);
    });
    socket.addEventListener('close', (event) => {
      if (this.socket !== socket) {
        return;
      }
      const code = typeof event.code === 'number' ? event.code : null;
      const reason = typeof event.reason === 'string' ? event.reason : null;
      this.handleClose(code, reason);
    });
    socket.addEventListener('error', (event) => {
      if (this.socket !== socket) {
        return;
      }
      this.logger.warn('relay.client.socket.error', { message: describeSocketError(event) });
    });
  }

  private handleOpen(): void {
    this.status = 'open';
    this.reconnectAttempt = 0;
    this.openCount += 1;
    this.logger.info('relay.client.open', {
      queue: this.queue.length,
      reconnects: Math.max(0, this.openCount - 1),
    });
    this.startHeartbeat();
    this.flushQueue();
    this.resolveOpenWaiters();
    for (const listener of [...this.openListeners]) {
      try {
        listener();
      } catch (error) {
        this.logger.warn('relay.client.open.listener.error', {
          message: safeErrorMessage(error),
        });
      }
    }
  }

  private handleClose(code: number | null, reason: string | null): void {
    this.socket = null;
    this.stopHeartbeat();
    this.status = 'closed';
    this.logger.warn('relay.client.close', { code, reason });
    if (code === RELAY_HANDSHAKE_AUTH_CLOSE_CODE) {
      // token 失效：下次连接前重新配对换 token。
      this.needsUrlRefresh = this.urlRefresher !== undefined;
      this.reconnectAttempt = 0;
    }
    for (const listener of [...this.closeListeners]) {
      try {
        listener({ code, reason });
      } catch (error) {
        this.logger.warn('relay.client.close.listener.error', {
          message: safeErrorMessage(error),
        });
      }
    }
    if (!this.disposed) {
      this.scheduleReconnect();
    }
  }

  private scheduleReconnect(): void {
    if (this.disposed || !this.autoReconnect || this.reconnectTimer !== null) {
      return;
    }
    this.reconnectAttempt += 1;
    const exponent = Math.min(this.reconnectAttempt - 1, 10);
    const raw = Math.min(this.reconnectMaxMs, this.reconnectBaseMs * Math.pow(2, exponent));
    const delayMs = jitterDelay(raw, this.random);
    this.logger.info('relay.client.reconnect.scheduled', {
      attempt: this.reconnectAttempt,
      delayMs,
    });
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this.openSocket();
    }, delayMs);
  }

  /* ---------------------------------------------------------------------- */
  /* 收发                                                                     */
  /* ---------------------------------------------------------------------- */

  private enqueue(envelope: RelayEnvelope<unknown>): void {
    if (this.queue.length >= this.maxQueueSize) {
      while (this.queue.length >= this.maxQueueSize) {
        this.queue.shift();
        this.counters.dropped += 1;
      }
      this.logger.warn('relay.client.queue.overflow', {
        limit: this.maxQueueSize,
        dropped: this.counters.dropped,
      });
    }
    this.queue.push(envelope);
    this.logger.debug('relay.client.send.queued', {
      type: envelope.type,
      queue: this.queue.length,
    });
  }

  private flushQueue(): void {
    while (this.queue.length > 0) {
      const envelope = this.queue[0];
      if (envelope === undefined || !this.writeToSocket(envelope)) {
        return;
      }
      this.queue.shift();
    }
  }

  private writeToSocket(envelope: RelayEnvelope<unknown>): boolean {
    const socket = this.socket;
    if (socket === null || this.status !== 'open') {
      return false;
    }
    let text: string;
    try {
      text = JSON.stringify(envelope);
    } catch (error) {
      this.logger.warn('relay.client.send.serialize.failed', {
        type: envelope.type,
        message: safeErrorMessage(error),
      });
      return true; // 已消费该条，避免队列卡死
    }
    try {
      socket.send(text);
    } catch (error) {
      this.logger.warn('relay.client.send.failed', {
        type: envelope.type,
        message: safeErrorMessage(error),
      });
      return false;
    }
    this.counters.sent += 1;
    this.logger.debug('relay.client.send', {
      type: envelope.type,
      bytes: envelopeByteSize(envelope),
    });
    return true;
  }

  private handleMessageEvent(event: { data: unknown }): void {
    const data = event.data;
    if (typeof data === 'string') {
      this.handleFrameText(data);
      return;
    }
    if (data instanceof ArrayBuffer) {
      this.handleFrameText(new TextDecoder().decode(data));
      return;
    }
    if (ArrayBuffer.isView(data)) {
      const view = data as ArrayBufferView;
      this.handleFrameText(
        new TextDecoder().decode(new Uint8Array(view.buffer, view.byteOffset, view.byteLength)),
      );
      return;
    }
    if (typeof data === 'object' && data !== null) {
      const maybeText = (data as { text?: unknown }).text;
      if (typeof maybeText === 'function') {
        void (data as { text: () => Promise<string> })
          .text()
          .then((text) => this.handleFrameText(text))
          .catch((error: unknown) => {
            this.logger.warn('relay.client.frame.blob.failed', {
              message: safeErrorMessage(error),
            });
          });
        return;
      }
    }
    this.logger.warn('relay.client.frame.unsupported', { kind: typeof data });
  }

  private handleFrameText(text: string): void {
    const envelope = parseEnvelope(text);
    if (envelope === null) {
      this.logger.warn('relay.client.frame.invalid', { bytes: text.length });
      return;
    }
    this.counters.received += 1;
    if (envelope.type === 'pong') {
      this.lastPongAt = new Date().toISOString();
    }
    this.logger.debug('relay.client.recv', {
      type: envelope.type,
      bytes: text.length,
    });
    for (const listener of [...this.messageListeners]) {
      try {
        listener(envelope);
      } catch (error) {
        this.logger.warn('relay.client.message.listener.error', {
          type: envelope.type,
          message: safeErrorMessage(error),
        });
      }
    }
  }

  /* ---------------------------------------------------------------------- */
  /* 心跳                                                                     */
  /* ---------------------------------------------------------------------- */

  private startHeartbeat(): void {
    this.stopHeartbeat();
    this.heartbeatTimer = setInterval(() => {
      if (this.status !== 'open') {
        return;
      }
      this.send(createEnvelope('ping'));
    }, this.heartbeatIntervalMs);
    if (typeof this.heartbeatTimer.unref === 'function') {
      this.heartbeatTimer.unref();
    }
  }

  private stopHeartbeat(): void {
    if (this.heartbeatTimer !== null) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = null;
    }
  }

  private clearTimers(): void {
    this.stopHeartbeat();
    if (this.reconnectTimer !== null) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
  }

  /* ---------------------------------------------------------------------- */
  /* 等待者                                                                   */
  /* ---------------------------------------------------------------------- */

  private resolveOpenWaiters(): void {
    while (this.openWaiters.length > 0) {
      const waiter = this.openWaiters.shift();
      if (waiter === undefined) {
        continue;
      }
      if (waiter.timer !== null) {
        clearTimeout(waiter.timer);
      }
      waiter.resolve();
    }
  }

  private rejectOpenWaiters(error: Error): void {
    while (this.openWaiters.length > 0) {
      const waiter = this.openWaiters.shift();
      if (waiter === undefined) {
        continue;
      }
      if (waiter.timer !== null) {
        clearTimeout(waiter.timer);
      }
      waiter.reject(error);
    }
  }

  private removeOpenWaiter(target: OpenWaiter): void {
    const index = this.openWaiters.indexOf(target);
    if (index >= 0) {
      this.openWaiters.splice(index, 1);
    }
  }
}
