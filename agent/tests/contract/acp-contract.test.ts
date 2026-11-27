/**
 * M0 合同测试（Contract Test）：用真实 DeepSeek Harness 验证 ACP 契约。
 *
 * 运行：node --test tests/contract/acp-contract.test.ts
 * 前提：本机已安装并登录 DeepSeek Harness（dsh --version 可用）。
 * 产物：agent/evidence/contract-<时间戳>.jsonl（逐事件证据）+ 工作区 agent/.workspaces/contract-<时间戳>/。
 *
 * 断言原则：只断言实测行为（H-xx 已确认项），不假设未验证能力。
 */
import { after, before, describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { AcpAdapter, type TurnSettlement } from '../../src/harness/acp/acp-adapter.ts';
import type { ApprovalRequest, HarnessEvent } from '../../src/harness/adapter.ts';
import { Logger } from '../../src/infra/logger.ts';

const STAMP = new Date().toISOString().replace(/[:.]/g, '-');
const ROOT = join(import.meta.dirname, '..', '..');
const WORKSPACE = join(ROOT, '.workspaces', `contract-${STAMP}`);
const EVIDENCE = join(ROOT, 'evidence', `contract-${STAMP}.jsonl`);

let adapter: AcpAdapter;
const evidence: string[] = [];
/** 仅取消用例使用：自动批准审批请求，使取消发生在工具执行中 */
let autoApproveApprovals = false;

function attachRecorder(target: AcpAdapter): void {
  target.subscribe((event) => {
    record({ event });
    if (event.type === 'approval_request' && autoApproveApprovals) {
      target.decideApproval(event.request.approvalId, 'approved');
    }
  });
}

function record(entry: unknown): void {
  evidence.push(JSON.stringify({ at: new Date().toISOString(), ...(entry as object) }));
  mkdirSync(join(ROOT, 'evidence'), { recursive: true });
  writeFileSync(EVIDENCE, evidence.join('\n') + '\n', 'utf8');
}

/** 等待某个事件（含已发生的事件不追溯：订阅必须在动作之前） */
function waitForEvent(
  predicate: (event: HarnessEvent) => boolean,
  timeoutMs: number,
  label: string,
): Promise<HarnessEvent> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      unsubscribe();
      reject(new Error(`等待事件超时（${label}，${timeoutMs}ms）`));
    }, timeoutMs);
    const unsubscribe = adapter.subscribe((event) => {
      if (predicate(event)) {
        clearTimeout(timer);
        unsubscribe();
        resolve(event);
      }
    });
  });
}

