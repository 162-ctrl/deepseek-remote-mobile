// 临时探针：用手机 token 读 /api/v1/desktop/tasks，并对运行中的会话读排队消息。
// 用法：node tools/queue-probe.mjs [sessionId]
import { readFileSync } from 'node:fs';

const TOKENS = 'C:/Users/user/.dsh/dsh-plugin-m1/tokens.json';
const BASE = 'http://127.0.0.1:8787';

const tokens = JSON.parse(readFileSync(TOKENS, 'utf8'));
const apps = tokens
  .filter((row) => row.role === 'app' && row.clientName === 'DeepSeek Remote 手机')
  .sort((a, b) => String(b.expiresAt).localeCompare(String(a.expiresAt)));
if (apps.length === 0) {
  console.error('no app token');
  process.exit(1);
}
const token = apps[0].token;

const call = async (path, init = {}) => {
  const response = await fetch(`${BASE}${path}`, {
    ...init,
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json', ...(init.headers ?? {}) },
  });
  const text = await response.text();
  let body;
  try {
    body = JSON.parse(text);
  } catch {
    body = text;
  }
  return { status: response.status, body };
};

const wanted = process.argv[2];
const tasks = await call('/api/v1/desktop/tasks');
const rows = Array.isArray(tasks.body?.tasks) ? tasks.body.tasks : [];
const targets = wanted
  ? rows.filter((row) => row.id === wanted)
  : rows.filter((row) => row.running);

console.log(`tasks=${rows.length} running=${rows.filter((r) => r.running).length}`);
for (const row of targets) {
  const queue = await call(`/api/v1/desktop/sessions/${encodeURIComponent(row.id)}/queue`);
  console.log(
    `\n[${row.id}] title=${row.title} running=${row.running} → status=${queue.status}`,
  );
  console.log(JSON.stringify(queue.body, null, 2).slice(0, 1400));
}
