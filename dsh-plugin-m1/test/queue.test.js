// M4.21：手机端也要有电脑端那排「N 条排队消息」。
//
// 电脑端在一轮还在跑的时候，会把后面排着的话列成「4 条排队消息」，每条能改字 /
// 删除 / 插话（Cmd/Ctrl+Enter 全部插话）。数据来自 Host `sessionController.state()`，
// 改动走 `updateQueue({ sessionId, itemId, action })`。这里验证插件这层的翻译：
//   1. state() 必须带 signal（少传就报 throwIfAborted）；
//   2. 队列项压成 { id, placement, text }，纯附件消息也有可读文案；
//   3. remove / steer / edit 三种 action 翻成 Host 的 QueueAction；
//   4. 不支持时给可区分错误码。
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { partText } from '../lib/assistant-text.js';

const here = dirname(fileURLToPath(import.meta.url));
const source = readFileSync(join(here, '..', 'lib', 'index.js'), 'utf8');

/** 截出 `const name = (async) (…` 的完整箭头函数源码（从 `{` 配平）。 */
const grabArrow = (name) => {
  const asyncHit = source.indexOf(`\n  const ${name} = async (`);
  const start = asyncHit >= 0 ? asyncHit : source.indexOf(`\n  const ${name} = (`);
  assert.ok(start >= 0, `找不到函数 ${name}`);
  const bodyStart = source.indexOf('{', source.indexOf('=>', start));
  let depth = 0;
  for (let i = bodyStart; i < source.length; i += 1) {
    const ch = source[i];
    if (ch === '{') depth += 1;
    else if (ch === '}') {
      depth -= 1;
      if (depth === 0) return source.slice(start + 1, i + 1);
    }
  }
  throw new Error(`函数 ${name} 花括号不配平`);
};

const grabConst = (name) => {
  const start = source.indexOf(`\n  const ${name} = `);
  assert.ok(start >= 0, `找不到 ${name}`);
  let depth = 0;
  for (let i = start; i < source.length; i += 1) {
    const ch = source[i];
    if (ch === '{') depth += 1;
    else if (ch === '}') {
      depth -= 1;
      if (depth === 0) return source.slice(start + 1, i + 1);
    }
  }
  throw new Error(`${name} 花括号不配平`);
};

const queueItemTextSrc = grabArrow('queueItemText');
const readSrc = grabArrow('readDesktopQueue');
const mutateSrc = grabArrow('mutateDesktopQueue');

const build = (ctx, calls, logs) => {
  const factory = new Function(
    'ctx',
    'log',
    'partText',
    'module',
    `
    ${queueItemTextSrc}
    ${readSrc}
    ${mutateSrc}
    return { queueItemText, readDesktopQueue, mutateDesktopQueue };
    `,
  );
  return factory(ctx, (line) => logs.push(String(line)), partText, {});
};

const collect = () => {
  const calls = [];
  const logs = [];
  return { calls, logs };
};

test('readDesktopQueue 把队列项压成手机能显示的形状', async () => {
  const stateCalls = [];
  const ctx = {
    get: () => ({
      state: async (request, signal) => {
        stateCalls.push({ request, hasSignal: typeof signal?.throwIfAborted === 'function' });
        return {
          running: true,
          active: true,
          queue: [
            {
              id: 'q1',
              placement: 'queued',
              content: [{ type: 'text', text: '对话做成这样' }],
            },
            {
              id: 'q2',
              placement: 'queued',
              content: [{ type: 'image', url: 'x' }],
            },
          ],
        };
      },
    }),
  };
  const { logs } = collect();
  const api = build(ctx, stateCalls, logs);

  const queue = await api.readDesktopQueue('session-1');

  assert.equal(queue.supported, true);
  assert.equal(queue.running, true);
  assert.equal(queue.items.length, 2);
  assert.deepEqual(queue.items[0], {
    id: 'q1',
    placement: 'queued',
    text: '对话做成这样',
  });
  assert.equal(queue.items[1].text, '（1 个附件）');
  // state 的第二个参数不能漏：Host 内部会 signal.throwIfAborted()。
  assert.equal(stateCalls.length, 1);
  assert.deepEqual(stateCalls[0].request, { sessionId: 'session-1' });
  assert.equal(stateCalls[0].hasSignal, true);
});

