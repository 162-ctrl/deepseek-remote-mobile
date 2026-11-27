/**
 * RelayAgent —— M1 relay 业务编排（唯一契约 docs/design/M1_PROTOCOL.md §3/§5）。
 *
 * 数据流：
 *   App → 后端 →（WSS）→ RelayAgent → AcpAdapter → `dsh --profile acp`
 *   AcpAdapter 事件流 →（RelayAgent 归因 session）→ session.update / approval.request → 后端 → App
 *
 * 状态模型（M1 单 Agent、内存态）：conversationId → { sessionId, workspacePath, seq, busy, handle }。
 *
 * 关键设计：
 *  - 事件归因：HarnessEvent 不含 sessionId，而 AcpAdapter 会把同一个事件对象同时 emit 并存入
 *    session 事件列表。本类按“对象引用身份”向 getSessionEvents(sessionId, consumedSeq) 认领事件，
 *    认领失败（不属于任何活跃 turn）的事件直接丢弃。
 *  - turn 生命周期：prompt.send 置 busy → waitForTurn 结算 → 先 flush 事件队列（保证 session.update
 *    先于 task.state 终态）→ 发终态 → busy 解除。
 *  - 审批：approval_request 事件 → 本地按 expiresAt 定时判定超时 → approval.resolved。
 *  - 所有上报 payload 统一 redactDeep 脱敏后再交给 transport。
 */
import { mkdirSync } from 'node:fs';
import { isAbsolute, resolve, sep } from 'node:path';

import type {
  ApprovalRequest,
  CancelResult,
  HarnessCapabilities,
  HarnessEvent,
  HarnessSession,
  TaskHandle,
  TaskInput,
} from '../harness/adapter.ts';
import type { TurnSettlement } from '../harness/acp/acp-adapter.ts';
import { toHarnessError } from '../harness/errors.ts';
import type { HarnessErrorCode } from '../harness/errors.ts';
import { Logger } from '../infra/logger.ts';
import { redactDeep, safeErrorMessage, truncateText } from '../infra/redact.ts';
import { createEnvelope, envelopeByteSize, isRecord, readNumber, readPayloadRecord, readString } from './protocol.ts';
import { WorkspaceFsError, listDirectory, readTextFile, writeTextFile } from './workspace-fs.ts';
import type {
  ApprovalRequestPayload,
  ApprovalResolvedPayload,
  ConversationCreatedPayload,
  DeviceCapabilitiesPayload,
  DeviceStatusPayload,
  ErrorPayload,
  RelayEnvelope,
  RelayErrorCode,
  RelayTransport,
  SessionUpdateBody,
  SessionUpdatePayload,
  TaskState,
  TaskStateDetail,
  TaskStatePayload,
} from './protocol.ts';

/** 审批结算状态（与 AcpAdapter.decideApproval 的入参一致）。 */
export type ApprovalSettlement = 'approved' | 'denied' | 'expired' | 'cancelled';

/**
 * RelayAgent 依赖的 Harness 结构子集。
 * 真实实现传 AcpAdapter（它满足全部方法），自测可注入脚本化假实现。
 */
export interface RelayHarness {
  createSession(workspacePath: string, title?: string): Promise<HarnessSession>;
  sendMessage(sessionId: string, input: TaskInput): Promise<TaskHandle>;
  cancelTask(handle: TaskHandle): Promise<CancelResult>;
  waitForTurn(sessionId: string, timeoutMs?: number): Promise<TurnSettlement>;
  decideApproval(approvalId: string, status: ApprovalSettlement): boolean;
  getSessionEvents(sessionId: string, sinceSeq?: number): Promise<ReadonlyArray<HarnessEvent>>;
  subscribe(listener: (event: HarnessEvent) => void): () => void;
  getCapabilities(): Promise<HarnessCapabilities>;
  getHarnessVersion(): string | null;
}

export interface RelayAgentOptions {
  readonly harness: RelayHarness;
  readonly transport: RelayTransport;
  /** 允许的工作区根目录（绝对路径）；conversation.create 的 workspacePath 必须落在其中任一之内。 */
  readonly workspaceRoot: string;
  /** M2.6.1：多个授权根目录（可选，首个作为默认工作区）；提供时优先于 workspaceRoot。 */
  readonly workspaceRoots?: readonly string[];
  readonly logger?: Logger;
  readonly deviceName?: string;
  readonly agentVersion?: string;
  /**
   * 单轮 prompt 的 ACP 超时（秒），默认 720。
   * 需大于审批超时（默认 10 分钟），否则审批等待会被 JSON-RPC 超时打断。
   */
  readonly promptTimeoutSec?: number;
}

interface ConversationState {
  conversationId: string;
  sessionId: string;
  workspacePath: string;
  title?: string;
  /** session.update 序号，从 1 开始单调递增。 */
  seq: number;
  busy: boolean;
  handle: TaskHandle | null;
  /** 已认领到该 session 事件流的最后一条事件 seq。 */
  consumedEventSeq: number;
  /** 该会话尚未结算的审批 id。 */
  pendingApprovalIds: Set<string>;
}

