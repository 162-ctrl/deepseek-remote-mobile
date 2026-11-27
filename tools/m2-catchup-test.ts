/**
 * M2.1 断线补偿端到端演练（模拟手机 App 断流 → 重连 → 事件补拉）
 *
 * 用法：
 *   node tools/m2-catchup-test.ts [--base http://127.0.0.1:8080] [--code 824613]
 *                                 [--drop-ms 60000] [--events-before-drop 2]
 *
 * 前置：后端（含 M2.1 events 端点）已启动、Agent 已连上、PostgreSQL 可用。
 * 验收：docs/design/M2_1_DELTA.md 的 M2.1-A2 / M2.1-A3。
 *
 * 流程：
 *   1) pair(app) → WSS → 建会话 → 发一条会持续十几秒的真实任务（pwsh 慢循环）
 *   2) 收到 N 个带 seq 的事件后**主动断流**（模拟地铁/电梯里没信号）
 *   3) 等待 drop-ms（默认 60s，可用 --drop-ms 300000 模拟 5 分钟）
 *   4) 重连 → GET /conversations/{id}/events?afterSeq=<断流前 lastSeq> 补拉
 *   5) 断言：补拉事件 seq 严格递增、> lastSeq、与断流前/重连后事件无重复；
 *      任务终态 completed 能在补拉或实时流中观察到（不丢终态）
 *
 * 证据：docs/research/evidence/m2/catchup-<stamp>.json
 */
import { mkdirSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

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
const DROP_MS = Number(arg('drop-ms', '60000'));
const EVENTS_BEFORE_DROP = Number(arg('events-before-drop', '2'));
const EVIDENCE_DIR = join(ROOT, 'docs', 'research', 'evidence', 'm2');
const WORKSPACE = join(ROOT, 'agent', '.m1ws');

function sleep(ms: number): Promise<void> { return new Promise((r) => setTimeout(r, ms)); }

async function pair(): Promise<string> {
  const res = await fetch(`${BASE}/api/v1/auth/pair`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ pairingCode: CODE, clientName: 'm2-catchup-test', role: 'app' }),
  });
  if (!res.ok) throw new Error(`pair failed: HTTP ${res.status} ${await res.text()}`);
  return ((await res.json()) as { token: string }).token;
}

function wsUrl(token: string): string {
  const u = new URL(BASE);
  u.protocol = u.protocol === 'https:' ? 'wss:' : 'ws:';
  u.pathname = '/ws';
  u.search = `?role=app&token=${encodeURIComponent(token)}`;
  return u.toString();
}

class App {
  readonly events: Envelope[] = [];
  private ws?: WebSocket;
  private waiters: Array<{ predicate: (e: Envelope) => boolean; label: string; resolve: (e: Envelope) => void; timer: NodeJS.Timeout }> = [];
  readonly label: string;

  constructor(label: string) { this.label = label; }

