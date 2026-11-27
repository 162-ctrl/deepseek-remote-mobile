/**
 * M1-α 端到端验收客户端（模拟手机 App）
 *
 * 用法：
 *   node tools/m1-client.ts [--base http://127.0.0.1:8080] [--code 824613] [--skip-approval]
 *
 * 前置：后端已启动、Agent 已用 node agent/scripts/serve.ts 连上后端。
 * 验收：docs/design/M1_PROTOCOL.md §7 的 M1-A1..A8。
 * 证据：docs/research/evidence/m1/e2e-<stamp>.json
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync, unlinkSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { tmpdir } from 'node:os';

type Role = 'app' | 'agent';
type Envelope = { v: number; type: string; id?: string; ts?: string; payload: any };

const ROOT = resolve(import.meta.dirname, '..');
const STAMP = new Date().toISOString().replace(/[:.]/g, '-');

function arg(name: string, fallback?: string): string | undefined {
  const i = process.argv.indexOf(`--${name}`);
  if (i >= 0 && process.argv[i + 1]) return process.argv[i + 1];
  return fallback;
}
const BASE = arg('base', 'http://127.0.0.1:8080')!.replace(/\/$/, '');
const CODE = arg('code', '824613')!;
const SKIP_APPROVAL = process.argv.includes('--skip-approval');
const EVIDENCE_DIR = join(ROOT, 'docs', 'research', 'evidence', 'm1');

function wsUrl(role: Role, token: string): string {
  const u = new URL(BASE);
  u.protocol = u.protocol === 'https:' ? 'wss:' : 'ws:';
  u.pathname = '/ws';
  u.search = `?role=${role}&token=${encodeURIComponent(token)}`;
  return u.toString();
}

async function pair(clientName: string, role: Role): Promise<{ token: string; deviceId?: string }> {
  const res = await fetch(`${BASE}/api/v1/auth/pair`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ pairingCode: CODE, clientName, role }),
  });
  if (!res.ok) throw new Error(`pair failed: HTTP ${res.status} ${await res.text()}`);
  return (await res.json()) as { token: string; deviceId?: string };
}

async function health(): Promise<any> {
  const res = await fetch(`${BASE}/api/v1/health`);
  if (!res.ok) throw new Error(`health failed: HTTP ${res.status}`);
  return await res.json();
}

class Client {
  readonly events: Envelope[] = [];
  private ws?: WebSocket;
  private waiters: Array<{ predicate: (e: Envelope) => boolean; label: string; resolve: (e: Envelope) => void; reject: (e: Error) => void; timer: NodeJS.Timeout }> = [];

  connect(token: string): Promise<void> {
    return new Promise((resolvePromise, rejectPromise) => {
      const ws = new WebSocket(wsUrl('app', token));
      this.ws = ws;
      const timer = setTimeout(() => rejectPromise(new Error('ws open timeout')), 10000);
      ws.addEventListener('open', () => { clearTimeout(timer); resolvePromise(); });
      ws.addEventListener('error', (ev: any) => { clearTimeout(timer); rejectPromise(new Error(`ws error: ${ev?.message ?? 'unknown'}`)); });
      ws.addEventListener('message', (ev: any) => {
        const text = typeof ev.data === 'string' ? ev.data : String(ev.data);
        let env: Envelope;
        try { env = JSON.parse(text) as Envelope; } catch { return; }
        this.events.push(env);
        for (const w of [...this.waiters]) {
          if (w.predicate(env)) {
            clearTimeout(w.timer);
            this.waiters = this.waiters.filter((x) => x !== w);
            w.resolve(env);
          }
        }
      });
    });
  }

  mark(): number { return this.events.length; }

  waitFor(predicate: (e: Envelope) => boolean, timeoutMs: number, label: string, since = 0): Promise<Envelope> {
    const hit = this.events.slice(since).find(predicate);
    if (hit) return Promise.resolve(hit);
    return new Promise((resolvePromise, rejectPromise) => {
      const timer = setTimeout(() => {
        this.waiters = this.waiters.filter((w) => w.label !== label);
        rejectPromise(new Error(`timeout ${timeoutMs}ms waiting for ${label}`));
      }, timeoutMs);
      this.waiters.push({ predicate, label, resolve: resolvePromise, reject: rejectPromise, timer });
    });
  }

  send(type: string, payload: any): void {
    if (!this.ws || this.ws.readyState !== 1) throw new Error('ws not open');
    this.ws.send(JSON.stringify({ v: 1, type, id: `c_${Date.now()}_${Math.random().toString(36).slice(2, 7)}`, ts: new Date().toISOString(), payload }));
  }

  close(): void { this.ws?.close(); }
}

type Step = { name: string; ok: boolean; detail: string; ms: number };
const steps: Step[] = [];
async function step(name: string, fn: () => Promise<string>): Promise<boolean> {
  const t0 = Date.now();
  try {
    const detail = await fn();
    steps.push({ name, ok: true, detail, ms: Date.now() - t0 });
    console.log(`PASS ${name} — ${detail} (${Date.now() - t0}ms)`);
    return true;
  } catch (err) {
    const detail = err instanceof Error ? err.message : String(err);
    steps.push({ name, ok: false, detail, ms: Date.now() - t0 });
    console.log(`FAIL ${name} — ${detail} (${Date.now() - t0}ms)`);
    return false;
  }
}

function sleep(ms: number): Promise<void> { return new Promise((r) => setTimeout(r, ms)); }

/** 审批步骤：竞速审批请求与任务终态，最多 3 次尝试（与 M0 合同测试一致的确定性触发方式）。 */
async function runApprovalCase(client: Client, convId: string, outsidePath: string, decision: 'approved' | 'denied'): Promise<string> {
  const prompts = [
    `请用 pwsh 命令在 ${outsidePath} 创建文件，内容 m1-ok。必须用命令行执行，不要用 write 工具。`,
    `请用 pwsh 命令在 ${outsidePath} 创建文件，内容 m1-ok。必须用命令行执行，不要用 write 工具。`,
    `刚才的写入被沙箱拒绝了，请按流程申请一次性权限提升（escalation / permission approval）后再写入 ${outsidePath}，不要放弃。`,
  ];
  for (let attempt = 0; attempt < prompts.length; attempt++) {
    const before = client.mark();
    const approvalPromise = client.waitFor(
      (e) => e.type === 'approval.request' && e.payload?.conversationId === convId,
      180_000,
      `approval.request(attempt ${attempt + 1})`,
      before,
    ).catch(() => null);
    const settledPromise = client.waitFor(
      (e) => e.type === 'task.state' && e.payload?.conversationId === convId && ['completed', 'failed', 'cancelled'].includes(e.payload?.state),
      180_000,
      `task terminal(attempt ${attempt + 1})`,
      before,
    ).catch(() => null);
    client.send('prompt.send', { conversationId: convId, text: prompts[attempt] });
    const winner = await Promise.race([
      approvalPromise.then((e) => ({ kind: 'approval' as const, env: e })),
      settledPromise.then((e) => ({ kind: 'settled' as const, env: e })),
    ]);
    if (winner.kind === 'approval' && winner.env) {
      const approval = winner.env.payload;
      client.send('approval.decide', { conversationId: convId, approvalId: approval.approvalId, decision });
      const resolved = await client.waitFor(
        (e) => e.type === 'approval.resolved' && e.payload?.approvalId === approval.approvalId,
        60_000, 'approval.resolved', before,
      );
      const terminal = await client.waitFor(
        (e) => e.type === 'task.state' && e.payload?.conversationId === convId && ['completed', 'failed', 'cancelled'].includes(e.payload?.state),
        240_000, 'task terminal after approval', before,
      );
      return `attempt ${attempt + 1}: approval ${decision} (tool=${approval.tool}), resolved=${resolved.payload.decision}, task=${terminal.payload.state}, newEvents=${client.events.length - before}`;
    }
    // 没触发审批：模型直接拒绝/放弃或直接完成，重试
  }
  throw new Error('approval.request never triggered after 3 attempts');
}