interface PendingApprovalState {
  approvalId: string;
  conversationId: string;
  timer: ReturnType<typeof setTimeout> | null;
}

interface RelayAgentStats {
  conversations: number;
  activeTurns: number;
  pendingApprovals: number;
  queuedHarnessEvents: number;
}

/** Harness 错误码 → relay 错误码（§3 错误码全集）。 */
function mapHarnessErrorCode(code: HarnessErrorCode): RelayErrorCode {
  switch (code) {
    case 'SESSION_BUSY':
      return 'SESSION_BUSY';
    case 'SESSION_NOT_FOUND':
      return 'CONVERSATION_NOT_FOUND';
    default:
      return 'INTERNAL';
  }
}

/** 判断 target 是否位于 root 之内（Windows 大小写不敏感）。 */
function isPathInsideWorkspace(target: string, root: string): boolean {
  const caseFold = process.platform === 'win32';
  const normalizedRoot = root.endsWith(sep) ? root : root + sep;
  const t = caseFold ? target.toLowerCase() : target;
  const r = caseFold ? normalizedRoot.toLowerCase() : normalizedRoot;
  const base = caseFold ? root.toLowerCase() : root;
  return t === base || t.startsWith(r);
}

/** M4.20：去空、转绝对路径、去重（Windows 大小写不敏感）。 */
function normalizeWorkspaceRoots(roots: readonly string[]): readonly string[] {
  const caseFold = process.platform === 'win32';
  const seen = new Set<string>();
  const out: string[] = [];
  for (const item of roots) {
    if (typeof item !== 'string') {
      continue;
    }
    const trimmed = item.trim();
    if (trimmed.length === 0) {
      continue;
    }
    const absolute = isAbsolute(trimmed) ? trimmed : resolve(trimmed);
    const key = caseFold ? absolute.toLowerCase() : absolute;
    if (seen.has(key)) {
      continue;
    }
    seen.add(key);
    out.push(absolute);
  }
  return out;
}

/** M4.20：两组授权目录是否等价（顺序也算，首个是默认工作区）。 */
function sameWorkspaceRoots(a: readonly string[], b: readonly string[]): boolean {
  if (a.length !== b.length) {
    return false;
  }
  return a.every((item, index) => item === b[index]);
}

export class RelayAgent {
  private readonly harness: RelayHarness;
  private readonly transport: RelayTransport;
  private readonly logger: Logger;
  private workspaceRoot: string;
  private workspaceRoots: readonly string[];
  private readonly deviceName: string;
  private readonly agentVersion: string;
  private readonly promptTimeoutSec: number;

  private readonly conversations = new Map<string, ConversationState>();
  private readonly pendingApprovals = new Map<string, PendingApprovalState>();
  private readonly eventQueue: HarnessEvent[] = [];
  private drainPromise: Promise<void> | null = null;
  private unsubscribe: (() => void) | null = null;
  private capabilities: HarnessCapabilities | null = null;
  private started = false;
  private taskCounter = 0;
  private conversationCounter = 0;

  constructor(options: RelayAgentOptions) {
    this.harness = options.harness;
    this.transport = options.transport;
    this.logger = options.logger ?? new Logger({ scope: 'relay-agent' });
    const roots = (options.workspaceRoots ?? [options.workspaceRoot])
      .map((item) => item.trim())
      .filter((item) => item.length > 0)
      .map((item) => resolve(item));
    this.workspaceRoots = roots.length > 0 ? roots : [resolve(options.workspaceRoot)];
    this.workspaceRoot = this.workspaceRoots[0];
    this.deviceName = options.deviceName ?? 'deepseek-agent';
    this.agentVersion = options.agentVersion ?? '0.1.0-m1';
    this.promptTimeoutSec = options.promptTimeoutSec ?? 720;
  }

  /* ---------------------------------------------------------------------- */
  /* 生命周期                                                                */
  /* ---------------------------------------------------------------------- */

  /** 探测能力并订阅 harness 事件。可重复调用（幂等）。 */
  async start(): Promise<void> {
    if (this.started) {
      return;
    }
    this.started = true;
    try {
      this.capabilities = await this.harness.getCapabilities();
    } catch (error) {
      this.capabilities = null;
      this.logger.warn('relay.agent.capabilities.failed', { message: safeErrorMessage(error) });
    }
    this.unsubscribe = this.harness.subscribe((event) => this.onHarnessEvent(event));
    this.logger.info('relay.agent.started', {
      workspaceRoot: this.workspaceRoot,
      workspaceRoots: this.workspaceRoots,
      harnessVersion: this.harness.getHarnessVersion(),
      capabilities: this.capabilities?.values ?? null,
    });
  }

  /** 取消订阅、清空审批定时器。 */
  stop(): void {
    this.started = false;
    if (this.unsubscribe !== null) {
      this.unsubscribe();
      this.unsubscribe = null;
    }
    for (const pending of [...this.pendingApprovals.values()]) {
      this.disposeApproval(pending);
    }
    this.eventQueue.length = 0;
    this.drainPromise = null;
    this.logger.info('relay.agent.stopped', { stats: this.getStats() });
  }

