/**
 * M4.16：手机端「对话」视图的正文过滤。
 *
 * 两件事必须在这里统一做，否则手机上看到的就不是对话：
 *
 * 1. **Host 每轮注入的上下文不是用户说的话**。`user/message` 里混着
 *    「Current runtime context…」「Time sampled while preparing turn 3, step 24…」
 *    「<system-reminder>…」这类注入，归档后它们会变成一条条英文用户气泡
 *    （用户原话：「而且你这英文是什么，我要的是对话」）。
 * 2. **assistant 的 reasoning 不是回复**。`assistant/message` 的 content 里如果只有
 *    `reasoning`/`thinking` part，以前 `assistantText()` 会「回退到全部 part」，
 *    于是模型的英文思考过程被当成回复正文整段下发。
 *
 * 这里只做判定与取文，不改事件结构，直播流与存档共用同一套规则。
 */

import { assistantText } from './assistant-text.js';

/** 注入消息的固定开头（Host 换版本时可能新增，集中在这里加）。 */
export const INJECTED_USER_PREFIXES = [
  'Current runtime context',
  'Time sampled while preparing',
  'Browser time zone for this request',
  'Elapsed since the preceding',
  '<system-reminder',
  '<hindsight_knowledge',
  '<hindsight_knowledge_refresh',
  '<available_skills',
  '<acp ',
  '<user_',
  '<user ',
];

/** 出现在开头附近就足以判定为注入的特征串（有些注入前面带几个空行）。 */
const INJECTED_USER_MARKERS = [
  'current runtime-context snapshot',
  'This snapshot supersedes earlier runtime-context snapshots',
  'The following skills are available in this session',
  'A skill is a reusable set of task-specific instructions',
];

/** 只在前 160 个字符里找标记：正文中段引用这些词的用户消息不该被吃掉。 */
const MARKER_SCAN = 160;

/** 这条 `user/message` 是 Host 注入还是人真的说的话。 */
export const isInjectedUserText = (raw) => {
  const text = typeof raw === 'string' ? raw : String(raw ?? '');
  const head = text.replace(/^\s+/, '');
  if (!head) return true;
  if (INJECTED_USER_PREFIXES.some((prefix) => head.startsWith(prefix))) return true;
  const window = head.slice(0, MARKER_SCAN).toLowerCase();
  return INJECTED_USER_MARKERS.some((marker) => window.includes(marker.toLowerCase()));
};

/**
 * 取 assistant 正文；**没有正文 part 就返回空串**（不要退回 reasoning）。
 * 空串的调用方会跳过这条事件——用户宁可少一条气泡，也不要满屏英文推理。
 * 规则只有一份，实际实现见 `./assistant-text.js` 的 `assistantText()`；这里只是
 * 给「对话正文」起个语义更直白的名字，避免两处各写一套过滤逻辑。
 */
export const chatText = assistantText;

/**
 * 对已存进 `session-archive.json` 的旧事件做一次读取时清洗：
 * 老存档里已经躺着注入消息和英文推理，只在写入端过滤救不了它们。
 */
export const isInjectedEvent = (event) => {
  if (!event || typeof event !== 'object') return true;
  const kind = String(event.kind ?? '');
  if (kind === 'user') return isInjectedUserText(event.text);
  if (kind === 'assistant') {
    const text = String(event.text ?? '').trim();
    return !text;
  }
  return false;
};
