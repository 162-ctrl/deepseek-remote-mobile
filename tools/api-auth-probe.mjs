// M4.40 鉴权面专项：坏 token、角色越权、过期语义、token 表规模。
import fs from 'node:fs';

const BASE = 'http://127.0.0.1:8787';
const raw = JSON.parse(fs.readFileSync('C:/Users/user/.dsh/dsh-plugin-m1/tokens.json', 'utf8'));
const list = Array.isArray(raw) ? raw : raw.tokens || [];
const apps = list.filter((t) => t.role === 'app').sort((a, b) => String(b.expiresAt).localeCompare(String(a.expiresAt)));
const agents = list.filter((t) => t.role === 'agent').sort((a, b) => String(b.expiresAt).localeCompare(String(a.expiresAt)));
const appToken = apps[0]?.token;
const agentToken = agents[0]?.token;

console.log(`token 表共 ${list.length} 条：app ${apps.length} / agent ${agents.length}`);
const expired = list.filter((t) => new Date(t.expiresAt).getTime() < Date.now()).length;
console.log(`其中已过期 ${expired} 条（仍在文件里）`);

async function call(label, path, token) {
  const headers = {};
  if (token) headers.Authorization = `Bearer ${token}`;
  const res = await fetch(BASE + path, { headers, signal: AbortSignal.timeout(20000) });
  const text = (await res.text()).slice(0, 90).replace(/\n/g, ' ');
  console.log(`${String(res.status).padEnd(4)} ${label.padEnd(46)} ${text}`);
}

for (const path of ['/api/v1/desktop/tasks', '/api/v1/desktop/file/read', '/api/v1/desktop/account/balance']) {
  await call(`坏 token ${path}`, path, 'not-a-real-token');
  await call(`空 token ${path}`, path, '');
  await call(`app token ${path}`, path, appToken);
  await call(`agent token ${path}`, path, agentToken);
}

// agent 专用路由：app token 不该能读全部工作区清单
await call('agent 路由 + app token', '/api/v1/agent/workspaces', appToken);
await call('agent 路由 + agent token', '/api/v1/agent/workspaces', agentToken);

// 过期语义：把过期时间算在 30 天后，检查是否被自动续期（这里只能看现状）
const soonest = apps[0];
console.log(`最新 app token 过期时间：${soonest?.expiresAt}`);
