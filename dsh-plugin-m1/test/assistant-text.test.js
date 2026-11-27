import test from 'node:test';
import assert from 'node:assert/strict';

import { assistantText, contentText, partText } from '../lib/assistant-text.js';

test('assistantText 只取正文 part，丢掉 reasoning/thinking', () => {
  const content = [
    { type: 'reasoning', text: 'Let me check lines 20-95 and 135-226.' },
    { type: 'text', text: '修好了：把 m1-up.ps1 存成 UTF-8 BOM。' },
  ];
  assert.equal(assistantText(content), '修好了：把 m1-up.ps1 存成 UTF-8 BOM。');
});

test('assistantText 保留 markdown / output_text / 无 type 的正文', () => {
  const content = [
    { type: 'markdown', text: '## 结论\n\n**已修复**' },
    { type: 'output_text', text: '\n第二段' },
  ];
  assert.equal(assistantText(content), '## 结论\n\n**已修复**\n第二段');
  assert.equal(assistantText([{ text: '无 type 也算正文' }]), '无 type 也算正文');
});

test('assistantText 没有正文 part 时返回空串（M4.16：不再把推理当回复）', () => {
  const content = [{ type: 'reasoning', text: '纯推理消息' }];
  assert.equal(assistantText(content), '');
  assert.equal(
    assistantText([
      { type: 'reasoning', text: 'Header empty. So where does blue come from?' },
      { type: 'thinking', text: ' Maybe page background…' },
    ]),
    '',
  );
});

test('assistantText 兼容字符串输入与空值，并压缩多余空行', () => {
  assert.equal(assistantText('  直接字符串  '), '直接字符串');
  assert.equal(assistantText(null), '');
  assert.equal(assistantText([]), '');
  assert.equal(assistantText([{ type: 'text', text: 'a\n\n\n\nb' }]), 'a\n\nb');
});

test('contentText 保留全部 part（工具结果场景）', () => {
  const content = [
    { type: 'reasoning', text: 'think ' },
    'raw ',
    { content: 'tail' },
    { type: 'tool', text: '' },
  ];
  assert.equal(contentText(content), 'think raw tail');
});

test('partText 对非对象/非字符串返回空串', () => {
  assert.equal(partText(undefined), '');
  assert.equal(partText(42), '');
  assert.equal(partText({ text: 'x' }), 'x');
});
