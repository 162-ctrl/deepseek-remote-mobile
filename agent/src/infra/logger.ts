/**
 * 结构化日志（M0 最小实现）。
 * 约束：日志一律脱敏；默认写 stderr（stdout 留给协议/CLI 输出）。
 */
import { redactDeep } from './redact.ts';

export type LogLevel = 'debug' | 'info' | 'warn' | 'error';

const LEVEL_ORDER: Readonly<Record<LogLevel, number>> = {
  debug: 10,
  info: 20,
  warn: 30,
  error: 40,
};

export type LogSink = (line: string) => void;

export interface LoggerOptions {
  readonly level?: LogLevel;
  readonly scope?: string;
  readonly sink?: LogSink;
  /** 附加字段，随每条日志输出（如 deviceId） */
  readonly fields?: Readonly<Record<string, unknown>>;
}

function defaultSink(line: string): void {
  process.stderr.write(line + '\n');
}

function formatValue(value: unknown): string {
  if (value === undefined) return '';
  if (typeof value === 'string') return value.includes(' ') ? JSON.stringify(value) : value;
  if (typeof value === 'number' || typeof value === 'boolean') return String(value);
  if (value instanceof Error) return JSON.stringify({ name: value.name, message: value.message });
  try {
    return JSON.stringify(value);
  } catch {
    return String(value);
  }
}

export class Logger {
  private readonly level: LogLevel;
  private readonly scope: string;
  private readonly sink: LogSink;
  private readonly fields: Readonly<Record<string, unknown>>;

  constructor(options: LoggerOptions = {}) {
    this.level = options.level ?? 'info';
    this.scope = options.scope ?? 'agent';
    this.sink = options.sink ?? defaultSink;
    this.fields = options.fields ?? {};
  }

  child(scope: string, fields: Readonly<Record<string, unknown>> = {}): Logger {
    return new Logger({
      level: this.level,
      scope: `${this.scope}.${scope}`,
      sink: this.sink,
      fields: { ...this.fields, ...fields },
    });
  }

  debug(message: string, fields: Readonly<Record<string, unknown>> = {}): void {
    this.log('debug', message, fields);
  }

  info(message: string, fields: Readonly<Record<string, unknown>> = {}): void {
    this.log('info', message, fields);
  }

  warn(message: string, fields: Readonly<Record<string, unknown>> = {}): void {
    this.log('warn', message, fields);
  }

  error(message: string, fields: Readonly<Record<string, unknown>> = {}): void {
    this.log('error', message, fields);
  }

  private log(level: LogLevel, message: string, fields: Readonly<Record<string, unknown>>): void {
    if (LEVEL_ORDER[level] < LEVEL_ORDER[this.level]) return;
    const merged = redactDeep({ ...this.fields, ...fields }) as Readonly<Record<string, unknown>>;
    const parts: string[] = [`[${new Date().toISOString()}]`, level.toUpperCase(), this.scope, message];
    for (const [key, value] of Object.entries(merged)) {
      const formatted = formatValue(value);
      if (formatted !== '') parts.push(`${key}=${formatted}`);
    }
    this.sink(parts.join(' '));
  }
}

/** 测试用：把日志收进数组 */
export function memoryLogger(level: LogLevel = 'debug'): { logger: Logger; lines: string[] } {
  const lines: string[] = [];
  const logger = new Logger({ level, scope: 'test', sink: (line) => lines.push(line) });
  return { logger, lines };
}
