/**
 * M1-α Relay 自测（零依赖，直接用 Node 24 运行）。
 *
 *   node tools/relay-selftest.ts              # Phase A + B + C（真实 ACP 基础链路）
 *   node tools/relay-selftest.ts --no-acp     # 只跑假 harness / 假后端（毫秒级，CI 友好）
 *   node tools/relay-selftest.ts --acp-full   # 额外跑真实 ACP 的 cancel 路径
 *   node tools/relay-selftest.ts --acp-approval  # 额外尝试真实 ACP 审批路径（依赖沙箱/模型行为，可能不稳定）
 *
 * Phase A：FakeHarness + FakeTransport，验证 RelayAgent 的全部编排逻辑
 *          （conversation.create / 路径越界 / prompt → session.update → task.state /
 *            busy 拦截 / cancel / 审批 approved / 审批超时 expired / 事件映射 / 脱敏 / failed / 默认工作区）。
 * Phase B：startFakeRelayServer（真实 http + 手写 WSS 服务端）+ 真 RelayClient，
 *          验证 pair、WSS 往返、心跳 pong、发送队列上限 100、断线重连、4401 拒绝。
 * Phase C：真 AcpAdapter + RelayAgent + FakeTransport，验证真实 ACP 的
 *          conversation.create → prompt → session.update(output) → task.state completed。
 *
 * 证据写入 agent/evidence/relay-selftest-<stamp>.json。
 */
import { mkdirSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

import { AcpAdapter } from '../src/harness/acp/acp-adapter.ts';
import type { TurnSettlement } from '../src/harness/acp/acp-adapter.ts';
import type {
  ApprovalRequest,
  CancelResult,
  HarnessCapabilities,
  HarnessCapability,
  HarnessEvent,
  HarnessSession,
  TaskHandle,
  TaskInput,
} from '../src/harness/adapter.ts';
import { HarnessError } from '../src/harness/errors.ts';
import { Logger } from '../src/infra/logger.ts';
import {
  createEnvelope,
  isRecord,
} from '../src/relay/protocol.ts';
import type {
  ApprovalRequestPayload,
  ApprovalResolvedPayload,
  ConversationCreatedPayload,
  DeviceStatusPayload,
  ErrorPayload,
  RelayEnvelope,
  RelayTransport,
  SessionUpdatePayload,
  TaskStatePayload,
} from '../src/relay/protocol.ts';
import { RelayAgent } from '../src/relay/relay-agent.ts';
import type { ApprovalSettlement, RelayHarness } from '../src/relay/relay-agent.ts';
import { buildRelayWebSocketUrl, RelayClient } from '../src/relay/relay-client.ts';
import { startFakeRelayServer } from './fake-relay-server.ts';
import type { FakeRelayConnection, FakeRelayServer } from './fake-relay-server.ts';

const AGENT_ROOT = resolve(import.meta.dirname, '..');
const WORKSPACE_BASE = join(AGENT_ROOT, '.m1ws');
const EVIDENCE_DIR = join(AGENT_ROOT, 'evidence');
const DEFAULT_WAIT_MS = 30_000;

const logLines: string[] = [];
const quietLogger = new Logger({
  level: 'error',
  scope: 'selftest',
  sink: (line: string) => {
    if (logLines.length < 500) logLines.push(line);
  },
});

const startedAt = new Date().toISOString();

// ---------------------------------------------------------------------------
// 断言 / 等待 / 结果记录
// ---------------------------------------------------------------------------

function nowIso(): string {
  return new Date().toISOString();
}

function delay(ms: number): Promise<void> {
  return new Promise((done) => {
    setTimeout(done, ms);
  });
}

function assert(condition: unknown, message: string): void {
  if (!condition) throw new Error(message);
}

function assertEqual(actual: unknown, expected: unknown, label: string): void {
  if (actual !== expected) {
    throw new Error(`${label}：期望 ${JSON.stringify(expected)}，实际 ${JSON.stringify(actual)}`);
  }
}

function assertString(value: unknown, label: string): string {
  if (typeof value !== 'string' || value.length === 0) {
    throw new Error(`${label}：期望非空字符串，实际 ${JSON.stringify(value)}`);
  }
  return value;
}

async function waitFor<T>(label: string, probe: () => T | null | undefined | false, timeoutMs = DEFAULT_WAIT_MS): Promise<T> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const value = probe();
    if (value !== null && value !== undefined && value !== false) return value;
    if (Date.now() > deadline) throw new Error(`等待超时（${timeoutMs}ms）：${label}`);
    await delay(20);
  }
}

interface CheckResult {
  phase: string;
  id: string;
  title: string;
  ok: boolean;
  error: string | null;
  details: Record<string, unknown>;
  durationMs: number;
}

const results: CheckResult[] = [];
const collected: Record<string, unknown> = {};

async function check(
  phase: string,
  id: string,
  title: string,
  body: () => Promise<Record<string, unknown> | void>,
): Promise<boolean> {
  const begunAt = Date.now();
  try {
    const details = await body();
    results.push({ phase, id, title, ok: true, error: null, details: details ?? {}, durationMs: Date.now() - begunAt });
    console.log(`[PASS] ${id} ${title}`);
    return true;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    results.push({ phase, id, title, ok: false, error: message, details: {}, durationMs: Date.now() - begunAt });
    console.error(`[FAIL] ${id} ${title} -> ${message}`);
    return false;
  }
}

// ---------------------------------------------------------------------------
// FakeTransport：实现 relay 的 RelayTransport 结构（send / onMessage / isConnected）
// 用来替代真实 WSS 连接，收集所有上行信封。
// ---------------------------------------------------------------------------

class FakeTransport implements RelayTransport {
  readonly sent: RelayEnvelope<unknown>[] = [];
  private readonly listeners = new Set<(envelope: RelayEnvelope<unknown>) => void>();
  private open = true;

  send(envelope: RelayEnvelope<unknown>): void {
    this.sent.push(envelope);
  }

  onMessage(listener: (envelope: RelayEnvelope<unknown>) => void): () => void {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }

  isConnected(): boolean {
    return this.open;
  }

  close(): void {
    this.open = false;
    this.listeners.clear();
  }

  /** 模拟手机端/后端下行：触发 RelayAgent 的 onMessage。 */
  receive(envelope: RelayEnvelope<unknown>): void {
    for (const listener of [...this.listeners]) listener(envelope);
  }

  clear(): RelayEnvelope<unknown>[] {
    return this.sent.splice(0, this.sent.length);
  }

  typed<T>(type: string): RelayEnvelope<T>[] {
    return this.sent.filter((envelope) => envelope.type === type) as RelayEnvelope<T>[];
  }
}

function receive(agent: RelayAgent, transport: FakeTransport, type: string, payload?: unknown): void {
  assert(transport.isConnected(), 'FakeTransport 已关闭');
  const envelope = createEnvelope(type, payload);
  // 真实运行时由 serve.ts 把 transport.onMessage 接到 agent.handleEnvelope；
  // 自测里直接调 handleEnvelope，避免再起一条订阅路径（下行入口是同一个）。
  void agent.handleEnvelope(envelope).catch((error: unknown) => {
    console.error('[WARN] handleEnvelope 异常：', error instanceof Error ? error.message : String(error));
  });
}

