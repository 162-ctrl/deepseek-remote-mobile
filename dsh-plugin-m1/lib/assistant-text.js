/**
 * M3.6：把 Host 的 content part 数组压成「人真正看到的正文」。
 *
 * 电脑端把 reasoning / thinking 折叠在「思考过程」里；手机端如果直接拼接全部
 * part，就会把英文推理当成回复正文整段下发（用户反馈「不要这样的英文」）。
 * 这里只收集正文类 part（text / markdown / output_text）。
 *
 * M4.16：没有正文 part 时**返回空串**，不再退回 reasoning。用户看到「Header empty.
 * So where does blue come from?…」这种英文思考气泡，就是旧回退逻辑把整条推理当
 * 回复下发造成的；空串的调用方会跳过这条事件，宁可少一条气泡也不要满屏英文推理。
 */

export const TEXT_PART_TYPES = new Set(['', 'text', 'markdown', 'output_text']);

export const partText = (part) => {
  if (typeof part === 'string') return part;
  if (!part || typeof part !== 'object') return '';
  if (typeof part.text === 'string') return part.text;
  if (typeof part.content === 'string') return part.content;
  return '';
};

export const partType = (part) => {
  if (!part || typeof part !== 'object') return '';
  return typeof part.type === 'string' ? part.type : '';
};

/** 拼接所有 part（含推理），只用于工具结果等非正文场景。 */
export const contentText = (content) => {
  if (typeof content === 'string') return content;
  if (!Array.isArray(content)) return '';
  return content.map(partText).join('');
};

/** 只取正文 part；没有正文 part 时返回空串（M4.16：不再退回推理）。 */
export const assistantText = (content) => {
  if (typeof content === 'string') return content.trim();
  if (!Array.isArray(content)) return '';
  const texts = [];
  for (const part of content) {
    const text = partText(part);
    if (!text) continue;
    if (TEXT_PART_TYPES.has(partType(part))) texts.push(text);
  }
  return texts.join('').replace(/\n{3,}/g, '\n\n').trim();
};
