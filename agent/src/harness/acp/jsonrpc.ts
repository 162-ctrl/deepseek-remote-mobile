/**
 * JSON-RPC 2.0 over NDJSON stdio（ACP 传输层，M0 核心）。
 * 依据：docs/research/HARNESS_INTERFACES.md —— 逐行 JSON、请求/响应按 id 关联、通知无 id。
 *
 * 设计约束：
 * - 单行上限可配（默认 1MB），超限按协议错误处理并让上层重启进程（90004）。
 * - 所有 outbound 帧串行写入，避免大帧交错。
 * - close() 后所有 pending 请求以 ACP_PROCESS_EXIT 拒绝，避免任务悬挂。
 */
import type { ChildProcessWithoutNullStreams } from 'node:child_process';
import { HarnessError, mapJsonRpcError } from '../errors.ts';
import type { JsonRpcErrorPayload } from '../errors.ts';

export interface RpcSuccess {
  readonly jsonrpc: '2.0';
  readonly id: number | string;
  readonly result: unknown;
}

export interface RpcFailure {
  readonly jsonrpc: '2.0';
  readonly id: number | string;
  readonly error: JsonRpcErrorPayload;
}

export type RpcResponseMessage = RpcSuccess | RpcFailure;

export interface RpcNotification {
  readonly jsonrpc?: '2.0';
  readonly method: string;
  readonly params?: unknown;
}

export interface RpcRequestMessage {
  readonly jsonrpc?: '2.0';
  readonly id: number | string;
  readonly method: string;
  readonly params?: unknown;
}

export const DEFAULT_MAX_LINE_BYTES = 1024 * 1024;

/** 增量 NDJSON 解码器：处理被任意切分的行，校验行长度上限。 */
export class NdjsonDecoder {
  private buffer = '';
  private readonly maxLineBytes: number;

  constructor(maxLineBytes: number = DEFAULT_MAX_LINE_BYTES) {
    this.maxLineBytes = maxLineBytes;
  }

  push(chunk: string): string[] {
    this.buffer += chunk;
    const lines: string[] = [];
    let index = this.buffer.indexOf('\n');
    while (index >= 0) {
      const line = this.buffer.slice(0, index).replace(/\r$/, '');
      this.buffer = this.buffer.slice(index + 1);
      if (line.trim() !== '') lines.push(line);
      index = this.buffer.indexOf('\n');
    }
    if (this.buffer.length > this.maxLineBytes) {
      this.buffer = '';
      throw new HarnessError('ACP_PROTOCOL_ERROR', `ACP 单行超过 ${this.maxLineBytes} 字节上限`, {
        details: { maxLineBytes: this.maxLineBytes },
      });
    }
    return lines;
  }

  /** 进程退出前把残留（无换行的最后一行）当作一帧处理 */
  flush(): string[] {
    const rest = this.buffer.trim();
    this.buffer = '';
    return rest === '' ? [] : [rest];
  }
}

interface PendingRequest {
  readonly method: string;
  readonly resolve: (value: unknown) => void;
  readonly reject: (error: Error) => void;
  readonly timer: NodeJS.Timeout;
}

export type NotificationHandler = (method: string, params: unknown) => void;
export type RequestHandler = (params: unknown) => Promise<unknown>;
export type Unsubscribe = () => void;

export interface JsonRpcPeerOptions {
  readonly maxLineBytes?: number;
  readonly defaultTimeoutMs?: number;
  /** 出站写函数；默认 no-op，便于单测捕获。attach() 会用子进程 stdin 覆盖。 */
  readonly writeLine?: (line: string) => void;
}

export class JsonRpcPeer {
  private readonly decoder: NdjsonDecoder;
  private readonly defaultTimeoutMs: number;
  private readonly pending = new Map<string, PendingRequest>();
  private readonly notificationHandlers = new Set<NotificationHandler>();
  private readonly requestHandlers = new Map<string, RequestHandler>();
  private nextId = 1;
  private stdout: (line: string) => void = () => undefined;
  private closed = false;

  constructor(options: JsonRpcPeerOptions = {}) {
    this.decoder = new NdjsonDecoder(options.maxLineBytes ?? DEFAULT_MAX_LINE_BYTES);
    this.defaultTimeoutMs = options.defaultTimeoutMs ?? 60_000;
    const writeLine = options.writeLine;
    if (writeLine !== undefined) this.stdout = writeLine;
  }

  /** 绑定子进程 stdio；返回 detach 以便 disconnect 时解绑 */
  attach(child: ChildProcessWithoutNullStreams, onProcessLog?: (stream: 'stdout' | 'stderr', line: string) => void): () => void {
    const stdoutHandler = (chunk: Buffer): void => {
      void onProcessLog?.('stdout', chunk.toString('utf8'));
      for (const line of this.decoder.push(chunk.toString('utf8'))) {
        this.handleLine(line);
      }
    };
    const stderrHandler = (chunk: Buffer): void => {
      void onProcessLog?.('stderr', chunk.toString('utf8'));
    };
    child.stdout.on('data', stdoutHandler);
    child.stderr.on('data', stderrHandler);
    this.stdout = (line: string): void => {
      if (this.closed) return;
      child.stdin.write(line + '\n');
    };
    return (): void => {
      child.stdout.off('data', stdoutHandler);
      child.stderr.off('data', stderrHandler);
    };
  }