async function waitForEnvelope<T>(
  transport: FakeTransport,
  type: string,
  predicate?: (envelope: RelayEnvelope<unknown>, payload: Record<string, unknown>) => boolean,
  timeoutMs = DEFAULT_WAIT_MS,
  label?: string,
): Promise<RelayEnvelope<T>> {
  const match = await waitFor<RelayEnvelope<unknown>>(
    label ?? `${type} 消息`,
    () => {
      const found = transport.sent.find((envelope) => {
        if (envelope.type !== type) return false;
        if (predicate === undefined) return true;
        if (!isRecord(envelope.payload)) return false;
        return predicate(envelope, envelope.payload);
      });
      return found ?? null;
    },
    timeoutMs,
  );
  return match as RelayEnvelope<T>;
}

function payloadRecord<T extends Record<string, unknown>>(envelope: RelayEnvelope<unknown>): T {
  assert(isRecord(envelope.payload), `${envelope.type} payload 不是对象`);
  return envelope.payload as T;
}

// ---------------------------------------------------------------------------
// FakeHarness：实现 RelayAgent 依赖的 RelayHarness 结构子集，脚本化地产生
// HarnessEvent / TurnSettlement，让编排逻辑可以被离线、确定性地测试。
// ---------------------------------------------------------------------------

interface FakeTurn {
  taskId: string;
  sessionId: string;
  settled: boolean;
  resolve: (settlement: TurnSettlement) => void;
  promise: Promise<TurnSettlement>;
}

class FakeHarness implements RelayHarness {
  readonly createdSessions: HarnessSession[] = [];
  readonly cancelledHandles: string[] = [];
  readonly decisions: Array<{ approvalId: string; status: string }> = [];
  private readonly listeners = new Set<(event: HarnessEvent) => void>();
  private readonly eventsBySession = new Map<string, HarnessEvent[]>();
  private sessionCounter = 0;
  private taskCounter = 0;
  private turn: FakeTurn | null = null;

  async createSession(workspacePath: string, title?: string): Promise<HarnessSession> {
    this.sessionCounter += 1;
    const session: HarnessSession = {
      sessionId: `fake-session-${this.sessionCounter}`,
      workspacePath,
      createdAt: nowIso(),
      lastActiveAt: nowIso(),
      title,
    };
    this.createdSessions.push(session);
    this.eventsBySession.set(session.sessionId, []);
    return session;
  }

  async sendMessage(sessionId: string, input: TaskInput): Promise<TaskHandle> {
    if (this.turn !== null) throw new HarnessError('SESSION_BUSY', '模拟 SESSION_BUSY');
    if (!this.eventsBySession.has(sessionId)) {
      throw new HarnessError('SESSION_NOT_FOUND', `会话不存在：${sessionId}`);
    }
    this.taskCounter += 1;
    let settle: (settlement: TurnSettlement) => void = () => {};
    const promise = new Promise<TurnSettlement>((resolvePromise) => {
      settle = resolvePromise;
    });
    const turn: FakeTurn = {
      taskId: input.taskId,
      sessionId,
      settled: false,
      resolve: settle,
      promise,
    };
    this.turn = turn;
    const handle: TaskHandle = {
      taskId: input.taskId,
      harnessRef: sessionId,
      startedAt: nowIso(),
      cancel: async () => this.cancelTask(handle),
    };
    this.scriptTurn(turn, input);
    return handle;
  }

  async cancelTask(handle: TaskHandle): Promise<CancelResult> {
    const turn = this.turn;
    if (turn === null || turn.taskId !== handle.taskId) {
      return { accepted: false, harnessAck: false, mechanism: 'native', detail: '没有进行中的 turn' };
    }
    this.cancelledHandles.push(handle.taskId);
    this.settleTurn(turn, { stopReason: 'cancelled', summary: '已取消' });
    return { accepted: true, harnessAck: true, mechanism: 'native', detail: 'stopReason=cancelled' };
  }

  async waitForTurn(sessionId: string, timeoutMs = 120_000): Promise<TurnSettlement> {
    const turn = this.turn;
    if (turn === null) throw new HarnessError('INTERNAL', '该会话没有进行中的 turn');
    if (turn.sessionId !== sessionId) throw new HarnessError('SESSION_NOT_FOUND', `会话不存在：${sessionId}`);
    let timer: ReturnType<typeof setTimeout> | null = null;
    const timeout = new Promise<TurnSettlement>((resolvePromise) => {
      timer = setTimeout(() => {
        resolvePromise({ stopReason: 'error', summary: '', error: new HarnessError('TIMEOUT', '等待 turn 结束超时') });
      }, timeoutMs);
    });
    try {
      return await Promise.race([turn.promise, timeout]);
    } finally {
      if (timer !== null) clearTimeout(timer);
    }
  }

  decideApproval(approvalId: string, status: ApprovalSettlement): boolean {
    const request = this.pendingApprovals.get(approvalId);
    if (request === undefined) return false;
    this.pendingApprovals.delete(approvalId);
    this.decisions.push({ approvalId, status });
    const turn = this.turn;
    if (turn !== null && !turn.settled) {
      const label = status === 'approved' ? '已允许' : status === 'denied' ? '已拒绝' : '已超时';
      this.emit(turn.sessionId, { type: 'output', stream: 'answer', text: `审批${label}`, at: nowIso() });
      this.settleTurn(turn, { stopReason: 'end_turn', summary: `审批${label}` });
    }
    return true;
  }

  async getSessionEvents(sessionId: string, sinceSeq = 0): Promise<ReadonlyArray<HarnessEvent>> {
    const events = this.eventsBySession.get(sessionId);
    if (events === undefined) throw new HarnessError('SESSION_NOT_FOUND', `会话不存在：${sessionId}`);
    return events.slice(sinceSeq);
  }

  subscribe(listener: (event: HarnessEvent) => void): () => void {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }

  async getCapabilities(): Promise<HarnessCapabilities> {
    const values: Record<HarnessCapability, boolean> = {
      chat: true,
      streaming: true,
      structuredResult: true,
      cancel: true,
      pause: false,
      continue: true,
      sessions: true,
      sessionResume: true,
      toolCallDetail: true,
      workspaceList: false,
      fileRead: false,
      fileWrite: false,
      terminal: false,
      approvalIntercept: true,
      modelSwitch: false,
      usageReport: true,
    };
    return {
      adapter: 'acp',
      harnessVersion: 'fake-harness-1.0.0',
      values,
      evidence: {} as Record<HarnessCapability, string>,
      probedAt: nowIso(),
    };
  }

  getHarnessVersion(): string | null {
    return 'fake-harness-1.0.0';
  }

  // -- 内部：脚本化行为 -------------------------------------------------------

  private pendingApprovals = new Map<string, ApprovalRequest>();

