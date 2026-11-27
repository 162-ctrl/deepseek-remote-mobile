import test from 'node:test';
import assert from 'node:assert/strict';

import {
  INJECTED_USER_PREFIXES,
  chatText,
  isInjectedEvent,
  isInjectedUserText,
} from '../lib/chat-filter.js';

test('注入的运行时上下文被认出来（含旧版漏掉的 Time sampled）', () => {
  const injected = [
    'Time sampled while preparing turn 3, step 24: 2026-11-10T22:49:03+08:00[Asia/Shanghai]',
    '\n\nTime sampled while preparing turn 9, step 13: 2026-11-16T16:35:20+08:00',
    'Current runtime context. This snapshot supersedes earlier runtime-context snapshots.',
    'Browser time zone for this request: Asia/Shanghai.',
    'Elapsed since the preceding model-visible message: unavailable.',
    '<system-reminder> A skill is a reusable set of task-specific instructions.',
    '<hindsight_knowledge_refresh> Reminder — this repo has memory',
    '<available_skills> …',
    '<acp tokens="63" type="text">m01812</acp>',
    '   ',
  ];
  for (const text of injected) {
    assert.equal(isInjectedUserText(text), true, `应判定为注入：${text.slice(0, 30)}`);
  }
});

test('真正的人话不会被误杀', () => {
  const human = [
    '继续',
    '每个对话里面的内容你不应该放到最新的吗，而且你这英文是什么，我要的是对话',
    // 正文中段提到 system-reminder 不算注入：只看开头 160 字符。
    `${'这是一段很长的说明，'.repeat(20)}顺便提一下 <system-reminder> 这种标签的处理`,
    '帮我改一下 dsh-plugin-m1/lib/index.js 里的过滤逻辑',
  ];
  for (const text of human) {
    assert.equal(isInjectedUserText(text), false, `不该判定为注入：${text.slice(0, 30)}`);
  }
});

test('chatText 只取正文 part，纯 reasoning 返回空串', () => {
  assert.equal(
    chatText([
      { type: 'reasoning', text: 'Header empty. So where does blue come from?' },
      { type: 'text', text: '蓝色来自第 6 页的页面背景。' },
    ]),
    '蓝色来自第 6 页的页面背景。',
  );
  assert.equal(chatText([{ type: 'reasoning', text: '纯推理' }]), '');
  assert.equal(chatText('  直接字符串  '), '直接字符串');
  assert.equal(chatText(null), '');
});

test('isInjectedEvent 清洗老存档里的脏事件', () => {
  assert.equal(
    isInjectedEvent({ kind: 'user', text: 'Time sampled while preparing turn 3, step 24: …' }),
    true,
  );
  assert.equal(isInjectedEvent({ kind: 'user', text: '帮我看看这个报错' }), false);
  // 英文推理整段下发的老记录：assistant 文本有内容但其实是推理，这里只能按空文本清；
  // 非空 assistant 一律保留，避免误删真正的回复。
  assert.equal(isInjectedEvent({ kind: 'assistant', text: 'Header empty. So where…' }), false);
  assert.equal(isInjectedEvent({ kind: 'assistant', text: '   ' }), true);
  assert.equal(isInjectedEvent({ kind: 'tool-call', name: 'read' }), false);
  assert.equal(isInjectedEvent(null), true);
});

test('前缀表集中在一处，且已经包含 Time sampled', () => {
  assert.ok(INJECTED_USER_PREFIXES.includes('Time sampled while preparing'));
  assert.ok(INJECTED_USER_PREFIXES.includes('Current runtime context'));
});
