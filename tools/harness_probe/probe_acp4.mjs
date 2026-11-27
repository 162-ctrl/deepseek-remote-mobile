// ACP probe v4: concurrency (multi-session), same-session double prompt, reject-once behavior,
// cancel-then-continue, chunk granularity, raw request_permission payload.
// Read-only investigation helper. Throwaway DSH_HOME under tools/harness_probe/tmp.
import { spawn } from 'node:child_process';
import { readFileSync, mkdirSync, writeFileSync, existsSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { homedir } from 'node:os';

const ROOT = resolve(import.meta.dirname);
const TMP = join(ROOT, 'tmp');
const HOME = join(TMP, 'acp-home4');
const WS = join(TMP, 'ws-acp4');
const CLI = 'C:/Users/user/AppData/Local/Programs/DeepSeek Harness/resources/app.asar/dsh/node_modules/@deepseek-ai/dsh-desktop-host/lib/cli.js';
const EXE = 'C:/Users/user/AppData/Local/Programs/DeepSeek Harness/DeepSeek Harness.exe';

mkdirSync(HOME, { recursive: true });
mkdirSync(WS, { recursive: true });
const realHome = join(homedir(), '.dsh');
for (const f of ['.credentials.yaml', 'settings.yaml']) {
  const src = join(realHome, f);
  if (existsSync(src)) writeFileSync(join(HOME, f), readFileSync(src));
}
let key = '';
const credPath = join(HOME, '.credentials.yaml');
if (existsSync(credPath)) { const m = readFileSync(credPath, 'utf8').match(/DEEPSEEK_API_KEY:\s*(\S+)/); if (m) key = m[1]; }

const env = { ...process.env };
for (const k of ['DSH_PROFILE', 'DSH_PROFILE_DIR', 'DSH_SESSION_ID', 'DSH_WEB_URL', 'DSH_SHELL']) delete env[k];
env.ELECTRON_RUN_AS_NODE = '1';
env.DSH_HOME = HOME;
env.DEEPSEEK_API_KEY = key;
env.NO_COLOR = '1';

const log = [];
const t0 = Date.now();
let phase = 'boot';
let permMode = 'allow'; // 'allow' | 'reject' | 'cancel'
const permRequests = [];
function mark(tag, obj) {
  const rec = { t: Date.now() - t0, tag, phase, obj };
  log.push(rec);
  const s = JSON.stringify(obj);
  console.log(`[${String(rec.t).padStart(6)}ms] ${phase}/${tag} ${s === undefined ? '' : s.slice(0, 300)}`);
}
const child = spawn(EXE, ['--expose-internals', CLI, '--profile', 'acp'], { cwd: WS, env, stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true });
let childExit = null; let stderrBuf = '';
child.stderr.setEncoding('utf8'); child.stderr.on('data', (d) => { stderrBuf += d; });
child.on('exit', (code) => { childExit = code; mark('child-exit', { code }); });
let buf = ''; const waiters = new Map();
const notifies = [];
child.stdout.setEncoding('utf8');
child.stdout.on('data', (chunk) => {
  buf += chunk; let i;
  while ((i = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, i).trim(); buf = buf.slice(i + 1);
    if (!line) continue;
    let msg; try { msg = JSON.parse(line); } catch { mark('bad-line', line.slice(0, 160)); continue; }
    if (msg.id !== undefined && msg.method) {
      mark('server-request', { method: msg.method, params: msg.params });
      if (msg.method === 'session/request_permission') {
        permRequests.push({ t: Date.now() - t0, phase, params: msg.params });
        const optionId = permMode === 'reject' ? 'reject-once' : 'allow-once';
        const result = permMode === 'cancel'
          ? { outcome: { outcome: 'cancelled' } }
          : { outcome: { outcome: 'selected', optionId } };
        send({ jsonrpc: '2.0', id: msg.id, result });
        mark('permission-answered', { mode: permMode, optionId });
      } else {
        send({ jsonrpc: '2.0', id: msg.id, error: { code: -32601, message: 'probe: unsupported' } });
      }
      continue;
    }
    if (msg.method) {
      const u = msg.params?.update ?? {};
      const sid = msg.params?.sessionId;
      const rec = { t: Date.now() - t0, phase, method: msg.method, sid, kind: u.sessionUpdate };
      notifies.push(rec);
      mark('notify', { sid, kind: u.sessionUpdate, text: (u.content?.text ?? u.content?.[0]?.content?.text ?? '').slice(0, 120), status: u.status, used: u.used });
      continue;
    }
    mark('response', msg.result ?? msg.error);
    if (msg.id !== undefined && waiters.has(msg.id)) { const w = waiters.get(msg.id); waiters.delete(msg.id); w(msg); }
  }
});
function send(obj) { child.stdin.write(JSON.stringify(obj) + '\n'); }
let nextId = 1;
function request(method, params, timeoutMs = 90000) {
  const id = nextId++;
  return new Promise((res, rej) => {
    const timer = setTimeout(() => { waiters.delete(id); rej(new Error('timeout ' + method)); }, timeoutMs);
    waiters.set(id, (m) => { clearTimeout(timer); res(m); });
    send({ jsonrpc: '2.0', id, method, params });
  });
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const results = {};
const t = () => Date.now() - t0;
function prompt(sessionId, text, timeout = 90000) {
  return request('session/prompt', { sessionId, prompt: [{ type: 'text', text }] }, timeout);
}
try {
  phase = 'init';
  const init = await request('initialize', { protocolVersion: 1, clientCapabilities: {} }, 30000);
  results.initialize = init.result ?? init.error;
  const a = await request('session/new', { cwd: WS, mcpServers: [] }, 30000);
  const b = await request('session/new', { cwd: WS, mcpServers: [] }, 30000);
  const sidA = a.result?.sessionId; const sidB = b.result?.sessionId;
  results.sessions = { A: sidA, B: sidB };
  if (!sidA || !sidB) throw new Error('no session ids');

  // ---- Q1: concurrency across two sessions (same process) ----
  phase = 'concurrency';
  const cStart = t();
  const pA = prompt(sidA, '请用大约 150 个汉字介绍你自己，分成三段，每段一句话。', 120000).then((r) => ({ r, at: t() }));
  const pB = prompt(sidB, '只回复两个字：收到', 120000).then((r) => ({ r, at: t() }));
  const [rA, rB] = await Promise.all([pA, pB]);
  const conc = notifies.filter((n) => n.phase === 'concurrency');
  const aNot = conc.filter((n) => n.sid === sidA);
  const bNot = conc.filter((n) => n.sid === sidB);
  results.concurrency = {
    start: cStart,
    A: { responseAt: rA.at, stopReason: rA.r?.result?.stopReason, notifyCount: aNot.length, firstNotify: aNot[0]?.t, lastNotify: aNot.at(-1)?.t },
    B: { responseAt: rB.at, stopReason: rB.r?.result?.stopReason, notifyCount: bNot.length, firstNotify: bNot[0]?.t, lastNotify: bNot.at(-1)?.t },
    overlap: aNot.length > 0 && bNot.length > 0 ? (Math.max(aNot[0].t, bNot[0].t) < Math.min(rA.at, rB.at)) : null,
    timeline: [...conc.map((n) => `${n.t}:${n.sid === sidA ? 'A' : 'B'}:${n.kind}`)],
  };

  // ---- Q1b: two prompts on the SAME session back-to-back ----
  phase = 'same-session-double';
  const s1 = prompt(sidA, '请用大约 100 个字描述春天，只写一段。', 120000).then((r) => ({ r, at: t() }));
  await sleep(80);
  const s2 = prompt(sidA, '只回复：第二', 120000).then((r) => ({ r, at: t() }));
  const [r1, r2] = await Promise.all([s1, s2]);
  results.sameSessionDouble = {
    first: { at: r1.at, stopReason: r1.r?.result?.stopReason, error: r1.r?.error },
    second: { at: r2.at, stopReason: r2.r?.result?.stopReason, error: r2.r?.error },
  };

  // ---- Q4: cancel then continue on the same session ----
  phase = 'cancel';
  const pc = prompt(sidB, '请写一篇大约 200 个字的中文短文，介绍深海。', 120000).then((r) => ({ r, at: t() }));
  await sleep(900);
  send({ jsonrpc: '2.0', method: 'session/cancel', params: { sessionId: sidB } });
  mark('sent-cancel', { sidB });
  const rc = await pc;
  phase = 'cancel-continue';
  const pAfter = await prompt(sidB, '只回复四个字：继续成功', 120000).then((r) => r.result ?? r.error);
  results.cancelThenContinue = { cancelledStopReason: rc.r?.result?.stopReason, continueResult: pAfter };

  // ---- Q2: reject-once on approval, then see if the session continues ----
  phase = 'reject';
  permMode = 'reject';
  const pr = await prompt(sidA, '请用 pwsh 命令把文本 hello 写入当前目录的 hello.txt，然后确认文件内容。', 180000).then((r) => r.result ?? r.error);
  results.rejection = { promptResult: pr, permRequests: permRequests.slice() };
  phase = 'reject-continue';
  permMode = 'allow';
  const pr2 = await prompt(sidA, '只回复四个字：拒绝后通', 120000).then((r) => r.result ?? r.error);
  results.rejection.continueResult = pr2;

  // ---- Q6: chunk granularity for a long single-block answer ----
  phase = 'granularity';
  const gStart = t();
  const pg = await prompt(sidB, '请用大约 250 个汉字介绍你自己，写成一整段连贯的话。', 120000);
  const gNot = notifies.filter((n) => n.phase === 'granularity');
  const chunks = gNot.filter((n) => n.kind === 'agent_message_chunk');
  const gEvents = log.filter((r) => r.phase === 'granularity' && r.tag === 'notify');
  results.granularity = {
    start: gStart,
    stopReason: pg.result?.stopReason,
    doneAt: t(),
    messageChunkCount: chunks.length,
    thoughtChunkCount: gNot.filter((n) => n.kind === 'agent_thought_chunk').length,
    chunkTextLengths: gEvents.filter((r) => (r.obj?.kind === 'agent_message_chunk'))
      .map((r) => ({ t: r.t, textLen: (r.obj?.text ?? '').length })),
    allKinds: gNot.map((n) => `${n.t}:${n.kind}`),
  };
} catch (error) {
  mark('probe-error', String(error));
} finally {
  try { child.stdin.end(); } catch {}
  await sleep(800);
  if (childExit === null) { try { child.kill(); } catch {} mark('killed', { pid: child.pid }); }
  mkdirSync(TMP, { recursive: true });
  writeFileSync(join(ROOT, 'evidence', 'acp-probe4.log.json'), JSON.stringify({ results, events: log, stderr: stderrBuf.slice(-8000) }, null, 1));
  console.log('\n=== RESULTS ===');
  console.log(JSON.stringify(results, null, 1).slice(0, 8000));
  console.log('--- STDERR tail ---');
  console.log(stderrBuf.slice(-1500));
}
