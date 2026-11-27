/**
 * M2.8 手机端写文件往返验证（WSS 真实链路）。
 *
 * 用法：node tools/verify-file-write.ts [--base http://127.0.0.1:8787] [--code 000000]
 *
 * 覆盖：
 *  - device.status.capabilities.fileWrite
 *  - file.write 新建（无 baseSha256，created=true，sha256 与本地计算一致）
 *  - file.write 已存在但无 base → FILE_EXISTS
 *  - file.write 陈旧 base → CONFLICT，且磁盘内容未被改动
 *  - file.write 正确 base 覆盖 → created=false，sha256 更新
 *  - file.write 越界路径 → PATH_NOT_ALLOWED
 *  - 用 file.read 回读校验（内容 + sha256）
 * 证据：docs/research/evidence/m2/file-write-<stamp>.json
 */
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const EVIDENCE_DIR = join(ROOT, 'docs', 'research', 'evidence', 'm2');
const STAMP = new Date().toISOString().replace(/[:.]/g, '-');

function arg(name: string, fallback: string): string {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

const BASE = arg('base', 'http://127.0.0.1:8787').replace(/\/+$/, '');
const CODE = arg('code', '000000');
const PROBE_DIR = 'docs/research/evidence/m2';
const REL_PATH = `${PROBE_DIR}/write-probe-${STAMP}.md`;

type Envelope = { v: number; type: string; id: string; ts: string; payload: any };
type CheckResult = { name: string; ok: boolean; detail: string };

function sha256(text: string): string {
  return createHash('sha256').update(Buffer.from(text, 'utf8')).digest('hex');
}

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
    body: JSON.stringify({ pairingCode: CODE, clientName: 'verify-file-write', role: 'app' }),
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
    const id = `vfw_${++seq}`;
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

  // Hub 先发骨架状态，Agent 的状态带 workspaceRoots；等后者。
  const status = await waitFor(
    (e) => e.type === 'device.status' && (e.payload?.workspaceRoots ?? []).length > 0,
    20_000,
    'device.status(workspaceRoots)',
  );
  const workspaceRoots = (status.payload?.workspaceRoots ?? []) as string[];
  // 授权根有多个，挑出本仓库（用脚本自身当标记），否则用第一个。
  const root =
    workspaceRoots.find((candidate) => existsSync(join(candidate, 'tools', 'verify-file-write.ts'))) ??
    workspaceRoots[0] ??
    '';
  const absPath = join(root, PROBE_DIR, `write-probe-${STAMP}.md`);
  const caps = status.payload?.capabilities ?? {};
  record('device.status.workspaceRoots', workspaceRoots.length >= 1 && !!root, JSON.stringify(workspaceRoots));
  record('device.status.capabilities.fileWrite', caps.fileWrite === true, JSON.stringify(caps));

  const writeRoundTrip = async (payload: any, label: string): Promise<any> => {
    const requestId = sendRequest('file.write', { workspacePath: root, ...payload });
    const res = await waitFor(
      (e) => e.type === 'file.write.result' && e.payload?.requestId === requestId,
      30_000,
      `file.write.result(${label})`,
    );
    return res.payload;
  };

  const readRoundTrip = async (relativePath: string): Promise<any> => {
    const requestId = sendRequest('file.read', { workspacePath: root, relativePath });
    const res = await waitFor(
      (e) => e.type === 'file.read.result' && e.payload?.requestId === requestId,
      30_000,
      `file.read.result(${relativePath})`,
    );
    return res.payload;
  };

  mkdirSync(dirname(absPath), { recursive: true });
  rmSync(absPath, { force: true });

  const v1 = `# M2.8 写入验证\n\n第一版 ${STAMP}\n`;
  const created = await writeRoundTrip({ relativePath: REL_PATH, content: v1 }, 'create');
  record('file.write 新建 ok', created.ok === true && created.created === true, JSON.stringify({ size: created.size, sha256: created.sha256 }));
  record('file.write 新建 sha256 与本地一致', created.sha256 === sha256(v1), String(created.sha256));
  record('file.write 新建 created=true', created.created === true, String(created.created));
  record(
    '磁盘内容与写入一致',
    readFileSync(absPath, 'utf8') === v1,
    `bytes=${readFileSync(absPath).length}`,
  );

  const readBack = await readRoundTrip(REL_PATH);
  record('file.read 回读一致', readBack.ok === true && readBack.content === v1 && readBack.sha256 === sha256(v1), `size=${readBack.size}`);

  const exists = await writeRoundTrip({ relativePath: REL_PATH, content: 'x' }, 'exists');
  record('无 base 覆盖已存在文件 → FILE_EXISTS', exists.ok === false && exists.code === 'FILE_EXISTS', String(exists.code));

  const stale = await writeRoundTrip(
    { relativePath: REL_PATH, content: 'should not land', baseSha256: '0'.repeat(64) },
    'stale',
  );
  record('陈旧 baseSha256 → CONFLICT', stale.ok === false && stale.code === 'CONFLICT', String(stale.code));
  record('冲突后磁盘内容未被改动', readFileSync(absPath, 'utf8') === v1, 'unchanged');

  const v2 = `# M2.8 写入验证\n\n第二版 ${STAMP}\n`;
  const overwritten = await writeRoundTrip(
    { relativePath: REL_PATH, content: v2, baseSha256: sha256(v1) },
    'overwrite',
  );
  record('正确 baseSha256 覆盖 ok', overwritten.ok === true && overwritten.created === false, JSON.stringify({ created: overwritten.created }));
  record('覆盖后 sha256 更新', overwritten.sha256 === sha256(v2), String(overwritten.sha256));
  record('覆盖后磁盘内容更新', readFileSync(absPath, 'utf8') === v2, `bytes=${readFileSync(absPath).length}`);

  const escape = await writeRoundTrip({ relativePath: '../escape-m28.txt', content: 'nope' }, 'escape');
  record('越界路径 → PATH_NOT_ALLOWED', escape.ok === false && escape.code === 'PATH_NOT_ALLOWED', String(escape.code));

  mkdirSync(EVIDENCE_DIR, { recursive: true });
  const evidencePath = join(EVIDENCE_DIR, `file-write-${STAMP}.json`);
  const failed = results.filter((r) => !r.ok);
  writeFileSync(
    evidencePath,
    JSON.stringify(
      {
        at: new Date().toISOString(),
        base: BASE,
        workspaceRoots,
        capabilities: caps,
        relPath: REL_PATH,
        firstSha256: sha256(v1),
        secondSha256: sha256(v2),
        created: { size: created.size, sha256: created.sha256, created: created.created },
        overwritten: { size: overwritten.size, sha256: overwritten.sha256, created: overwritten.created },
        results,
        passed: results.length - failed.length,
        total: results.length,
      },
      null,
      2,
    ),
    'utf8',
  );

  console.log(`---- ${results.length - failed.length}/${results.length} PASS ----`);
  console.log(`probe file: ${absPath}`);
  console.log(`evidence: ${evidencePath}`);

  ws.close();
  return failed.length === 0 ? 0 : 1;
}

main().then(
  (code) => process.exit(code),
  (err) => {
    console.error(`FAIL: ${err instanceof Error ? err.message : String(err)}`);
    process.exit(1);
  },
);
