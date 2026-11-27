// Probe: can the official `dsh web` serve the real Web UI to a LAN client natively?
import { spawn } from 'node:child_process';
import http from 'node:http';
import { readFileSync, mkdirSync, writeFileSync, existsSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { homedir } from 'node:os';

const HOST = process.argv[2] ?? '192.168.1.x';
const PORT = Number(process.argv[3] ?? 3098);
const ROOT = resolve(import.meta.dirname);
const TMP = join(ROOT, 'tmp');
const HOME = join(TMP, 'web-home');
const CLI = 'C:/Users/user/AppData/Local/Programs/DeepSeek Harness/resources/app.asar/dsh/node_modules/@deepseek-ai/dsh-desktop-host/lib/cli.js';
const EXE = 'C:/Users/user/AppData/Local/Programs/DeepSeek Harness/DeepSeek Harness.exe';
const results = {};
mkdirSync(HOME, { recursive: true });
const realHome = join(homedir(), '.dsh');
for (const f of ['.credentials.yaml', 'settings.yaml']) {
  const src = join(realHome, f);
  if (existsSync(src)) writeFileSync(join(HOME, f), readFileSync(src));
}
const env = { ...process.env };
for (const k of ['DSH_PROFILE', 'DSH_PROFILE_DIR', 'DSH_SESSION_ID', 'DSH_WEB_URL', 'DSH_SHELL']) delete env[k];
env.ELECTRON_RUN_AS_NODE = '1'; env.DSH_HOME = HOME; env.NO_COLOR = '1';
const child = spawn(EXE, ['--expose-internals', CLI, '--profile', 'web', '--host', HOST, '--port', String(PORT), '--no-open'], { cwd: TMP, env, stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true });
let out = '', err = '';
child.stdout.setEncoding('utf8'); child.stderr.setEncoding('utf8');
child.stdout.on('data', (d) => { out += d; }); child.stderr.on('data', (d) => { err += d; });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
function req(urlStr, headers = {}) {
  return new Promise((res) => {
    const r = http.request(urlStr, { method: 'GET', headers }, (resp) => {
      let data = ''; resp.setEncoding('utf8');
      resp.on('data', (d) => { data += d; });
      resp.on('end', () => res({ status: resp.statusCode, headers: resp.headers, body: data.slice(0, 300) }));
    });
    r.on('error', (e) => res({ error: String(e) }));
    r.end();
  });
}
function raw(hostHeader, path) {
  return new Promise((res) => {
    const r = http.request({ host: '127.0.0.1', port: PORT, method: 'POST', path, headers: { Host: hostHeader, 'content-type': 'application/json' } }, (resp) => {
      let data = ''; resp.setEncoding('utf8');
      resp.on('data', (d) => { data += d; });
      resp.on('end', () => res({ status: resp.statusCode, body: data.slice(0, 300) }));
    });
    r.on('error', (e) => res({ error: String(e) }));
    r.write(JSON.stringify({ type: 'client-request', rpcId: 'x', method: 'session/modelCatalog', payload: { args: {} } }));
    r.end();
  });
}
try {
  const t0 = Date.now();
  let url;
  while (Date.now() - t0 < 40000) {
    const m = out.match(/https?:\/\/[^\s"'<>]+/);
    if (m) { url = m[0]; break; }
    await sleep(100);
  }
  if (!url) throw new Error('no url; out=' + JSON.stringify(out.slice(-400)) + ' err=' + JSON.stringify(err.slice(-600)));
  const u = new URL(url);
  const token = u.searchParams.get('token');
  results.host = HOST; results.printedUrlHost = u.host; results.tokenPresent = Boolean(token);
  results.listenCheck = await req(`http://${HOST}:${PORT}/`);
  results.indexWithToken = await req(`http://${HOST}:${PORT}/?token=${encodeURIComponent(token)}`);
  const cookie = (String(results.indexWithToken.headers?.['set-cookie'] || '').match(/^[^=]+=[^;]+/) || [''])[0];
  results.apiNoAuth = await req(`http://${HOST}:${PORT}/api`);
  results.apiWithCookie = await new Promise((res) => {
    const r = http.request({ host: HOST, port: PORT, method: 'POST', path: '/api/session/modelCatalog', headers: { Cookie: cookie, 'content-type': 'application/json' } }, (resp) => {
      let data = ''; resp.setEncoding('utf8'); resp.on('data', (d) => { data += d; }); resp.on('end', () => res({ status: resp.statusCode, body: data.slice(0, 200) }));
    });
    r.on('error', (e) => res({ error: String(e) }));
    r.write(JSON.stringify({ type: 'client-request', rpcId: 'x', method: 'session/modelCatalog', payload: { args: {} } }));
    r.end();
  });
  // Host fence: request over loopback socket but declare the LAN authority vs a bogus one
  results.fenceLoopbackHost = await raw(`127.0.0.1:${PORT}`, '/api/session/modelCatalog');
  results.fenceBogusHost = await raw('evil.example.com', '/api/session/modelCatalog');
} catch (error) {
  results.error = String(error);
} finally {
  try { child.kill(); } catch {}
  await sleep(300);
  writeFileSync(join(TMP, 'web-probe3.log.json'), JSON.stringify({ results, stdoutTail: out.slice(-1200), stderrTail: err.slice(-1200) }, null, 1));
  console.log('=== RESULTS ===');
  for (const [k, v] of Object.entries(results)) console.log(k, '=', JSON.stringify(v).slice(0, 500));
  console.log('--- stderr tail ---'); console.log(err.slice(-500));
}
