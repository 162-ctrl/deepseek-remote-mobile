/**
 * ACP `session/update` → HarnessEvent 纯函数映射（可单测，不依赖子进程）。
 *
 * 实测事件（HARNESS_INTERFACES.md）：
 * - agent_message_chunk / agent_thought_chunk（提交点粒度，非 token 级）
 * - tool_call（含 rawInput 完整命令）/ tool_call_update（status + 结果）
 * - usage_update {used,size}（上下文窗口占用，非计费 token）
 * 未知 sessionUpdate 类型一律忽略（RC 契约只做加法，见 H-12）。
 */
import type { ConfigOptionView, HarnessEvent } from '../adapter.ts';
import { truncateText } from '../../infra/redact.ts';

export interface MappedUpdate {
  readonly sessionId: string | null;
  readonly kind: string | null;
  readonly events: ReadonlyArray<HarnessEvent>;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function str(value: unknown): string | null {
  return typeof value === 'string' ? value : null;
}

function num(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null;
}

/** ACP content 可能是字符串、单个 block 或 block 数组 */
export function extractText(content: unknown): string {
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) return content.map((item) => extractText(item)).join('');
  if (isRecord(content)) {
    const text = content['text'];
    if (typeof text === 'string') return text;
    const nested = content['content'];
    if (nested !== undefined) return extractText(nested);
  }
  return '';
}

function normalizeToolStatus(value: unknown): 'pending' | 'in_progress' | 'completed' | 'failed' {
  switch (value) {
    case 'pending':
      return 'pending';
    case 'in_progress':
      return 'in_progress';
    case 'completed':
      return 'completed';
    case 'failed':
      return 'failed';
    default:
      return 'in_progress';
  }
}

function toolLabel(update: Readonly<Record<string, unknown>>): string {
  return str(update['title']) ?? str(update['kind']) ?? str(update['toolName']) ?? str(update['name']) ?? 'unknown-tool';
}

function excerptOf(update: Readonly<Record<string, unknown>>): string | undefined {
  const raw = update['rawOutput'] ?? update['content'] ?? update['result'];
  if (raw === undefined || raw === null) return undefined;
  const text = typeof raw === 'string' ? raw : JSON.stringify(raw);
  return truncateText(text, 2000);
}

/**
 * @param params ACP 通知的 params（兼容 `{sessionId, sessionUpdate, ...}` 与 `{sessionId, update:{...}}` 两种形态）
 */
export function mapSessionUpdate(params: unknown, at: string = new Date().toISOString()): MappedUpdate {
  if (!isRecord(params)) return { sessionId: null, kind: null, events: [] };
  const sessionId = str(params['sessionId']);
  const rawUpdate = params['update'];
  const update = isRecord(rawUpdate) ? rawUpdate : params;
  const kind = str(update['sessionUpdate']) ?? str(update['type']);
  if (kind === null) return { sessionId, kind: null, events: [] };

  switch (kind) {
    case 'agent_message_chunk': {
      const text = extractText(update['content']);
      return {
        sessionId,
        kind,
        events: text === '' ? [] : [{ type: 'output', stream: 'answer', text, at }],
      };
    }
    case 'agent_thought_chunk': {
      const text = extractText(update['content']);
      return { sessionId, kind, events: text === '' ? [] : [{ type: 'thinking', text, at }] };
    }
    case 'tool_call': {
      const callId = str(update['toolCallId']);
      if (callId === null) return { sessionId, kind, events: [] };
      return {
        sessionId,
        kind,
        events: [{ type: 'tool_call', callId, tool: toolLabel(update), input: update['rawInput'] ?? null, at }],
      };
    }
    case 'tool_call_update': {
      const callId = str(update['toolCallId']);
      if (callId === null) return { sessionId, kind, events: [] };
      const excerpt = excerptOf(update);
      const event: HarnessEvent = {
        type: 'tool_call_update',
        callId,
        status: normalizeToolStatus(update['status']),
        at,
        ...(excerpt === undefined ? {} : { resultExcerpt: excerpt }),
      };
      return { sessionId, kind, events: [event] };
    }
    case 'usage_update': {
      const used = num(update['used']);
      const size = num(update['size']);
      if (used === null && size === null) return { sessionId, kind, events: [] };
      return {
        sessionId,
        kind,
        events: [
          {
            type: 'usage',
            at,
            ...(used === null ? {} : { contextUsed: used }),
            ...(size === null ? {} : { contextSize: size }),
          },
        ],
      };
    }
    default:
      return { sessionId, kind, events: [] };
  }
}

