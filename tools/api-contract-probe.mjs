// M4.40 接口契约体检：真 token 打本机插件，只看「契约是否自洽」。
import fs from 'node:fs';

const BASE = 'http://127.0.0.1:8787';
const tokens = JSON.parse(fs.readFileSync('C:/Users/user/.dsh/dsh-plugin-m1/tokens.json', 'utf8'));
const list = Array.isArray(tokens) ? tokens : tokens.tokens || [];
const apps = list
  .filter((t) => t.role === 'app')
  .sort((a, b) => String(b.expiresAt).localeCompare(String(a.expiresAt)));
const token = apps[0]?.token;
if (!token) {
  console.log('no app token');
  process.exit(1);
}

const rows = [];
async function probe(label, method, path, { auth = true, headers = {}, body, timeout = 25000 } = {}) {
  const started = Date.now();
  const h = { ...headers };
  if (auth) h.Authorization = `Bearer ${token}`;
  try {
    const res = await fetch(BASE + path, { method, headers: h, body, signal: AbortSignal.timeout(timeout) });
    const buf = Buffer.from(await res.arrayBuffer());
    const text = buf.toString('utf8');
    rows.push({
      label,
      status: res.status,
      ms: Date.now() - started,
      bytes: buf.length,
      body: text.length > 180 ? text.slice(0, 180) + '…' : text,
    });
  } catch (error) {
    rows.push({ label, status: 'ERR', ms: Date.now() - started, bytes: 0, body: String(error).slice(0, 120) });
  }
}

const sample = 'session-55cdd3b7-c94a-42c2-a343-aa60f5fc54b5';

// 1) 鉴权：所有敏感路由不带 token 都该 401
const guarded = [
  '/api/v1/desktop/tasks',
  '/api/v1/desktop/workspaces',
  '/api/v1/desktop/pending',
  '/api/v1/desktop/plugins/catalog',
  '/api/v1/desktop/account/balance',
  '/api/v1/desktop/archive/sessions',
];
for (const path of guarded) await probe(`NOAUTH ${path}`, 'GET', path, { auth: false });
await probe('BADTOKEN /desktop/tasks', 'GET', '/api/v1/desktop/tasks', {
  headers: { Authorization: 'Bearer not-a-real-token' },
});

// 2) 会话事件：不存在的 id、越界 afterSeq、非数字 afterSeq
await probe('events 不存在会话', 'GET', `/api/v1/desktop/sessions/session-does-not-exist/events`);
await probe('events afterSeq=999999999', 'GET', `/api/v1/desktop/sessions/${sample}/events?afterSeq=999999999`);
await probe('events afterSeq=abc', 'GET', `/api/v1/desktop/sessions/${sample}/events?afterSeq=abc`);
await probe('events afterSeq=-5', 'GET', `/api/v1/desktop/sessions/${sample}/events?afterSeq=-5`);
await probe('events 首屏', 'GET', `/api/v1/desktop/sessions/${sample}/events`);

// 3) 排队接口：未知 action、空体、坏 JSON
await probe('queue GET', 'GET', `/api/v1/desktop/sessions/${sample}/queue`);
await probe('queue 未知 action', 'POST', `/api/v1/desktop/sessions/${sample}/queue`, {
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ action: 'dropEverything', id: 'x' }),
});
await probe('queue 坏 JSON', 'POST', `/api/v1/desktop/sessions/${sample}/queue`, {
  headers: { 'Content-Type': 'application/json' },
  body: '{oops',
});
await probe('queue 空体', 'POST', `/api/v1/desktop/sessions/${sample}/queue`, {
  headers: { 'Content-Type': 'application/json' },
  body: '',
});

// 4) 新建工作区：空名、路径穿越、坏 JSON
await probe('workspaces 坏 JSON', 'POST', '/api/v1/desktop/workspaces', {
  headers: { 'Content-Type': 'application/json' },
  body: '{"name":',
});
await probe('workspaces 空名', 'POST', '/api/v1/desktop/workspaces', {
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ name: '   ' }),
});
await probe('workspaces 穿越名', 'POST', '/api/v1/desktop/workspaces', {
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ name: '../../escape-probe', parentDir: 'D:\\Projects\\项目' }),
});

// 5) 文件读取：路径穿越 / 不存在的文件
await probe('file/read 穿越', 'POST', '/api/v1/desktop/file/read', {
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ path: 'C:\\Windows\\win.ini' }),
});
await probe('file/read 不存在', 'POST', '/api/v1/desktop/file/read', {
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ path: '<项目根>\\no-such-file.txt' }),
});

// 6) app/version 与 apk 头
await probe('app/version', 'GET', '/api/v1/app/version', { auth: false });
await probe('apk HEAD', 'HEAD', '/api/v1/app/apk', { auth: false });
await probe('apk Range 头', 'GET', '/api/v1/app/apk', {
  auth: false,
  headers: { Range: 'bytes=0-99' },
});
await probe('apk 起 3 字节', 'GET', '/api/v1/app/apk', { auth: false, headers: { Range: 'bytes=0-2' } });

for (const row of rows) {
  console.log(
    `${String(row.status).padEnd(4)} ${String(row.ms).padStart(6)}ms ${String(row.bytes).padStart(9)}B  ${row.label}\n     ${row.body.replace(/\n/g, ' ')}`,
  );
}
