// ACP probe v2: verify approval roundtrip, model config option, close+resume continuity.
// Read-only investigation helper. Throwaway DSH_HOME under tools/harness_probe/tmp.
import { spawn } from 'node:child_process';
import { readFileSync, mkdirSync, writeFileSync, existsSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { homedir } from 'node:os';

const ROOT = resolve(import.meta.dirname);
const TMP = join(ROOT, 'tmp');
const HOME = join(TMP, 'acp-home');
const WS = join(TMP, 'ws-acp2');
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
function mark(tag, obj) {
  const rec = { t: Date.now() - t0, tag, obj };
  log.push(rec);
  const s = JSON.stringify(obj);
  console.log(`[${String(rec.t).padStart(6)}ms] ${tag} ${s === undefined ? '' : s.slice(0, 260)}`);
}
const child = spawn(EXE, ['--expose-internals', CLI, '--profile', 'acp'], { cwd: WS, env, stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true });
let childExit = null; let stderrBuf = '';
child.stderr.setEncoding('utf8'); child.stderr.on('data', (d) => { stderrBuf += d; });
child.on('exit', (code) => { childExit = code; mark('child-exit', { code }); });
let buf = ''; const waiters = new Map();
child.stdout.setEncoding('utf8');
child.stdout.on('data', (chunk) => {
  buf += chunk; let i;
  while ((i = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, i).trim(); buf = buf.slice(i + 1);
    if (!line) continue;
    let msg; try { msg = JSON.parse(line); } catch { mark('bad-line', line.slice(0, 160)); continue; }
    if (msg.id !== undefined && msg.method) {
      const summary = { method: msg.method, params: msg.params };
      mark('server-request', summary);
      if (msg.method === 'session/request_permission') {
        send({ jsonrpc: '2.0', id: msg.id, result: { outcome: { outcome: 'selected', optionId: 'allow-once' } } });
        mark('permission-allowed', { optionId: 'allow-once' });
      } else {
        send({ jsonrpc: '2.0', id: msg.id, error: { code: -32601, message: 'probe: unsupported' } });
      }
      continue;
    }
    if (msg.method) {
      const u = msg.params?.update ?? {};
      mark('notify', { kind: u.sessionUpdate, text: (u.content?.text ?? u.content?.[0]?.content?.text ?? '').slice(0, 120), status: u.status, used: u.used });
      continue;
    }
    mark('response', msg.result ?? msg.error);
    if (msg.id !== undefined && waiters.has(msg.id)) { const w = waiters.get(msg.id); waiters.delete(msg.id); w(msg); }
  }
});
function send(obj) { child.stdin.write(JSON.stringify(obj) + '\n'); }
let nextId = 1;
function request(method, params, timeoutMs = 60000) {
  const id = nextId++;
  return new Promise((res, rej) => {
    const timer = setTimeout(() => { waiters.delete(id); rej(new Error('timeout ' + method)); }, timeoutMs);
    waiters.set(id, (m) => { clearTimeout(timer); res(m); });
    send({ jsonrpc: '2.0', id, method, params });
  });
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const results = {};
try {
  const init = await request('initialize', { protocolVersion: 1, clientCapabilities: {} }, 30000);
  results.initialize = init.result ?? init.error;
  const created = await request('session/new', { cwd: WS, mcpServers: [] }, 30000);
  results['session/new'] = created.result ?? created.error;
  const sessionId = created.result?.sessionId;
  if (!sessionId) throw new Error('no sessionId');
  results.sessionId = sessionId;

  // model config option control
  const modelOpt = (created.result?.configOptions ?? []).find((o) => o.id === 'model');
  results['model/configOptions'] = modelOpt;
  if (modelOpt) {
    const set = await request('session/set_config_option', { sessionId, configId: modelOpt.id, value: modelOpt.currentValue }, 30000);
    results['session/set_config_option'] = set.result ?? set.error;
  }

  // 1) simple prompt
  results.prompt1 = (await request('session/prompt', { sessionId, prompt: [{ type: 'text', text: '只回复两个字：收到' }] }, 60000)).result ?? 'ERR';
  // 2) cancel
  const p2 = request('session/prompt', { sessionId, prompt: [{ type: 'text', text: '请用三句话介绍你自己，并逐句用列表输出' }] }, 60000);
  await sleep(300);
  send({ jsonrpc: '2.0', method: 'session/cancel', params: { sessionId } });
  mark('sent-cancel', {});
  results.prompt2 = (await p2).result ?? 'ERR';
  // 3) approval prompt — the tool needs an approval channel (sandbox provisioning is broken on this host)
  results.prompt3 = (await request('session/prompt', { sessionId, prompt: [{ type: 'text', text: '请用 pwsh 命令把文本 hello 写入当前目录的 hello.txt，然后告诉我结果' }] }, 90000)).result ?? 'ERR';
  // 4) list, close, resume, continue
  results['session/list'] = (await request('session/list', {}, 30000)).result ?? 'ERR';
  results['session/close'] = (await request('session/close', { sessionId }, 30000)).result ?? 'ERR';
  const resumed = await request('session/resume', { sessionId, cwd: WS }, 60000);
  results['session/resume'] = resumed.result ?? resumed.error;
  results.prompt4 = (await request('session/prompt', { sessionId, prompt: [{ type: 'text', text: '用一句话说明你上一条回答了什么' }] }, 60000)).result ?? 'ERR';
} catch (error) {
  mark('probe-error', String(error));
} finally {
  try { child.stdin.end(); } catch {}
  await sleep(600);
  if (childExit === null) { try { child.kill(); } catch {} mark('killed', { pid: child.pid }); }
  writeFileSync(join(ROOT, 'tmp', 'acp-probe2.log.json'), JSON.stringify({ results, events: log, stderr: stderrBuf.slice(-8000) }, null, 1));
  console.log('\n=== RESULTS ===');
  console.log(JSON.stringify(results, null, 1).slice(0, 3000));
  console.log('--- STDERR tail ---');
  console.log(stderrBuf.slice(-1500));
}
