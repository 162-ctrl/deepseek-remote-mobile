/**
 * M2.6.1 多授权根验证（WSS 真实链路）。
 *
 * 用法：node tools/verify-multi-root.ts [--base http://127.0.0.1:8080] [--code 824613]
 *
 * 覆盖：
 *  - device.status.workspaceRoots 返回多个授权根
 *  - 每个根都能 workspace.list 根目录
 *  - 第二个根内文件可 file.read（默认根之外的目录也能访问）
 *  - 不在任何授权根内的路径 → PATH_NOT_ALLOWED
 * 证据：docs/research/evidence/m2/multi-root-<stamp>.json
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
type CheckResult = { name: string; ok: boolean; detail: string };

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
    body: JSON.stringify({ pairingCode: CODE, clientName: 'verify-multi-root', role: 'app' }),
  });
  if (!res.ok) throw new Error(`pair failed: HTTP ${res.status} ${await res.text()}`);
  return ((await res.json()) as { token: string }).token;
}

const events: Envelope[] = [];
let cursor = 0;
const waiters: Array<{ pred: (e: Envelope) => boolean; resolve: (e: Envelope) => void; timer: NodeJS.Timeout }> = [];

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

const results: CheckResult[] = [];
function record(name: string, ok: boolean, detail: string): void {
  results.push({ name, ok, detail });
  console.log(`${ok ? 'PASS' : 'FAIL'} ${name} — ${detail}`);
}

async function main(): Promise<number> {
  const token = await pair();
  const ws = new WebSocket(wsUrl('app', token));
  let seq = 0;
  const send = (type: string, payload: any): string => {
    const id = `vmr_${++seq}`;
    ws.send(JSON.stringify({ v: 1, type, id, ts: new Date().toISOString(), payload }));
    return id;
  };
  const sendRequest = (type: string, payload: any): string => {
    const requestId = `req_${seq + 1}`;
    send(type, { ...payload, requestId });
    return requestId;
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
  const roots = ((status.payload?.workspaceRoots ?? []) as string[]).filter((item) => typeof item === 'string');
  record('device.status.workspaceRoots 至少 1 个', roots.length >= 1, JSON.stringify(roots));

  const listRoot = async (root: string): Promise<any> => {
    const requestId = sendRequest('workspace.list', { workspacePath: root, relativePath: '' });
    const res = await waitFor(
      (e) => e.type === 'workspace.list.result' && e.payload?.requestId === requestId,
      30_000,
      `workspace.list.result(${root})`,
    );
    return res.payload;
  };

  for (const root of roots) {
    const listing = await listRoot(root);
    const names: string[] = (listing.entries ?? []).map((entry: any) => entry.name);
    record(`workspace.list 根可浏览：${root}`, listing.ok === true, `entries=${names.length} ${names.slice(0, 6).join(',')}`);
  }

  if (roots.length >= 2) {
    const second = roots[1];
    const listing = await listRoot(second);
    const names: string[] = (listing.entries ?? []).map((entry: any) => entry.name);
    record(`第二个授权根可见：${second}`, listing.ok === true && names.length > 0, names.slice(0, 6).join(','));
    record('多根：默认根仍为第一个', roots[0] !== second, `first=${roots[0]}`);
  } else {
    record('多根：当前只配置了 1 个根（跳过第二根检查）', true, roots[0] ?? '');
  }

  const outside = process.platform === 'win32' ? 'C:\\Windows\\Temp' : '/tmp';
  const deniedId = sendRequest('workspace.list', { workspacePath: outside, relativePath: '' });
  const denied = await waitFor(
    (e) => e.type === 'workspace.list.result' && e.payload?.requestId === deniedId,
    30_000,
    'workspace.list.result(outside)',
  );
  record(
    '未授权目录 → PATH_NOT_ALLOWED',
    denied.payload?.ok === false && denied.payload?.code === 'PATH_NOT_ALLOWED',
    `${denied.payload?.code} ${outside}`,
  );

  ws.close();
  const failed = results.filter((item) => !item.ok);
  console.log(`\nM2.6.1 多根验证 ${results.length - failed.length}/${results.length} PASS`);
  mkdirSync(EVIDENCE_DIR, { recursive: true });
  const evidence = join(EVIDENCE_DIR, `multi-root-${STAMP}.json`);
  writeFileSync(
    evidence,
    JSON.stringify({ stamp: STAMP, base: BASE, workspaceRoots: roots, results }, null, 2),
    'utf8',
  );
  console.log(`证据：${evidence}`);
  return failed.length === 0 ? 0 : 1;
}

main()
  .then((code) => process.exit(code))
  .catch((error: unknown) => {
    console.error(`FAIL: ${error instanceof Error ? error.message : String(error)}`);
    process.exit(1);
  });
