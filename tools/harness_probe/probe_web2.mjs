// HTTP RPC + WebSocket mux probe v2: real Remote endpoints over /api and the $events stream.
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
env.ELECTRON_RUN_AS_NODE = '1'; env.DSH_HOME = HOME; env.NO_COLOR = '1';

const child = spawn(EXE, ['--expose-internals', CLI, '--profile', 'web', '--host', '127.0.0.1', '--port', String(PORT), '--no-open'], { cwd: TMP, env, stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true });
let out = '', err = '';
child.stdout.setEncoding('utf8'); child.stderr.setEncoding('utf8');
child.stdout.on('data', (d) => { out += d; }); child.stderr.on('data', (d) => { err += d; });
function waitForUrl(ms = 40000) {
  return new Promise((res, rej) => {
    const t0 = Date.now();
    const iv = setInterval(() => {
      const m = out.match(/(https?:\/\/[^\s"'<>]+)/);
      if (m) { clearInterval(iv); res(m[1]); }
      else if (Date.now() - t0 > ms) { clearInterval(iv); rej(new Error('no URL; out=' + JSON.stringify(out.slice(-500)) + ' err=' + JSON.stringify(err.slice(-500)))); }
    }, 100);
  });
}
function req(method, path, headers = {}, body) {
  return new Promise((res) => {
    const r = http.request({ host: '127.0.0.1', port: PORT, method, path, headers }, (resp) => {
      let data = ''; resp.setEncoding('utf8');
      resp.on('data', (d) => { data += d; });
      resp.on('end', () => res({ status: resp.statusCode, headers: resp.headers, body: data.slice(0, 900) }));
    });
    r.on('error', (e) => res({ error: String(e) }));
    if (body) r.write(body);
    r.end();
  });
}
// Minimal WS client
function wsConnect(path, headers) {
  return new Promise((res, rej) => {
    const r = http.request({ host: '127.0.0.1', port: PORT, path, headers: { Connection: 'Upgrade', Upgrade: 'websocket', 'Sec-WebSocket-Version': '13', 'Sec-WebSocket-Key': 'dGhlIHNhbXBsZSBub25jZQ==', ...headers } });
    r.on('upgrade', (resp, socket) => {
      const messages = [];
      let buf = Buffer.alloc(0);
      socket.on('data', (chunk) => {
        buf = Buffer.concat([buf, chunk]);
        while (buf.length >= 2) {
          const fin = (buf[0] & 0x80) !== 0; const op = buf[0] & 0x0f; let len = buf[1] & 0x7f; let off = 2;
          if (len === 126) { if (buf.length < 4) return; len = buf.readUInt16BE(2); off = 4; }
          else if (len === 127) { if (buf.length < 10) return; len = Number(buf.readBigUInt64BE(2)); off = 10; }
          if (buf.length < off + len) return;
          const payload = buf.subarray(off, off + len); buf = buf.subarray(off + len);
          if (op === 1) messages.push({ t: Date.now(), text: payload.toString('utf8') });
          else if (op === 8) { socket.destroy(); }
          else if (op === 9) { socket.write(Buffer.concat([Buffer.from([0x8a, payload.length]), payload])); }
        }
      });
      res({ socket, messages, status: resp.statusCode });
    });
    r.on('response', (resp) => { resp.resume(); rej(new Error('not upgraded: ' + resp.statusCode)); });
    r.on('error', (e) => rej(e));
    r.end();
    setTimeout(() => { try { r.destroy(); } catch {} rej(new Error('upgrade timeout')); }, 8000);
  });
}
function wsSend(socket, obj) {
  const data = Buffer.from(JSON.stringify(obj), 'utf8');
  const len = data.length;
  const mask = Buffer.from([1, 2, 3, 4]);
  let header;
  if (len < 126) header = Buffer.from([0x81, 0x80 | len]);
  else if (len < 65536) { header = Buffer.alloc(4); header[0] = 0x81; header[1] = 0x80 | 126; header.writeUInt16BE(len, 2); }
  else { header = Buffer.alloc(10); header[0] = 0x81; header[1] = 0x80 | 127; header.writeBigUInt64BE(BigInt(len), 2); }
  const masked = Buffer.alloc(len);
  for (let i = 0; i < len; i++) masked[i] = data[i] ^ mask[i & 3];
  socket.write(Buffer.concat([header, mask, masked]));
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let ws1 = null, ws2 = null;
try {
  const url = await waitForUrl();
  const u = new URL(url);
  const token = u.searchParams.get('token');
  results.printedUrl = url.replace(token, '<redacted>');
  const index = await req('GET', `/?token=${encodeURIComponent(token)}`);
  const browserCookie = (String(index.headers['set-cookie'] || '').match(/^[^=]+=[^;]+/) || [''])[0];

  // real Remote endpoints over /api (payload = {args})
  for (const endpoint of ['session/list', 'session/create', 'session/modelCatalog', 'settings/describe']) {
    const r = await req('POST', `/api/${endpoint}`, { Cookie: browserCookie, 'content-type': 'application/json' },
      JSON.stringify({ type: 'client-request', rpcId: 'r-' + endpoint, method: endpoint, payload: { args: {} } }));
    results['rpc:' + endpoint] = { status: r.status, body: r.body };
  }

  // /connect gives an interactions=answer peer cookie for the WS mux
  const connect = await req('GET', `/connect?token=${encodeURIComponent(token)}&interactions=answer`);
  results.connect = { status: connect.status, location: connect.headers.location, setCookie: String(connect.headers['set-cookie'] || '').replace(/=[^;]+/, '=<redacted>') };
  const peerCookie = (String(connect.headers['set-cookie'] || '').match(/^[^=]+=[^;]+/) || [''])[0];

  // WS mux with peer cookie: open the forwarded event stream ($events)
  ws1 = await wsConnect('/api/remote.mux', { Cookie: peerCookie });
  results.wsMux = { status: ws1.status };
  wsSend(ws1.socket, { type: 'open', streamId: 'ev1', endpoint: '$events', payload: { args: {} } });
  await sleep(2500);
  results.wsEvents = ws1.messages.slice(0, 8).map((m) => ({ t: m.t, text: m.text.slice(0, 300) }));

  // WS mux with only the browser cookie (no answer interactions): expect refusal on $events
  ws2 = await wsConnect('/api/remote.mux', { Cookie: browserCookie });
  wsSend(ws2.socket, { type: 'open', streamId: 'ev2', endpoint: '$events', payload: { args: {} } });
  await sleep(1500);
  results.wsBrowserPeerEvents = ws2.messages.slice(0, 4).map((m) => ({ t: m.t, text: m.text.slice(0, 300) }));
} catch (error) {
  results.error = String(error);
} finally {
  if (ws1) { try { ws1.socket.destroy(); } catch {} }
  if (ws2) { try { ws2.socket.destroy(); } catch {} }
  try { child.kill(); } catch {}
  writeFileSync(join(ROOT, 'tmp', 'web-probe2.log.json'), JSON.stringify({ results, stdoutTail: out.slice(-2000), stderrTail: err.slice(-2000) }, null, 1));
  console.log('=== RESULTS ===');
  for (const [k, v] of Object.entries(results)) console.log(k, '=', JSON.stringify(v).slice(0, 700));
  console.log('--- stderr tail ---'); console.log(err.slice(-800));
}
