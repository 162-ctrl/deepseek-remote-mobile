import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { extractText, mapSessionUpdate, summarizeConfigOptions } from '../../src/harness/acp/mapper.ts';

const AT = '2026-10-31T00:00:00.000Z';

describe('mapSessionUpdate', () => {
  it('agent_message_chunk（字符串 content）→ output/answer', () => {
    const mapped = mapSessionUpdate(
      { sessionId: 's1', sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: '收到' } },
      AT,
    );
    assert.equal(mapped.sessionId, 's1');
    assert.deepEqual(mapped.events, [{ type: 'output', stream: 'answer', text: '收到', at: AT }]);
  });

  it('兼容 {sessionId, update:{...}} 形态与数组 content', () => {
    const mapped = mapSessionUpdate(
      { sessionId: 's1', update: { sessionUpdate: 'agent_message_chunk', content: [{ type: 'text', text: 'A' }, { type: 'text', text: 'B' }] } },
      AT,
    );
    assert.equal(mapped.events[0]?.type, 'output');
    assert.equal((mapped.events[0] as { text: string }).text, 'AB');
  });

  it('agent_thought_chunk → thinking', () => {
    const mapped = mapSessionUpdate({ sessionId: 's1', sessionUpdate: 'agent_thought_chunk', content: { text: '思考中' } }, AT);
    assert.deepEqual(mapped.events, [{ type: 'thinking', text: '思考中', at: AT }]);
  });

  it('tool_call 携带 rawInput', () => {
    const mapped = mapSessionUpdate(
      { sessionId: 's1', sessionUpdate: 'tool_call', toolCallId: 't1', title: 'shell', rawInput: { command: 'node -v' } },
      AT,
    );
    assert.deepEqual(mapped.events, [{ type: 'tool_call', callId: 't1', tool: 'shell', input: { command: 'node -v' }, at: AT }]);
  });

  it('tool_call_update 归一化状态并截断结果', () => {
    const mapped = mapSessionUpdate(
      { sessionId: 's1', sessionUpdate: 'tool_call_update', toolCallId: 't1', status: 'failed', rawOutput: 'x'.repeat(3000) },
      AT,
    );
    const event = mapped.events[0];
    assert.equal(event?.type, 'tool_call_update');
    if (event?.type === 'tool_call_update') {
      assert.equal(event.status, 'failed');
      assert.ok((event.resultExcerpt ?? '').length <= 2100);
    }
  });

  it('usage_update → usage', () => {
    const mapped = mapSessionUpdate({ sessionId: 's1', sessionUpdate: 'usage_update', used: 6425, size: 1000000 }, AT);
    assert.deepEqual(mapped.events, [{ type: 'usage', contextUsed: 6425, contextSize: 1000000, at: AT }]);
  });

  it('未知类型忽略且不抛错（RC 契约只做加法）', () => {
    const mapped = mapSessionUpdate({ sessionId: 's1', sessionUpdate: 'plan_update', plan: [] }, AT);
    assert.deepEqual(mapped.events, []);
    assert.equal(mapped.kind, 'plan_update');
  });

  it('非对象参数安全返回空', () => {
    assert.deepEqual(mapSessionUpdate(null, AT), { sessionId: null, kind: null, events: [] });
  });
});

describe('extractText', () => {
  it('支持字符串/对象/数组与嵌套 content', () => {
    assert.equal(extractText('abc'), 'abc');
    assert.equal(extractText({ text: 'x' }), 'x');
    assert.equal(extractText({ content: { text: 'y' } }), 'y');
    assert.equal(extractText([{ text: 'a' }, 'b']), 'ab');
    assert.equal(extractText({ other: 1 }), '');
  });
});

describe('summarizeConfigOptions', () => {
  it('拍平 id/current/values', () => {
    const summary = summarizeConfigOptions([
      { id: 'reasoning_effort', currentValue: 'high', options: [{ value: 'off' }, { value: 'low' }, 'max'] },
      { id: 'model', current: '["deepseek-official","deepseek-v4-flash"]' },
    ]);
    assert.deepEqual(summary, [
      { id: 'reasoning_effort', current: 'high', values: ['off', 'low', 'max'] },
      { id: 'model', current: '["deepseek-official","deepseek-v4-flash"]', values: [] },
    ]);
  });

  it('非数组返回空', () => {
    assert.deepEqual(summarizeConfigOptions(undefined), []);
  });
});