  private scheduleAction(turn: FakeTurn, action: () => void, ms = 15): void {
    setTimeout(() => {
      if (turn.settled) return;
      action();
    }, ms);
  }

  private scriptTurn(turn: FakeTurn, input: TaskInput): void {
    const prompt = input.prompt;
    if (prompt.includes('取消测试')) {
      this.scheduleAction(turn, () => {
        this.emit(turn.sessionId, {
          type: 'tool_call',
          callId: 'call_cancel_1',
          tool: 'pwsh',
          input: { command: '1..30 | ForEach-Object { Start-Sleep -Milliseconds 300; $_ }' },
          at: nowIso(),
        });
      });
      return;
    }
    if (prompt.includes('审批超时测试')) {
      this.scheduleAction(turn, () => this.raiseApproval(turn, 200));
      return;
    }
    if (prompt.includes('审批测试')) {
      this.scheduleAction(turn, () => this.raiseApproval(turn, 60_000));
      return;
    }
    if (prompt.includes('失败测试')) {
      this.scheduleAction(turn, () => {
        this.emit(turn.sessionId, {
          type: 'failed',
          errorCode: 'ACP_PROTOCOL_ERROR',
          message: '模拟 turn 失败',
          retryable: false,
          at: nowIso(),
        });
        this.settleTurn(turn, {
          stopReason: 'error',
          summary: '',
          error: new HarnessError('ACP_PROTOCOL_ERROR', '模拟 turn 失败'),
        });
      });
      return;
    }
    if (prompt.includes('事件测试')) {
      this.scheduleAction(turn, () => {
        this.emit(turn.sessionId, { type: 'thinking', text: '先思考一下', at: nowIso() });
        this.emit(turn.sessionId, {
          type: 'tool_call',
          callId: 'call_events_1',
          tool: 'pwsh',
          input: { command: 'echo events' },
          at: nowIso(),
        });
        this.emit(turn.sessionId, {
          type: 'tool_call_update',
          callId: 'call_events_1',
          status: 'completed',
          resultExcerpt: 'events ok',
          at: nowIso(),
        });
        this.emit(turn.sessionId, {
          type: 'usage',
          contextUsed: 1234,
          contextSize: 200000,
          inputTokens: 2345,
          outputTokens: 67,
          at: nowIso(),
        });
        this.finishTurn(turn, '事件测试完成');
      });
      return;
    }
    if (prompt.includes('脱敏测试')) {
      this.scheduleAction(turn, () => {
        this.emit(turn.sessionId, {
          type: 'tool_call',
          callId: 'call_redact_1',
          tool: 'pwsh',
          input: { token: 'super-secret-value', command: 'echo hi', authorization: 'Bearer abc' },
          at: nowIso(),
        });
        this.finishTurn(turn, '脱敏完成');
      });
      return;
    }
    this.scheduleAction(turn, () => {
      const text = prompt.includes('收到') ? '收到' : prompt.includes('继续') ? '继续' : '自测完成';
      this.finishTurn(turn, text);
    });
  }

  private finishTurn(turn: FakeTurn, text: string): void {
    this.emit(turn.sessionId, { type: 'output', stream: 'answer', text, at: nowIso() });
    this.settleTurn(turn, { stopReason: 'end_turn', summary: text });
  }

  private raiseApproval(turn: FakeTurn, ttlMs: number): void {
    const approvalId = `apr_fake_${this.cancelledHandles.length}_${this.decisions.length}_${Math.random().toString(36).slice(2, 8)}`;
    const request: ApprovalRequest = {
      approvalId,
      taskId: turn.taskId,
      source: 'acp_permission',
      toolCallId: 'call_approval_1',
      tool: 'pwsh',
      approvalType: 'acp_permission',
      permissionLevel: 6,
      riskLevel: 'high',
      actionHash: 'fake-action-hash',
      actionSummary: '模拟：创建文件需要一次性权限',
      payload: {
        sessionId: turn.sessionId,
        toolCallId: 'call_approval_1',
        toolInput: { command: 'pwsh -Command "New-Item -ItemType File -Force m1-selftest-ok.txt"' },
      },
      options: [
        { optionId: 'allow_1', label: '允许一次', kind: 'allow_once' },
        { optionId: 'reject_1', label: '拒绝', kind: 'reject_once' },
      ],
      expiresAt: new Date(Date.now() + ttlMs).toISOString(),
    };
    this.pendingApprovals.set(approvalId, request);
    this.emit(turn.sessionId, { type: 'approval_request', request, at: nowIso() });
  }

  private emit(sessionId: string, event: HarnessEvent): void {
    const events = this.eventsBySession.get(sessionId);
    if (events !== undefined) events.push(event);
    for (const listener of [...this.listeners]) listener(event);
  }

  private settleTurn(turn: FakeTurn, settlement: TurnSettlement): void {
    if (turn.settled) return;
    turn.settled = true;
    if (this.turn === turn) this.turn = null;
    turn.resolve(settlement);
  }
}

// ---------------------------------------------------------------------------
// Phase A：FakeHarness + FakeTransport 验证 RelayAgent 编排
// ---------------------------------------------------------------------------