  /* ---------------------------------------------------------------------- */
  /* 下行消息入口（由 transport.onMessage 或自测直接调用）                     */
  /* ---------------------------------------------------------------------- */

  async handleEnvelope(envelope: RelayEnvelope<unknown>): Promise<void> {
    const type = envelope.type;
    if (type === 'ping') {
      this.send('pong');
      return;
    }
    if (type === 'pong') {
      this.logger.debug('relay.agent.pong', {});
      return;
    }
    const payload = readPayloadRecord(envelope);
    const conversationId = readString(payload, 'conversationId') ?? undefined;
    this.logger.info('relay.agent.recv', { type, conversationId });
    try {
      switch (type) {
        case 'conversation.create':
          await this.handleConversationCreate(payload);
          return;
        case 'prompt.send':
          await this.handlePromptSend(payload);
          return;
        case 'task.cancel':
          await this.handleTaskCancel(payload);
          return;
        case 'approval.decide':
          this.handleApprovalDecide(payload);
          return;
        case 'workspace.list':
          await this.handleWorkspaceList(payload);
          return;
        case 'file.read':
          await this.handleFileRead(payload);
          return;
        case 'file.write':
          await this.handleFileWrite(payload);
          return;
        case 'error':
          this.logger.warn('relay.agent.backend.error', {
            code: readString(payload, 'code'),
            message: readString(payload, 'message'),
          });
          return;
        default:
          this.logger.warn('relay.agent.recv.unknown', { type });
      }
    } catch (error) {
      this.logger.warn('relay.agent.handle.failed', {
        type,
        conversationId,
        message: safeErrorMessage(error),
      });
      this.sendError('INTERNAL', safeErrorMessage(error), conversationId);
    }
  }

  /* ---------------------------------------------------------------------- */
  /* device.status                                                           */
  /* ---------------------------------------------------------------------- */

  /** 构造 device.status（供 serve.ts 在每次 WSS 连接建立后上报）。 */
  buildDeviceStatus(): DeviceStatusPayload {
    const values = this.capabilities?.values;
    const capabilities: DeviceCapabilitiesPayload = {
      chat: values?.chat ?? true,
      cancel: values?.cancel ?? true,
      approvalIntercept: values?.approvalIntercept ?? true,
      sessionResume: values?.sessionResume ?? true,
      // M2.6：工作区浏览/文件预览由 Agent 本地文件系统实现，与 Harness 能力无关。
      workspaceList: true,
      fileRead: true,
      // M2.8：手机端写入（授权根内 + sha256 乐观锁 + 人工确认）。
      fileWrite: true,
    };
    return {
      online: true,
      deviceName: this.deviceName,
      agentVersion: this.agentVersion,
      harnessVersion: this.harness.getHarnessVersion(),
      capabilities,
      workspaceRoots: [...this.workspaceRoots],
      lastSeen: new Date().toISOString(),
    };
  }

  /** 上报 device.status（连接建立后调用）。 */
  sendDeviceStatus(): void {
    const payload = this.buildDeviceStatus();
    this.send('device.status', payload);
    this.logger.info('relay.device.status.sent', {
      online: payload.online,
      deviceName: payload.deviceName,
      harnessVersion: payload.harnessVersion,
    });
  }

  /**
   * M4.20：换掉授权目录。
   *
   * Agent 是插件在 DSH 刚启动时拉起来的，那时 `workspaceRegistry` 往往还没就绪，
   * 插件只能把 `homedir()` 递进来 —— 手机上「工作区」整页就只剩一个 `C:\Users\…`，
   * 项目卡、会话全都不见了。所以允许外部（`serve.ts` 的定时刷新）拿插件侧的真实
   * 目录覆盖它；真有变化就补发一次 device.status，手机不用重连也能把卡片长回来。
   *
   * @returns 是否真的变了（调用方据此决定要不要记日志）。
   */
  setWorkspaceRoots(next: readonly string[]): boolean {
    const normalized = normalizeWorkspaceRoots(next);
    if (normalized.length === 0) {
      return false;
    }
    if (sameWorkspaceRoots(normalized, this.workspaceRoots)) {
      return false;
    }
    const before = [...this.workspaceRoots];
    this.workspaceRoots = normalized;
    this.workspaceRoot = normalized[0] ?? this.workspaceRoot;
    this.logger.info('relay.agent.workspace_roots.updated', {
      before,
      after: [...normalized],
    });
    if (this.started) {
      this.sendDeviceStatus();
    }
    return true;
  }

  /* ---------------------------------------------------------------------- */
  /* 诊断                                                                    */
  /* ---------------------------------------------------------------------- */

  getStats(): RelayAgentStats {
    let activeTurns = 0;
    for (const conversation of this.conversations.values()) {
      if (conversation.busy) {
        activeTurns += 1;
      }
    }
    return {
      conversations: this.conversations.size,
      activeTurns,
      pendingApprovals: this.pendingApprovals.size,
      queuedHarnessEvents: this.eventQueue.length,
    };
  }

