// HTTP probe: boot a private `dsh --profile web` on 127.0.0.1:3099 and verify
// the /api auth fence, launch-token cookie exchange, RPC envelope, and the
// /api/remote.mux WebSocket upgrade. Read-only; throwaway DSH_HOME.
import { spawn } from 'node:child_process';
import http from 'node:http';
import { readFileSync, mkdirSync, writeFileSync, existsSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { homedir } from 'node:os';

const ROOT = resolve(import.meta.dirname);
const TMP = join(ROOT, 'tmp');
const HOME = join(TMP, 'web-home');
const CLI = 'C:/Users/user/AppData/Local/Programs/DeepSeek Harness/resources/app.asar/dsh/node_modules/@deepseek-ai/dsh-desktop-host/lib/cli.js';
const EXE = 'C:/Users/user/AppData/Local/Programs/DeepSeek Harness/DeepSeek Harness.exe';
const PORT = 3099;
const results = {};
mkdirSync(HOME, { recursive: true });
const realHome = join(homedir(), '.dsh');
for (const f of ['.credentials.yaml', 'settings.yaml']) {
  const src = join(realHome, f);
  if (existsSync(src)) writeFileSync(join(HOME, f), readFileSync(src));
}
const env = { ...process.env };
for (const k of ['DSH_PROFILE', 'DSH_PROFILE_DIR', 'DSH_SESSION_ID', 'DSH_WEB_URL', 'DSH_SHELL']) delete env[k];
env.ELECTRON_RUN_AS_NODE = '1';
env.DSH_HOME = HOME;
env.NO_COLOR = '1';

const child = spawn(EXE, ['--expose-internals', CLI, '--profile', 'web', '--host', '127.0.0.1', '--port', String(PORT), '--no-open'], {
  cwd: TMP, env, stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true,
});
let out = '', err = '';
child.stdout.setEncoding('utf8'); child.stderr.setEncoding('utf8');
child.stdout.on('data', (d) => { out += d; });
child.stderr.on('data', (d) => { err += d; });

function waitForUrl(ms = 40000) {
  return new Promise((res, rej) => {
    const t0 = Date.now();
    const iv = setInterval(() => {
      const m = out.match(/(https?:\/\/[^\s"'<>]+)/);
      if (m) { clearInterval(iv); res(m[1]); }
      else if (Date.now() - t0 > ms) { clearInterval(iv); rej(new Error('no URL printed; out=' + JSON.stringify(out.slice(-800)) + ' err=' + JSON.stringify(err.slice(-800)))); }
    }, 100);
  });
}
function req(method, path, headers = {}, body) {
  return new Promise((res) => {
    const r = http.request({ host: '127.0.0.1', port: PORT, method, path, headers }, (resp) => {
      let data = '';
      resp.setEncoding('utf8');
      resp.on('data', (d) => { data += d; });
      resp.on('end', () => res({ status: resp.statusCode, headers: resp.headers, body: data.slice(0, 500) }));
    });
    r.on('error', (e) => res({ error: String(e) }));
    if (body) r.write(body);
    r.end();
  });
}
function upgrade(path, headers) {
  return new Promise((res) => {
    const r = http.request({ host: '127.0.0.1', port: PORT, path, headers: { Connection: 'Upgrade', Upgrade: 'websocket', 'Sec-WebSocket-Version': '13', 'Sec-WebSocket-Key': 'dGhlIHNhbXBsZSBub25jZQ==', ...headers } });
    r.on('upgrade', (resp, socket) => { socket.destroy(); res({ upgraded: true, status: resp.statusCode, headers: resp.headers }); });
    r.on('response', (resp) => { resp.resume(); res({ upgraded: false, status: resp.statusCode, body: JSON.stringify(resp.headers).slice(0, 200) }); });
    r.on('error', (e) => res({ error: String(e) }));
    r.end();
    setTimeout(() => { try { r.destroy(); } catch {} res({ timeout: true }); }, 8000);
  });
}
const log = [];
try {
  const url = await waitForUrl();
  results.printedUrl = url.replace(/token=([^&]+)/, 'token=<redacted>');
  const u = new URL(url);
  const token = u.searchParams.get('token');
  results.tokenFormat = { host: u.host, path: u.pathname, tokenLength: (token || '').length };
  log.push({ step: 'boot', url: results.printedUrl, elapsedMs: 0 });

  results.rootNoToken = await req('GET', '/');
  results.apiNoToken = await req('GET', '/api');
  results.apiPostNoToken = await req('POST', '/api/gateway/ping', { 'content-type': 'application/json' }, '{}');
  results.rootBadToken = await req('GET', '/?token=deadbeef');

  const index = await req('GET', `/?token=${encodeURIComponent(token)}`);
  results.indexWithToken = { status: index.status, location: index.headers.location, setCookie: String(index.headers['set-cookie'] || '').replace(/=[^;]+/, '=<redacted>') };
  const cookie = (String(index.headers['set-cookie'] || '').match(/^[^=]+=[^;]+/) || [''])[0];
  results.cookiePresent = cookie.length > 0;

  results.indexWithCookie = await req('GET', '/', { Cookie: cookie });
  results.apiWithCookieGet = await req('GET', '/api', { Cookie: cookie });
  results.apiPostWithCookie = await req('POST', '/api/gateway/ping', { Cookie: cookie, 'content-type': 'application/json' }, JSON.stringify({ type: 'client-request', rpcId: 'r1', method: 'gateway/ping', payload: {} }));
  results.apiPostNonJson = await req('POST', '/api/gateway/ping', { Cookie: cookie, 'content-type': 'text/plain' }, 'x');
  results.apiWrongHost = await req('GET', '/', { Cookie: cookie, Host: 'example.com' });
  results.apiCrossSite = await req('GET', '/', { Cookie: cookie, 'sec-fetch-site': 'cross-site' });

  results.wsNoCookie = await upgrade('/api/remote.mux', {});
  results.wsWithCookie = await upgrade('/api/remote.mux', { Cookie: cookie });
  results.connectNoToken = await req('GET', '/connect');
  results.connectWithToken = await req('GET', `/connect?token=${encodeURIComponent(token)}&interactions=answer`, {});
} catch (error) {
  results.error = String(error);
} finally {
  try { child.kill(); } catch {}
  writeFileSync(join(ROOT, 'tmp', 'web-probe.log.json'), JSON.stringify({ results, stdoutTail: out.slice(-3000), stderrTail: err.slice(-3000), log }, null, 1));
  console.log('=== RESULTS ===');
  for (const [k, v] of Object.entries(results)) console.log(k, '=', JSON.stringify(v).slice(0, 320));
  console.log('--- stdout tail ---');
  console.log(out.slice(-1200));
  console.log('--- stderr tail ---');
  console.log(err.slice(-1200));
}