test('readDesktopQueue 在没有 state 能力时说不支持', async () => {
  const ctx = { get: () => ({}) };
  const { logs } = collect();
  const api = build(ctx, [], logs);

  const queue = await api.readDesktopQueue('session-1');

  assert.equal(queue.supported, false);
  assert.deepEqual(queue.items, []);
  assert.match(queue.error, /Harness/);
});

test('readDesktopQueue 把 Host 抛的错收进 error，不往上抛', async () => {
  const ctx = {
    get: () => ({
      state: async () => {
        const error = new Error('boom');
        error.code = 'session/not-found';
        throw error;
      },
    }),
  };
  const { logs } = collect();
  const api = build(ctx, [], logs);

  const queue = await api.readDesktopQueue('session-gone');

  assert.equal(queue.supported, true);
  assert.equal(queue.error, 'session/not-found');
});

test('mutateDesktopQueue 把 remove / steer / edit 翻成 QueueAction', async () => {
  const updates = [];
  const ctx = {
    get: () => ({
      updateQueue: async (request) => {
        updates.push(request);
        return { accepted: true };
      },
      state: async () => ({ running: true, queue: [] }),
    }),
  };
  const { logs } = collect();
  const api = build(ctx, [], logs);

  await api.mutateDesktopQueue('session-1', 'q1', 'remove');
  await api.mutateDesktopQueue('session-1', 'q2', 'steer');
  await api.mutateDesktopQueue('session-1', 'q3', 'edit', '  改过的话  ');

  assert.deepEqual(
    updates.map((row) => row.action),
    [
      { kind: 'remove' },
      { kind: 'steer' },
      { kind: 'edit', content: [{ type: 'text', text: '改过的话' }] },
    ],
  );
  assert.equal(updates[0].itemId, 'q1');
  assert.equal(updates[2].sessionId, 'session-1');
  assert.ok(logs.some((line) => line.includes('手机改排队消息')));
});

test('mutateDesktopQueue 拒绝空 id、空内容和未知操作', async () => {
  const ctx = {
    get: () => ({
      updateQueue: async () => ({ accepted: true }),
      state: async () => ({ running: true, queue: [] }),
    }),
  };
  const { logs } = collect();
  const api = build(ctx, [], logs);

  await assert.rejects(() => api.mutateDesktopQueue('s', '', 'remove'), /缺少排队消息 id/);
  await assert.rejects(() => api.mutateDesktopQueue('s', 'q1', 'edit', '   '), /不能为空/);
  await assert.rejects(() => api.mutateDesktopQueue('s', 'q1', 'moveUp'), /不认识的排队操作/);
});

test('mutateDesktopQueue 在没有 updateQueue 时给出 QUEUE_UNSUPPORTED', async () => {
  const ctx = { get: () => ({}) };
  const { logs } = collect();
  const api = build(ctx, [], logs);

  await assert.rejects(
    () => api.mutateDesktopQueue('s', 'q1', 'remove'),
    (error) => error.code === 'QUEUE_UNSUPPORTED',
  );
});

test('mutateDesktopQueue 把 Host 错误码透传给手机', async () => {
  const ctx = {
    get: () => ({
      updateQueue: async () => {
        const error = new Error('writer held');
        error.code = 'session/writer-held';
        throw error;
      },
    }),
  };
  const { logs } = collect();
  const api = build(ctx, [], logs);

  await assert.rejects(
    () => api.mutateDesktopQueue('s', 'q1', 'steer'),
    (error) => error.code === 'session/writer-held',
  );
});