  getConversation(conversationId: string): {
    sessionId: string;
    workspacePath: string;
    busy: boolean;
    seq: number;
  } | null {
    const conversation = this.conversations.get(conversationId);
    if (conversation === undefined) {
      return null;
    }
    return {
      sessionId: conversation.sessionId,
      workspacePath: conversation.workspacePath,
      busy: conversation.busy,
      seq: conversation.seq,
    };
  }

  getWorkspaceRoot(): string {
    return this.workspaceRoot;
  }

  /* ---------------------------------------------------------------------- */
  /* conversation.create                                                     */
  /* ---------------------------------------------------------------------- */

  private async handleConversationCreate(payload: Record<string, unknown> | null): Promise<void> {
    const conversationId = readString(payload, 'conversationId') ?? this.nextConversationId();
    const title = readString(payload, 'title') ?? undefined;
    const requestedWorkspacePath = readString(payload, 'workspacePath');
    this.logger.info('relay.conversation.create', {
      conversationId,
      workspacePath: requestedWorkspacePath ?? this.workspaceRoot,
      title,
    });

    const existing = this.conversations.get(conversationId);
    if (existing !== undefined) {
      // 幂等：重复 create 直接回已建信息，不重复开 ACP 会话。
      this.sendConversationCreated(existing);
      return;
    }

    const resolved = this.resolveWorkspacePath(requestedWorkspacePath);
    if (!resolved.ok) {
      this.logger.warn('relay.conversation.create.path_not_allowed', {
        conversationId,
        workspacePath: requestedWorkspacePath,
        root: this.workspaceRoot,
      });
      this.sendError('PATH_NOT_ALLOWED', resolved.message, conversationId);
      return;
    }
    try {
      mkdirSync(resolved.path, { recursive: true });
    } catch (error) {
      this.sendError('INTERNAL', `无法创建工作区目录：${safeErrorMessage(error)}`, conversationId);
      return;
    }

    let session: HarnessSession;
    try {
      session = await this.harness.createSession(resolved.path, title);
    } catch (error) {
      this.sendError('INTERNAL', `创建 ACP 会话失败：${safeErrorMessage(error)}`, conversationId);
      return;
    }

    const state: ConversationState = {
      conversationId,
      sessionId: session.sessionId,
      workspacePath: resolved.path,
      title,
      seq: 0,
      busy: false,
      handle: null,
      consumedEventSeq: 0,
      pendingApprovalIds: new Set<string>(),
    };
    this.conversations.set(conversationId, state);
    this.sendConversationCreated(state);
  }

  private sendConversationCreated(conversation: ConversationState): void {
    const payload: ConversationCreatedPayload = {
      conversationId: conversation.conversationId,
      sessionId: conversation.sessionId,
      workspacePath: conversation.workspacePath,
      title: conversation.title,
    };
    this.send('conversation.created', payload);
    this.logger.info('relay.conversation.created', {
      conversationId: conversation.conversationId,
      sessionId: conversation.sessionId,
      workspacePath: conversation.workspacePath,
    });
  }

  /**
   * 校验工作区：缺省用第一个根；必须是绝对路径；resolve 后必须位于任一授权根内。
   * 使用 path.resolve 前缀检查（Windows 大小写不敏感），拒绝 `..` 逃逸与 UNC 歧义。
   */
  private resolveWorkspacePath(
    requestedPath: string | null,
  ): { ok: true; path: string } | { ok: false; message: string } {
    if (requestedPath === null || requestedPath.trim() === '') {
      return { ok: true, path: this.workspaceRoot };
    }
    if (requestedPath.includes('\u0000')) {
      return { ok: false, message: 'workspacePath 含非法字符' };
    }
    if (!isAbsolute(requestedPath)) {
      return {
        ok: false,
        message: `workspacePath 必须是绝对路径：${requestedPath}（roots=${this.workspaceRoots.join(', ')}）`,
      };
    }
    const target = resolve(requestedPath);
    if (!this.workspaceRoots.some((root) => isPathInsideWorkspace(target, root))) {
      return {
        ok: false,
        message: `workspacePath 不在授权目录内：${target}（roots=${this.workspaceRoots.join(', ')}）`,
      };
    }
    return { ok: true, path: target };
  }

  /* ---------------------------------------------------------------------- */
  /* prompt.send / turn 生命周期                                             */
  /* ---------------------------------------------------------------------- */

  private async handlePromptSend(payload: Record<string, unknown> | null): Promise<void> {
    const conversationId = readString(payload, 'conversationId');
    const text = readString(payload, 'text');
    if (conversationId === null) {
      this.sendError('BAD_REQUEST', 'prompt.send 缺少 conversationId');
      return;
    }
    const conversation = this.conversations.get(conversationId);
    if (conversation === undefined) {
      this.sendError('CONVERSATION_NOT_FOUND', `未知会话：${conversationId}`, conversationId);
      return;
    }
    if (text === null || text.trim().length === 0) {
      this.sendError('BAD_REQUEST', 'prompt.send 缺少 text', conversationId);
      return;
    }
    if (conversation.busy) {
      this.sendError('SESSION_BUSY', '该会话已有进行中的 turn', conversationId);
      return;
    }

    this.logger.info('relay.prompt.send', { conversationId, chars: text.length });
    // 先占位，防止并发 prompt 穿透 busy 检查。
    conversation.busy = true;

    let handle: TaskHandle;
    try {
      const input: TaskInput = {
        taskId: this.nextTaskId(),
        conversationId,
        prompt: text,
        workspacePath: conversation.workspacePath,
        timeoutSec: this.promptTimeoutSec,
      };
      handle = await this.harness.sendMessage(conversation.sessionId, input);
    } catch (error) {
      conversation.busy = false;
      conversation.handle = null;
      const harnessError = toHarnessError(error, 'INTERNAL');
      this.logger.warn('relay.prompt.send.failed', {
        conversationId,
        code: harnessError.code,
        message: harnessError.message,
      });
      this.sendError(mapHarnessErrorCode(harnessError.code), harnessError.message, conversationId);
      return;
    }

    conversation.handle = handle;
    this.sendTaskState(conversation, 'running');
    void this.monitorTurn(conversation, handle);
  }