/** 把 initialize / session-new 返回的 configOptions 里可选项拍平（供能力探测与 UI 用） */export function summarizeConfigOptions(configOptions: unknown): ReadonlyArray<{ id: string; current: string | null; values: ReadonlyArray<string> }> {
  if (!Array.isArray(configOptions)) return [];
  const out: Array<{ id: string; current: string | null; values: string[] }> = [];
  for (const item of configOptions) {
    if (!isRecord(item)) continue;
    const id = str(item['id']) ?? str(item['configId']) ?? str(item['name']);
    if (id === null) continue;
    const current = str(item['currentValue']) ?? str(item['current']) ?? str(item['value']);
    const values: string[] = [];
    const options = item['options'];
    if (Array.isArray(options)) {
      for (const option of options) {
        if (isRecord(option)) {
          const value = str(option['value']) ?? str(option['optionId']);
          if (value !== null) values.push(value);
        } else if (typeof option === 'string') {
          values.push(option);
        }
      }
    }
    out.push({ id, current, values });
  }
  return out;
}

/**
 * M2.7：把 ACP `configOptions` 规范化成 UI 可直接渲染的结构（保留显示名/描述/分组）。
 *
 * 实测结构（DSH 0.2.1-rc.5）：
 * - `{ id: 'model', name: 'Model', category: 'model', type: 'select', currentValue: '["deepseek-official","deepseek-v4-flash"]',
 *     options: [{ group: 'deepseek-official', name: 'DeepSeek', options: [{ value, name, description }] }] }`
 * - `{ id: 'reasoning_effort', name: 'Reasoning effort', type: 'select', currentValue: 'high',
 *     options: [{ value: 'off', name: 'Off', description }, ...] }`
 * 未知形状一律跳过，保证 RC 契约只做加法。
 */
export function normalizeConfigOptions(configOptions: unknown): ReadonlyArray<ConfigOptionView> {
  if (!Array.isArray(configOptions)) return [];
  const out: ConfigOptionView[] = [];
  for (const item of configOptions) {
    if (!isRecord(item)) continue;
    const id = str(item['id']) ?? str(item['configId']);
    if (id === null) continue;
    const options: Array<{ value: string; name: string; description?: string; group?: string }> = [];
    const collect = (list: unknown, group?: string): void => {
      if (!Array.isArray(list)) return;
      for (const entry of list) {
        if (typeof entry === 'string') {
          options.push(group === undefined ? { value: entry, name: entry } : { value: entry, name: entry, group });
          continue;
        }
        if (!isRecord(entry)) continue;
        const nested = entry['options'];
        const groupName = str(entry['name']) ?? group;
        if (Array.isArray(nested)) {
          collect(nested, groupName);
          continue;
        }
        const value = str(entry['value']) ?? str(entry['optionId']);
        if (value === null) continue;
        const description = str(entry['description']);
        options.push({
          value,
          name: str(entry['name']) ?? value,
          ...(description === null ? {} : { description }),
          ...(groupName === undefined ? {} : { group: groupName }),
        });
      }
    };
    collect(item['options']);
    out.push({
      id,
      name: str(item['name']) ?? id,
      category: str(item['category']),
      type: str(item['type']),
      currentValue: str(item['currentValue']) ?? str(item['current']) ?? str(item['value']),
      options,
    });
  }
  return out;
}
