// M4.14：桌面直播首屏「0 条消息」与增量拉取「追不上」的回归测试。
//
// 背景（用户两处反馈的同一处根因）：
//   1. 「每次点进去加载不出来对话」——首屏只取日志最后 80 条事件，而一个忙会话里
//      80 条可能全是 tool-call / tool-result（实测 41 步的会话就是），手机端只留
//      user/assistant，过滤后一条正文都没有，于是显示空态。
//   2. 增量拉取（带 afterSeq）以前从头往后扫、凑够 limit 就 break，积压几百条时
//      手机永远只收到最早那几条，追不上最新进度。
//
// 这里按函数名从源码截出 `listDesktopSessionEvents`，注入假会话跑窗口逻辑。
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const source = readFileSync(join(here, '..', 'lib', 'index.js'), 'utf8');

const grabFunction = (name) => {
  const arrow = source.indexOf(`\n  const ${name} = async (`);
  const arrowSync = source.indexOf(`\n  const ${name} = (`);
  const decl = source.indexOf(`\nfunction ${name}(`);
  const start = arrow >= 0 ? arrow : arrowSync >= 0 ? arrowSync : decl;
  assert.ok(start >= 0, `找不到函数 ${name}`);
  // 函数体从 `=>` 之后的第一个 `{` 开始：参数里的默认值（`options = {}`）也带花括号，
  // 从声明处直接配平会在那里就提前收尾。
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

const listSrc = grabFunction('listDesktopSessionEvents');

/** 注入依赖，返回一个只能看事件的 listDesktopSessionEvents。 */
const build = (log) => {
  const watchedSessions = new Map();
  const counters = { watched: 0 };
  const fn = new Function(
    'getDesktopSession',
    'mapDesktopEvent',
    'watchedSessions',
    'desktopTaskState',
    'inferRunning',
    'pendingApprovals',
    'pendingQuestions',
    'basename',
    'collectLogQuestions',
    'mergeQuestionEntries',
    'remoteQuestionEntries',
    'serializeQuestionItems',
    `${listSrc};
     return listDesktopSessionEvents;`,
  )(
    () => ({ header: { cwd: 'D:\\x', title: 't' }, log }),
    (event) => {
      const type = String(event?.type ?? '');
      if (type === 'user/message') return { seq: event.seq, kind: 'user', text: 'u' };
      if (type === 'assistant/message') return { seq: event.seq, kind: 'assistant', text: 'a' };
      if (type === 'tool/call') return { seq: event.seq, kind: 'tool-call', name: 't' };
      if (type === 'tool/result') return { seq: event.seq, kind: 'tool-result', text: 'r' };
      return null;
    },
    {
      set(key) {
        counters.watched += 1;
        watchedSessions.set(key, Date.now());
      },
    },
    new Map(),
    () => true,
    new Map(),
    new Map(),
    (p) => p,
    () => [],
    (...groups) => {
      const merged = new Map();
      for (const group of groups) {
        for (const entry of Array.isArray(group) ? group : []) {
          const key = String(entry?.questionId ?? '');
          if (!key || merged.has(key)) continue;
          merged.set(key, entry);
        }
      }
      return [...merged.values()];
    },
    () => [],
    (questions) => (Array.isArray(questions) ? questions : []),
  );
  return { fn, counters };
};

/** 造一段「一条用户消息 + 一句助手结论 + 后面挂 200 条工具调用」的日志。 */
const busyLog = (toolPairs = 100) => {
  const log = [
    { seq: 1, type: 'user/message' },
    { seq: 2, type: 'assistant/message' },
  ];
  let seq = 3;
  for (let i = 0; i < toolPairs; i += 1) {
    log.push({ seq: seq++, type: 'tool/call' });
    log.push({ seq: seq++, type: 'tool/result' });
  }
  return log;
};

test('首屏窗口够得到对话：最后 80 条事件全是工具调用时也要带回正文', () => {
  const { fn } = build(busyLog(100));
  const feed = fn('s1');
  const kinds = feed.events.map((event) => event.kind);
  assert.ok(kinds.includes('user'), '应当带回用户消息');
  assert.ok(kinds.includes('assistant'), '应当带回助手结论');
  // 仍然是「最新的一段」，顺序从小到大。
  assert.deepEqual(
    feed.events.map((event) => event.seq),
    [...feed.events.map((event) => event.seq)].sort((a, b) => a - b),
  );
});

test('首屏窗口不会无限膨胀：上限 600 条事件', () => {
  const { fn } = build(busyLog(1000));
  const feed = fn('s1');
  assert.ok(feed.events.length <= 600, `实际 ${feed.events.length}`);
  assert.ok(feed.events.length > 80, '为了够到对话，窗口应当大于 limit');
});

test('对话很少的会话不浪费窗口：凑够 12 条对话就停', () => {
  // 12 条对话 + 300 条工具调用：窗口应该在 12 条对话之外多加一点，不是 600。
  const log = [];
  let seq = 1;
  for (let i = 0; i < 12; i += 1) {
    log.push({ seq: seq++, type: 'user/message' });
    log.push({ seq: seq++, type: 'assistant/message' });
    for (let j = 0; j < 25; j += 1) {
      log.push({ seq: seq++, type: 'tool/call' });
      log.push({ seq: seq++, type: 'tool/result' });
    }
  }
  const { fn } = build(log);
  const feed = fn('s1');
  const chat = feed.events.filter((e) => e.kind === 'user' || e.kind === 'assistant').length;
  // 每段 2 条对话 + 50 条工具：凑到 12 条对话就该收手，不该一路扫到 600 条上限。
  assert.equal(chat, 12);
  assert.ok(feed.events.length < 600, `实际 ${feed.events.length}`);
});

test('增量拉取取的是游标之后最新的一段，而不是最早的一段', () => {
  const log = [];
  for (let i = 1; i <= 500; i += 1) {
    log.push({ seq: i, type: i % 2 === 0 ? 'assistant/message' : 'tool/call' });
  }
  const { fn } = build(log);
  const feed = fn('s1', { afterSeq: 100, limit: 10 });
  assert.deepEqual(
    feed.events.map((event) => event.seq),
    [491, 492, 493, 494, 495, 496, 497, 498, 499, 500],
  );
});

test('增量拉取没有新事件时返回空数组', () => {
  const { fn } = build(busyLog(10));
  const last = fn('s1').lastSeq;
  const feed = fn('s1', { afterSeq: last, limit: 10 });
  assert.deepEqual(feed.events, []);
});

test('打开直播页会记账「正在看」（授权接管依赖它）', () => {
  const { fn, counters } = build(busyLog(2));
  fn('s9');
  assert.equal(counters.watched, 1);
});

test('授权接管窗口与超时都放宽了（M4.14）', () => {
  assert.match(source, /WATCH_WINDOW_MS = 10 \* 60 \* 1000/);
  assert.match(source, /APPROVAL_TIMEOUT_MS = 2 \* 60 \* 1000/);
  // 超时不能一声不响地放弃，至少留一条日志。
  assert.match(source, /接管授权超时，已退回电脑/);
});