async function runPhaseA(): Promise<void> {
  const phase = 'A';
  const workspace = join(WORKSPACE_BASE, 'phase-a');
  mkdirSync(workspace, { recursive: true });
  const harness = new FakeHarness();
  const transport = new FakeTransport();
  const conversationId = `conv_selftest_${process.pid}_${Math.random().toString(36).slice(2, 6)}`;
  const agent = new RelayAgent({
    harness,
    transport,
    workspaceRoot: WORKSPACE_BASE,
    logger: quietLogger,
    deviceName: 'selftest-agent',
    agentVersion: '0.1.0-m1',
    promptTimeoutSec: 30,
  });
  await agent.start();
  console.log('Phase A：FakeHarness + FakeTransport');

  try {
    await check(phase, 'A1', 'device.status 含 online/harnessVersion/capabilities', async () => {
      transport.clear();
      agent.sendDeviceStatus();
      const envelope = await waitForEnvelope<DeviceStatusPayload>(transport, 'device.status');
      const payload = envelope.payload as DeviceStatusPayload;
      assertEqual(payload.online, true, 'online');
      assertEqual(payload.deviceName, 'selftest-agent', 'deviceName');
      assertEqual(payload.harnessVersion, 'fake-harness-1.0.0', 'harnessVersion');
      assertEqual(payload.capabilities.chat, true, 'capabilities.chat');
      assertEqual(payload.capabilities.approvalIntercept, true, 'capabilities.approvalIntercept');
      assert(Array.isArray(payload.workspaceRoots) && payload.workspaceRoots.length === 1, 'workspaceRoots 应为 1 个根');
      return { payload };
    });

    await check(phase, 'A2', 'conversation.create 合法路径 → conversation.created', async () => {
      transport.clear();
      receive(agent, transport, 'conversation.create', {
        conversationId,
        workspacePath: workspace,
        title: 'M1 自测会话',
      });
      const envelope = await waitForEnvelope<ConversationCreatedPayload>(
        transport,
        'conversation.created',
        (_envelope, payload) => payload.conversationId === conversationId,
      );
      const payload = envelope.payload as ConversationCreatedPayload;
      assertString(payload.sessionId, 'sessionId');
      assertEqual(payload.workspacePath, workspace, 'workspacePath');
      assertEqual(payload.conversationId, conversationId, 'conversationId');
      assertEqual(harness.createdSessions.length, 1, 'createSession 调用次数');
      assertEqual(harness.createdSessions[0]?.workspacePath, workspace, 'harness 收到的工作区');
      return { sessionId: payload.sessionId };
    });

    await check(phase, 'A3', 'workspacePath 越界/相对路径 → error PATH_NOT_ALLOWED', async () => {
      transport.clear();
      const outside = resolve(WORKSPACE_BASE, '..', '..', 'Windows');
      receive(agent, transport, 'conversation.create', {
        conversationId: `${conversationId}_bad1`,
        workspacePath: outside,
        title: '越界',
      });
      const outsideError = await waitForEnvelope<ErrorPayload>(
        transport,
        'error',
        (_envelope, payload) => payload.code === 'PATH_NOT_ALLOWED',
      );
      assertEqual((outsideError.payload as ErrorPayload).code, 'PATH_NOT_ALLOWED', '越界错误码');
      assert(harness.createdSessions.length === 1, '越界路径不应创建 session');

      transport.clear();
      receive(agent, transport, 'conversation.create', {
        conversationId: `${conversationId}_bad2`,
        workspacePath: 'relative/path',
        title: '相对路径',
      });
      await waitForEnvelope<ErrorPayload>(transport, 'error', (_envelope, payload) => payload.code === 'PATH_NOT_ALLOWED');
      return { outside };
    });

    await check(phase, 'A4', 'prompt.send → task.state running → session.update(output) → completed', async () => {
      transport.clear();
      receive(agent, transport, 'prompt.send', { conversationId, text: '只回复两个字：收到' });
      await waitForEnvelope<TaskStatePayload>(
        transport,
        'task.state',
        (_envelope, payload) => payload.conversationId === conversationId && payload.state === 'running',
      );
      const updateEnvelope = await waitForEnvelope<SessionUpdatePayload>(
        transport,
        'session.update',
        (_envelope, payload) =>
          payload.conversationId === conversationId &&
          payload.kind === 'output' &&
          typeof payload.text === 'string' &&
          payload.text.includes('收到'),
      );
      const update = updateEnvelope.payload as SessionUpdatePayload;
      assertEqual(update.seq, 1, '单会话首个 session.update 的 seq');
      const completedEnvelope = await waitForEnvelope<TaskStatePayload>(
        transport,
        'task.state',
        (_envelope, payload) => payload.conversationId === conversationId && payload.state === 'completed',
      );
      assert(
        transport.sent.indexOf(updateEnvelope) < transport.sent.indexOf(completedEnvelope),
        'session.update 必须先于 task.state completed',
      );
      const state = agent.getConversation(conversationId);
      assert(state !== null, 'getConversation 应返回状态');
      assertEqual(state?.busy, false, '完成后 busy');
      return { seq: update.seq, updateCount: transport.sent.filter((envelope) => envelope.type === 'session.update').length };
    });

    await check(phase, 'A5', '同会话并发 prompt → error SESSION_BUSY', async () => {
      transport.clear();
      receive(agent, transport, 'prompt.send', { conversationId, text: '取消测试：先挂起一个 turn' });
      await waitForEnvelope<TaskStatePayload>(
        transport,
        'task.state',
        (_envelope, payload) => payload.state === 'running',
      );
      receive(agent, transport, 'prompt.send', { conversationId, text: '再发一条应该被拒绝' });
      const envelope = await waitForEnvelope<ErrorPayload>(
        transport,
        'error',
        (_envelope, payload) => payload.code === 'SESSION_BUSY',
      );
      const payload = envelope.payload as ErrorPayload;
      assertEqual(payload.conversationId, conversationId, 'error.conversationId');
      return { error: payload };
    });

    await check(phase, 'A6', 'task.cancel → task.state cancelled → 同会话可继续下一轮', async () => {
      await waitForEnvelope<SessionUpdatePayload>(
        transport,
        'session.update',
        (_envelope, payload) => payload.kind === 'tool_call',
      );
      transport.clear();
      receive(agent, transport, 'task.cancel', { conversationId });
      await waitForEnvelope<TaskStatePayload>(
        transport,
        'task.state',
        (_envelope, payload) => payload.conversationId === conversationId && payload.state === 'cancelled',
      );
      assertEqual(harness.cancelledHandles.length, 1, 'cancelTask 调用次数');
      assertEqual(agent.getConversation(conversationId)?.busy, false, '取消后 busy');

      transport.clear();
      receive(agent, transport, 'prompt.send', { conversationId, text: '只回复两个字：继续' });
      await waitForEnvelope<SessionUpdatePayload>(
        transport,
        'session.update',
        (_envelope, payload) => payload.kind === 'output' && typeof payload.text === 'string' && payload.text.includes('继续'),
      );
      await waitForEnvelope<TaskStatePayload>(
        transport,
        'task.state',
        (_envelope, payload) => payload.state === 'completed',
      );
      return { cancelledHandles: harness.cancelledHandles };
    });

    await check(phase, 'A7', '审批 approved：approval.request → decide → resolved(phone) → completed', async () => {
      transport.clear();
      receive(agent, transport, 'prompt.send', { conversationId, text: '审批测试：需要一次性权限' });
      const requestEnvelope = await waitForEnvelope<ApprovalRequestPayload>(
        transport,
        'approval.request',
        (_envelope, payload) => payload.conversationId === conversationId,
      );
      const request = requestEnvelope.payload as ApprovalRequestPayload;
      assertEqual(request.tool, 'pwsh', 'tool');
      assert(request.options.length === 2, 'options 数量应为 2');
      assertEqual(request.options[0]?.kind, 'allow_once', '选项 1 kind');
      assertEqual(request.options[1]?.kind, 'reject_once', '选项 2 kind');
      assert(isRecord(request.input), 'input 应为对象');
      assert((request.input as Record<string, unknown>).command !== undefined, 'input 应含 command');

      transport.clear();
      receive(agent, transport, 'approval.decide', {
        conversationId,
        approvalId: request.approvalId,
        decision: 'approved',
      });
      const resolvedEnvelope = await waitForEnvelope<ApprovalResolvedPayload>(
        transport,
        'approval.resolved',
        (_envelope, payload) => payload.approvalId === request.approvalId,
      );
      const resolved = resolvedEnvelope.payload as ApprovalResolvedPayload;
      assertEqual(resolved.decision, 'approved', 'resolved.decision');
      assertEqual(resolved.decidedBy, 'phone', 'decidedBy');
      await waitForEnvelope<TaskStatePayload>(
        transport,
        'task.state',
        (_envelope, payload) => payload.state === 'completed',
      );
      assertEqual(harness.decisions[harness.decisions.length - 1]?.status, 'approved', 'harness 收到的审批决定');
      return { approvalId: request.approvalId, decisions: harness.decisions };
    });

    await check(phase, 'A8', '审批超时：本地定时器 → resolved(expired, timeout) → completed', async () => {
      transport.clear();
      receive(agent, transport, 'prompt.send', { conversationId, text: '审批超时测试：等待手机' });
      const requestEnvelope = await waitForEnvelope<ApprovalRequestPayload>(
        transport,
        'approval.request',
        (_envelope, payload) => payload.conversationId === conversationId,
      );
      const request = requestEnvelope.payload as ApprovalRequestPayload;
      const resolvedEnvelope = await waitForEnvelope<ApprovalResolvedPayload>(
        transport,
        'approval.resolved',
        (_envelope, payload) => payload.approvalId === request.approvalId && payload.decision === 'expired',
        10_000,
        '审批超时 resolved',
      );
      assertEqual((resolvedEnvelope.payload as ApprovalResolvedPayload).decidedBy, 'timeout', 'decidedBy');
      await waitForEnvelope<TaskStatePayload>(
        transport,
        'task.state',
        (_envelope, payload) => payload.state === 'completed',
        15_000,
        '超时后任务终态',
      );
      assertEqual(harness.decisions[harness.decisions.length - 1]?.status, 'expired', 'harness 收到的超时决定');
      return { approvalId: request.approvalId, decisions: harness.decisions };
    });

    await check(phase, 'A9', 'thinking/tool_call/tool_call_update/usage 映射 + seq 单调递增', async () => {
      transport.clear();
      receive(agent, transport, 'prompt.send', { conversationId, text: '事件测试：全部事件类型' });
      const thinking = await waitForEnvelope<SessionUpdatePayload>(
        transport,
        'session.update',
        (_envelope, payload) => payload.kind === 'thinking',
      );
      const toolCall = await waitForEnvelope<SessionUpdatePayload>(
        transport,
        'session.update',
        (_envelope, payload) => payload.kind === 'tool_call',
      );
      const toolUpdate = await waitForEnvelope<SessionUpdatePayload>(
        transport,
        'session.update',
        (_envelope, payload) => payload.kind === 'tool_call_update',
      );
      const usage = await waitForEnvelope<SessionUpdatePayload>(
        transport,
        'session.update',
        (_envelope, payload) => payload.kind === 'usage',
      );
      await waitForEnvelope<SessionUpdatePayload>(
        transport,
        'session.update',
        (_envelope, payload) => payload.kind === 'output' && typeof payload.text === 'string' && payload.text.includes('事件测试完成'),
      );
      await waitForEnvelope<TaskStatePayload>(transport, 'task.state', (_envelope, payload) => payload.state === 'completed');

      const thinkingPayload = thinking.payload as SessionUpdatePayload;
      const toolCallPayload = toolCall.payload as SessionUpdatePayload;
      const toolUpdatePayload = toolUpdate.payload as SessionUpdatePayload;
      const usagePayload = usage.payload as SessionUpdatePayload;
      assertEqual(thinkingPayload.kind === 'thinking' ? thinkingPayload.text : '', '先思考一下', 'thinking.text');
      assertEqual(toolCallPayload.kind === 'tool_call' ? toolCallPayload.callId : '', 'call_events_1', 'tool_call.callId');
      assertEqual(toolCallPayload.kind === 'tool_call' ? toolCallPayload.tool : '', 'pwsh', 'tool_call.tool');
      assertEqual(toolUpdatePayload.kind === 'tool_call_update' ? toolUpdatePayload.status : '', 'completed', 'tool_call_update.status');
      assertEqual(toolUpdatePayload.kind === 'tool_call_update' ? toolUpdatePayload.resultExcerpt : '', 'events ok', 'resultExcerpt');
      assertEqual(usagePayload.kind === 'usage' ? usagePayload.contextUsed : -1, 1234, 'usage.contextUsed');
      assertEqual(usagePayload.kind === 'usage' ? usagePayload.contextSize : -1, 200000, 'usage.contextSize');

      const seqs = transport.typed<SessionUpdatePayload>('session.update').map((envelope) => envelope.payload?.seq ?? -1);
      assert(seqs.length >= 5, `事件类型覆盖不足：${seqs.length}`);
      for (let index = 1; index < seqs.length; index += 1) {
        assert((seqs[index] ?? 0) > (seqs[index - 1] ?? 0), `seq 必须单调递增：${seqs.join(',')}`);
      }
      return { seqs, count: seqs.length };
    });

    await check(phase, 'A10', '上报前 redact：tool_call.input 中 token 被替换为 ***', async () => {
      transport.clear();
      receive(agent, transport, 'prompt.send', { conversationId, text: '脱敏测试：发送 secret' });
      const toolCall = await waitForEnvelope<SessionUpdatePayload>(
        transport,
        'session.update',
        (_envelope, payload) => payload.kind === 'tool_call',
      );
      const payload = toolCall.payload as SessionUpdatePayload;
      assert(payload.kind === 'tool_call', 'kind 应为 tool_call');
      assert(isRecord(payload.input), 'input 应为对象');
      const input = payload.input as Record<string, unknown>;
      assertEqual(input.token, '***', 'token 应脱敏');
      assertEqual(input.authorization, '***', 'authorization 应脱敏');
      assertEqual(input.command, 'echo hi', '非敏感字段应保留');
      await waitForEnvelope<TaskStatePayload>(transport, 'task.state', (_envelope, state) => state.state === 'completed');
      return { input };
    });

    await check(phase, 'A11', 'turn 失败 → task.state failed + detail{code,message}', async () => {
      transport.clear();
      receive(agent, transport, 'prompt.send', { conversationId, text: '失败测试：模拟异常' });
      const failedEnvelope = await waitForEnvelope<TaskStatePayload>(
        transport,
        'task.state',
        (_envelope, payload) => payload.state === 'failed',
      );
      const payload = failedEnvelope.payload as TaskStatePayload;
      assertEqual(payload.detail?.code, 'ACP_PROTOCOL_ERROR', 'detail.code');
      assertString(payload.detail?.message, 'detail.message');
      assertEqual(agent.getConversation(conversationId)?.busy, false, '失败后 busy');
      return { detail: payload.detail };
    });

    await check(phase, 'A12', '未知会话 prompt.send → error CONVERSATION_NOT_FOUND', async () => {
      transport.clear();
      receive(agent, transport, 'prompt.send', { conversationId: 'conv_unknown', text: 'hello' });
      const envelope = await waitForEnvelope<ErrorPayload>(
        transport,
        'error',
        (_envelope, payload) => payload.code === 'CONVERSATION_NOT_FOUND',
      );
      return { error: envelope.payload };
    });

    await check(phase, 'A13', 'conversation.create 省略 workspacePath → 使用 M1_WORKSPACE_ROOT', async () => {
      transport.clear();
      const defaultConversationId = `${conversationId}_default`;
      receive(agent, transport, 'conversation.create', { conversationId: defaultConversationId, title: '默认工作区' });
      const envelope = await waitForEnvelope<ConversationCreatedPayload>(
        transport,
        'conversation.created',
        (_envelope, payload) => payload.conversationId === defaultConversationId,
      );
      const payload = envelope.payload as ConversationCreatedPayload;
      assertEqual(payload.workspacePath, WORKSPACE_BASE, '默认 workspacePath');
      return { workspacePath: payload.workspacePath };
    });
  } finally {
    agent.stop();
  }
  collected.phaseA = {
    createdSessions: harness.createdSessions,
    decisions: harness.decisions,
    cancelledHandles: harness.cancelledHandles,
    stats: agent.getStats(),
    queuedLogLines: logLines.length,
  };
}

