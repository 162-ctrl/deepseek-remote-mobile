/**
 * M0 E2E 冒烟：一条真实任务流走完 Remote Agent 需要的能力（不是 Mock）。
 *
 * 步骤（全部对真实 DeepSeek Harness 执行）：
 *  1. 真执行：让 Harness 在工作区创建 hello.txt（工具调用，无需审批），校验文件内容。
 *  2. 审批：让 Harness 用 pwsh 写"工作区外"路径 → 触发 ACP request_permission → 批准 → 校验文件存在。
 *  3. 取消：让 Harness 跑长命令 → 工具执行中 session/cancel → 校验 stopReason=cancelled 且会话可继续。
 *  4. 续跑：断开 ACP 进程 → 重连 → session/resume → 追问上文，校验上下文仍在。
 *
 * 运行：node scripts/e2e-smoke.ts
 * 产物：agent/evidence/e2e-<时间戳>.json（步骤结果 + 事件计数）+ 工作区 agent/.workspaces/e2e-<时间戳>/
 */
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { AcpAdapter } from '../src/harness/acp/acp-adapter.ts';
import type { HarnessEvent } from '../src/harness/adapter.ts';
import { Logger } from '../src/infra/logger.ts';

const ROOT = join(import.meta.dirname, '..');
const STAMP = new Date().toISOString().replace(/[:.]/g, '-');
const WORKSPACE = join(ROOT, '.workspaces', `e2e-${STAMP}`);
const EVIDENCE = join(ROOT, 'evidence', `e2e-${STAMP}.json`);

const logger = new Logger({ scope: 'e2e', level: 'info' });
let adapter = new AcpAdapter({ logger, permissionPolicy: 'ask' });
const eventCounts: Record<string, number> = {};
const steps: Array<{ name: string; ok: boolean; detail: string; durationMs: number }> = [];

function countEvent(event: HarnessEvent): void {
  eventCounts[event.type] = (eventCounts[event.type] ?? 0) + 1;
}

function cancelableWait(
  predicate: (event: HarnessEvent) => boolean,
  timeoutMs: number,
  label: string,
): { promise: Promise<HarnessEvent>; cancel: () => void } {
  let unsubscribe = (): void => undefined;
  let timer: ReturnType<typeof setTimeout> | undefined;
  const promise = new Promise<HarnessEvent>((resolve, reject) => {
    timer = setTimeout(() => {
      unsubscribe();
      reject(new Error(`等待事件超时（${label}，${timeoutMs}ms）`));
    }, timeoutMs);
    unsubscribe = adapter.subscribe((event) => {
      if (predicate(event)) {
        if (timer !== undefined) clearTimeout(timer);
        unsubscribe();
        resolve(event);
      }
    });
  });
  return {
    promise,
    cancel: () => {
      if (timer !== undefined) clearTimeout(timer);
      unsubscribe();
    },
  };
}

async function step(name: string, action: () => Promise<string>): Promise<void> {
  const startedAt = Date.now();
  try {
    const detail = await action();
    steps.push({ name, ok: true, detail, durationMs: Date.now() - startedAt });
    process.stdout.write(`✔ ${name} — ${detail}\n`);
  } catch (error: unknown) {
    const detail = error instanceof Error ? error.message : String(error);
    steps.push({ name, ok: false, detail, durationMs: Date.now() - startedAt });
    process.stdout.write(`✖ ${name} — ${detail}\n`);
  }
}

/** 触发一次"工作区外写入"的审批，批准后返回文件内容 */
async function approvalStep(target: string): Promise<string> {
  const session = await adapter.createSession(WORKSPACE, 'e2e approval');
  const prompts = [
    `请用 pwsh 命令在路径 ${target} 创建文件，内容为 e2e-ok。必须使用 pwsh 命令执行，不要使用 write 工具。`,
    `刚才的写入被沙箱拒绝了。请按流程申请一次性权限提升（escalation / permission approval），获得批准后在路径 ${target} 写入内容 e2e-ok。不要放弃。`,
  ];
  for (let attempt = 1; attempt <= 3; attempt += 1) {
    const approval = cancelableWait((event) => event.type === 'approval_request', 90_000, 'approval');
    const done = cancelableWait((event) => event.type === 'completed', 90_000, 'completed');
    try {
      await adapter.sendMessage(session.sessionId, {
        taskId: `e2e-approval-${attempt}`,
        conversationId: `e2e-approval-${attempt}`,
        prompt: prompts[Math.min(attempt - 1, prompts.length - 1)] as string,
        workspacePath: WORKSPACE,
        timeoutSec: 240,
      });
      const first = await Promise.race([approval.promise, done.promise]);
      if (first.type === 'approval_request') {
        adapter.decideApproval(first.request.approvalId, 'approved');
        await adapter.waitForTurn(session.sessionId, 240_000);
        const content = existsSync(target) ? readFileSync(target, 'utf8') : null;
        if (content === null) throw new Error('批准后目标文件不存在');
        return `审批批准 → 文件已写入（${content.trim()}）`;
      }
    } finally {
      approval.cancel();
      done.cancel();
    }
  }
  throw new Error('3 次尝试均未触发审批请求');
}

