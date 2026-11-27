/**
 * Harness 错误模型。
 * 原则（docs/design/REMOTE_AGENT.md §9）：所有失败必须映射为有 errorCode 的 HarnessError，
 * 上层（TaskService / 协议层）只按 code 分支，不解析自然语言报错。
 */

export type HarnessErrorCode =
  | 'HARNESS_NOT_INSTALLED'
  | 'HARNESS_NOT_LOGGED_IN'
  | 'ACP_PROTOCOL_ERROR'
  | 'ACP_PROCESS_EXIT'
  | 'SESSION_BUSY'
  | 'SESSION_NOT_FOUND'
  | 'APPROVAL_UNAVAILABLE'
  | 'CANCEL_UNSUPPORTED'
  | 'TIMEOUT'
  | 'UNSUPPORTED_CAPABILITY'
  | 'INTERNAL';

const RETRYABLE_CODES: ReadonlySet<HarnessErrorCode> = new Set<HarnessErrorCode>([
  'ACP_PROCESS_EXIT',
  'TIMEOUT',
  'INTERNAL',
]);

export interface HarnessErrorOptions {
  readonly details?: Readonly<Record<string, unknown>>;
  readonly cause?: unknown;
  readonly retryable?: boolean;
}

export class HarnessError extends Error {
  readonly code: HarnessErrorCode;
  readonly details: Readonly<Record<string, unknown>>;
  readonly retryable: boolean;

  constructor(code: HarnessErrorCode, message: string, options: HarnessErrorOptions = {}) {
    super(message);
    this.name = 'HarnessError';
    this.code = code;
    this.details = options.details ?? {};
    this.retryable = options.retryable ?? RETRYABLE_CODES.has(code);
    if (options.cause !== undefined) this.cause = options.cause;
  }

  toJSON(): Readonly<Record<string, unknown>> {
    return { code: this.code, message: this.message, retryable: this.retryable, details: this.details };
  }
}

export interface JsonRpcErrorPayload {
  readonly code: number;
  readonly message: string;
  readonly data?: unknown;
}

/**
 * JSON-RPC error → HarnessError。
 * 注意：只映射已实测的语义（-32602 同会话 in-flight），其余一律 ACP_PROTOCOL_ERROR，
 * 不猜测官方未来错误码（见 HARNESS_INTERFACES.md 的“只做加法”约束）。
 */
export function mapJsonRpcError(payload: JsonRpcErrorPayload, method: string): HarnessError {
  if (payload.code === -32602 && /already in flight/i.test(payload.message)) {
    return new HarnessError('SESSION_BUSY', `同一会话已有进行中的 turn：${payload.message}`, {
      details: { method, rpcCode: payload.code },
    });
  }
  if (/login|auth|credential|unauthor/i.test(payload.message)) {
    return new HarnessError('HARNESS_NOT_LOGGED_IN', `Harness 未登录或无有效凭证：${payload.message}`, {
      details: { method, rpcCode: payload.code },
    });
  }
  if (/not found|unknown session/i.test(payload.message)) {
    return new HarnessError('SESSION_NOT_FOUND', payload.message, { details: { method, rpcCode: payload.code } });
  }
  return new HarnessError('ACP_PROTOCOL_ERROR', `ACP 调用失败（${method}，${payload.code}）：${payload.message}`, {
    details: { method, rpcCode: payload.code, data: payload.data },
  });
}

/** 把任意异常规范化为 HarnessError（未分类的包成 INTERNAL，原始信息保留在 cause） */
export function toHarnessError(error: unknown, fallbackCode: HarnessErrorCode = 'INTERNAL'): HarnessError {
  if (error instanceof HarnessError) return error;
  const message = error instanceof Error ? error.message : String(error);
  return new HarnessError(fallbackCode, message, { cause: error });
}
