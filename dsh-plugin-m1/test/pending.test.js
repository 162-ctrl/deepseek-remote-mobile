// M4.31：手机不在那条会话的直播页时，也要能看到「电脑在等你选一项」。
//
// 两件事：①接管策略从「正在看这条会话」放宽到「手机 App 还连着」；
// ②新增跨会话的待回答摘要（`GET /api/v1/desktop/pending`），让手机在别的页面
// 也能弹出提示，点进去再拿完整选项。
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

import { createRelayHttpServer } from '../lib/server.js';

const source = readFileSync(
  fileURLToPath(new URL('../lib/index.js', import.meta.url)),
  'utf8',
);

/** 从源码里截一个 `const name = (...) => {...}` 或 `const name = (...) => expr;`。 */
const grabArrow = (name) => {
  const start = source.indexOf(`const ${name} = (`);
  assert.ok(start >= 0, `找不到函数 ${name}`);
  const bodyStart = source.indexOf('{', source.indexOf('=>', start));
  if (bodyStart < 0) {
    const end = source.indexOf(';', start);
    return source.slice(start, end + 1);
  }
  let depth = 0;
  for (let i = bodyStart; i < source.length; i += 1) {
    const ch = source[i];
    if (ch === '{') depth += 1;
    else if (ch === '}') {
      depth -= 1;
      if (depth === 0) return source.slice(start, i + 2);
    }
  }
  throw new Error(`函数 ${name} 花括号不配平`);
};

const buildPending = (deps = {}) => {
  const factory = new Function(
    'pendingQuestions',
    'pendingApprovals',
    'getDesktopSession',
    'getArchivedSession',
    'ctx',
    'collectLogQuestions',
    'remoteQuestionEntries',
    'mergeQuestionEntries',
    `${grabArrow('listPendingDesktop')}\nreturn listPendingDesktop;`,
  );
  return factory(
    deps.pendingQuestions ?? new Map(),
    deps.pendingApprovals ?? new Map(),
    deps.getDesktopSession ?? (() => null),
    deps.getArchivedSession ?? (() => null),
    deps.ctx ?? { get: () => undefined },
    deps.collectLogQuestions ?? (() => []),
    deps.remoteQuestionEntries ?? (() => []),
    deps.mergeQuestionEntries ??
      ((...groups) => {
        const merged = new Map();
        for (const group of groups) {
          for (const entry of Array.isArray(group) ? group : []) {
            const key = String(entry?.questionId ?? '');
            if (!key || merged.has(key)) continue;
            merged.set(key, entry);
          }
        }
        return [...merged.values()];
      }),
  );
};

test('M4.31 提问与授权都被压成标题级摘要', () => {
  const pendingQuestions = new Map([
    [
      'call_1',
      {
        sessionId: 'session-a',
        questionId: 'call_1',
        createdAt: 1700000000000,
        questions: [{ header: '确认范围', question: '整首歌都放进去吗？' }, { question: '第二个问题' }],
        finish: () => {},
      },
    ],
  ]);
  const pendingApprovals = new Map([
    [
      'ap_1',
      { sessionId: 'session-b', approvalId: 'ap_1', createdAt: 1700000001000, toolName: 'bash', finish: () => {} },
    ],
  ]);
  const list = buildPending({
    pendingQuestions,
    pendingApprovals,
    getDesktopSession: (id) => (id === 'session-a' ? { title: '示例项目E' } : null),
    getArchivedSession: (id) => (id === 'session-b' ? { title: '存档的会话' } : null),
  });

  const pending = list();
  assert.equal(pending.questions.length, 1);
  const [question] = pending.questions;
  assert.equal(question.sessionId, 'session-a');
  assert.equal(question.questionId, 'call_1');
  assert.equal(question.count, 2);
  assert.equal(question.header, '确认范围');
  assert.equal(question.question, '整首歌都放进去吗？');
  assert.equal(question.title, '示例项目E');
  // finish 是函数，绝不能下发
  assert.equal(question.finish, undefined);

  assert.equal(pending.approvals.length, 1);
  assert.equal(pending.approvals[0].title, '存档的会话');
  assert.equal(pending.approvals[0].toolName, 'bash');
});

test('M4.31 空的 sessionId / questionId 不进摘要', () => {
  const pendingQuestions = new Map([
    ['x', { sessionId: '', questionId: 'x', questions: [{ question: 'a' }], finish: () => {} }],
    ['y', { sessionId: 'session-y', questionId: '', questions: [{ question: 'b' }], finish: () => {} }],
  ]);
  const list = buildPending({ pendingQuestions });
  assert.deepEqual(list().questions, []);
  assert.deepEqual(list().approvals, []);
});

test('M4.31 没有提问时摘要为空数组而不是 null', () => {
  const list = buildPending();
  const pending = list();
  assert.deepEqual(pending.questions, []);
  assert.deepEqual(pending.approvals, []);
});

// 路由层：真起 http server，守 token 与 501 两条边界。
function fakeHub() {
  const tokens = new Map([
    ['agent-token', 'agent'],
    ['app-token', 'app'],
  ]);
  return {
    pairingCode: '000000',
    agentOnline: true,
    appCount: 1,
    authorizeToken(token, role = 'app') {
      const actual = tokens.get(String(token ?? ''));
      return actual !== undefined && actual === role;
    },
  };
}

async function withServer(pageContext, run) {
  const server = createRelayHttpServer({
    hub: fakeHub(),
    version: '0.2.30-test',
    pageContext: { port: 8787, ...pageContext },
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address();
  try {
    await run(`http://127.0.0.1:${port}`);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
}

const get = (base, path, token) =>
  fetch(`${base}${path}`, { headers: token ? { authorization: `Bearer ${token}` } : {} });

test('M4.31 app token 读到待回答摘要', async () => {
  const pending = { questions: [{ sessionId: 's1', questionId: 'q1', count: 1 }], approvals: [] };
  await withServer({ desktopPending: () => pending }, async (base) => {
    const response = await get(base, '/api/v1/desktop/pending', 'app-token');
    assert.equal(response.status, 200);
    assert.deepEqual((await response.json()).questions, pending.questions);
  });
});

test('M4.31 不带 token 或 agent token 读不到', async () => {
  await withServer({ desktopPending: () => ({ questions: [], approvals: [] }) }, async (base) => {
    assert.equal((await get(base, '/api/v1/desktop/pending')).status, 401);
    const asAgent = await get(base, '/api/v1/desktop/pending', 'agent-token');
    assert.equal(asAgent.status, 401);
    assert.equal((await asAgent.json()).code, 'AUTH_FAILED');
  });
});

test('M4.31 插件太旧（没有 desktopPending）时回 501', async () => {
  await withServer({}, async (base) => {
    const response = await get(base, '/api/v1/desktop/pending', 'app-token');
    assert.equal(response.status, 501);
    assert.equal((await response.json()).code, 'PENDING_UNAVAILABLE');
  });
});