  onNotification(handler: NotificationHandler): Unsubscribe {
    this.notificationHandlers.add(handler);
    return () => this.notificationHandlers.delete(handler);
  }

  onRequest(method: string, handler: RequestHandler): Unsubscribe {
    this.requestHandlers.set(method, handler);
    return () => this.requestHandlers.delete(method);
  }

  sendNotification(method: string, params?: unknown): void {
    this.stdout(JSON.stringify(params === undefined ? { jsonrpc: '2.0', method } : { jsonrpc: '2.0', method, params }));
  }

  sendRequest<T = unknown>(method: string, params?: unknown, timeoutMs?: number): Promise<T> {
    if (this.closed) {
      return Promise.reject(
        new HarnessError('ACP_PROCESS_EXIT', `ACP 进程已关闭，无法发送 ${method}`, { retryable: true }),
      );
    }
    const id = this.nextId++;
    const key = String(id);
    const timeout = timeoutMs ?? this.defaultTimeoutMs;
    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(key);
        reject(
          new HarnessError('TIMEOUT', `ACP 请求超时（${method}，${timeout}ms）`, {
            details: { method, timeoutMs: timeout },
          }),
        );
      }, timeout);
      timer.unref?.();
      this.pending.set(key, {
        method,
        resolve: (value) => resolve(value as T),
        reject,
        timer,
      });
      this.stdout(JSON.stringify({ jsonrpc: '2.0', id, method, params }));
    });
  }

  handleLine(line: string): void {
    let message: unknown;
    try {
      message = JSON.parse(line);
    } catch (error) {
      throw new HarnessError('ACP_PROTOCOL_ERROR', `ACP 返回了非 JSON 行：${line.slice(0, 200)}`, { cause: error });
    }
    if (typeof message !== 'object' || message === null) {
      throw new HarnessError('ACP_PROTOCOL_ERROR', 'ACP 消息不是对象');
    }
    const record = message as Record<string, unknown>;
    const hasId = typeof record['id'] === 'number' || typeof record['id'] === 'string';
    const method = typeof record['method'] === 'string' ? record['method'] : undefined;

    if (method !== undefined && hasId) {
      void this.handleServerRequest(record['id'] as number | string, method, record['params']);
      return;
    }
    if (method !== undefined) {
      for (const handler of this.notificationHandlers) handler(method, record['params']);
      return;
    }
    if (hasId) {
      this.handleResponse(record as unknown as RpcResponseMessage, line);
      return;
    }
    throw new HarnessError('ACP_PROTOCOL_ERROR', `ACP 消息缺少 method/id：${line.slice(0, 200)}`);
  }

  close(reason: string): void {
    if (this.closed) return;
    this.closed = true;
    for (const [key, pending] of this.pending) {
      clearTimeout(pending.timer);
      pending.reject(
        new HarnessError('ACP_PROCESS_EXIT', `ACP 进程关闭，请求未完成（${pending.method}）：${reason}`, {
          retryable: true,
        }),
      );
      this.pending.delete(key);
    }
    this.notificationHandlers.clear();
    this.requestHandlers.clear();
  }

  get isClosed(): boolean {
    return this.closed;
  }

  private handleResponse(message: RpcResponseMessage, raw: string): void {
    const key = String(message.id);
    const pending = this.pending.get(key);
    if (pending === undefined) return; // 迟到/重复的响应，安全忽略
    this.pending.delete(key);
    clearTimeout(pending.timer);
    if ('error' in message && message.error !== undefined) {
      pending.reject(mapJsonRpcError(message.error, pending.method));
      return;
    }
    if (!('result' in message)) {
      pending.reject(
        new HarnessError('ACP_PROTOCOL_ERROR', `ACP 响应既无 result 也无 error：${raw.slice(0, 200)}`, {
          details: { method: pending.method },
        }),
      );
      return;
    }
    pending.resolve(message.result);
  }

  private async handleServerRequest(id: number | string, method: string, params: unknown): Promise<void> {
    const handler = this.requestHandlers.get(method);
    if (handler === undefined) {
      this.stdout(JSON.stringify({ jsonrpc: '2.0', id, error: { code: -32601, message: `Method not supported: ${method}` } }));
      return;
    }
    try {
      const result = await handler(params);
      this.stdout(JSON.stringify({ jsonrpc: '2.0', id, result: result ?? null }));
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      this.stdout(JSON.stringify({ jsonrpc: '2.0', id, error: { code: -32603, message } }));
    }
  }
}
