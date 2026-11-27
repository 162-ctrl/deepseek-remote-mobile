/**
 * 验证「手机端接入的工作区 = 电脑上正在做的项目目录」。
 *
 * 用法：node tools/verify-workspace.ts [--base http://127.0.0.1:8080] [--code 824613]
 *
 * 流程：pair(app) → WSS 连接 → device.status → conversation.create（不传 workspacePath，走 Agent 的工作区根）
 * → prompt.send（只读命令列目录）→ 自动批准审批 → 打印 Harness 输出 → 写证据 JSON。
 */
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const EVIDENCE_DIR = join(ROOT, 'docs', 'research', 'evidence', 'm2');
const STAMP = new Date().toISOString().replace(/[:.]/g, '-');

function arg(name: string, fallback: string): string {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

const BASE = arg('base', 'http://127.0.0.1:8080').replace(/\/+$/, '');
const CODE = arg('code', '824613');

type Envelope = { v: number; type: string; id: string; ts: string; payload: any };

function wsUrl(role: string, token: string): string {
  const u = new URL(BASE);
  u.protocol = u.protocol === 'https:' ? 'wss:' : 'ws:';
  u.pathname = '/ws';
  u.search = `?role=${role}&token=${encodeURIComponent(token)}`;
  return u.toString();
}

async function pair(): Promise<string> {
  const res = await fetch(`${BASE}/api/v1/auth/pair`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ pairingCode: CODE, clientName: 'verify-workspace', role: 'app' }),
  });
  if (!res.ok) throw new Error(`pair failed: HTTP ${res.status} ${await res.text()}`);
  return ((await res.json()) as { token: string }).token;
}

const events: Envelope[] = [];
let cursor = 0;
const waiters: Array<{ pred: (e: Envelope) => boolean; resolve: (e: Envelope) => void; timer: NodeJS.Timeout }> = [];

/** 从当前游标开始等待第一个匹配事件（消费式，避免重复命中旧事件）。 */
function waitFor(pred: (e: Envelope) => boolean, timeoutMs: number, label: string): Promise<Envelope> {
  for (let i = cursor; i < events.length; i++) {
    if (pred(events[i])) {
      cursor = i + 1;
      return Promise.resolve(events[i]);
    }
  }
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      waiters.splice(waiters.indexOf(entry), 1);
      reject(new Error(`timeout ${timeoutMs}ms waiting for ${label}`));
    }, timeoutMs);
    const entry = {
      pred,
      resolve: (e: Envelope) => {
        clearTimeout(timer);
        resolve(e);
      },
      timer,
    };
    waiters.push(entry);
  });
}

async function main(): Promise<number> {
  const token = await pair();
  const ws = new WebSocket(wsUrl('app', token));
  let seq = 0;
  const send = (type: string, payload: any): void => {
    ws.send(JSON.stringify({ v: 1, type, id: `vw_${++seq}`, ts: new Date().toISOString(), payload }));
  };

  await new Promise<void>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('ws open timeout')), 10_000);
    ws.addEventListener('open', () => {
      clearTimeout(timer);
      resolve();
    });
    ws.addEventListener('error', (ev: any) => reject(new Error(`ws error: ${ev?.message ?? 'unknown'}`)));
    ws.addEventListener('message', (ev: any) => {
      let env: Envelope;
      try {
        env = JSON.parse(typeof ev.data === 'string' ? ev.data : String(ev.data)) as Envelope;
      } catch {
        return;
      }
      events.push(env);
      for (const w of [...waiters]) {
        if (w.pred(env)) {
          cursor = events.length;
          w.resolve(env);
          waiters.splice(waiters.indexOf(w), 1);
        }
      }
    });
  });

  const status = await waitFor((e) => e.type === 'device.status', 20_000, 'device.status');
  const workspaceRoots = status.payload?.workspaceRoots ?? null;
  console.log(`device.status: device=${status.payload?.deviceName} online=${status.payload?.online}`);
  console.log(`device.status.workspaceRoots=${JSON.stringify(workspaceRoots)}`);

  send('conversation.create', { title: '本地项目同步验证' });
  const created = await waitFor((e) => e.type === 'conversation.created' && !!e.payload?.conversationId, 60_000, 'conversation.created');
  const conversationId = created.payload.conversationId as string;
  console.log(`conversation.created: ${conversationId} workspacePath=${created.payload?.workspacePath ?? '(未返回)'}`);

  const prompt = [
    '这是一次只读验证，请不要修改任何文件。',
    '请执行一条命令：显示当前工作目录（Get-Location 或 pwd），并列出该目录下前 10 个顶层条目的名字。',
    '然后用一句话说明：这是一个什么项目？（例如是手机 App / 后端 / Agent 的哪个仓库）',
  ].join('\n');
  send('prompt.send', { conversationId, text: prompt });

  const outputs: string[] = [];
  let approvals = 0;
  let terminal: string | null = null;
  const deadline = Date.now() + 240_000;

  while (Date.now() < deadline && !terminal) {
    const env = await waitFor(
      (e) =>
        (e.type === 'session.update' && e.payload?.conversationId === conversationId) ||
        (e.type === 'approval.request' && e.payload?.conversationId === conversationId) ||
        (e.type === 'task.state' && e.payload?.conversationId === conversationId),
      240_000,
      'session.update/approval/task.state',
    );
    if (env.type === 'session.update' && env.payload?.kind === 'output') {
      outputs.push(String(env.payload?.text ?? ''));
    }
    if (env.type === 'approval.request' && approvals < 3) {
      approvals++;
      console.log(`approval.request: tool=${env.payload?.tool} → auto approve`);
      send('approval.decide', { conversationId, approvalId: env.payload?.approvalId, decision: 'approved' });
    }
    if (env.type === 'task.state' && ['completed', 'failed', 'cancelled'].includes(env.payload?.state)) {
      terminal = env.payload.state as string;
    }
  }

  const text = outputs.join('\n').trim();
  console.log('---- Harness 输出 ----');
  console.log(text.slice(0, 2000));
  console.log('---- 结束 ----');
  console.log(`state=${terminal} approvals=${approvals} outputs=${outputs.length}`);

  mkdirSync(EVIDENCE_DIR, { recursive: true });
  const evidencePath = join(EVIDENCE_DIR, `verify-workspace-${STAMP}.json`);
  writeFileSync(
    evidencePath,
    JSON.stringify({ base: BASE, conversationId, workspaceRoots, deviceStatus: status.payload, outputs, approvals, state: terminal, at: new Date().toISOString() }, null, 2),
    'utf8',
  );
  console.log(`evidence: ${evidencePath}`);

  ws.close();
  return terminal === 'completed' ? 0 : 1;
}

main().then(
  (code) => process.exit(code),
  (err) => {
    console.error(`FAIL: ${err instanceof Error ? err.message : String(err)}`);
    process.exit(1);
  },
);