  /** 等待 turn 结算 → flush 流式事件 → 上报终态。 */
  private async monitorTurn(conversation: ConversationState, handle: TaskHandle): Promise<void> {
    const timeoutMs = (this.promptTimeoutSec + 60) * 1000;
    let settlement: TurnSettlement;
    try {
      settlement = await this.harness.waitForTurn(conversation.sessionId, timeoutMs);
    } catch (error) {
      settlement = {
        stopReason: 'error',
        summary: '',
        error: toHarnessError(error, 'INTERNAL'),
      };
    }
    // 保证 session.update（output/tool_call/usage…）先于 task.state 终态发出。
    try {
      await this.flushHarnessEvents();
    } catch (error) {
      this.logger.warn('relay.turn.flush.failed', {
        conversationId: conversation.conversationId,
        message: safeErrorMessage(error),
      });
    }
    this.finalizeTurn(conversation, handle, settlement);
  }

  private finalizeTurn(
    conversation: ConversationState,
    handle: TaskHandle,
    settlement: TurnSettlement,
  ): void {
    if (conversation.handle !== handle) {
      this.logger.debug('relay.turn.stale', {
        conversationId: conversation.conversationId,
        stopReason: settlement.stopReason,
      });
      return;
    }
    conversation.handle = null;
    conversation.busy = false;
    this.discardPendingApprovals(conversation);

    if (settlement.stopReason === 'end_turn') {
      this.sendTaskState(conversation, 'completed');
      return;
    }
    if (settlement.stopReason === 'cancelled') {
      this.sendTaskState(conversation, 'cancelled');
      return;
    }
    const error = settlement.error;
    const detail: TaskStateDetail = {
      code: error?.code ?? 'INTERNAL',
      message: truncateText(error?.message ?? 'ACP turn 异常结束', 1000),
    };
    this.logger.warn('relay.turn.failed', {
      conversationId: conversation.conversationId,
      code: detail.code,
      message: detail.message,
    });
    this.sendTaskState(conversation, 'failed', detail);
  }

  /* ---------------------------------------------------------------------- */
  /* task.cancel                                                             */
  /* ---------------------------------------------------------------------- */

  private async handleTaskCancel(payload: Record<string, unknown> | null): Promise<void> {
    const conversationId = readString(payload, 'conversationId');
    if (conversationId === null) {
      this.sendError('BAD_REQUEST', 'task.cancel 缺少 conversationId');
      return;
    }
    const conversation = this.conversations.get(conversationId);
    if (conversation === undefined) {
      this.sendError('CONVERSATION_NOT_FOUND', `未知会话：${conversationId}`, conversationId);
      return;
    }
    const handle = conversation.handle;
    if (handle === null) {
      this.logger.info('relay.cancel.noop', { conversationId });
      this.sendError('BAD_REQUEST', '该会话没有进行中的 turn', conversationId);
      return;
    }
    this.logger.info('relay.cancel.request', { conversationId, taskId: handle.taskId });
    try {
      const result: CancelResult = await this.harness.cancelTask(handle);
      this.logger.info('relay.cancel.result', {
        conversationId,
        accepted: result.accepted,
        harnessAck: result.harnessAck,
        mechanism: result.mechanism,
      });
    } catch (error) {
      this.logger.warn('relay.cancel.failed', {
        conversationId,
        message: safeErrorMessage(error),
      });
      this.sendError('INTERNAL', `取消失败：${safeErrorMessage(error)}`, conversationId);
    }
    // 终态不在此处上报：monitorTurn 会依据 turn settlement 发 task.state cancelled，
    // 避免与正常结束路径重复发终态。
  }

  /* ---------------------------------------------------------------------- */
  /* 审批                                                                    */
  /* ---------------------------------------------------------------------- */

