// 本地冒烟：不装进 Harness，直接起中继 + 假 agent + 假 app，验证配对、路由、seq、忙闲。
// 用法：node tools/smoke.mjs
import { fileURLToPath } from 'node:url';
import { M1Hub } from '../lib/hub.js';
import { createRelayHttpServer } from '../lib/server.js';

const PORT = 8799;
const CODE = '123456';

const hub = new M1Hub({ pairingCode: CODE, version: '9.9.9', log: () => {} });
const server = createRelayHttpServer({
  hub,
  version: '9.9.9',
  qrcodeAssetPath: fileURLToPath(new URL('../assets/qrcode.js', import.meta.url)),
  pageContext: { port: PORT, rotatePairingCode: () => '000000' },
});
server.on('upgrade', (request, socket) => hub.acceptUpgrade(request, socket));

const base = `http://127.0.0.1:${PORT}`;
let failures = 0;
const check = (label, ok, detail = '') => {
  if (ok) console.log(`  ok   ${label}`);
  else {
    failures += 1;
    console.log(`  FAIL ${label} ${detail}`);
  }
};

const post = (path, body) =>
  fetch(base + path, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });

function connect(role, token) {
  const ws = new WebSocket(`ws://127.0.0.1:${PORT}/ws?role=${role}&token=${token}`);
  const queue = [];
  const waiters = [];
  ws.addEventListener('message', (event) => {
    const envelope = JSON.parse(String(event.data));
    if (waiters.length > 0) waiters.shift()(envelope);
    else queue.push(envelope);
  });
  const next = (timeoutMs = 3000) =>
    new Promise((resolve, reject) => {
      if (queue.length > 0) return resolve(queue.shift());
      const timer = setTimeout(() => reject(new Error('timeout waiting for envelope')), timeoutMs);
      waiters.push((value) => {
        clearTimeout(timer);
        resolve(value);
      });
    });
  const ready = new Promise((resolve, reject) => {
    ws.addEventListener('open', () => resolve());
    ws.addEventListener('error', () => reject(new Error(`ws error for ${role}`)));
  });
  return { ws, next, ready, send: (envelope) => ws.send(JSON.stringify(envelope)) };
}

await new Promise((resolve) => server.listen(PORT, '127.0.0.1', resolve));

const health = await (await fetch(`${base}/api/v1/health`)).json();
check('health ok', health.status === 'ok' && health.agentOnline === false, JSON.stringify(health));
check('health apps=0', health.apps === 0, JSON.stringify(health));

const badPair = await post('/api/v1/auth/pair', { pairingCode: '000000', clientName: 'phone', role: 'app' });
check('wrong code → 401', badPair.status === 401, String(badPair.status));
check('wrong code → AUTH_FAILED', (await badPair.json()).code === 'AUTH_FAILED');

const badRole = await post('/api/v1/auth/pair', { pairingCode: CODE, clientName: 'x', role: 'root' });
check('bad role → 401', badRole.status === 401, String(badRole.status));

const agentPair = await (await post('/api/v1/auth/pair', { pairingCode: CODE, clientName: 'pc', role: 'agent' })).json();
const appPair = await (await post('/api/v1/auth/pair', { pairingCode: CODE, clientName: 'phone', role: 'app' })).json();
check('agent pair shape', /^[0-9A-Z]{26}$/.test(agentPair.deviceId), agentPair.deviceId);
check('app pair shape', /^dev_\d+$/.test(appPair.deviceId), appPair.deviceId);
check('expiresAt format', /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(appPair.expiresAt), appPair.expiresAt);

// 未授权的 ws 应被 4401 关掉
const rejected = new WebSocket(`ws://127.0.0.1:${PORT}/ws?role=app&token=nope`);
const rejectedCode = await new Promise((resolve) => {
  rejected.addEventListener('close', (event) => resolve(event.code));
  setTimeout(() => resolve(-1), 3000);
});
check('bad token closes 4401', rejectedCode === 4401, String(rejectedCode));

const app = connect('app', appPair.token);
await app.ready;
const snapshot = await app.next();
check('app gets device.status snapshot', snapshot.type === 'device.status' && snapshot.payload.online === false, JSON.stringify(snapshot));

const agent = connect('agent', agentPair.token);
await agent.ready;
const online = await app.next();
check('agent online broadcast', online.type === 'device.status' && online.payload.online === true, JSON.stringify(online));

app.send({ v: 1, type: 'ping' });
const pong = await app.next();
check('ping → pong', pong.type === 'pong', JSON.stringify(pong));

app.send({ v: 1, type: 'conversation.create', payload: { workspacePath: 'C:/x', title: 't' } });
const createdReq = await agent.next();
check('conversation.create forwarded', createdReq.type === 'conversation.create', JSON.stringify(createdReq));
const conversationId = createdReq.payload.conversationId;
check('conversationId is ULID', /^[0-9A-Z]{26}$/.test(conversationId), conversationId);

agent.send({ v: 1, type: 'conversation.created', payload: { conversationId, title: 't' } });
const createdNotice = await app.next();
check('conversation.created broadcast', createdNotice.type === 'conversation.created', JSON.stringify(createdNotice));

app.send({ v: 1, type: 'prompt.send', payload: { conversationId, text: 'hi' } });
const prompt = await agent.next();
check('prompt.send forwarded with seq', prompt.type === 'prompt.send' && prompt.payload.seq === 1 && prompt.seq === 1, JSON.stringify(prompt));

app.send({ v: 1, type: 'prompt.send', payload: { conversationId, text: 'again' } });
const busy = await app.next();
check('second prompt → SESSION_BUSY', busy.type === 'error' && busy.payload.code === 'SESSION_BUSY', JSON.stringify(busy));

agent.send({ v: 1, type: 'session.update', payload: { conversationId, kind: 'output', text: 'hello' } });
const update = await app.next();
check('session.update broadcast + seq assigned', update.type === 'session.update' && update.payload.seq === 2, JSON.stringify(update));

agent.send({ v: 1, type: 'task.state', payload: { conversationId, state: 'completed' } });
const done = await app.next();
check('task.state broadcast', done.type === 'task.state', JSON.stringify(done));

app.send({ v: 1, type: 'prompt.send', payload: { conversationId, text: 'third' } });
const third = await agent.next();
// 注意：session.update / task.state 也会各占一个 seq，所以这里只验证「不再 busy、能再次转发」
check('session free again', third.type === 'prompt.send' && third.payload.seq > update.payload.seq, JSON.stringify(third));

// agent 在线时对未知 conversationId 采取宽松策略：登记后照常转发
app.send({ v: 1, type: 'prompt.send', payload: { conversationId: 'unknown-conv-id', text: 'x' } });
const lazy = await agent.next();
check('unknown conversation lazily registered & forwarded', lazy.type === 'prompt.send' && lazy.payload.conversationId === 'unknown-conv-id', JSON.stringify(lazy));

const page = await (await fetch(`${base}/`)).text();
check('pair page renders', page.includes('匹配码') && page.includes(CODE));

const asset = await fetch(`${base}/assets/qrcode.js`);
check('qrcode asset served', asset.status === 200 && (await asset.text()).length > 1000);

agent.ws.close();
const offline = await app.next();
check('agent offline broadcast', offline.type === 'device.status' && offline.payload.online === false, JSON.stringify(offline));

app.ws.close();
hub.dispose();
server.close();
console.log(failures === 0 ? '\nALL PASS' : `\n${failures} FAILED`);
process.exit(failures === 0 ? 0 : 1);