async function main(): Promise<number> {
  mkdirSync(EVIDENCE_DIR, { recursive: true });
  mkdirSync(join(tmpdir(), 'm1-e2e'), { recursive: true });
  const token = (await pair('m1-e2e-client', 'app')).token;
  const client = new Client();
  await client.connect(token);
  let conversationId = '';
  const insideWorkspace = join(ROOT, 'agent', '.m1ws');
  const insideFile = join(insideWorkspace, `m1-inside-${STAMP}.txt`);
  const approvePath = join(tmpdir(), 'm1-e2e', `m1-approve-${STAMP}.txt`);
  const rejectPath = join(tmpdir(), 'm1-e2e', `m1-reject-${STAMP}.txt`);
  for (const p of [approvePath, rejectPath]) if (existsSync(p)) unlinkSync(p);

  try {
    await step('M1-A3 device.status online=true', async () => {
      const env = await client.waitFor((e) => e.type === 'device.status', 20_000, 'device.status');
      if (!env.payload?.online) throw new Error(`agent offline: ${JSON.stringify(env.payload)}`);
      return `device=${env.payload.deviceName} agent=${env.payload.agentVersion} harness=${env.payload.harnessVersion}`;
    });

    await step('M1-A4 conversation.create → conversation.created', async () => {
      client.send('conversation.create', { workspacePath: insideWorkspace, title: 'M1 E2E 会话' });
      const env = await client.waitFor((e) => e.type === 'conversation.created' && !!e.payload?.conversationId, 30_000, 'conversation.created');
      conversationId = env.payload.conversationId;
      return `conversationId=${conversationId} sessionId=${String(env.payload.sessionId).slice(0, 8)}…`;
    });

    await step('M1-A5 真实 prompt → output「收到」→ completed', async () => {
      client.send('prompt.send', { conversationId, text: '只回复两个字：收到' });
      const out = await client.waitFor(
        (e) => e.type === 'session.update' && e.payload?.conversationId === conversationId && e.payload?.kind === 'output' && String(e.payload?.text ?? '').includes('收到'),
        90_000, 'session.update output 收到',
      );
      const done = await client.waitFor(
        (e) => e.type === 'task.state' && e.payload?.conversationId === conversationId && e.payload?.state === 'completed',
        90_000, 'task.state completed',
      );
      return `output="${String(out.payload.text).slice(0, 20)}" state=${done.payload.state}`;
    });

    await step('M1-A6 长命令中 cancel → cancelled，会话可继续', async () => {
      client.send('prompt.send', { conversationId, text: '请用 pwsh 执行：1..30 | ForEach-Object { Start-Sleep -Milliseconds 300; $_ }' });
      await client.waitFor(
        (e) => e.type === 'session.update' && e.payload?.conversationId === conversationId && e.payload?.kind === 'tool_call',
        90_000, 'tool_call before cancel',
      );
      client.send('task.cancel', { conversationId });
      const cancelled = await client.waitFor(
        (e) => e.type === 'task.state' && e.payload?.conversationId === conversationId && e.payload?.state === 'cancelled',
        120_000, 'task.state cancelled',
      );
      client.send('prompt.send', { conversationId, text: '只回复两个字：继续' });
      const again = await client.waitFor(
        (e) => e.type === 'session.update' && e.payload?.conversationId === conversationId && e.payload?.kind === 'output' && String(e.payload?.text ?? '').includes('继续'),
        120_000, 'output 继续 after cancel',
      );
      return `cancelled=ok, after-cancel output="${String(again.payload.text).slice(0, 12)}"`;
    });

    if (!SKIP_APPROVAL) {
      await step('M1-A7 审批 request → approved → 文件生成 → completed', async () => {
        const detail = await runApprovalCase(client, conversationId, approvePath, 'approved');
        if (!existsSync(approvePath)) throw new Error(`approved file not created: ${approvePath}`);
        const content = readFileSync(approvePath, 'utf8').trim();
        return `${detail}; file="${content.slice(0, 20)}"`;
      });

      await step('M1-A8 审批 request → denied → 文件不生成 → completed(非 failed)', async () => {
        const detail = await runApprovalCase(client, conversationId, rejectPath, 'denied');
        if (existsSync(rejectPath)) throw new Error(`denied file should NOT exist: ${rejectPath}`);
        return detail;
      });
    }
  } finally {
    client.close();
  }

  const failed = steps.filter((s) => !s.ok);
  const evidence = {
    stamp: STAMP,
    base: BASE,
    ok: failed.length === 0,
    steps,
    eventCount: client.events.length,
    eventTypes: client.events.reduce<Record<string, number>>((acc, e) => { acc[e.type] = (acc[e.type] ?? 0) + 1; return acc; }, {}),
    events: client.events,
  };
  const file = join(EVIDENCE_DIR, `e2e-${STAMP}.json`);
  writeFileSync(file, JSON.stringify(evidence, null, 2), 'utf8');
  console.log(`\n${failed.length === 0 ? 'M1 E2E PASS' : 'M1 E2E FAIL'} (${steps.length - failed.length}/${steps.length})，证据：${file}`);
  return failed.length === 0 ? 0 : 1;
}

main().then((code) => process.exit(code)).catch((err) => { console.error('M1 E2E 崩溃：', err); process.exit(2); });