  private handleApprovalRequest(conversation: ConversationState, request: ApprovalRequest): void {
    if (this.pendingApprovals.has(request.approvalId)) {
      this.logger.debug('relay.approval.duplicate', {
        conversationId: conversation.conversationId,
        approvalId: request.approvalId,
      });
      return;
    }
    const providedOptions = (request.options ?? []).map((option) => ({
      kind: option.kind,
      label: option.label,
    }));
    const payload: ApprovalRequestPayload = {
      conversationId: conversation.conversationId,
      approvalId: request.approvalId,
      tool: request.tool ?? 'unknown',
      input: this.extractApprovalInput(request),
      workspace: conversation.workspacePath,
      options:
        providedOptions.length > 0
          ? providedOptions
          : [
              { kind: 'allow_once', label: '允许一次' },
              { kind: 'reject_once', label: '拒绝' },
            ],
      permissionLevel: request.permissionLevel,
      riskLevel: request.riskLevel,
      expiresAt: request.expiresAt,
    };
    const pending: PendingApprovalState = {
      approvalId: request.approvalId,
      conversationId: conversation.conversationId,
      timer: null,
    };
    const delayMs = this.approvalDelayMs(request.expiresAt);
    pending.timer = setTimeout(() => this.expireApproval(request.approvalId), delayMs);
    if (typeof pending.timer.unref === 'function') {
      pending.timer.unref();
    }
    this.pendingApprovals.set(request.approvalId, pending);
    conversation.pendingApprovalIds.add(request.approvalId);
    this.send('approval.request', payload);
    this.logger.info('relay.approval.request', {
      conversationId: conversation.conversationId,
      approvalId: request.approvalId,
      tool: request.tool,
      expiresAt: request.expiresAt,
      options: payload.options.length,
    });
  }

  /** ACP 的 toolInput 在 ApprovalRequest.payload.toolInput 中，优先作为 input 上报。 */
  private extractApprovalInput(request: ApprovalRequest): unknown {
    const payload = isRecord(request.payload) ? request.payload : null;
    if (payload !== null && payload.toolInput !== undefined) {
      return payload.toolInput;
    }
    return request.payload ?? null;
  }

  private approvalDelayMs(expiresAt: string): number {
    const expires = Date.parse(expiresAt);
    if (!Number.isFinite(expires)) {
      return 10 * 60_000;
    }
    // 比 ACP 自动超时略晚 1s：正常情况下由 ACP 先结算，这里只兜底。
    return Math.max(1_000, expires - Date.now() + 1_000);
  }

  private handleApprovalDecide(payload: Record<string, unknown> | null): void {
    const approvalId = readString(payload, 'approvalId');
    const decision = readString(payload, 'decision');
    const conversationId = readString(payload, 'conversationId') ?? undefined;
    if (approvalId === null || (decision !== 'approved' && decision !== 'denied')) {
      this.sendError('BAD_REQUEST', 'approval.decide 参数非法', conversationId);
      return;
    }
    const pending = this.pendingApprovals.get(approvalId);
    if (pending === undefined) {
      this.sendError('BAD_REQUEST', `审批不存在或已结算：${approvalId}`, conversationId);
      return;
    }
    if (conversationId !== undefined && conversationId !== pending.conversationId) {
      this.sendError('BAD_REQUEST', 'approvalId 与 conversationId 不匹配', conversationId);
      return;
    }
    let accepted = false;
    try {
      accepted = this.harness.decideApproval(approvalId, decision);
    } catch (error) {
      this.logger.warn('relay.approval.decide.failed', {
        approvalId,
        message: safeErrorMessage(error),
      });
    }
    this.disposeApproval(pending);
    if (!accepted) {
      this.sendError('BAD_REQUEST', `审批已失效：${approvalId}`, pending.conversationId);
      return;
    }
    const resolved: ApprovalResolvedPayload = {
      conversationId: pending.conversationId,
      approvalId,
      decision,
      decidedBy: 'phone',
    };
    this.send('approval.resolved', resolved);
    this.logger.info('relay.approval.resolved', {
      conversationId: pending.conversationId,
      approvalId,
      decision,
    });
  }

  /* ---------------------------------------------------------------------- */
  /* M2.6 项目同步：工作区文件系统（只读，契约 M2_6_PROJECT_SYNC_DELTA.md §2） */
  /* ---------------------------------------------------------------------- */

  /** workspace.list：列目录（目录在前，忽略 node_modules/.git 等）。 */
  private async handleWorkspaceList(payload: Record<string, unknown> | null): Promise<void> {
    const requestId = readString(payload, 'requestId');
    if (requestId === null) {
      this.sendError('BAD_REQUEST', 'workspace.list 缺少 requestId');
      return;
    }
    try {
      const listing = await listDirectory(
        this.workspaceRoots,
        readString(payload, 'workspacePath'),
        readString(payload, 'relativePath'),
      );
      this.send('workspace.list.result', { requestId, ok: true, ...listing });
    } catch (error) {
      this.sendWorkspaceError('workspace.list.result', requestId, error);
    }
  }

  /** file.read：读文本文件（限大小、二进制拒绝、返回 sha256）。 */
  private async handleFileRead(payload: Record<string, unknown> | null): Promise<void> {
    const requestId = readString(payload, 'requestId');
    if (requestId === null) {
      this.sendError('BAD_REQUEST', 'file.read 缺少 requestId');
      return;
    }
    try {
      const file = await readTextFile(
        this.workspaceRoots,
        readString(payload, 'workspacePath'),
        readString(payload, 'relativePath'),
        readNumber(payload, 'maxBytes'),
      );
      this.send('file.read.result', { requestId, ok: true, ...file });
    } catch (error) {
      this.sendWorkspaceError('file.read.result', requestId, error);
    }
  }

