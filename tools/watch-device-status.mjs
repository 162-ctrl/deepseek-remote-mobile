// 临时：验证 M4.20 的授权目录自愈。
//
// 用法：node tools/watch-device-status.mjs [秒数]
//
// 以「手机」身份连上中继（token 取自插件状态目录里 role=app 的最近一枚），
// 打印收到的 device.status 里的 workspaceRoots —— 新连上的 App 会立刻收到
// 中继缓存的最近一次上报，所以这能直接看到 Agent 眼里的授权目录。
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const STATE_DIR = 'C:/Users/user/.dsh/dsh-plugin-m1';
const BASE = 'http://127.0.0.1:8787';
const seconds = Number(process.argv[2] ?? '3');

const tokens = JSON.parse(readFileSync(join(STATE_DIR, 'tokens.json'), 'utf8'));
const appTokens = tokens
  .filter((item) => item.role === 'app' && item.clientName === 'DeepSeek Remote 手机')
  .sort((a, b) => new Date(b.expiresAt) - new Date(a.expiresAt));
if (appTokens.length === 0) {
  console.error('找不到 role=app 的手机 token');
  process.exit(1);
}
const token = appTokens[0].token;

const url = `${BASE.replace('http', 'ws')}/ws?role=app&token=${encodeURIComponent(token)}`;
const socket = new WebSocket(url);

socket.addEventListener('message', (event) => {
  const envelope = JSON.parse(String(event.data));
  if (envelope.type === 'device.status') {
    const payload = envelope.payload ?? {};
    const roots = payload.workspaceRoots ?? [];
    console.log(`workspaceRoots(${roots.length}):`);
    for (const root of roots) console.log(`  - ${root}`);
    if (payload.harnessVersion) console.log(`harnessVersion: ${payload.harnessVersion}`);
  }
});

socket.addEventListener('error', (event) => {
  console.error('ws error', event?.message ?? '');
});

socket.addEventListener('open', () => console.log(`connected ${url.replace(token, '***')}`));

setTimeout(() => {
  socket.close();
  process.exit(0);
}, seconds * 1000);