// ---------------------------------------------------------------------------
// Phase B：假后端（http + 手写 WSS）+ 真 RelayClient
// ---------------------------------------------------------------------------

async function runPhaseB(): Promise<void> {
  const phase = 'B';
  console.log('Phase B：FakeRelayServer + RelayClient');
  const server = await startFakeRelayServer({ logger: quietLogger.child('fake-relay') });
  const clients: RelayClient[] = [];
  try {
    let agentToken = '';
    const pairedOk = await check(phase, 'B1', 'POST /api/v1/auth/pair → 64 hex token/role/deviceId', async () => {
      const response = await fetch(`${server.serverUrl}/api/v1/auth/pair`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ pairingCode: server.pairingCode, clientName: 'selftest-agent', role: 'agent' }),
      });
      assertEqual(response.status, 200, 'HTTP 状态码');
      const body = (await response.json()) as Record<string, unknown>;
      agentToken = assertString(body.token, 'token');
      assertEqual(agentToken.length, 64, 'token 长度');
      assertEqual(body.role, 'agent', 'role');
      assertString(body.deviceId, 'deviceId');
      return { tokenLength: agentToken.length, deviceId: body.deviceId, expiresAt: body.expiresAt };
    });
    if (!pairedOk) return;

    await check(phase, 'B2', '错误配对码 → 401 AUTH_FAILED', async () => {
      const response = await fetch(`${server.serverUrl}/api/v1/auth/pair`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ pairingCode: '000000', clientName: 'selftest-agent', role: 'agent' }),
      });
      assertEqual(response.status, 401, 'HTTP 状态码');
      const body = (await response.json()) as Record<string, unknown>;
      assertEqual(body.code, 'AUTH_FAILED', '错误码');
      return { body };
    });

    await check(phase, 'B3', 'GET /api/v1/health → status ok', async () => {
      const response = await fetch(`${server.serverUrl}/api/v1/health`);
      assertEqual(response.status, 200, 'HTTP 状态码');
      const body = (await response.json()) as Record<string, unknown>;
      assertEqual(body.status, 'ok', 'status');
      assertEqual(body.agentOnline, false, '连接前 agentOnline');
      return { body };
    });

    let mainClient: RelayClient | null = null;
    let mainConnection: FakeRelayConnection | null = null;
    await check(phase, 'B4', 'WSS 连接 + 30s 心跳被压到 100ms：收到 pong 且 health.agentOnline=true', async () => {
      const received: RelayEnvelope<unknown>[] = [];
      mainClient = new RelayClient({
        url: buildRelayWebSocketUrl(server.serverUrl, 'agent', agentToken),
        logger: quietLogger.child('relay-client'),
        heartbeatIntervalMs: 100,
        reconnectBaseMs: 100,
        reconnectMaxMs: 500,
      });
      clients.push(mainClient);
      mainClient.onMessage((envelope) => received.push(envelope));
      mainClient.connect();
      await mainClient.waitForOpen(5_000);
      mainConnection = await server.waitForConnection('agent', 5_000);
      await waitFor('收到 pong', () => mainClient?.getStats().lastPongAt ?? null, 3_000);
      const response = await fetch(`${server.serverUrl}/api/v1/health`);
      const body = (await response.json()) as Record<string, unknown>;
      assertEqual(body.agentOnline, true, '连接后 agentOnline');
      return { lastPongAt: mainClient.getStats().lastPongAt, received: received.length, health: body };
    });

    await check(phase, 'B5', 'WSS 双向：client→server 信封与 server→client 信封', async () => {
      assert(mainClient !== null && mainConnection !== null, 'B4 未建立连接');
      const client = mainClient as RelayClient;
      const connection = mainConnection as FakeRelayConnection;
      const serverReceived: RelayEnvelope<unknown>[] = [];
      connection.onMessage((envelope) => serverReceived.push(envelope));

      client.send(createEnvelope('conversation.create', { workspacePath: WORKSPACE_BASE, title: 'B5' }));
      await waitFor('服务端收到 conversation.create', () => {
        const found = serverReceived.find((envelope) => envelope.type === 'conversation.create');
        return found ?? null;
      }, 5_000);

      const clientReceived: RelayEnvelope<unknown>[] = [];
      client.onMessage((envelope) => clientReceived.push(envelope));
      connection.send('device.status', {
        online: true,
        deviceName: 'fake-server',
        agentVersion: '0.1.0-m1',
        harnessVersion: null,
        capabilities: { chat: true, cancel: true, approvalIntercept: true, sessionResume: true, fileRead: false },
        workspaceRoots: [WORKSPACE_BASE],
        lastSeen: nowIso(),
      });
      await waitFor('客户端收到 device.status', () => {
        const found = clientReceived.find((envelope) => envelope.type === 'device.status');
        return found ?? null;
      }, 5_000);
      return { serverReceived: serverReceived.map((envelope) => envelope.type) };
    });

    await check(phase, 'B6', '未连接时发送队列上限 100（丢最旧 5 条）→ 连接后 flush', async () => {
      const offline = new RelayClient({
        url: buildRelayWebSocketUrl(server.serverUrl, 'agent', agentToken),
        logger: quietLogger.child('relay-client'),
        autoReconnect: false,
        heartbeatIntervalMs: 60_000,
      });
      clients.push(offline);
      for (let index = 0; index < 105; index += 1) {
        offline.send(createEnvelope('session.update', {
          conversationId: 'conv_queue',
          seq: index,
          kind: 'output',
          text: `chunk-${index}`,
        }));
      }
      assertEqual(offline.getQueueSize(), 100, '队列长度');
      assertEqual(offline.getStats().dropped, 5, '丢弃计数');

      const knownIds = new Set(server.connections.map((connection) => connection.id));
      offline.connect();
      await offline.waitForOpen(5_000);
      const flushedConnection = await waitFor<FakeRelayConnection>(
        '新增 agent 连接',
        () => server.connections.find((connection) => connection.role === 'agent' && !knownIds.has(connection.id)) ?? null,
        5_000,
      );
      const received: RelayEnvelope<unknown>[] = [];
      flushedConnection.onMessage((envelope) => received.push(envelope));
      await waitFor('flush 后服务端收到 100 条', () => (received.length >= 100 ? true : null), 5_000);
      assertEqual(received.length, 100, 'flush 消息数量');
      const texts = received
        .filter((envelope) => envelope.type === 'session.update' && isRecord(envelope.payload))
        .map((envelope) => (envelope.payload as Record<string, unknown>).text);
      assertEqual(texts[0], 'chunk-5', '队首（最旧的 5 条被丢弃）');
      assertEqual(texts[texts.length - 1], 'chunk-104', '队尾');
      assertEqual(offline.getStats().sent, 100, 'sent 计数');
      assertEqual(offline.getQueueSize(), 0, 'flush 后队列为空');
      return { dropped: offline.getStats().dropped, sent: offline.getStats().sent, first: texts[0], last: texts[texts.length - 1] };
    });

    await check(phase, 'B7', '断线指数退避重连（base 100ms）并恢复心跳', async () => {
      assert(mainClient !== null && mainConnection !== null, 'B4 未建立连接');
      const client = mainClient as RelayClient;
      const connection = mainConnection as FakeRelayConnection;
      connection.close(4000, 'selftest: force reconnect');
      await waitFor('客户端进入重连', () => (client.isConnected() ? null : true), 5_000);
      await client.waitForOpen(5_000);
      await waitFor('reconnects 计数 ≥ 1', () => (client.getStats().reconnects >= 1 ? client.getStats().reconnects : null), 5_000);
      const previousPong = client.getStats().lastPongAt;
      await waitFor('重连后心跳恢复', () => {
        const current = client.getStats().lastPongAt;
        return current !== null && current !== previousPong ? current : null;
      }, 5_000);
      return { stats: client.getStats() };
    });

    await check(phase, 'B8', '错误 token 握手被 4401 拒绝：服务端不注册连接且客户端保持断开', async () => {
      const beforeCount = server.connections.length;
      const badClient = new RelayClient({
        url: buildRelayWebSocketUrl(server.serverUrl, 'agent', 'invalid-token'),
        logger: quietLogger.child('relay-client'),
        reconnectBaseMs: 50,
        reconnectMaxMs: 200,
        heartbeatIntervalMs: 60_000,
      });
      clients.push(badClient);
      badClient.connect();
      await delay(1_200);
      assertEqual(badClient.isConnected(), false, '错误 token 不应保持连接');
      assertEqual(server.connections.length, beforeCount, '服务端不应注册被拒绝的连接');
      const status = badClient.getStatus();
      assert(status !== 'open', `错误 token 的连接状态不应是 open：${status}`);
      return { status, connections: server.connections.length };
    });
  } finally {
    for (const client of clients) client.close();
    await server.close();
    collected.phaseB = {
      serverUrl: server.serverUrl,
      issuedTokens: server.issuedTokens.length,
      connections: server.connections.length,
    };
  }
}