/** 可取消的事件等待：用于"审批 or 完成"竞争，避免超时定时器拖住测试进程 */
function waitForEventCancelable(
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

type ApprovalDecision = 'approved' | 'denied';

/**
 * 触发一次 ACP request_permission 并按 decision 裁决。
 *
 * 实测结论（M0）：
 * - 工作区内的普通写命令会被沙箱自动放行，不触发审批；写入工作区外路径才会触发"一次性权限提升"审批。
 * - 模型第一次被沙箱拒绝后，有时会直接放弃而不申请升级，所以最多重试 3 次，第 2 次起用"请申请升级"的跟进提示。
 */
async function runApprovalCase(
  decision: ApprovalDecision,
  label: string,
  target: string,
  content: string,
): Promise<{ request: ApprovalRequest; settlement: TurnSettlement }> {
  const session = await adapter.createSession(WORKSPACE, label);
  const prompts = [
    `请用 pwsh 命令在路径 ${target} 创建文件，内容为 ${content}。必须使用 pwsh 命令执行，不要使用 write 工具。`,
    `刚才的写入被沙箱拒绝了。请按流程申请一次性权限提升（escalation / permission approval），获得批准后在路径 ${target} 写入内容 ${content}。不要放弃，也不要改用其他路径或工具。`,
  ];
  for (let attempt = 1; attempt <= 3; attempt += 1) {
    const prompt = prompts[Math.min(attempt - 1, prompts.length - 1)] as string;
    const approval = waitForEventCancelable((event) => event.type === 'approval_request', 90_000, `${label} approval`);
    const done = waitForEventCancelable((event) => event.type === 'completed', 90_000, `${label} completed`);
    try {
      await adapter.sendMessage(session.sessionId, {
        taskId: `${label}-${attempt}`,
        conversationId: `${label}-${attempt}`,
        prompt,
        workspacePath: WORKSPACE,
        timeoutSec: 240,
      });
      const first = await Promise.race([approval.promise, done.promise]);
      if (first.type === 'approval_request') {
        const decided = adapter.decideApproval(first.request.approvalId, decision);
        assert.equal(decided, true);
        const settlement = await adapter.waitForTurn(session.sessionId, 240_000);
        record({ kind: `approval_${decision}`, label, attempt, request: first.request, settlement });
        return { request: first.request, settlement };
      }
      record({ kind: 'approval_not_triggered', label, attempt, first });
    } finally {
      approval.cancel();
      done.cancel();
    }
  }
  throw new Error(`3 次尝试均未触发审批请求（${label}）`);
}

before(async () => {
  mkdirSync(WORKSPACE, { recursive: true });
  const logger = new Logger({ scope: 'contract', level: 'debug' });
  adapter = new AcpAdapter({ logger, permissionPolicy: 'ask' });
  attachRecorder(adapter);
  await adapter.connect();
});
after(async () => {
  await adapter?.disconnect().catch(() => undefined);
  record({ kind: 'summary', evidenceFile: EVIDENCE, workspace: WORKSPACE });
});

describe('M0 ACP 合同测试', () => {
  it('1. initialize 返回 protocolVersion=1，版本可探测', async () => {
    const status = await adapter.getStatus();
    assert.equal(status.running, true);
    const initialize = adapter.getInitializeResult() as Record<string, unknown> | null;
    assert.equal(initialize?.['protocolVersion'], 1);
    assert.equal(typeof adapter.getHarnessVersion(), 'string');
    record({ kind: 'initialize', version: adapter.getHarnessVersion(), initialize });
  });

  it('2. 能力矩阵诚实上报（ACP 可用，文件/终端为 false）', async () => {
    const caps = await adapter.getCapabilities();
    assert.equal(caps.adapter, 'acp');
    assert.equal(caps.values.chat, true);
    assert.equal(caps.values.cancel, true);
    assert.equal(caps.values.approvalIntercept, true);
    assert.equal(caps.values.fileRead, false);
    assert.equal(caps.values.terminal, false);
    assert.equal(caps.values.pause, false);
    record({ kind: 'capabilities', caps });
  });

  it('3. session/list 可用，session/new 固定工作目录', async () => {
    const listed = await adapter.getSessions();
    assert.ok(Array.isArray(listed));
    const session = await adapter.createSession(WORKSPACE, 'M0 contract');
    assert.ok(session.sessionId.length > 10);
    assert.equal(session.workspacePath, WORKSPACE);
    record({ kind: 'session', sessionId: session.sessionId, listedCount: listed.length });
  });

  it('4. 一次真实 turn：prompt → output → completed', async () => {
    const session = await adapter.createSession(WORKSPACE, 'M0 chat');
    const handle = await adapter.sendMessage(session.sessionId, {
      taskId: 'm0-chat',
      conversationId: 'm0-chat',
      prompt: '只回复两个字：收到。不要调用任何工具。',
      workspacePath: WORKSPACE,
      timeoutSec: 180,
    });
    const settlement = await adapter.waitForTurn(session.sessionId, 180_000);
    assert.equal(settlement.stopReason, 'end_turn', `实际 stopReason=${settlement.stopReason}`);
    assert.match(settlement.summary, /收到/);
    assert.equal(handle.harnessRef, session.sessionId);
    record({ kind: 'chat', sessionId: session.sessionId, settlement, eventCount: 1 });
    (globalThis as Record<string, unknown>)['__m0ChatSession'] = session.sessionId;
  });

  it('5. 多轮继续：同一 sessionId 再 prompt，上下文连续', async () => {
    const sessionId = (globalThis as Record<string, unknown>)['__m0ChatSession'] as string;
    await adapter.sendMessage(sessionId, {
      taskId: 'm0-continue',
      conversationId: 'm0-continue',
      prompt: '我刚才要求你回复什么？只回答那两个字。',
      workspacePath: WORKSPACE,
      timeoutSec: 180,
    });
    const settlement = await adapter.waitForTurn(sessionId, 180_000);
    assert.equal(settlement.stopReason, 'end_turn');
    assert.match(settlement.summary, /收到/);
    record({ kind: 'continue', sessionId, settlement });
  });

  it('6. 取消：工具执行中 session/cancel → stopReason=cancelled，取消后会话可继续', async () => {
    const session = await adapter.createSession(WORKSPACE, 'M0 cancel');
    autoApproveApprovals = true;
    try {
      const toolStarted = waitForEvent((event) => event.type === 'tool_call', 120_000, 'tool_call');
      const handle = await adapter.sendMessage(session.sessionId, {
        taskId: 'm0-cancel',
        conversationId: 'm0-cancel',
        prompt: '请用 pwsh 命令执行这段脚本并输出结果：1..30 | ForEach-Object { Start-Sleep -Milliseconds 300; $_ }。必须用命令执行，不要自己算。',
        workspacePath: WORKSPACE,
        timeoutSec: 240,
      });
      await toolStarted;
      await new Promise((resolve) => setTimeout(resolve, 900));
      const cancelResult = await handle.cancel();
      assert.equal(cancelResult.accepted, true);
      assert.equal(cancelResult.harnessAck, true, `cancelResult=${JSON.stringify(cancelResult)}`);
      assert.equal(cancelResult.mechanism, 'native');
      assert.match(cancelResult.detail ?? '', /cancelled/);
      record({ kind: 'cancel', sessionId: session.sessionId, cancelResult });

      // 取消不破坏会话：同一 session 继续一轮正常对话
      await adapter.sendMessage(session.sessionId, {
        taskId: 'm0-after-cancel',
        conversationId: 'm0-after-cancel',
        prompt: '只回复两个字：继续。不要调用工具。',
        workspacePath: WORKSPACE,
        timeoutSec: 120,
      });
      const after = await adapter.waitForTurn(session.sessionId, 180_000);
      assert.equal(after.stopReason, 'end_turn');
      assert.match(after.summary, /继续/);
      record({ kind: 'after_cancel', sessionId: session.sessionId, settlement: after });
    } finally {
      autoApproveApprovals = false;
    }
  });

  it('7. 审批 allow-once：request_permission → 批准后命令执行并写文件', async () => {
    const target = join(tmpdir(), `m0-allow-outside-${STAMP}.txt`);
    if (existsSync(target)) rmSync(target);
    const { request, settlement } = await runApprovalCase('approved', 'm0-approval-allow', target, 'allow-ok');
    assert.equal(request.source, 'acp_permission');
    assert.ok(request.toolCallId !== undefined, '审批请求应带 toolCallId');
    const kinds = (request.options ?? []).map((option) => option.kind);
    assert.ok(kinds.length > 0, `审批选项不应为空，实际=${JSON.stringify(request.options)}`);
    assert.equal(settlement.stopReason, 'end_turn');
    const content = existsSync(target) ? readFileSync(target, 'utf8') : null;
    record({ kind: 'approval_allow_result', target, kinds, fileExists: content !== null, content });
    assert.ok(content !== null, '批准后目标文件应存在（批准了一次性沙箱升级）');
    assert.match(content ?? '', /allow-ok/);
  });

  it('8. 审批 reject-once：拒绝后工具不执行、turn 正常结束（end_turn，不是 failed）', async () => {
    const target = join(tmpdir(), `m0-reject-outside-${STAMP}.txt`);
    if (existsSync(target)) rmSync(target);
    const { settlement } = await runApprovalCase('denied', 'm0-approval-reject', target, 'reject-ok');
    assert.equal(settlement.stopReason, 'end_turn', '用户拒绝不是系统失败，turn 应正常结束');
    const fileExists = existsSync(target);
    record({ kind: 'approval_reject_result', target, fileExists });
    assert.equal(fileExists, false, '拒绝后目标文件不应存在（工具未被批准执行）');
  });

  it('9. resume：断开后重连并恢复会话上下文', async () => {
    const sessionId = (globalThis as Record<string, unknown>)['__m0ChatSession'] as string;
    assert.ok(sessionId !== undefined);
    await adapter.disconnect();
    const logger = new Logger({ scope: 'contract.resume', level: 'debug' });
    adapter = new AcpAdapter({ logger, permissionPolicy: 'ask' });
    attachRecorder(adapter);
    await adapter.connect();
    const session = await adapter.resumeSession(sessionId, WORKSPACE);
    assert.equal(session.sessionId, sessionId);
    await adapter.sendMessage(sessionId, {
      taskId: 'm0-resume',
      conversationId: 'm0-resume',
      prompt: '继续刚才的对话：我最开始让你回复什么？只回答那两个字。',
      workspacePath: WORKSPACE,
      timeoutSec: 180,
    });
    const settlement = await adapter.waitForTurn(sessionId, 180_000);
    assert.equal(settlement.stopReason, 'end_turn');
    assert.match(settlement.summary, /收到/);
    record({ kind: 'resume', sessionId, settlement });
  });
});
