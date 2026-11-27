// M4.23：电脑端「确认需求」提问卡在手机上的接管。
//
// 背景：用户说「这个需要审核操作的手机上还是没有」。查到截图里那张卡不是权限审批，
// 而是 `ask_user_question` 工具弹的提问卡 —— 它走的是 Host 的
// `user-questions/request` waterfall，而不是 `approval/request`，所以以前手机上什么都没有。
//
// 这里从源码截出 `normalizeQuestionAnswers` 与 `answerDesktopQuestion`，注入假的
// pendingQuestions / log，验证答案的压缩与「谁有权回答」的边界。
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const source = readFileSync(join(here, '..', 'lib', 'index.js'), 'utf8');

/** 截出 `const name = (...) => { ... }` 的整个声明。 */
const grabArrow = (name) => {
  const start = source.indexOf(`\n  const ${name} = (`);
  assert.ok(start >= 0, `找不到函数 ${name}`);
  const bodyStart = source.indexOf('{', source.indexOf('=>', start));
  assert.ok(bodyStart > start, `找不到函数体 ${name}`);
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

const normalizeSrc = grabArrow('normalizeQuestionAnswers');
const answerSrc = grabArrow('answerDesktopQuestion');

/** 截出 `async function onDesktopQuestion(...) {...}`（M4.58f 起它是独立函数，根 ctx 与 agent 作用域各注册一次）。 */
const grabHandler = () => {
  const start = source.indexOf('async function onDesktopQuestion');
  assert.ok(start >= 0, '找不到提问监听');
  const fnStart = start;
  const bodyStart = source.indexOf('{', fnStart);
  let depth = 0;
  for (let i = bodyStart; i < source.length; i += 1) {
    const ch = source[i];
    if (ch === '{') depth += 1;
    else if (ch === '}') {
      depth -= 1;
      if (depth === 0) {
        const fnSrc = source.slice(fnStart, i + 1);
        return (deps) =>
          new Function(
            'isWatching',
            'phoneOnline',
            'phoneConnected',
            'pendingQuestions',
            'log',
            'QUESTION_TIMEOUT_MS',
            'traceAnswer',
            `const handler = ${fnSrc}; return handler;`,
          )(
              deps.isWatching,
              deps.phoneOnline ?? (() => false),
              deps.phoneConnected ?? (() => false),
              deps.pendingQuestions,
              deps.log,
              deps.timeoutMs ?? 300000,
              deps.traceAnswer ?? (() => {}),
            );
      }
    }
  }
  throw new Error('提问监听花括号不配平');
};

const build = (deps = {}) => {
  const pending = deps.pending ?? new Map();
  const logs = [];
  const factory = new Function(
    'pendingQuestions',
    'log',
    'ctx',
    'collectLogQuestions',
    'questionContentKey',
    'logCallSettled',
    'remoteQuestions',
    'dropRemoteQuestion',
    'traceAnswer',
    `let questionAnswerFailure = null;\nlet answeredQuestions = new Map();\nconst ANSWERED_TTL_MS = 10 * 60 * 1000;\n${normalizeSrc}\n${answerSrc}\nreturn { normalizeQuestionAnswers, answerDesktopQuestion, failure: () => questionAnswerFailure };`,
  );
  const contentKey =
    deps.questionContentKey ??
    ((entry) =>
      `${String(entry?.sessionId ?? '')}|${(Array.isArray(entry?.questions) ? entry.questions : [])
        .map((item) => `${String(item?.id ?? '')}:${String(item?.question ?? item?.header ?? '')}`)
        .join('~')}`);
  const api = factory(
    pending,
    (line) => logs.push(line),
    deps.ctx ?? { get: () => undefined },
    deps.collectLogQuestions ?? (() => []),
    contentKey,
    deps.logCallSettled ?? (() => false),
    deps.remoteQuestions ?? new Map(),
    deps.dropRemoteQuestion ?? ((id) => deps.remoteQuestions?.delete?.(String(id))),
    () => {},
  );
  return { pending, logs, ...api };
};

const question = {
  id: 'q1',
  question: '歌词字幕想要什么形式？',
  options: [{ label: '手写体' }],
};

test('答案只带 id + selected + custom，空项被丢掉', () => {
  const { normalizeQuestionAnswers } = build();
  const answers = normalizeQuestionAnswers([
    { id: 'q1', selected: ['手写体'], custom: '' },
    { id: 'q2', selected: [], custom: '  竖排  ' },
    { id: 'q3', selected: [], custom: '   ' },
    { id: '', selected: ['x'] },
    null,
  ]);
  assert.deepEqual(answers, [
    { id: 'q1', selected: ['手写体'] },
    { id: 'q2', selected: [], custom: '竖排' },
  ]);
});

test('selected 里的空白项被过滤，非数组当空处理', () => {
  const { normalizeQuestionAnswers } = build();
  assert.deepEqual(normalizeQuestionAnswers([{ id: 'q1', selected: ['a', '  ', 'b'] }]), [
    { id: 'q1', selected: ['a', 'b'] },
  ]);
  assert.deepEqual(normalizeQuestionAnswers([{ id: 'q1', selected: 'oops' }]), []);
  assert.deepEqual(normalizeQuestionAnswers(null), []);
});

test('回答会把答案交给挂起的 Promise，并从队列里摘掉', () => {
  const { pending, logs, answerDesktopQuestion } = build();
  const received = [];
  pending.set('call_1', {
    sessionId: 'session-a',
    questionId: 'call_1',
    questions: [question],
    createdAt: Date.now(),
    finish: (value) => received.push(value),
  });
  const ok = answerDesktopQuestion('session-a', 'call_1', [{ id: 'q1', selected: ['手写体'] }]);
  assert.equal(ok, true);
  assert.deepEqual(received, [{ answers: [{ id: 'q1', selected: ['手写体'] }] }]);
  assert.match(logs.at(-1), /手机回答提问：session-a · 1 个问题/);
});

test('跳过（空答案）也算回答，日志会标注', () => {
  const { pending, logs, answerDesktopQuestion } = build();
  const received = [];
  pending.set('call_2', {
    sessionId: 'session-a',
    questionId: 'call_2',
    questions: [question],
    createdAt: Date.now(),
    finish: (value) => received.push(value),
  });
  assert.equal(answerDesktopQuestion('session-a', 'call_2', []), true);
  assert.deepEqual(received, [{ answers: [] }]);
  assert.match(logs.at(-1), /（跳过）/);
});

test('别人的会话回答不了，未知 questionId 也不行', () => {
  const { pending, answerDesktopQuestion } = build();
  pending.set('call_3', {
    sessionId: 'session-a',
    questionId: 'call_3',
    questions: [question],
    createdAt: Date.now(),
    finish: () => assert.fail('不该被调用'),
  });
  assert.equal(answerDesktopQuestion('session-b', 'call_3', [{ id: 'q1', selected: ['x'] }]), false);
  assert.equal(answerDesktopQuestion('session-a', 'call_missing', []), false);
});

// M4.56：DSH 的问答工具走 askTimed，压根不派发 `user-questions/request`，
// 所以手机这边的提问要从会话日志里认，再用 userQuestions.answer() 交回去。
test('M4.56 日志里认出来的提问，用 userQuestions.answer 交回会话', () => {
  const calls = [];
  const agent = { id: 'session-a' };
  const { logs, answerDesktopQuestion } = build({
    ctx: {
      get: (name) => {
        if (name === 'userQuestions') return { answer: (...args) => (calls.push(args), true) };
        if (name === 'agents') return { get: (id) => (id === 'session-a' ? agent : undefined) };
        return undefined;
      },
    },
    collectLogQuestions: (sessionId) =>
      sessionId === 'session-a'
        ? [{ sessionId: 'session-a', questionId: 'call_7', questions: [question], fromLog: true }]
        : [],
  });
  const ok = answerDesktopQuestion('session-a', 'call_7', [{ id: 'q1', selected: ['手写体'] }]);
  assert.equal(ok, true);
  assert.deepEqual(calls, [[agent, 'call_7', { answers: [{ id: 'q1', selected: ['手写体'] }] }]]);
  assert.match(logs.at(-1), /手机回答提问（日志路径）：session-a · 1 个问题/);
});

test('M4.56 日志路径的「跳过」也要每题一条空 selected', () => {
  const calls = [];
  const { answerDesktopQuestion } = build({
    ctx: {
      get: (name) => {
        if (name === 'userQuestions') return { answer: (...args) => (calls.push(args), true) };
        if (name === 'agents') return { get: () => ({ id: 'session-a' }) };
        return undefined;
      },
    },
    collectLogQuestions: () => [
      { sessionId: 'session-a', questionId: 'call_8', questions: [question], fromLog: true },
    ],
  });
  assert.equal(answerDesktopQuestion('session-a', 'call_8', []), true);
  assert.deepEqual(calls[0][2], { answers: [{ id: 'q1', selected: [] }] });
});

test('M4.58 回答失败会说明原因：提问没了 / 服务不在 / Agent 不在 / 不再等待', () => {
  const logEntry = () => [
    { sessionId: 'session-a', questionId: 'call_9', questions: [question], fromLog: true },
  ];
  // 提问在日志里已经找不到
  const missing = build({ collectLogQuestions: () => [] });
  assert.equal(missing.answerDesktopQuestion('session-a', 'call_9', []), false);
  assert.equal(missing.failure().code, 'QUESTION_NOT_FOUND');

  // DSH 没有 userQuestions 服务
  const noService = build({ ctx: { get: () => undefined }, collectLogQuestions: logEntry });
  assert.equal(noService.answerDesktopQuestion('session-a', 'call_9', []), false);
  assert.equal(noService.failure().code, 'NO_QUESTION_SERVICE');

  // 有服务但 Agent 已经不在
  const noAgent = build({
    ctx: {
      get: (name) =>
        name === 'userQuestions'
          ? { answer: () => true }
          : name === 'agents'
            ? { get: () => undefined, list: () => [] }
            : undefined,
    },
    collectLogQuestions: logEntry,
  });
  assert.equal(noAgent.answerDesktopQuestion('session-a', 'call_9', []), false);
  assert.equal(noAgent.failure().code, 'NO_AGENT');

  // Agent 从列表里还能捞回来（get 拿不到时兜底）
  const listAgent = { id: 'session-a' };
  const viaList = build({
    ctx: {
      get: (name) =>
        name === 'userQuestions'
          ? { answer: () => true }
          : name === 'agents'
            ? { get: () => undefined, list: () => [listAgent] }
            : undefined,
    },
    collectLogQuestions: logEntry,
  });
  assert.equal(viaList.answerDesktopQuestion('session-a', 'call_9', []), true);

  // M4.58e：answer() 返回 false = 这条提问已经结束（多半电脑先答了），按成功处理，不弹红条
  const notContinued = build({
    ctx: {
      get: (name) =>
        name === 'userQuestions'
          ? { answer: () => false }
          : name === 'agents'
            ? { get: () => ({ id: 'session-a' }) }
            : undefined,
    },
    collectLogQuestions: logEntry,
  });
  assert.equal(notContinued.answerDesktopQuestion('session-a', 'call_9', []), true);
  assert.match(notContinued.logs.at(-1), /已经结束/);

  // answer() 抛错时把错误码透出来
  const thrown = build({
    ctx: {
      get: (name) =>
        name === 'userQuestions'
          ? {
              answer: () => {
                const error = new Error('batch does not name each question');
                error.code = 'BAD_ANSWER';
                throw error;
              },
            }
          : name === 'agents'
            ? { get: () => ({ id: 'session-a' }) }
            : undefined,
    },
    collectLogQuestions: logEntry,
  });
  assert.equal(thrown.answerDesktopQuestion('session-a', 'call_9', []), false);
  assert.equal(thrown.failure().code, 'BAD_ANSWER');
  assert.match(thrown.failure().message, /batch does not name/);
});

test('M4.58b 手机用日志里的 callId 提交，也能把 waterfall 那条挂起的提问答掉', () => {
  const pending = new Map();
  const received = [];
  pending.set('q_k3f1ab', {
    sessionId: 'session-a',
    questionId: 'q_k3f1ab',
    questions: [question],
    createdAt: Date.now(),
    finish: (value) => received.push(value),
  });
  const { answerDesktopQuestion, logs } = build({
    pending,
    // waterfall 里没有 wait.callId，插件只能自己生成 q_…；日志里是真实 callId。
    collectLogQuestions: () => [
      { sessionId: 'session-a', questionId: 'call_00_abc', questions: [question], fromLog: true },
    ],
    ctx: { get: () => undefined },
  });
  const ok = answerDesktopQuestion('session-a', 'call_00_abc', [{ id: 'q1', selected: ['手写体'] }]);
  assert.equal(ok, true);
  assert.deepEqual(received, [{ answers: [{ id: 'q1', selected: ['手写体'] }] }]);
  assert.equal(pending.size, 1, 'waterfall 的那条应该由 finish 收尾，不在这里删');
  assert.match(logs.at(-1), /waterfall 路径/);
});

test('M4.58c 同一条提问点两次提交，第二次按成功处理（不再弹 409 红条）', () => {
  const pending = new Map();
  const questions = [question];
  pending.set('call_00_abc', {
    sessionId: 'session-a',
    questionId: 'call_00_abc',
    questions,
    createdAt: Date.now(),
    finish: () => {},
  });
  const { answerDesktopQuestion, logs } = build({
    pending,
    collectLogQuestions: () => [
      { sessionId: 'session-a', questionId: 'call_00_abc', questions, fromLog: true },
    ],
    ctx: { get: () => undefined },
  });
  assert.equal(answerDesktopQuestion('session-a', 'call_00_abc', [{ id: 'q1', selected: ['手写体'] }]), true);
  // 第一次已经把挂起项答掉，第二次再来（日志里有、挂起项没了）也要 200。
  pending.clear();
  assert.equal(answerDesktopQuestion('session-a', 'call_00_abc', [{ id: 'q1', selected: ['手写体'] }]), true);
  assert.match(logs.at(-1), /刚答过/);
});

test('M4.58d 电脑先答过（日志里有 result）时，手机再提交按成功处理', () => {
  const { answerDesktopQuestion, logs } = build({
    collectLogQuestions: () => [],
    logCallSettled: () => true,
  });
  assert.equal(answerDesktopQuestion('session-a', 'call_00_done', [{ id: 'q1', selected: ['手写体'] }]), true);
  assert.match(logs.at(-1), /已经在电脑上答过/);
});

test('M4.58b 同一题面在两路里各有一条时只显示一张卡', () => {
  const start = source.indexOf('const questionContentKey = (entry) =>');
  const end = source.indexOf('const listDesktopSessionEvents =', start);
  assert.ok(start > 0 && end > start, '找不到去重源码');
  const mergeSrc = source.slice(start, end);
  const merge = new Function(`${mergeSrc}\nreturn { mergeQuestionEntries, questionContentKey };`)();
  const waterfallEntry = {
    sessionId: 'session-a',
    questionId: 'q_k3f1ab',
    questions: [question],
  };
  const logEntry = { sessionId: 'session-a', questionId: 'call_00_abc', questions: [question] };
  const merged = merge.mergeQuestionEntries([waterfallEntry], [logEntry]);
  assert.equal(merged.length, 1);
  assert.equal(merged[0].questionId, 'q_k3f1ab');
  assert.equal(merge.mergeQuestionEntries([logEntry], [waterfallEntry])[0].questionId, 'call_00_abc');
});

test('M4.58 服务端把失败原因带回手机（不再一律 question not found）', () => {
  assert.match(source, /desktopQuestionError: \(\) => questionAnswerFailure/);
});

test('M4.56 从会话日志认提问：只认没结果的 ask_user_question 调用', () => {
  assert.match(source, /const collectLogQuestions = \(sessionId\) => \{/);
  assert.match(source, /const ASK_TOOL_NAMES = new Set\(\['ask_user_question'\]\);/);
  assert.match(source, /const resultId = data\.toolCallId \?\? data\.callId \?\? data\.message\?\.source\?\.callId;/);
  assert.match(source, /typeOf\(entry\) === 'tool\/call' && ASK_TOOL_NAMES\.has/);
  // 工作区横幅也要能看到日志里的提问。
  assert.match(source, /mergeQuestionEntries\(logEntries, remoteQuestionEntries\(\), \[\.\.\.pendingQuestions\.values\(\)\]\)/);
});

test('M4.56 collectLogQuestions 只挑「还没有结果」的提问调用', () => {
  const collectSrc = grabArrow('collectLogQuestions');
  const run = (log) =>
    new Function('getDesktopSession', 'ASK_TOOL_NAMES', `${collectSrc}\nreturn collectLogQuestions;`)(
      () => ({ log }),
      new Set(['ask_user_question']),
    )('session-a');
  const args = JSON.stringify({ questions: [{ id: 'q1', header: '标题', question: '怎么显示？' }] });
  const log = [
    { type: 'user/message', time: 1 },
    { type: 'tool/call', time: 2, data: { callId: 'done_1', name: 'ask_user_question', arguments: args } },
    { type: 'tool/result', time: 3, data: { toolCallId: 'done_1' } },
    { type: 'tool/call', time: 4, data: { callId: 'open_1', name: 'ask_user_question', arguments: args } },
    { type: 'tool/call', time: 5, data: { callId: 'other_1', name: 'read_file', arguments: '{}' } },
    { type: 'tool/call', time: 6, data: { callId: 'open_2', name: 'ask_user_question', arguments: '{坏 JSON' } },
  ];
  const found = run(log);
  assert.equal(found.length, 1);
  assert.equal(found[0].questionId, 'open_1');
  assert.equal(found[0].sessionId, 'session-a');
  assert.equal(found[0].fromLog, true);
  assert.equal(found[0].createdAt, 4);
  assert.equal(found[0].questions.length, 1);
  assert.equal(found[0].questions[0].question, '怎么显示？');
});

test('会话事件里下发的问题不含 finish 这种函数字段', () => {
  const start = source.indexOf('\n  const listDesktopSessionEvents = (');
  assert.ok(start >= 0);
  const slice = source.slice(start, start + 6000);
  // M4.56：负载改成「waterfall 的 + 日志里认出来的」两路合并。
  assert.match(slice, /questions: mergeQuestionEntries\(/);
  assert.match(slice, /items: serializeQuestionItems\(questions\)/);
  assert.doesNotMatch(slice, /finish,?\s*$/m);
});
test('看着这个会话时才接管，看不到就交回桌面', async () => {
  const handler = grabHandler();
  const pending = new Map();
  const logs = [];
  const make = (watching) =>
    handler({
      ctx: { on: () => {} },
      pendingQuestions: pending,
      log: (line) => logs.push(line),
      isWatching: () => watching,
    });
  let delegated = 0;
  const next = async () => {
    delegated += 1;
    return { answers: [] };
  };
  const req = {
    agent: { id: 'session-a' },
    questions: [question],
    wait: { callId: 'call_9' },
  };
  assert.deepEqual(await make(false)(req, next), { answers: [] });
  assert.equal(delegated, 1);
  assert.equal(pending.size, 0);

  // 接管时 handler 会一直挂着等手机回答，所以不能 await 它。
  const waiting = make(true)(req, next);
  assert.equal(pending.size, 1);
  assert.match(logs.at(-1), /接管提问：session-a · 1 个问题 · 电脑和手机都能答/);
  for (const entry of pending.values()) entry.finish({ answers: [] });
  await waiting;
  assert.equal(pending.size, 0);
});

test('M4.55 手机连着、但没看这条会话时，也要接管并给手机挂卡', async () => {
  const handler = grabHandler();
  const pending = new Map();
  const logs = [];
  const run = handler({
    ctx: { on: () => {} },
    pendingQuestions: pending,
    log: (line) => logs.push(line),
    isWatching: () => false,
    phoneConnected: () => true,
  });
  let delegated = 0;
  const next = async () => {
    delegated += 1;
    return { answers: [{ id: 'q1', selected: ['电脑上选的'] }] };
  };
  const waiting = run(
    { agent: { id: 'session-a' }, questions: [question], wait: { callId: 'call_11' } },
    next,
  );
  // 手机没看着这条会话，但手机连着：照样接管，并且先把电脑那张卡挂出去。
  assert.equal(delegated, 1);
  assert.equal(pending.size, 1);
  assert.match(logs.at(-1), /电脑和手机都能答/);
  pending.get('call_11').finish({ answers: [{ id: 'q1', selected: ['手机上选的'] }] });
  assert.deepEqual(await waiting, { answers: [{ id: 'q1', selected: ['手机上选的'] }] });
});

test('M4.55 手机没连、也没看这条会话时，提问交回电脑', async () => {
  const handler = grabHandler();
  const pending = new Map();
  const logs = [];
  const run = handler({
    ctx: { on: () => {} },
    pendingQuestions: pending,
    log: (line) => logs.push(line),
    isWatching: () => false,
    phoneConnected: () => false,
  });
  let delegated = 0;
  const next = async () => {
    delegated += 1;
    return { answers: [{ id: 'q1', selected: ['电脑上选的'] }] };
  };
  const result = await run(
    { agent: { id: 'session-a' }, questions: [question], wait: { callId: 'call_14' } },
    next,
  );
  assert.equal(delegated, 1);
  assert.equal(pending.size, 0);
  assert.deepEqual(result, { answers: [{ id: 'q1', selected: ['电脑上选的'] }] });
  assert.equal(logs.length, 0);
});

test('M4.53/M4.55 门禁只看 isWatching 与 phoneConnected，不再看 phoneOnline', () => {
  const fnStart = source.indexOf('async function onDesktopQuestion');
  assert.ok(fnStart > 0);
  const body = source.slice(fnStart, fnStart + 400);
  assert.doesNotMatch(body, /phoneOnline/);
  assert.match(body, /if \(!isWatching\(sessionId\) && !phoneConnected\(\)\) return next\(\);/);
});

test('接管后把问题交给手机，回答能解开挂起的 Promise', async () => {
  const handler = grabHandler();
  const pending = new Map();
  const logs = [];
  const run = handler({
    ctx: { on: () => {} },
    pendingQuestions: pending,
    log: (line) => logs.push(line),
    isWatching: () => true,
  });
  let delegated = 0;
  let resolveDesktop;
  const desktop = new Promise((resolve) => {
    resolveDesktop = resolve;
  });
  const promise = run(
    { agent: { id: 'session-a' }, questions: [question], wait: { callId: 'call_10' } },
    () => {
      delegated += 1;
      return desktop;
    },
  );
  assert.equal(pending.size, 1);
  assert.equal(delegated, 1, 'M4.54：电脑那张卡也要挂出来');
  const entry = pending.get('call_10');
  assert.equal(entry.sessionId, 'session-a');
  assert.equal(entry.questions.length, 1);
  entry.finish({ answers: [{ id: 'q1', selected: ['手写体'] }] });
  assert.deepEqual(await promise, { answers: [{ id: 'q1', selected: ['手写体'] }] });
  resolveDesktop({ answers: [{ id: 'q1', selected: ['电脑晚到的'] }] });
});

test('M4.54 电脑先答：用电脑的答案，同时把手机上那张卡摘掉', async () => {
  const handler = grabHandler();
  const pending = new Map();
  const logs = [];
  const run = handler({
    ctx: { on: () => {} },
    pendingQuestions: pending,
    log: (line) => logs.push(line),
    isWatching: () => true,
  });
  let resolveDesktop;
  const desktop = new Promise((resolve) => {
    resolveDesktop = resolve;
  });
  const promise = run(
    { agent: { id: 'session-a' }, questions: [question], wait: { callId: 'call_12' } },
    () => desktop,
  );
  assert.equal(pending.size, 1, '手机上也要挂一张');
  resolveDesktop({ answers: [{ id: 'q1', selected: ['电脑上选的'] }] });
  assert.deepEqual(await promise, { answers: [{ id: 'q1', selected: ['电脑上选的'] }] });
  assert.equal(pending.size, 0, '电脑答完手机那张要收掉');
});

test('M4.54 手机先答：用手机的答案，电脑那边之后再答也不影响', async () => {
  const handler = grabHandler();
  const pending = new Map();
  const run = handler({
    ctx: { on: () => {} },
    pendingQuestions: pending,
    log: () => {},
    isWatching: () => true,
  });
  let resolveDesktop;
  const desktop = new Promise((resolve) => {
    resolveDesktop = resolve;
  });
  const promise = run(
    { agent: { id: 'session-a' }, questions: [question], wait: { callId: 'call_13' } },
    () => desktop,
  );
  pending.get('call_13').finish({ answers: [{ id: 'q1', selected: ['手机上选的'] }] });
  assert.deepEqual(await promise, { answers: [{ id: 'q1', selected: ['手机上选的'] }] });
  resolveDesktop({ answers: [{ id: 'q1', selected: ['电脑晚到的'] }] });
  assert.equal(pending.size, 0);
});

test('没有 callId 时自己生成一个，两次不重样', async () => {
  const handler = grabHandler();
  const pending = new Map();
  const run = handler({
    ctx: { on: () => {} },
    pendingQuestions: pending,
    log: () => {},
    isWatching: () => true,
  });
  void run({ agent: { id: 's' }, questions: [question] }, async () => ({ answers: [] }));
  void run({ agent: { id: 's' }, questions: [question] }, async () => ({ answers: [] }));
  const ids = [...pending.keys()];
  assert.equal(ids.length, 2);
  assert.match(ids[0], /^q_/);
  assert.notEqual(ids[0], ids[1]);
  for (const entry of pending.values()) entry.finish({ answers: [] });
});