  /** file.write：写文本文件（契约 M2_8_FILE_WRITE_DELTA §3，sha256 乐观锁 + 原子落盘）。 */
  private async handleFileWrite(payload: Record<string, unknown> | null): Promise<void> {
    const requestId = readString(payload, 'requestId');
    if (requestId === null) {
      this.sendError('BAD_REQUEST', 'file.write 缺少 requestId');
      return;
    }
    try {
      const content = readString(payload, 'content');
      if (content === null) {
        throw new WorkspaceFsError('BAD_REQUEST', 'file.write 缺少 content');
      }
      const result = await writeTextFile(
        this.workspaceRoots,
        readString(payload, 'workspacePath'),
        readString(payload, 'relativePath'),
        content,
        {
          baseSha256: readString(payload, 'baseSha256'),
          force: payload !== null && payload['force'] === true,
        },
      );
      this.logger.info('relay.file.write', {
        relativePath: result.relativePath,
        size: result.size,
        sha256: result.sha256.slice(0, 8),
        created: result.created,
        forced: payload !== null && payload['force'] === true,
      });
      this.send('file.write.result', { requestId, ok: true, ...result });
    } catch (error) {
      this.sendWorkspaceError('file.write.result', requestId, error);
    }
  }

  private sendWorkspaceError(
    type: 'workspace.list.result' | 'file.read.result' | 'file.write.result',
    requestId: string,
    error: unknown,
  ): void {
    const code = error instanceof WorkspaceFsError ? error.code : 'INTERNAL';
    const message = safeErrorMessage(error);
    this.logger.warn('relay.workspace.failed', { type, requestId, code, message });
    this.send(type, { requestId, ok: false, code, message });
  }

  /** 本地超时兜底：让 ACP 按拒绝语义结算，并上报 approval.resolved(expired/timeout)。 */
  private expireApproval(approvalId: string): void {
    const pending = this.pendingApprovals.get(approvalId);
    if (pending === undefined) {
      return;
    }
    try {
      this.harness.decideApproval(approvalId, 'expired');
    } catch (error) {
      this.logger.warn('relay.approval.expire.failed', {
        approvalId,
        message: safeErrorMessage(error),
      });
    }
    this.disposeApproval(pending);
    const resolved: ApprovalResolvedPayload = {
      conversationId: pending.conversationId,
      approvalId,
      decision: 'expired',
      decidedBy: 'timeout',
    };
    this.send('approval.resolved', resolved);
    this.logger.info('relay.approval.timeout', {
      conversationId: pending.conversationId,
      approvalId,
    });
  }

  /** 清掉本地定时器与索引（不发送消息）。 */
  private disposeApproval(pending: PendingApprovalState): void {
    if (pending.timer !== null) {
      clearTimeout(pending.timer);
      pending.timer = null;
    }
    this.pendingApprovals.delete(pending.approvalId);
    const conversation = this.conversations.get(pending.conversationId);
    if (conversation !== undefined) {
      conversation.pendingApprovalIds.delete(pending.approvalId);
    }
  }

  /** turn 终态时丢弃残留审批（取消/异常结束场景），App 依据 task.state 清理 UI。 */
  private discardPendingApprovals(conversation: ConversationState): void {
    for (const approvalId of [...conversation.pendingApprovalIds]) {
      const pending = this.pendingApprovals.get(approvalId);
      if (pending !== undefined) {
        this.disposeApproval(pending);
      } else {
        conversation.pendingApprovalIds.delete(approvalId);
      }
    }
  }

  /* ---------------------------------------------------------------------- */
  /* Harness 事件 → session.update                                           */
  /* ---------------------------------------------------------------------- */

  private onHarnessEvent(event: HarnessEvent): void {
    this.eventQueue.push(event);
    this.scheduleDrain();
  }

  private scheduleDrain(): void {
    if (this.drainPromise !== null) {
      return;
    }
    this.drainPromise = this.drainQueue().finally(() => {
      this.drainPromise = null;
      if (this.eventQueue.length > 0) {
        this.scheduleDrain();
      }
    });
  }

  private async drainQueue(): Promise<void> {
    while (this.eventQueue.length > 0) {
      const event = this.eventQueue.shift();
      if (event === undefined) {
        continue;
      }
      try {
        const conversation = await this.attributeEvent(event);
        if (conversation === null) {
          this.logger.debug('relay.event.unattributed', { eventType: event.type });
          continue;
        }
        this.forwardHarnessEvent(conversation, event);
      } catch (error) {
        this.logger.warn('relay.event.forward.failed', {
          eventType: event.type,
          message: safeErrorMessage(error),
        });
      }
    }
  }

  /** 等待当前事件队列清空（保证终态排在所有 session.update 之后）。 */
  private async flushHarnessEvents(): Promise<void> {
    let guard = 0;
    while ((this.eventQueue.length > 0 || this.drainPromise !== null) && guard < 10_000) {
      guard += 1;
      if (this.drainPromise === null) {
        this.scheduleDrain();
      }
      const pending = this.drainPromise;
      if (pending === null) {
        break;
      }
      await pending;
    }
  }

