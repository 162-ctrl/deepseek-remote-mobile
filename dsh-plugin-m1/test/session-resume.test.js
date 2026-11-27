// M4.24：存档会话要能在**原来那条对话里**继续，不是新开一条。
//
// 以前（M4.19）的做法是「同目录新开一条会话 + 把最近 12 句压成摘要当开场」，因为当时
// 直接唤醒冷会话只会得到 turn/end {kind:'blocked'}。M4.24 查到了真相：DSH 的
// ArchivedSessionGate 会在每一步 pre-step 拒掉被归档的会话，门由
// workspaceController.unarchiveSession() 抬起。所以现在改成：
//   1. 活跃会话一步不多走，直接发；
//   2. 存档会话 → unarchiveSession → 往**同一个 sessionId** 发原话，不新开、不带摘要；
//   3. 抬不起来（老 Harness / 仍在归档里 / 抛异常）都有可区分的错误码；
//   4. 存档里都没有 → SESSION_NOT_FOUND，别凭空开一条空会话。
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const source = readFileSync(join(here, '..', 'lib', 'index.js'), 'utf8');

const grabFunction = (name) => {
  const arrow = source.indexOf(`\n  const ${name} = async (`);
  assert.ok(arrow >= 0, `找不到函数 ${name}`);
  // 从 `=>` 之后的第一个 `{` 开始配平：参数默认值也带花括号，从声明处配平会提前收尾。
  const bodyStart = source.indexOf('{', source.indexOf('=>', arrow));
  let depth = 0;
  for (let i = bodyStart; i < source.length; i += 1) {
    const ch = source[i];
    if (ch === '{') depth += 1;
    else if (ch === '}') {
      depth -= 1;
      if (depth === 0) return source.slice(arrow + 1, i + 1);
    }
  }
  throw new Error(`函数 ${name} 花括号不配平`);
};

const resumeSrc = grabFunction('resumeArchivedSession');
const promptSrc = grabFunction('promptDesktopSession');

const archivedRecord = (overrides = {}) => ({
  id: 'session-old',
  title: '古典诗词鉴赏',
  workspace: 'D:\\work\\poetry',
  events: [
    { seq: 1, kind: 'user', text: '帮我看看《静夜思》' },
    { seq: 2, kind: 'assistant', text: '这首诗写的是月夜思乡。' },
  ],
  ...overrides,
});

/** 造一个只关心「归档门 + 发话」两件事的 promptDesktopSession。 */
const build = (options = {}) => {
  const calls = { unarchive: [], prompt: [], logs: [] };
  const live = options.live ?? true;
  const record = options.record === undefined ? archivedRecord() : options.record;
  const unarchiveResult = options.unarchiveResult ?? { archivedSessionIds: [] };
  const controller = {
    get prompt() {
      return options.hasPrompt === false
        ? undefined
        : async (request) => {
            calls.prompt.push(request);
            return { accepted: true };
          };
    },
  };
  const workspaces = {
    get unarchiveSession() {
      if (options.hasUnarchive === false) return undefined;
      return async (request) => {
        calls.unarchive.push(request);
        if (typeof unarchiveResult === 'function') return unarchiveResult(request);
        return unarchiveResult;
      };
    },
  };
  const ctx = {
    get: (key) => {
      if (key === 'sessionController') return controller;
      if (key === 'workspaceController') return workspaces;
      return undefined;
    },
  };
  const fn = new Function(
    'ctx',
    'getDesktopSession',
    'getArchivedSession',
    'log',
    `${resumeSrc};
     ${promptSrc};
     return { promptDesktopSession, resumeArchivedSession };`,
  )(
    ctx,
    () => (live ? { id: 'session-x' } : null),
    () => record,
    (line) => calls.logs.push(line),
  );
  return { ...fn, calls };
};

