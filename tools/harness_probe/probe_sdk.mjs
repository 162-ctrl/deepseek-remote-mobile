// Probe: official SDK profile over stdio JSON-RPC (dsh --profile sdk).
import { spawn } from 'node:child_process';
import { readFileSync, mkdirSync, writeFileSync, existsSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { homedir } from 'node:os';

const ROOT = resolve(import.meta.dirname);
const TMP = join(ROOT, 'tmp');
const HOME = join(TMP, 'sdk-home');
const WS = join(TMP, 'ws-sdk');
const CLI = 'C:/Users/user/AppData/Local/Programs/DeepSeek Harness/resources/app.asar/dsh/node_modules/@deepseek-ai/dsh-desktop-host/lib/cli.js';
const EXE = 'C:/Users/user/AppData/Local/Programs/DeepSeek Harness/DeepSeek Harness.exe';
mkdirSync(HOME, { recursive: true }); mkdirSync(WS, { recursive: true });
const realHome = join(homedir(), '.dsh');
for (const f of ['.credentials.yaml', 'settings.yaml']) {
  const src = join(realHome, f);
  if (existsSync(src)) writeFileSync(join(HOME, f), readFileSync(src));
}
const env = { ...process.env };
for (const k of ['DSH_PROFILE', 'DSH_PROFILE_DIR', 'DSH_SESSION_ID', 'DSH_WEB_URL', 'DSH_SHELL']) delete env[k];
env.ELECTRON_RUN_AS_NODE = '1'; env.DSH_HOME = HOME; env.NO_COLOR = '1';
const child = spawn(EXE, ['--expose-internals', CLI, '--profile', 'sdk'], { cwd: WS, env, stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true });
const results = { rpc: [], notifications: [] };
let buf = '';
child.stdout.setEncoding('utf8');
child.stdout.on('data', (d) => {
  buf += d;
  let i;
  while ((i = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, i).trim(); buf = buf.slice(i + 1);
    if (!line) continue;
    let msg; try { msg = JSON.parse(line); } catch { results.rpc.push({ raw: line.slice(0, 200) }); continue; }
    if (msg.id === undefined) results.notifications.push(msg);
    else {
      results.rpc.push(msg);
      const pending = msg.id === 1 ? sessionNew : msg.id === 2 ? prompted : msg.id === 3 ? waited : null;
      pending?.(msg);
    }
  }
});
let err = ''; child.stderr.setEncoding('utf8'); child.stderr.on('data', (d) => { err += d; });
const send = (obj) => child.stdin.write(JSON.stringify(obj) + '\n');
const t0 = Date.now();
const log = (k, v) => results[k] = v;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const waitFor = (promise, ms) => Promise.race([promise, sleep(ms).then(() => ({ timeout: true }))]);
let sessionNew, prompted, waited;
try {
  const initPromise = new Promise((res) => { const iv = setInterval(() => { const r = results.rpc.find((m) => m.id === 0); if (r) { clearInterval(iv); res(r); } }, 50); setTimeout(() => { clearInterval(iv); res({ timeout: true }); }, 20000); });
  send({ jsonrpc: '2.0', id: 0, method: 'initialize', params: { cwd: WS, provider: 'deepseek-official', model: 'deepseek-flash' } });
  log('initialize', await initPromise);
  log('initElapsedMs', Date.now() - t0);
  sessionNew = (res) => (results.prompt = res);
  prompted = (res) => (results.prompt = res);
  waited = (res) => (results.wait = res);
  send({ jsonrpc: '2.0', id: 1, method: 'session/prompt', params: { sessionId: 'session-probe-sdk-1', contentBlocks: [{ type: 'text', text: '只回复两个字：收到' }] } });
  log('prompt', await waitFor(new Promise((res) => { const iv = setInterval(() => { const r = results.rpc.find((m) => m.id === 1); if (r) { clearInterval(iv); res(r); } }, 50); }), 30000));
  await sleep(3000);
  log('notifications', results.notifications.slice(0, 12).map((n) => ({ method: n.method, params: JSON.stringify(n.params).slice(0, 260) })));
  send({ jsonrpc: '2.0', id: 2, method: 'session/wait', params: { sessionId: 'session-probe-sdk-1' } });
  log('wait', await waitFor(new Promise((res) => { const iv = setInterval(() => { const r = results.rpc.find((m) => m.id === 2); if (r) { clearInterval(iv); res(r); } }, 50); }), 30000));
  send({ jsonrpc: '2.0', id: 3, method: 'session/working-directory/get', params: { sessionId: 'session-probe-sdk-1' } });
  log('wdGet', await waitFor(new Promise((res) => { const iv = setInterval(() => { const r = results.rpc.find((m) => m.id === 3); if (r) { clearInterval(iv); res(r); } }, 50); }), 10000));
} catch (error) {
  results.error = String(error);
} finally {
  try { child.stdin.end(); } catch {}
  const timer = setTimeout(() => { try { child.kill(); } catch {} }, 5000);
  child.on('exit', (code) => { clearTimeout(timer); log('childExit', code); });
  await sleep(1200);
  try { child.kill(); } catch {}
  writeFileSync(join(TMP, 'sdk-probe.log.json'), JSON.stringify({ results, stderrTail: err.slice(-800) }, null, 1));
  console.log('=== RESULTS ===');
  for (const [k, v] of Object.entries(results)) console.log(k, '=', JSON.stringify(v).slice(0, 900));
  console.log('--- stderr tail ---'); console.log(err.slice(-400));
}