  /**
   * 事件归因：HarnessEvent 无 sessionId，用对象引用身份到各活跃会话的事件流里认领。
   * 认领成功即推进该会话的 consumedEventSeq（顺带丢弃之前未被认领的陈旧事件）。
   */
  private async attributeEvent(event: HarnessEvent): Promise<ConversationState | null> {
    for (const conversation of this.conversations.values()) {
      if (!conversation.busy) {
        continue;
      }
      const events = await this.harness.getSessionEvents(
        conversation.sessionId,
        conversation.consumedEventSeq,
      );
      const index = events.indexOf(event);
      if (index >= 0) {
        conversation.consumedEventSeq += index + 1;
        return conversation;
      }
    }
    return null;
  }

  private forwardHarnessEvent(conversation: ConversationState, event: HarnessEvent): void {
    switch (event.type) {
      case 'output':
        // answer/stdout/stderr/log 统一以 output 上报，App 端负责展示。
        this.sendSessionUpdate(conversation, { kind: 'output', text: event.text });
        return;
      case 'thinking':
        this.sendSessionUpdate(conversation, { kind: 'thinking', text: event.text });
        return;
      case 'tool_call':
        this.sendSessionUpdate(conversation, {
          kind: 'tool_call',
          callId: event.callId,
          tool: event.tool,
          input: event.input,
        });
        return;
      case 'tool_call_update':
        this.sendSessionUpdate(conversation, {
          kind: 'tool_call_update',
          callId: event.callId,
          status: event.status,
          resultExcerpt: event.resultExcerpt,
        });
        return;
      case 'usage':
        this.sendSessionUpdate(conversation, {
          kind: 'usage',
          contextUsed: event.contextUsed,
          contextSize: event.contextSize,
        });
        return;
      case 'approval_request':
        this.handleApprovalRequest(conversation, event.request);
        return;
      case 'completed':
      case 'failed':
        // 终态统一由 turn settlement 决定，避免与 waitForTurn 的结果竞态。
        return;
      default:
        // progress / session_message 等 M1 未定义 kind，跳过。
        this.logger.debug('relay.event.skipped', { eventType: event.type });
    }
  }

  private sendSessionUpdate(conversation: ConversationState, body: SessionUpdateBody): void {
    conversation.seq += 1;
    const payload = {
      conversationId: conversation.conversationId,
      seq: conversation.seq,
      ...body,
    } as unknown as SessionUpdatePayload;
    this.send('session.update', payload);
  }

  /* ---------------------------------------------------------------------- */
  /* 发送                                                                    */
  /* ---------------------------------------------------------------------- */

  /** 统一出口：redact 脱敏 + 日志 + 交给 transport（未连接时由 transport 排队）。 */
  private send(type: string, payload?: unknown): void {
    const safePayload = payload === undefined ? undefined : redactDeep(payload);
    let envelope: RelayEnvelope<unknown>;
    try {
      envelope = createEnvelope(type, safePayload);
    } catch (error) {
      this.logger.warn('relay.agent.send.serialize.failed', {
        type,
        message: safeErrorMessage(error),
      });
      return;
    }
    try {
      this.transport.send(envelope);
    } catch (error) {
      this.logger.warn('relay.agent.send.failed', {
        type,
        message: safeErrorMessage(error),
      });
      return;
    }
    const conversationId = isRecord(safePayload)
      ? (readString(safePayload, 'conversationId') ?? undefined)
      : undefined;
    if (type !== 'session.update') {
      this.logger.info('relay.agent.send', {
        type,
        conversationId,
        bytes: envelopeByteSize(envelope),
      });
    } else {
      this.logger.debug('relay.agent.send', {
        type,
        conversationId,
        bytes: envelopeByteSize(envelope),
      });
    }
  }

  private sendError(code: RelayErrorCode, message: string, conversationId?: string): void {
    const payload: ErrorPayload = { code, message: truncateText(message, 1000) };
    if (conversationId !== undefined) {
      payload.conversationId = conversationId;
    }
    this.send('error', payload);
    this.logger.warn('relay.agent.error.report', { code, conversationId, message });
  }

  private sendTaskState(
    conversation: ConversationState,
    state: TaskState,
    detail?: TaskStateDetail,
  ): void {
    const payload: TaskStatePayload = { conversationId: conversation.conversationId, state };
    if (detail !== undefined) {
      payload.detail = detail;
    }
    this.send('task.state', payload);
    this.logger.info('relay.task.state', {
      conversationId: conversation.conversationId,
      state,
      code: detail?.code,
    });
  }

  /* ---------------------------------------------------------------------- */
  /* id 生成                                                                 */
  /* ---------------------------------------------------------------------- */

  private nextConversationId(): string {
    this.conversationCounter += 1;
    return `conv_${Date.now().toString(36)}_${this.conversationCounter.toString(36)}`;
  }

  private nextTaskId(): string {
    this.taskCounter += 1;
    return `task_${Date.now().toString(36)}_${this.taskCounter.toString(36)}`;
  }
}
