/**
 * M2.6 项目同步往返验证（WSS 真实链路）。
 *
 * 用法：node tools/verify-project-sync.ts [--base http://127.0.0.1:8080] [--code 824613] [--dir .]
 *
 * 覆盖：
 *  - workspace.list 根目录 / 子目录（排序、忽略项、path 前缀）
 *  - file.read 文本文件（content/sha256/size）
 *  - 错误：FILE_NOT_FOUND、PATH_NOT_ALLOWED
 *  - A4：conversation.create 绑定子目录工作区 + prompt 让 Harness 打印 PWD
 * 证据：docs/research/evidence/m2/project-sync-<stamp>.json
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
const SUB_DIR = arg('dir', 'docs/research');

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
    body: JSON.stringify({ pairingCode: CODE, clientName: 'verify-project-sync', role: 'app' }),
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
    const id = `vps_${++seq}`;
    ws.send(JSON.stringify({ v: 1, type, id, ts: new Date().toISOString(), payload }));
    return id;
  };
  /** 请求-响应类消息：把 requestId 写进 payload 并返回它（Agent 会原样回显）。 */
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
  const workspaceRoots = (status.payload?.workspaceRoots ?? []) as string[];
  const root = workspaceRoots[0] ?? '';
  const caps = status.payload?.capabilities ?? {};
  record('device.status.workspaceRoots', workspaceRoots.length >= 1 && !!root, JSON.stringify(workspaceRoots));
  record('device.status.capabilities.workspaceList', caps.workspaceList === true, JSON.stringify(caps));

  const listRoundTrip = async (relativePath: string, label: string): Promise<any> => {
    const requestId = sendRequest('workspace.list', { workspacePath: root, relativePath });
    const res = await waitFor(
      (e) => e.type === 'workspace.list.result' && e.payload?.requestId === requestId,
      30_000,
      `workspace.list.result(${label})`,
    );
    return res.payload;
  };

  const rootList = await listRoundTrip('', 'root');
  const names: string[] = (rootList.entries ?? []).map((entry: any) => entry.name);
  record('workspace.list 根目录 ok', rootList.ok === true, `entries=${names.length} ignored=${rootList.ignoredCount}`);
  record(
    'workspace.list 根目录含项目关键目录',
    names.includes('agent') && names.includes('app') && names.includes('backend') && names.includes('docs'),
    names.slice(0, 8).join(','),
  );
  record('workspace.list 忽略 node_modules/.git', !names.includes('node_modules') && !names.includes('.git'), `entries=${names.join(',')}`);
  record(
    'workspace.list 目录在前',
    (rootList.entries?.[0]?.isDir ?? false) === true,
    `first=${rootList.entries?.[0]?.name}`,
  );

  const subList = await listRoundTrip(SUB_DIR, SUB_DIR);
  const subPaths: string[] = (subList.entries ?? []).map((entry: any) => entry.path);
  record(
    `workspace.list 子目录 ${SUB_DIR}`,
    subList.ok === true && subPaths.every((p) => p.startsWith(`${SUB_DIR}/`)),
    subPaths.slice(0, 5).join(','),
  );

  const readRequestId = sendRequest('file.read', { workspacePath: root, relativePath: 'README.md' });
  const readRes = await waitFor(
    (e) => e.type === 'file.read.result' && e.payload?.requestId === readRequestId,
    30_000,
    'file.read.result(README.md)',
  );
  const content = String(readRes.payload?.content ?? '');
  record('file.read README.md ok', readRes.payload?.ok === true, `size=${readRes.payload?.size} truncated=${readRes.payload?.truncated}`);
  record('file.read 返回 sha256', typeof readRes.payload?.sha256 === 'string' && readRes.payload.sha256.length === 64, readRes.payload?.sha256);
  record('file.read 内容像 Markdown', content.includes('#'), content.slice(0, 40).replace(/\n/g, ' '));

  const missingId = sendRequest('file.read', { workspacePath: root, relativePath: 'no-such-file-m26.txt' });
  const missing = await waitFor(
    (e) => e.type === 'file.read.result' && e.payload?.requestId === missingId && e.payload?.ok === false,
    15_000,
    'file.read.result(FILE_NOT_FOUND)',
  );
  record('缺失文件 → FILE_NOT_FOUND', missing.payload?.code === 'FILE_NOT_FOUND', String(missing.payload?.code));

  const escapeId = sendRequest('workspace.list', { workspacePath: root, relativePath: '../..' });
  const escape = await waitFor(
    (e) => e.type === 'workspace.list.result' && e.payload?.requestId === escapeId && e.payload?.ok === false,
    15_000,
    'workspace.list.result(PATH_NOT_ALLOWED)',
  );
  record('越界路径 → PATH_NOT_ALLOWED', escape.payload?.code === 'PATH_NOT_ALLOWED', String(escape.payload?.code));

  // A4：会话绑定子目录工作区（项目内发指令）
  send('conversation.create', { title: 'M2.6 项目内指令验证', workspacePath: `${root}\\${SUB_DIR.replace(/\//g, '\\')}` });
  const created = await waitFor((e) => e.type === 'conversation.created' && !!e.payload?.conversationId, 90_000, 'conversation.created');
  const conversationId = created.payload.conversationId as string;
  const createdPath = String(created.payload?.workspacePath ?? '');
  record('conversation.create 绑定子目录工作区', createdPath.endsWith(SUB_DIR.replace(/\//g, '\\')), createdPath);

  send('prompt.send', { conversationId, text: '只读验证，不要修改文件。请用一条命令打印当前工作目录（pwd 或 Get-Location）。' });
  const outputs: string[] = [];
  let terminal: string | null = null;
  let approvals = 0;
  const deadline = Date.now() + 180_000;
  while (Date.now() < deadline && !terminal) {
    const env = await waitFor(
      (e) =>
        (e.type === 'session.update' && e.payload?.conversationId === conversationId) ||
        (e.type === 'approval.request' && e.payload?.conversationId === conversationId) ||
        (e.type === 'task.state' && e.payload?.conversationId === conversationId),
      180_000,
      'session.update/approval/task.state',
    );
    if (env.type === 'session.update' && env.payload?.kind === 'output') outputs.push(String(env.payload?.text ?? ''));
    if (env.type === 'approval.request' && approvals < 2) {
      approvals++;
      send('approval.decide', { conversationId, approvalId: env.payload?.approvalId, decision: 'approved' });
    }
    if (env.type === 'task.state' && ['completed', 'failed', 'cancelled'].includes(env.payload?.state)) {
      terminal = env.payload.state as string;
    }
  }
  const harnessText = outputs.join('\n');
  record(
    'A4 项目内指令执行完成',
    terminal === 'completed' && harnessText.includes(SUB_DIR.replace(/\//g, '\\')),
    `state=${terminal} approvals=${approvals} output=${harnessText.slice(0, 120).replace(/\s+/g, ' ')}`,
  );

  mkdirSync(EVIDENCE_DIR, { recursive: true });
  const evidencePath = join(EVIDENCE_DIR, `project-sync-${STAMP}.json`);
  const failed = results.filter((r) => !r.ok);
  writeFileSync(
    evidencePath,
    JSON.stringify(
      {
        at: new Date().toISOString(),
        base: BASE,
        workspaceRoots,
        capabilities: caps,
        rootEntries: names,
        subEntries: subPaths,
        read: { size: readRes.payload?.size, sha256: readRes.payload?.sha256, truncated: readRes.payload?.truncated },
        conversationId,
        conversationWorkspacePath: createdPath,
        harnessOutput: harnessText.slice(0, 2000),
        terminal,
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