// ---------------------------------------------------------------------------
// Phase C：真实 AcpAdapter + RelayAgent（FakeTransport 收上行）
// ---------------------------------------------------------------------------

interface PhaseCOptions {
  acpFull: boolean;
  acpApproval: boolean;
}

async function runPhaseC(options: PhaseCOptions): Promise<void> {
  const phase = 'C';
  console.log('Phase C：真实 ACP（AcpAdapter + RelayAgent）');
  const workspace = join(WORKSPACE_BASE, 'phase-c');
  mkdirSync(workspace, { recursive: true });
  const adapter = new AcpAdapter({ logger: quietLogger.child('acp'), permissionPolicy: 'ask' });
  const transport = new FakeTransport();
  const conversationId = `conv_acp_${process.pid}_${Math.random().toString(36).slice(2, 6)}`;
  let agent: RelayAgent | null = null;
  try {
    const connected = await check(phase, 'C1', 'AcpAdapter.connect + device.status 使用真实 harnessVersion', async () => {
      const status = await adapter.connect();
      assert(status.running, 'ACP harness 未运行');
      agent = new RelayAgent({
        harness: adapter,
        transport,
        workspaceRoot: WORKSPACE_BASE,
        logger: quietLogger,
        deviceName: 'selftest-acp',
        agentVersion: '0.1.0-m1',
        promptTimeoutSec: 180,
      });
      await agent.start();
      transport.clear();
      agent.sendDeviceStatus();
      const envelope = await waitForEnvelope<DeviceStatusPayload>(transport, 'device.status');
      const payload = envelope.payload as DeviceStatusPayload;
      assertEqual(payload.online, true, 'online');
      assertString(payload.harnessVersion, '真实 harnessVersion');
      assertEqual(payload.capabilities.chat, true, 'capabilities.chat');
      assertEqual(payload.capabilities.approvalIntercept, true, 'capabilities.approvalIntercept');
      return {
        online: payload.online,
        harnessVersion: payload.harnessVersion,
        capabilities: payload.capabilities,
        acpStatus: { running: status.running, version: status.version, adapter: status.adapter },
      };
    });
    if (!connected || agent === null) return;
    const relay = agent as RelayAgent;

    const created = await check(phase, 'C2', 'conversation.create → conversation.created（真实 ACP session）', async () => {
      transport.clear();
      receive(relay, transport, 'conversation.create', { conversationId, workspacePath: workspace, title: 'M1 relay 自测' });
      const envelope = await waitForEnvelope<ConversationCreatedPayload>(
        transport,
        'conversation.created',
        (_envelope, payload) => payload.conversationId === conversationId,
        60_000,
      );
      const payload = envelope.payload as ConversationCreatedPayload;
      assertString(payload.sessionId, 'sessionId');
      assertEqual(payload.workspacePath, workspace, 'workspacePath');
      return { sessionId: payload.sessionId };
    });
    if (!created) return;

    const prompted = await check(phase, 'C3', 'prompt.send → session.update(output 含「收到」) → task.state completed', async () => {
      transport.clear();
      receive(relay, transport, 'prompt.send', { conversationId, text: '只回复两个字：收到' });
      const updateEnvelope = await waitForEnvelope<SessionUpdatePayload>(
        transport,
        'session.update',
        (_envelope, payload) =>
          payload.conversationId === conversationId &&
          payload.kind === 'output' &&
          typeof payload.text === 'string' &&
          payload.text.includes('收到'),
        120_000,
        '真实 output',
      );
      const completedEnvelope = await waitForEnvelope<TaskStatePayload>(
        transport,
        'task.state',
        (_envelope, payload) => payload.conversationId === conversationId && payload.state === 'completed',
        120_000,
        '真实 completed',
      );
      assert(
        transport.sent.indexOf(updateEnvelope) < transport.sent.indexOf(completedEnvelope),
        '真实链路：session.update 必须先于 completed',
      );
      const update = updateEnvelope.payload as SessionUpdatePayload;
      return {
        seq: update.seq,
        text: update.kind === 'output' ? update.text : '',
        updateCount: transport.typed('session.update').length,
        terminal: (completedEnvelope.payload as TaskStatePayload).state,
      };
    });

    if (prompted && options.acpFull) {
      await check(phase, 'C4', '真实 cancel：长命令 → task.cancel → cancelled → 同会话继续', async () => {
        transport.clear();
        receive(relay, transport, 'prompt.send', {
          conversationId,
          text: '1..30 | ForEach-Object { Start-Sleep -Milliseconds 300; $_ }',
        });
        const toolUpdate = await waitForEnvelope<SessionUpdatePayload>(
          transport,
          'session.update',
          (_envelope, payload) => payload.kind === 'tool_call' || payload.kind === 'tool_call_update',
          120_000,
          '真实 tool_call（用于确认 turn 已开始执行）',
        );
        transport.clear();
        receive(relay, transport, 'task.cancel', { conversationId });
        await waitForEnvelope<TaskStatePayload>(
          transport,
          'task.state',
          (_envelope, payload) => payload.conversationId === conversationId && payload.state === 'cancelled',
          120_000,
          '真实 cancelled',
        );
        transport.clear();
        receive(relay, transport, 'prompt.send', { conversationId, text: '只回复两个字：继续' });
        await waitForEnvelope<SessionUpdatePayload>(
          transport,
          'session.update',
          (_envelope, payload) => payload.kind === 'output' && typeof payload.text === 'string' && payload.text.includes('继续'),
          120_000,
          '取消后继续的 output',
        );
        await waitForEnvelope<TaskStatePayload>(
          transport,
          'task.state',
          (_envelope, payload) => payload.state === 'completed',
          120_000,
          '取消后继续的 completed',
        );
        return { toolCallSeen: toolUpdate.payload };
      });
    } else if (prompted) {
      console.log('[SKIP] C4 真实 cancel（--acp-full 才运行）');
    }

    if (prompted && options.acpApproval) {
      await check(phase, 'C5', '真实审批：approval.request → approval.decide(approved) → approval.resolved + 终态', async () => {
        const target = join(workspace, 'm1-selftest-ok.txt');
        let requested = false;
        for (let attempt = 1; attempt <= 2 && !requested; attempt += 1) {
          const text = attempt === 1
            ? `请用 pwsh 命令在 ${target} 创建文件，内容 m1-ok。必须用命令行执行，不要使用 write 工具。`
            : `刚才的写入被沙箱拒绝了。请按流程申请一次性权限提升（escalation / permission approval）后再用 pwsh 命令写入 ${target}，内容 m1-ok。不要放弃。`;
          transport.clear();
          receive(relay, transport, 'prompt.send', { conversationId, text });
          const settled = await Promise.race([
            waitForEnvelope<ApprovalRequestPayload>(
              transport,
              'approval.request',
              (_envelope, payload) => payload.conversationId === conversationId,
              180_000,
              '真实 approval.request',
            ).then((envelope) => ({ kind: 'approval' as const, envelope })),
            waitForEnvelope<TaskStatePayload>(
              transport,
              'task.state',
              (_envelope, payload) => payload.conversationId === conversationId &&
                (payload.state === 'completed' || payload.state === 'failed' || payload.state === 'cancelled'),
              180_000,
              '真实终态（未触发审批）',
            ).then((envelope) => ({ kind: 'terminal' as const, envelope })),
          ]);
          if (settled.kind !== 'approval') continue;
          requested = true;
          const request = settled.envelope.payload as ApprovalRequestPayload;
          transport.clear();
          receive(relay, transport, 'approval.decide', {
            conversationId,
            approvalId: request.approvalId,
            decision: 'approved',
          });
          const resolvedEnvelope = await waitForEnvelope<ApprovalResolvedPayload>(
            transport,
            'approval.resolved',
            (_envelope, payload) => payload.approvalId === request.approvalId,
            60_000,
            '真实 approval.resolved',
          );
          assertEqual((resolvedEnvelope.payload as ApprovalResolvedPayload).decidedBy, 'phone', 'decidedBy');
          await waitForEnvelope<TaskStatePayload>(
            transport,
            'task.state',
            (_envelope, payload) => payload.conversationId === conversationId && payload.state !== 'running' && payload.state !== 'queued',
            240_000,
            '审批后的终态',
          );
          return { approvalId: request.approvalId, requested };
        }
        assert(requested, '3 次以内未触发真实审批请求（取决于模型/沙箱行为，可忽略）');
        return { requested };
      });
    } else if (prompted) {
      console.log('[SKIP] C5 真实审批（--acp-approval 才运行，依赖模型与沙箱行为）');
    }

    collected.phaseC = {
      workspace,
      conversationId,
      harnessVersion: adapter.getHarnessVersion(),
      capabilities: await adapter.getCapabilities().then((capabilities) => capabilities.values),
      stats: relay.getStats(),
    };
  } finally {
    agent?.stop();
    await adapter.disconnect().catch((error: unknown) => {
      console.error('[WARN] ACP 断开失败：', error instanceof Error ? error.message : String(error));
    });
  }
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

function parseArgs(argv: string[]): { acp: boolean; acpFull: boolean; acpApproval: boolean } {
  const args = new Set(argv);
  return {
    acp: !args.has('--no-acp'),
    acpFull: args.has('--acp-full'),
    acpApproval: args.has('--acp-approval'),
  };
}

async function main(): Promise<number> {
  const options = parseArgs(process.argv.slice(2));
  mkdirSync(WORKSPACE_BASE, { recursive: true });
  mkdirSync(EVIDENCE_DIR, { recursive: true });
  console.log(`M1 relay 自测开始：node ${process.version}，工作区根 ${WORKSPACE_BASE}`);
  console.log(`选项：${JSON.stringify(options)}`);

  await runPhaseA();
  await runPhaseB();
  if (options.acp) {
    await runPhaseC(options);
  } else {
    console.log('[SKIP] Phase C（--no-acp）');
  }

  const failed = results.filter((result) => !result.ok);
  const finishedAt = new Date().toISOString();
  const stamp = finishedAt.replace(/[:.]/g, '-');
  const evidencePath = join(EVIDENCE_DIR, `relay-selftest-${stamp}.json`);
  const evidence = {
    title: 'M1 relay selftest',
    startedAt,
    finishedAt,
    node: process.version,
    options,
    workspaceBase: WORKSPACE_BASE,
    summary: {
      total: results.length,
      passed: results.length - failed.length,
      failed: failed.length,
      failedIds: failed.map((result) => result.id),
    },
    results,
    collected,
    loggerLines: logLines.slice(-100),
  };
  writeFileSync(evidencePath, `${JSON.stringify(evidence, null, 2)}\n`, 'utf8');

  console.log('');
  console.log(`自测结果：${results.length - failed.length}/${results.length} 通过`);
  if (failed.length > 0) {
    for (const result of failed) console.error(`  ✗ ${result.id} ${result.title}：${result.error}`);
  }
  console.log(`证据文件：${evidencePath}`);
  return failed.length === 0 ? 0 : 1;
}

const entry = process.argv[1];
if (entry !== undefined && resolve(entry) === import.meta.filename) {
  main()
    .then((code) => {
      process.exit(code);
    })
    .catch((error: unknown) => {
      console.error('[FATAL] relay-selftest 失败：', error);
      process.exit(2);
    });
}

export { FakeHarness, FakeTransport, check, results, runPhaseA, runPhaseB, runPhaseC };