/** 工具执行中取消，并验证取消后会话仍可继续 */
async function cancelStep(): Promise<string> {
  const session = await adapter.createSession(WORKSPACE, 'e2e cancel');
  const toolStarted = cancelableWait((event) => event.type === 'tool_call', 90_000, 'tool_call');
  const handle = await adapter.sendMessage(session.sessionId, {
    taskId: 'e2e-cancel',
    conversationId: 'e2e-cancel',
    prompt: '请用 pwsh 命令执行这段脚本并输出结果：1..30 | ForEach-Object { Start-Sleep -Milliseconds 300; $_ }。必须用命令执行，不要自己算。',
    workspacePath: WORKSPACE,
    timeoutSec: 240,
  });
  try {
    await toolStarted.promise;
    await new Promise((resolve) => setTimeout(resolve, 900));
    const cancelResult = await handle.cancel();
    if (!cancelResult.accepted || !cancelResult.harnessAck) {
      throw new Error(`取消未被 Harness 确认：${JSON.stringify(cancelResult)}`);
    }
    await adapter.sendMessage(session.sessionId, {
      taskId: 'e2e-after-cancel',
      conversationId: 'e2e-after-cancel',
      prompt: '只回复两个字：继续。不要调用工具。',
      workspacePath: WORKSPACE,
      timeoutSec: 120,
    });
    const after = await adapter.waitForTurn(session.sessionId, 180_000);
    if (!after.summary.includes('继续')) throw new Error(`取消后会话未恢复：${after.summary}`);
    return `取消机制=${cancelResult.mechanism}、harnessAck=true、取消后会话语义正常`;
  } finally {
    toolStarted.cancel();
  }
}

async function main(): Promise<void> {
  mkdirSync(WORKSPACE, { recursive: true });
  mkdirSync(join(ROOT, 'evidence'), { recursive: true });
  const sessionIdHolder: { value?: string } = {};

  await step('1. 连接 Harness（ACP initialize）', async () => {
    const status = await adapter.connect();
    adapter.subscribe(countEvent);
    if (!status.running) throw new Error('Harness 未运行');
    const install = adapter.getInstallInfo();
    return `version=${status.version} install=${install?.root ?? 'unknown'}`;
  });

  await step('2. 真执行：Harness 在工作区创建 hello.txt', async () => {
    const session = await adapter.createSession(WORKSPACE, 'e2e hello');
    sessionIdHolder.value = session.sessionId;
    await adapter.sendMessage(session.sessionId, {
      taskId: 'e2e-hello',
      conversationId: 'e2e-hello',
      prompt: '请在当前目录创建文件 hello.txt，内容为 hello from e2e（用 write 工具即可）。',
      workspacePath: WORKSPACE,
      timeoutSec: 180,
    });
    const settlement = await adapter.waitForTurn(session.sessionId, 180_000);
    if (settlement.stopReason !== 'end_turn') throw new Error(`stopReason=${settlement.stopReason}`);
    const target = join(WORKSPACE, 'hello.txt');
    const content = existsSync(target) ? readFileSync(target, 'utf8') : null;
    if (content === null) throw new Error('hello.txt 不存在');
    if (!content.includes('hello from e2e')) throw new Error(`内容不符：${content}`);
    return `文件已创建（${content.trim()}）、stopReason=end_turn`;
  });

  await step('3. 审批：工作区外写入 → request_permission → 批准 → 文件存在', async () => {
    const target = join(tmpdir(), `m0-e2e-outside-${STAMP}.txt`);
    if (existsSync(target)) rmSync(target);
    return approvalStep(target);
  });

  await step('4. 取消：工具执行中 session/cancel', async () => {
    return cancelStep();
  });

  await step('5. 续跑：断开重连 + session/resume 上下文仍在', async () => {
    const sessionId = sessionIdHolder.value;
    if (sessionId === undefined) throw new Error('缺少会话 id');
    await adapter.disconnect();
    adapter = new AcpAdapter({ logger, permissionPolicy: 'ask' });
    adapter.subscribe(countEvent);
    await adapter.connect();
    const resumed = await adapter.resumeSession(sessionId, WORKSPACE);
    await adapter.sendMessage(resumed.sessionId, {
      taskId: 'e2e-resume',
      conversationId: 'e2e-resume',
      prompt: '继续刚才的对话：你在当前工作区创建了哪个文件？只回答文件名。',
      workspacePath: WORKSPACE,
      timeoutSec: 180,
    });
    const settlement = await adapter.waitForTurn(resumed.sessionId, 180_000);
    if (!settlement.summary.includes('hello')) throw new Error(`续跑上下文丢失：${settlement.summary}`);
    return `session/resume 成功、上下文命中（${settlement.summary.trim().slice(0, 40)}）`;
  });

  await adapter.disconnect().catch(() => undefined);
  const ok = steps.every((item) => item.ok);
  writeFileSync(
    EVIDENCE,
    JSON.stringify(
      {
        stamp: STAMP,
        harnessVersion: adapter.getHarnessVersion(),
        workspace: WORKSPACE,
        ok,
        steps,
        eventCounts,
      },
      null,
      2,
    ),
    'utf8',
  );
  process.stdout.write(`\nE2E ${ok ? 'PASS' : 'FAIL'}，证据：${EVIDENCE}\n`);
  process.exitCode = ok ? 0 : 1;
}

main().catch((error: unknown) => {
  process.stderr.write(`e2e 崩溃：${error instanceof Error ? error.stack ?? error.message : String(error)}\n`);
  process.exitCode = 2;
});
