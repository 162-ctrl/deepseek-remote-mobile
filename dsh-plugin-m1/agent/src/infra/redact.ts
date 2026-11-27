/**
 * 脱敏工具：任何要落盘、上报、打印的对象都必须先经过这里。
 * 规则与 docs/design/REMOTE_AGENT.md §10 一致：密钥类字段整体替换，长文本截断。
 */

const SECRET_KEY_PATTERN = /(token|secret|password|passwd|api[_-]?key|authorization|cookie|credential|private[_-]?key)/i;

export const REDACTED = '***';

export function redactDeep(value: unknown, depth = 0): unknown {
  if (depth > 8) return '[depth-limit]';
  if (value === null || value === undefined) return value;
  if (typeof value === 'string') return value;
  if (typeof value === 'number' || typeof value === 'boolean') return value;
  if (Array.isArray(value)) return value.map((item) => redactDeep(item, depth + 1));
  if (typeof value === 'object') {
    const out: Record<string, unknown> = {};
    for (const [key, item] of Object.entries(value as Record<string, unknown>)) {
      out[key] = SECRET_KEY_PATTERN.test(key) ? REDACTED : redactDeep(item, depth + 1);
    }
    return out;
  }
  return String(value);
}

/** 截断长文本，保留头尾，标记 omitted 字节数 */
export function truncateText(text: string, maxLength: number): string {
  if (maxLength <= 0) return '';
  if (text.length <= maxLength) return text;
  const head = Math.max(1, Math.floor(maxLength * 0.7));
  const tail = Math.max(1, maxLength - head - 32);
  const omitted = text.length - head - tail;
  return `${text.slice(0, head)}…[truncated ${omitted} chars]…${text.slice(text.length - tail)}`;
}

/** 从任意错误里提取可安全上报的字符串（不含堆栈中的敏感路径之外的密钥） */
export function safeErrorMessage(error: unknown): string {
  if (error instanceof Error) return error.message;
  if (typeof error === 'string') return error;
  try {
    return JSON.stringify(redactDeep(error));
  } catch {
    return 'unknown error';
  }
}
