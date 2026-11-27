/**
 * M1 审批联调辅助：制造一个"等待手机授权"的真实审批请求，并保持挂起，
 * 由手机 App 上点「允许一次/拒绝」来决定；脚本最后打印结果与文件是否生成。
 *
 * 用法：node tools/m1-approval-hold.ts [--base http://127.0.0.1:8080] [--decision 允许/拒绝不参与]
 * 说明：本脚本只作为"触发端"，不代替手机做决定（不需要 --decision）。
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { tmpdir } from 'node:os';

type Envelope = { v: number; type: string; payload: any };
const ROOT = resolve(import.meta.dirname, '..');
const STAMP = new Date().toISOString().replace(/[:.]/g, '-');
const BASE = (process.argv.includes('--base') ? process.argv[process.argv.indexOf('--base') + 1] : 'http://127.0.0.1:8080')!.replace(/\/$/, '');
const CODE = '824613';
const EVIDENCE_DIR = join(ROOT, 'docs', 'research', 'evidence', 'm1');
const WORKSPACE = join(ROOT, 'agent', '.m1ws');
const TARGET = join(tmpdir(), 'm1-e2e', `m1-app-approval-${STAMP}.txt`);

function wsUrl(token: string): string {
  const u = new URL(BASE);
  u.protocol = u.protocol === 'https:' ? 'wss:' : 'ws:';
  u.pathname = '/ws';
  u.search = `?role=app&token=${encodeURIComponent(token)}`;
  return u.toString();
}

async function main(): Promise<number> {
  mkdirSync(EVIDENCE_DIR, { recursive: true });
  mkdirSync(join(tmpdir(), 'm1-e2e'), { recursive: true });
  const pairRes = await fetch(`${BASE}/api/v1/auth/pair`, {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ pairingCode: CODE, clientName: 'approval-trigger', role: 'app' }),
  });
  if (!pairRes.ok) throw new Error(`pair failed: ${pairRes.status}`);
  const { token } = (await pairRes.json()) as { token: string };

  const ws = new WebSocket(wsUrl(token));
  const events: Envelope[] = [];
  const waiters: Array<{ pred: (e: Envelope) => boolean; resolve: (e: Envelope) => void }> = [];
  let conversationId = '';
  let approval: any = null;

  const next = (pred: (e: Envelope) => boolean, label: string, timeoutMs: number): Promise<Envelope> =>
    new Promise((resolvePromise, rejectPromise) => {
      const timer = setTimeout(() => rejectPromise(new Error(`timeout waiting ${label}`)), timeoutMs);
      waiters.push({ pred, resolve: (e) => { clearTimeout(timer); resolvePromise(e); } });
    });

  ws.addEventListener('message', (ev: any) => {
    const env = JSON.parse(String(ev.data)) as Envelope;
    events.push(env);
    for (const w of [...waiters]) {
      if (w.pred(env)) { waiters.splice(waiters.indexOf(w), 1); w.resolve(env); }
    }
    if (env.type === 'session.update' && env.payload?.kind === 'tool_call') {
      console.log(`[tool_call] ${env.payload.tool} :: ${JSON.stringify(env.payload.input).slice(0, 160)}`);
    }
    if (env.type === 'task.state') console.log(`[task.state] ${env.payload?.state}`);
    if (env.type === 'approval.resolved') console.log(`[approval.resolved] decision=${env.payload?.decision} by=${env.payload?.decidedBy}`);
  });
  await new Promise<void>((res, rej) => {
    ws.addEventListener('open', () => res());
    ws.addEventListener('error', () => rej(new Error('ws error')));
  });
  const send = (type: string, payload: any) => ws.send(JSON.stringify({ v: 1, type, id: `t_${Date.now()}`, ts: new Date().toISOString(), payload }));

  await next((e) => e.type === 'device.status', 'device.status', 15_000);
  send('conversation.create', { workspacePath: WORKSPACE, title: '手机审批联调' });
  conversationId = (await next((e) => e.type === 'conversation.created', 'conversation.created', 20_000)).payload.conversationId;
  console.log(`conversation=${conversationId} target=${TARGET}`);
  console.log('请在手机上等待审批弹层，并点「允许一次」或「拒绝」……');

  const prompts = [
    `请用 pwsh 命令在 ${TARGET} 创建文件，内容 m1-app-ok。必须用命令行执行，不要用 write 工具。`,
    `请用 pwsh 命令在 ${TARGET} 创建文件，内容 m1-app-ok。必须用命令行执行，不要用 write 工具。`,
    `刚才的写入被沙箱拒绝了，请按流程申请一次性权限提升后再写入 ${TARGET}，不要放弃。`,
  ];
  for (const text of prompts) {
    const before = events.length;
    const approvalP = next((e) => e.type === 'approval.request' && e.payload?.conversationId === conversationId, 'approval.request', 180_000).catch(() => null);
    const settledP = next((e) => e.type === 'task.state' && e.payload?.conversationId === conversationId && ['completed', 'failed', 'cancelled'].includes(e.payload?.state) && events.indexOf(e) >= before, 'terminal', 180_000).catch(() => null);
    send('prompt.send', { conversationId, text });
    const winner: any = await Promise.race([approvalP, settledP]);
    if (winner?.type === 'approval.request') { approval = winner.payload; break; }
    console.log('本轮未触发审批（模型直接完成/放弃），换提示重试');
  }
  if (!approval) throw new Error('approval.request 未触发');
  console.log(`\n[待手机决定] approvalId=${approval.approvalId} tool=${approval.tool}`);
  console.log(`  command=${JSON.stringify(approval.input ?? {}).slice(0, 300)}`);

  const resolved = await next((e) => e.type === 'approval.resolved' && e.payload?.approvalId === approval.approvalId, 'approval.resolved from phone', 600_000);
  const terminal = await next((e) => e.type === 'task.state' && e.payload?.conversationId === conversationId && ['completed', 'failed', 'cancelled'].includes(e.payload?.state) && events.indexOf(e) > events.indexOf(resolved), 'terminal after approval', 240_000);
  const fileExists = existsSync(TARGET);
  const content = fileExists ? readFileSync(TARGET, 'utf8').trim() : null;
  const evidence = {
    stamp: STAMP, base: BASE, conversationId, approval, resolved: resolved.payload,
    taskState: terminal.payload.state, target: TARGET, fileExists, content, eventTypes: events.reduce<Record<string, number>>((a, e) => { a[e.type] = (a[e.type] ?? 0) + 1; return a; }, {}),
  };
  const file = join(EVIDENCE_DIR, `approval-phone-${STAMP}.json`);
  writeFileSync(file, JSON.stringify(evidence, null, 2), 'utf8');
  console.log(`\n结果：decision=${resolved.payload?.decision} task=${terminal.payload.state} file=${fileExists} content=${content}`);
  console.log(`证据：${file}`);
  ws.close();
  return 0;
}

main().then((c) => process.exit(c)).catch((e) => { console.error('失败：', e); process.exit(1); });