test('活跃会话直接发话，不碰归档门', async () => {
  const api = build({ live: true });
  const result = await api.promptDesktopSession('session-x', '  继续  ');
  assert.equal(api.calls.unarchive.length, 0);
  assert.equal(api.calls.prompt.length, 1);
  assert.equal(api.calls.prompt[0].mode, 'queue');
  assert.equal(api.calls.prompt[0].sessionId, 'session-x');
  assert.deepEqual(api.calls.prompt[0].content, [{ type: 'text', text: '继续' }]);
  assert.deepEqual(result, { accepted: true });
});

test('存档会话先抬起归档门，再往同一条会话发原话', async () => {
  const api = build({ live: false });
  const result = await api.promptDesktopSession('session-old', '再讲讲背景');
  assert.equal(api.calls.unarchive.length, 1);
  assert.deepEqual(api.calls.unarchive[0], { sessionId: 'session-old' });
  assert.equal(api.calls.prompt.length, 1);
  // 关键：还是原来那条会话，不新开。
  assert.equal(api.calls.prompt[0].sessionId, 'session-old');
  // 也不塞摘要，发什么就是什么。
  assert.equal(api.calls.prompt[0].content[0].text, '再讲讲背景');
  assert.equal(result.resumed, true);
  assert.equal(result.resumedFrom, 'session-old');
  assert.equal(result.sessionId, 'session-old');
  assert.ok(api.calls.logs.some((line) => line.includes('存档会话已恢复到原会话继续')));
});

test('抬起之后仍在归档里时不发话，给出可区分的错误码', async () => {
  const api = build({ live: false, unarchiveResult: { archivedSessionIds: ['session-old'] } });
  await assert.rejects(
    () => api.promptDesktopSession('session-old', '你好'),
    (error) => {
      assert.equal(error.code, 'SESSION_NOT_RESUMABLE');
      assert.match(error.message, /接不上/);
      return true;
    },
  );
  assert.equal(api.calls.prompt.length, 0);
});

test('老 Harness 没有 unarchiveSession 时明确降级', async () => {
  const api = build({ live: false, hasUnarchive: false });
  await assert.rejects(
    () => api.promptDesktopSession('session-old', '你好'),
    (error) => {
      assert.equal(error.code, 'SESSION_UNARCHIVE_UNSUPPORTED');
      assert.match(error.message, /没法把存档会话接着聊下去/);
      return true;
    },
  );
  assert.equal(api.calls.prompt.length, 0);
});

test('unarchiveSession 抛异常也不把原始堆栈丢给手机', async () => {
  const api = build({
    live: false,
    unarchiveResult: () => {
      throw new Error('boom');
    },
  });
  await assert.rejects(
    () => api.promptDesktopSession('session-old', '你好'),
    (error) => error.code === 'SESSION_NOT_RESUMABLE',
  );
  assert.equal(api.calls.prompt.length, 0);
});

test('电脑上已经没有这条存档时抛手机能翻译的错误码', async () => {
  const api = build({ live: false, record: null });
  await assert.rejects(
    () => api.promptDesktopSession('session-gone', '你好'),
    (error) => {
      assert.equal(error.code, 'SESSION_NOT_FOUND');
      assert.match(error.message, /电脑上已经找不到这个会话/);
      return true;
    },
  );
  assert.equal(api.calls.unarchive.length, 0);
  assert.equal(api.calls.prompt.length, 0);
});

test('空内容是本地就能拦的错误，不必先抬归档门', async () => {
  const api = build({ live: false });
  await assert.rejects(() => api.promptDesktopSession('session-old', '   '), /内容不能为空/);
  assert.equal(api.calls.unarchive.length, 0);
  assert.equal(api.calls.prompt.length, 0);
});

test('Harness 没有 sessionController.prompt 时直接报不可用', async () => {
  const api = build({ live: true, hasPrompt: false });
  await assert.rejects(() => api.promptDesktopSession('session-x', '你好'), /sessionController 不可用/);
});

test('发话结果原样带回去，不吞 accepted', async () => {
  const api = build({ live: false });
  const result = await api.promptDesktopSession('session-old', '继续');
  assert.equal(result.accepted, true);
  assert.equal(result.resumed, true);
});