  connect(token: string): Promise<void> {
    return new Promise((resolvePromise, rejectPromise) => {
      const ws = new WebSocket(wsUrl(token));
      this.ws = ws;
      const timer = setTimeout(() => rejectPromise(new Error('ws open timeout')), 10_000);
      ws.addEventListener('open', () => { clearTimeout(timer); resolvePromise(); });
      ws.addEventListener('error', (ev: any) => { clearTimeout(timer); rejectPromise(new Error(`ws error: ${ev?.message ?? 'unknown'}`)); });
      ws.addEventListener('message', (ev: any) => {
        const text = typeof ev.data === 'string' ? ev.data : String(ev.data);
        let env: Envelope;
        try { env = JSON.parse(text) as Envelope } catch { return }
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

  waitFor(predicate: (e: Envelope) => boolean, timeoutMs: number, label: string, since = 0): Promise<Envelope> {
    const hit = this.events.slice(since).find(predicate);
    if (hit) return Promise.resolve(hit);
    return new Promise((resolvePromise, rejectPromise) => {
      const timer = setTimeout(() => {
        this.waiters = this.waiters.filter((w) => w.label !== label);
        rejectPromise(new Error(`timeout ${timeoutMs}ms waiting for ${label}`));
      }, timeoutMs);
      this.waiters.push({ predicate, label, resolve: resolvePromise, timer });
    });
  }

  send(type: string, payload: any): void {
    if (!this.ws || this.ws.readyState !== 1) throw new Error('ws not open');
    this.ws.send(JSON.stringify({ v: 1, type, id: `c_${Date.now()}_${Math.random().toString(36).slice(2, 7)}`, ts: new Date().toISOString(), payload }));
  }

  /** 主动断开（模拟手机没信号）；不等对端 close 握手。 */
  drop(): void {
    try { this.ws?.close(); } catch { /* ignore */ }
  }
}

async function getEvents(token: string, conversationId: string, afterSeq: number): Promise<any[]> {
  const out: any[] = [];
  let cursor = afterSeq;
  for (let page = 0; page < 20; page++) {
    const res = await fetch(`${BASE}/api/v1/conversations/${conversationId}/events?afterSeq=${cursor}&limit=500`, {
      headers: { authorization: `Bearer ${token}` },
    });
    if (!res.ok) throw new Error(`events failed: HTTP ${res.status} ${await res.text()}`);
    const body = (await res.json()) as { events: any[]; nextSeq?: number };
    const batch = body.events ?? [];
    out.push(...batch);
    if (batch.length < 500) break;
    cursor = batch[batch.length - 1].seq;
  }
  return out;
}

function seqOf(env: Envelope, conversationId: string): number | undefined {
  if (env.payload?.conversationId !== conversationId) return undefined;
  return typeof env.payload?.seq === 'number' ? env.payload.seq : undefined;
}

function seqsOf(events: Envelope[], conversationId: string): number[] {
  return events.map((e) => seqOf(e, conversationId)).filter((n): n is number => typeof n === 'number');
}

function checkMonotonic(seqs: number[], label: string): string | null {
  for (let i = 1; i < seqs.length; i++) {
    if (seqs[i] <= seqs[i - 1]) return `${label}: seq 非严格递增 @${i} (${seqs[i - 1]} -> ${seqs[i]})`;
  }
  return null;
}

async function main(): Promise<number> {
  mkdirSync(EVIDENCE_DIR, { recursive: true });
  const token = await pair();
  const client = new App('pre-drop');
  await client.connect(token);

  let conversationId = '';
  let lastSeqBeforeDrop = 0;
  const eventsBeforeDrop: Envelope[] = [];
  const eventsAfterReconnect: Envelope[] = [];
  let catchupEvents: any[] = [];
  const problems: string[] = [];

  try {
    // 1) 等 agent 上线并建会话
    await client.waitFor((e) => e.type === 'device.status' && e.payload?.online === true, 30_000, 'device.status online');
    client.send('conversation.create', { workspacePath: WORKSPACE, title: `M2.1 断线补偿演练 ${STAMP}` });
    const created = await client.waitFor((e) => e.type === 'conversation.created' && !!e.payload?.conversationId, 30_000, 'conversation.created');
    conversationId = created.payload.conversationId;
    lastSeqBeforeDrop = seqOf(created, conversationId) ?? 0;
    console.log(`conversationId=${conversationId} 初始 lastSeq=${lastSeqBeforeDrop}`);

    // 2) 发长任务：约 12–15 秒才能跑完，给断流留出窗口
    client.send('prompt.send', {
      conversationId,
      text: '请用 pwsh 执行这条命令，并把输出原样报告：1..15 | ForEach-Object { Start-Sleep -Milliseconds 700; Write-Output "tick $_" }',
    });

    // 3) 收到 N 个带 seq 的事件后主动断流
    const watchDeadline = Date.now() + 60_000;
    while (seqsOf(client.events, conversationId).length < EVENTS_BEFORE_DROP) {
      if (Date.now() > watchDeadline) throw new Error(`等待 ${EVENTS_BEFORE_DROP} 个带 seq 事件超时（当前 ${seqsOf(client.events, conversationId).length}）`);
      await sleep(300);
    }
    eventsBeforeDrop.push(...client.events);
    lastSeqBeforeDrop = Math.max(lastSeqBeforeDrop, ...seqsOf(eventsBeforeDrop, conversationId));
    const dropTime = new Date().toISOString();
    client.drop();
    console.log(`断流：时间=${dropTime} 断流前事件=${seqsOf(eventsBeforeDrop, conversationId).length} lastSeq=${lastSeqBeforeDrop}，等待 ${DROP_MS}ms…`);

    // 4) 断流期间后端继续接收 Agent 事件并落库
    await sleep(DROP_MS);

    // 5) 重连 + 补拉
    const live = new App('live-after');
    await live.connect(token);
    const catchup = await getEvents(token, conversationId, lastSeqBeforeDrop);
    catchupEvents = catchup;
    const catchupSeqs = catchup.map((e) => e.seq as number).filter((n) => typeof n === 'number');
    console.log(`重连补拉：${catchup.length} 条事件，seq ${catchupSeqs[0] ?? '-'}..${catchupSeqs[catchupSeqs.length - 1] ?? '-'}，等待终态…`);

    // 6) 断言补拉质量
    const catchupError = checkMonotonic(catchupSeqs, 'catchup');
    if (catchupError) problems.push(catchupError);
    if (catchupSeqs.some((s) => s <= lastSeqBeforeDrop)) problems.push('catchup: 存在 <= lastSeq 的事件（越界）');

    // 7) 终态不能丢：补拉事件或重连后的实时流里应看到 completed
    const terminalFromCatchup = catchup.some((e) => e.type === 'task.state' && e.payload?.state === 'completed');
    let terminalEnv: Envelope | undefined;
    if (!terminalFromCatchup) {
      terminalEnv = await live.waitFor(
        (e) => e.type === 'task.state' && e.payload?.conversationId === conversationId && e.payload?.state === 'completed',
        180_000, 'task.state completed after reconnect', 0,
      );
    }
    if (!terminalFromCatchup && !terminalEnv) problems.push('终态 completed 既不在补拉里也没等到');

    // 8) 等重连后实时流稳定，收集并检查全局 seq 唯一性
    await sleep(1500);
    eventsAfterReconnect.push(...live.events);
    const beforeSeqs = seqsOf(eventsBeforeDrop, conversationId);
    const afterSeqs = seqsOf(eventsAfterReconnect, conversationId);
    const allSeqs = [...beforeSeqs, ...catchupSeqs, ...afterSeqs];
    const dup = allSeqs.length - new Set(allSeqs).size;
    if (dup > 0) problems.push(`seq 重复 ${dup} 个`);

    const evidence = {
      stamp: STAMP,
      base: BASE,
      dropMs: DROP_MS,
      conversationId,
      workspace: WORKSPACE,
      dropTime,
      lastSeqBeforeDrop,
      beforeDrop: { count: beforeSeqs.length, seqs: beforeSeqs, eventTypes: eventsBeforeDrop.map((e) => e.type) },
      catchup: {
        count: catchup.length,
        seqs: catchupSeqs,
        nextSeq: catchupSeqs.length ? catchupSeqs[catchupSeqs.length - 1] + 1 : null,
        eventTypes: catchup.map((e) => `${e.type}${e.kind ? '/' + e.kind : ''}`),
        terminalFromCatchup,
      },
      afterReconnect: { count: afterSeqs.length, seqs: afterSeqs, eventTypes: eventsAfterReconnect.map((e) => e.type) },
      totals: { seqCount: allSeqs.length, uniqueSeqCount: new Set(allSeqs).size, duplicates: dup },
      throughput: {
        eventsWhileDropped: catchup.length,
        elapsedMs: DROP_MS,
      },
      problems,
      ok: problems.length === 0 && (catchup.length > 0 || terminalFromCatchup),
    };
    const file = join(EVIDENCE_DIR, `catchup-${STAMP}.json`);
    writeFileSync(file, JSON.stringify(evidence, null, 2), 'utf8');
    console.log(`\n${evidence.ok ? 'M2.1 CATCHUP PASS' : 'M2.1 CATCHUP FAIL'}：断流 ${DROP_MS}ms 期间补拉 ${catchup.length} 条事件，seq 唯一 ${new Set(allSeqs).size}/${allSeqs.length}，终态=${terminalFromCatchup ? '来自补拉' : '来自实时流'}`);
    if (problems.length) { console.log('问题：'); for (const p of problems) console.log(` - ${p}`); }
    console.log(`证据：${file}`);
    return evidence.ok ? 0 : 1;
  } finally {
    client.drop();
  }
}

main().then((code) => process.exit(code)).catch((err) => { console.error('M2.1 CATCHUP 崩溃：', err); process.exit(2); });
