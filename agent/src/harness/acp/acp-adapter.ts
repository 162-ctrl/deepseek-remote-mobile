/**
 * AcpAdapter —— 通过官方 ACP（`dsh --profile acp`，JSON-RPC 2.0 over stdio）驱动 DeepSeek Harness。
 *
 * 实测依据：docs/research/HARNESS_INTERFACES.md §7/§8；设计依据：docs/design/REMOTE_AGENT.md §4.3。
 *
 * M0 范围（只做「接上并闭环」，不做云端链路）：
 * connect / getStatus / getCapabilities / createSession / getSessions / resumeSession /
 * sendMessage / continueTask / cancelTask / setConfigOption / 审批 request_permission 双向闭环 / 事件订阅。
 * 文件与工作区能力：Harness 无官方接口（H-06），本适配器诚实上报不可用，由 M1 的 WorkspaceService 本地实现。
 */
import { createHash } from 'node:crypto';
import type { ChildProcessWithoutNullStreams } from 'node:child_process';
import type {
  ApprovalOutcome,
  ApprovalRequest,
  CancelResult,
  HarnessAdapter,
  HarnessCapabilities,
  HarnessCapability,
  HarnessEvent,
  HarnessSession,
  HarnessStatus,
  TaskHandle,
  TaskInput,
  Unsubscribe,
  WorkspaceFile,
  WorkspaceInfo,
} from '../adapter.ts';
import { HarnessError, toHarnessError } from '../errors.ts';
import { Logger } from '../../infra/logger.ts';
import { truncateText } from '../../infra/redact.ts';
import { JsonRpcPeer } from './jsonrpc.ts';
import { buildAcpEnv, detectHarnessVersion, discoverDshInstall, launchAcp } from './launcher.ts';
import type { DshInstall } from './launcher.ts';
import { mapSessionUpdate, summarizeConfigOptions } from './mapper.ts';

export type PermissionPolicy = 'ask' | 'allow-once' | 'reject-once';

export interface AcpAdapterOptions {
  readonly install?: DshInstall;
  readonly env?: NodeJS.ProcessEnv;
  readonly logger?: Logger;
  /** 控制类请求（initialize/session-new/prompt 之外的）超时 */
  readonly requestTimeoutMs?: number;
  readonly startupTimeoutMs?: number;
  /** in-flight 审批等待上限，默认 10 分钟（对应 D-8 建议值） */
  readonly approvalTimeoutMs?: number;
  /** 默认 ask：把审批请求抛给上层；allow-once/reject-once 仅用于契约测试与显式策略 */
  readonly permissionPolicy?: PermissionPolicy;
  readonly maxLineBytes?: number;
  readonly harnessVersion?: string | null;
  readonly workspacePath?: string;
}

export interface TurnSettlement {
  readonly stopReason: 'end_turn' | 'cancelled' | 'error';
  readonly summary: string;
  readonly error?: HarnessError;
}

interface TurnState {
  readonly taskId: string;
  readonly startedAt: string;
  readonly answerParts: string[];
  readonly promise: Promise<TurnSettlement>;
  settled: boolean;
  stopReason: string | null;
  settle: (settlement: TurnSettlement) => void;
}

interface SessionState {
  readonly session: HarnessSession;
  readonly configOptions: ReadonlyArray<{ id: string; current: string | null; values: ReadonlyArray<string> }>;
  turn: TurnState | null;
  readonly events: Array<{ seq: number; event: HarnessEvent }>;
  readonly toolCalls: Map<string, { tool: string; input: unknown }>;
  seq: number;
}

interface PendingApproval {
  readonly request: ApprovalRequest;
  readonly acpOptions: ReadonlyArray<{ optionId: string; name: string; kind: string }>;
  readonly resolve: (result: unknown) => void;
  readonly timer: NodeJS.Timeout;
}

const CAPABILITY_KEYS: ReadonlyArray<HarnessCapability> = [
  'chat',
  'streaming',
  'structuredResult',
  'cancel',
  'pause',
  'continue',
  'sessions',
  'sessionResume',
  'toolCallDetail',
  'workspaceList',
  'fileRead',
  'fileWrite',
  'terminal',
  'approvalIntercept',
  'modelSwitch',
  'usageReport',
];

const ACP_KIND = 'acp' as const;

function makeAllFalse(): Record<HarnessCapability, boolean> {
  const values = {} as Record<HarnessCapability, boolean>;
  for (const key of CAPABILITY_KEYS) values[key] = false;
  return values;
}

function sha256(text: string): string {
  return createHash('sha256').update(text, 'utf8').digest('hex');
}

function canonicalJson(value: unknown): string {
  if (value === null || typeof value !== 'object') return JSON.stringify(value) ?? 'null';
  if (Array.isArray(value)) return `[${value.map((item) => canonicalJson(item)).join(',')}]`;
  const record = value as Record<string, unknown>;
  const keys = Object.keys(record).sort();
  return `{${keys.map((key) => `${JSON.stringify(key)}:${canonicalJson(record[key])}`).join(',')}}`;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function asArray(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

export class AcpAdapter implements HarnessAdapter {
  readonly kind = ACP_KIND;

  private readonly options: AcpAdapterOptions;
  private readonly logger: Logger;
  private readonly sessions = new Map<string, SessionState>();
  private readonly listeners = new Set<(event: HarnessEvent) => void>();
  private readonly pendingApprovals = new Map<string, PendingApproval>();
  private readonly pendingByToolCall = new Map<string, string>();

  private peer: JsonRpcPeer | null = null;
  private child: ChildProcessWithoutNullStreams | null = null;
  private detach: (() => void) | null = null;
  private install: DshInstall | null = null;
  private harnessVersion: string | null = null;
  private initializeResult: unknown = null;
  private running = false;
  private lastProbeAt = new Date(0).toISOString();
  private lastError: string | null = null;
  private approvalCounter = 0;
  private connecting: Promise<HarnessStatus> | null = null;

  constructor(options: AcpAdapterOptions = {}) {
    this.options = options;
    this.logger =
      options.logger ?? new Logger({ scope: 'acp-adapter', level: process.env['AGENT_LOG_LEVEL'] === 'debug' ? 'debug' : 'info' });
    this.harnessVersion = options.harnessVersion ?? null;
  }

  // ---------------------------------------------------------------- 生命周期

  async connect(): Promise<HarnessStatus> {
    if (this.running && this.peer !== null) return this.getStatus();
    if (this.connecting !== null) return this.connecting;
    this.connecting = this.doConnect().finally(() => {
      this.connecting = null;
    });
    return this.connecting;
  }

  private async doConnect(): Promise<HarnessStatus> {
    const env = buildAcpEnv(this.options.env);
    this.install = this.options.install ?? discoverDshInstall({ env: this.options.env });
    if (this.harnessVersion === null) {
      this.harnessVersion = await detectHarnessVersion(this.install, env);
    }
    const { child } = launchAcp({ install: this.install, env: this.options.env, cwd: this.options.workspacePath });
    this.child = child;
    this.running = true;

    const peer = new JsonRpcPeer({
      maxLineBytes: this.options.maxLineBytes,
      defaultTimeoutMs: this.options.requestTimeoutMs ?? 60_000,
    });
    this.peer = peer;
    this.detach = peer.attach(child, (stream, line) => {
      const text = line.trim();
      if (text === '') return;
      if (stream === 'stderr') this.logger.warn('acp.stderr', { text: truncateText(text, 500) });
    });

    peer.onNotification((method, params) => this.handleNotification(method, params));
    peer.onRequest('session/request_permission', (params) => this.handlePermissionRequest(params));

    child.on('exit', (code, signal) => {
      this.logger.warn('acp.exit', { code, signal });
      this.running = false;
      const reason = `ACP 进程退出（code=${String(code)}, signal=${String(signal)}）`;
      this.lastError = reason;
      this.failAllTurns(new HarnessError('ACP_PROCESS_EXIT', reason, { retryable: true }));
      this.peer?.close(reason);
      this.detach?.();
      this.detach = null;
      this.peer = null;
      this.child = null;
    });

    try {
      const result = await peer.sendRequest<Record<string, unknown>>(
        'initialize',
        { protocolVersion: 1, clientCapabilities: {} },
        this.options.startupTimeoutMs ?? 30_000,
      );
      this.initializeResult = result;
      const protocolVersion = result['protocolVersion'];
      if (protocolVersion !== 1) {
        throw new HarnessError('ACP_PROTOCOL_ERROR', `ACP protocolVersion 不支持：${String(protocolVersion)}（期望 1）`, {
          details: { protocolVersion },
        });
      }
      const agentInfo = isRecord(result['agentInfo']) ? result['agentInfo'] : {};
      if (this.harnessVersion === null) {
        const reported = agentInfo['version'];
        this.harnessVersion = typeof reported === 'string' ? reported : null;
      }
      this.lastProbeAt = new Date().toISOString();
      this.logger.info('acp.connected', {
        version: this.harnessVersion,
        protocolVersion,
        agent: typeof agentInfo['name'] === 'string' ? agentInfo['name'] : undefined,
      });
      return this.getStatus();
    } catch (error) {
      this.running = false;
      this.peer?.close('initialize 失败');
      this.peer = null;
      this.detach?.();
      this.detach = null;
      this.child?.kill();
      this.child = null;
      const err = toHarnessError(error, 'ACP_PROTOCOL_ERROR');
      this.lastError = err.message;
      throw err;
    }
  }

  async disconnect(): Promise<void> {
    const child = this.child;
    if (child === null) {
      this.running = false;
      return;
    }
    this.failAllTurns(new HarnessError('ACP_PROCESS_EXIT', 'Agent 主动断开 ACP 进程', { retryable: true }));
    try {
      child.stdin.end();
    } catch {
      // ignore
    }
    await new Promise<void>((resolve) => {
      const timer = setTimeout(() => {
        try {
          child.kill();
        } catch {
          // ignore
        }
        resolve();
      }, 3_000);
      timer.unref?.();
      child.once('exit', () => {
        clearTimeout(timer);
        resolve();
      });
    });
    this.peer?.close('disconnect');
    this.detach?.();
    this.detach = null;
    this.peer = null;
    this.child = null;
    this.running = false;
    this.sessions.clear();
    this.logger.info('acp.disconnected');
  }

  async getStatus(): Promise<HarnessStatus> {
    let busy = false;
    let activeSessions = 0;
    for (const state of this.sessions.values()) {
      activeSessions += 1;
      if (state.turn !== null) busy = true;
    }
    const status: HarnessStatus = {
      running: this.running,
      version: this.harnessVersion,
      busy,
      activeSessions,
      lastProbeAt: this.lastProbeAt,
      degraded: !this.running,
      adapter: ACP_KIND,
      ...(this.lastError === null ? {} : { detail: this.lastError }),
    };
    return status;
  }

  // ---------------------------------------------------------------- 能力

  async getCapabilities(): Promise<HarnessCapabilities> {
    const values = makeAllFalse();
    const evidence = {} as Record<HarnessCapability, string>;
    for (const key of CAPABILITY_KEYS) evidence[key] = '未探测';
    if (this.running && this.peer !== null) {
      values['chat'] = true;
      evidence['chat'] = 'M0 合同测试：initialize → session/new → session/prompt 闭环';
      values['streaming'] = true;
      evidence['streaming'] = 'ACP session/update.agent_message_chunk（提交点粒度，非 token 级）';
      values['structuredResult'] = true;
      evidence['structuredResult'] = 'ACP tool_call/tool_call_update 携带 rawInput 与结果';
      values['cancel'] = true;
      evidence['cancel'] = 'M0 合同测试：session/cancel → stopReason=cancelled';
      values['pause'] = false;
      evidence['pause'] = 'ACP 无 pause 方法（HARNESS_INTERFACES §7.1）';
      values['continue'] = true;
      evidence['continue'] = '同一 sessionId 再次 session/prompt，上下文连续';
      values['sessions'] = true;
      evidence['sessions'] = 'ACP session/list（跨进程持久化会话）';
      values['sessionResume'] = true;
      evidence['sessionResume'] = 'ACP session/resume {sessionId, cwd}（cwd 必须与创建时一致）';
      values['toolCallDetail'] = true;
      evidence['toolCallDetail'] = 'ACP tool_call.rawInput 完整命令 + tool_call_update 结果';
      values['workspaceList'] = false;
      evidence['workspaceList'] = 'Harness 无官方文件/工作区接口（H-06）→ M1 本地 fs';
      values['fileRead'] = false;
      evidence['fileRead'] = '同上（H-06）';
      values['fileWrite'] = false;
      evidence['fileWrite'] = '同上（H-06）';
      values['terminal'] = false;
      evidence['terminal'] = 'ACP 无 terminal 客户端通道';
      values['approvalIntercept'] = true;
      evidence['approvalIntercept'] = 'M0 合同测试：session/request_permission allow-once/reject-once 闭环';
      values['modelSwitch'] = true;
      evidence['modelSwitch'] = 'ACP session/set_config_option（model / reasoning_effort）';
      values['usageReport'] = true;
      evidence['usageReport'] = 'ACP usage_update {used,size}（上下文占用，非 token 计费）';
      if (this.harnessVersion !== null) evidence['chat'] += `；harness=${this.harnessVersion}`;
    }
    return {
      adapter: ACP_KIND,
      harnessVersion: this.harnessVersion,
      values,
      evidence,
      probedAt: this.lastProbeAt,
    };
  }

  // ---------------------------------------------------------------- 会话

  async getSessions(): Promise<ReadonlyArray<HarnessSession>> {
    const peer = this.requirePeer('getSessions');
    const raw = await peer.sendRequest<unknown>('session/list', {});
    const list = Array.isArray(raw) ? raw : isRecord(raw) ? asArray(raw['sessions']) : [];
    const out: HarnessSession[] = [];
    for (const item of list) {
      if (!isRecord(item)) continue;
      const sessionId = typeof item['sessionId'] === 'string' ? item['sessionId'] : typeof item['id'] === 'string' ? item['id'] : null;
      if (sessionId === null) continue;
      const cwd = typeof item['cwd'] === 'string' ? item['cwd'] : typeof item['workspacePath'] === 'string' ? item['workspacePath'] : '';
      const now = new Date().toISOString();
      out.push({
        sessionId,
        workspacePath: cwd,
        createdAt: typeof item['createdAt'] === 'string' ? item['createdAt'] : now,
        lastActiveAt: typeof item['updatedAt'] === 'string' ? item['updatedAt'] : now,
        ...(typeof item['title'] === 'string' ? { title: item['title'] } : {}),
      });
    }
    return out;
  }

  async createSession(workspacePath: string, title?: string): Promise<HarnessSession> {
    const peer = this.requirePeer('createSession');
    const result = await peer.sendRequest<Record<string, unknown>>('session/new', { cwd: workspacePath, mcpServers: [] });
    const sessionId = typeof result['sessionId'] === 'string' ? result['sessionId'] : null;
    if (sessionId === null) {
      throw new HarnessError('ACP_PROTOCOL_ERROR', 'session/new 未返回 sessionId', { details: { result } });
    }
    const now = new Date().toISOString();
    const session: HarnessSession = {
      sessionId,
      workspacePath,
      createdAt: now,
      lastActiveAt: now,
      ...(title === undefined ? {} : { title }),
    };
    this.sessions.set(sessionId, {
      session,
      configOptions: summarizeConfigOptions(result['configOptions']),
      turn: null,
      events: [],
      toolCalls: new Map(),
      seq: 0,
    });
    this.logger.info('acp.session.created', { sessionId, workspacePath, configOptions: this.sessions.get(sessionId)?.configOptions });
    return session;
  }

  /** M0 扩展：断线恢复会话（cwd 必须与创建时一致） */
  async resumeSession(sessionId: string, workspacePath: string): Promise<HarnessSession> {
    const peer = this.requirePeer('resumeSession');
    const result = await peer.sendRequest<Record<string, unknown>>('session/resume', { sessionId, cwd: workspacePath });
    const now = new Date().toISOString();
    const existing = this.sessions.get(sessionId);
    const session: HarnessSession = {
      sessionId,
      workspacePath,
      createdAt: existing?.session.createdAt ?? now,
      lastActiveAt: now,
      ...(existing?.session.title === undefined ? {} : { title: existing.session.title }),
      ...(typeof result['title'] === 'string' ? { title: result['title'] } : {}),
    };
    this.sessions.set(sessionId, {
      session,
      configOptions: summarizeConfigOptions(result['configOptions']),
      turn: existing?.turn ?? null,
      events: existing?.events ?? [],
      toolCalls: existing?.toolCalls ?? new Map(),
      seq: existing?.seq ?? 0,
    });
    this.logger.info('acp.session.resumed', { sessionId, workspacePath });
    return session;
  }

  async getSessionEvents(sessionId: string, sinceSeq?: number): Promise<ReadonlyArray<HarnessEvent>> {
    const state = this.sessions.get(sessionId);
    if (state === undefined) return [];
    const since = sinceSeq ?? 0;
    return state.events.filter((item) => item.seq > since).map((item) => item.event);
  }

  /** M0 扩展：会话内切换配置项（model / reasoning_effort 等） */
  async setConfigOption(sessionId: string, configId: string, value: string): Promise<unknown> {
    const peer = this.requirePeer('setConfigOption');
    const result = await peer.sendRequest<unknown>('session/set_config_option', { sessionId, configId, value });
    this.logger.info('acp.config.option', { sessionId, configId, value });
    return result;
  }

  // ---------------------------------------------------------------- 任务

  async sendMessage(sessionId: string, input: TaskInput): Promise<TaskHandle> {
    return this.startTurn(sessionId, input);
  }

  async continueTask(sessionId: string, input: TaskInput): Promise<TaskHandle> {
    return this.startTurn(sessionId, input);
  }

  private startTurn(sessionId: string, input: TaskInput): TaskHandle {
    const peer = this.requirePeer('sendMessage');
    const state = this.sessions.get(sessionId);
    if (state === undefined) {
      throw new HarnessError('SESSION_NOT_FOUND', `未知会话：${sessionId}`, { details: { sessionId } });
    }
    if (state.turn !== null) {
      throw new HarnessError('SESSION_BUSY', '同一会话已有进行中的 turn，prompt 必须串行', {
        details: { sessionId, activeTaskId: state.turn.taskId },
      });
    }

    let settleFn: (settlement: TurnSettlement) => void = () => undefined;
    const promise = new Promise<TurnSettlement>((resolve) => {
      settleFn = resolve;
    });
    const turn: TurnState = {
      taskId: input.taskId,
      startedAt: new Date().toISOString(),
      answerParts: [],
      promise,
      settled: false,
      stopReason: null,
      settle: (settlement) => {
        if (turn.settled) return;
        turn.settled = true;
        settleFn(settlement);
        state.turn = null;
      },
    };
    state.turn = turn;
    state.session.lastActiveAt = turn.startedAt;

    const timeoutMs = Math.max(5_000, input.timeoutSec * 1000) + 5_000;
    peer
      .sendRequest<Record<string, unknown>>(
        'session/prompt',
        { sessionId, prompt: [{ type: 'text', text: input.prompt }] },
        timeoutMs,
      )
      .then((result) => {
        const stopReason = typeof result['stopReason'] === 'string' ? result['stopReason'] : 'end_turn';
        turn.stopReason = stopReason;
        const summary = turn.answerParts.join('');
        if (stopReason === 'end_turn') {
          this.emitForSession(state, { type: 'completed', summary, files: [], at: new Date().toISOString() });
          turn.settle({ stopReason: 'end_turn', summary });
          return;
        }
        if (stopReason === 'cancelled') {
          turn.settle({ stopReason: 'cancelled', summary });
          return;
        }
        const error = new HarnessError('ACP_PROTOCOL_ERROR', `prompt 以非正常原因结束：${stopReason}`, {
          details: { stopReason, sessionId },
        });
        this.emitForSession(state, {
          type: 'failed',
          errorCode: error.code,
          message: error.message,
          retryable: false,
          at: new Date().toISOString(),
        });
        turn.settle({ stopReason: 'error', summary, error });
      })
      .catch((error: unknown) => {
        const err = toHarnessError(error, 'ACP_PROTOCOL_ERROR');
        this.logger.warn('acp.prompt.error', { sessionId, code: err.code, message: err.message });
        if (!turn.settled) {
          this.emitForSession(state, {
            type: 'failed',
            errorCode: err.code,
            message: err.message,
            retryable: err.retryable,
            at: new Date().toISOString(),
          });
        }
        turn.settle({ stopReason: 'error', summary: turn.answerParts.join(''), error: err });
      });

    const handle: TaskHandle = {
      taskId: input.taskId,
      harnessRef: sessionId,
      startedAt: turn.startedAt,
      cancel: async () => this.cancelTurn(sessionId),
    };
    return handle;
  }

  async cancelTask(handle: TaskHandle): Promise<CancelResult> {
    if (handle.harnessRef === null) {
      return { accepted: false, harnessAck: false, mechanism: 'detach', detail: '任务未关联 ACP 会话' };
    }
    return this.cancelTurn(handle.harnessRef);
  }

  private async cancelTurn(sessionId: string): Promise<CancelResult> {
    const state = this.sessions.get(sessionId);
    const turn = state?.turn;
    if (state === undefined || turn === null || turn === undefined) {
      return { accepted: false, harnessAck: false, mechanism: 'native', detail: '该会话没有进行中的 turn' };
    }
    const peer = this.peer;
    if (peer === null) {
      return { accepted: false, harnessAck: false, mechanism: 'native', detail: 'ACP 未连接' };
    }
    peer.sendNotification('session/cancel', { sessionId });
    const timeoutMs = 10_000;
    const timeout = new Promise<'timeout'>((resolve) => {
      const timer = setTimeout(() => resolve('timeout'), timeoutMs);
      timer.unref?.();
    });
    const result = await Promise.race([turn.promise, timeout]);
    if (result === 'timeout') {
      this.logger.warn('acp.cancel.timeout', { sessionId });
      await this.disconnect();
      return {
        accepted: true,
        harnessAck: false,
        mechanism: 'signal_kill',
        detail: `session/cancel 在 ${timeoutMs}ms 内未确认，已终止 ACP 进程`,
      };
    }
    return {
      accepted: true,
      harnessAck: result.stopReason === 'cancelled',
      mechanism: 'native',
      detail: `stopReason=${String(turn.stopReason)}`,
    };
  }

  /** M0 扩展：等待某会话当前 turn 结束（TaskService/TaskHandle 可用） */
  async waitForTurn(sessionId: string, timeoutMs = 120_000): Promise<TurnSettlement> {
    const state = this.sessions.get(sessionId);
    if (state === undefined) throw new HarnessError('SESSION_NOT_FOUND', `未知会话：${sessionId}`);
    const turn = state.turn;
    if (turn === null) throw new HarnessError('INTERNAL', '该会话没有进行中的 turn');
    const timeout = new Promise<TurnSettlement>((resolve) => {
      const timer = setTimeout(
        () => resolve({ stopReason: 'error', summary: '', error: new HarnessError('TIMEOUT', '等待 turn 结束超时') }),
        timeoutMs,
      );
      timer.unref?.();
    });
    return Promise.race([turn.promise, timeout]);
  }

  // ---------------------------------------------------------------- 审批

  async requestApproval(request: ApprovalRequest): Promise<ApprovalOutcome> {
    const approvalId = request.approvalId;
    const byToolCall = request.toolCallId === undefined ? undefined : this.pendingByToolCall.get(request.toolCallId);
    const pending = this.pendingApprovals.get(approvalId) ?? (byToolCall === undefined ? undefined : this.pendingApprovals.get(byToolCall));
    if (pending === undefined) {
      return { status: 'cancelled', decidedAt: new Date().toISOString() };
    }
    const outcome: ApprovalOutcome = { status: 'approved', decidedAt: new Date().toISOString() };
    this.settlePending(pending, 'approved');
    return outcome;
  }

  /** M0 扩展：由上层显式裁决（手机端审批链路在 M3 接入后替换 requestApproval 的调用方式） */
  decideApproval(approvalId: string, status: 'approved' | 'denied' | 'expired' | 'cancelled'): boolean {
    const pending = this.pendingApprovals.get(approvalId);
    if (pending === undefined) return false;
    this.settlePending(pending, status);
    return true;
  }

  getPendingApprovals(): ReadonlyArray<ApprovalRequest> {
    return [...this.pendingApprovals.values()].map((pending) => pending.request);
  }

  private handlePermissionRequest(params: unknown): Promise<unknown> {
    if (!isRecord(params)) {
      return Promise.reject(new HarnessError('ACP_PROTOCOL_ERROR', 'request_permission 参数不是对象'));
    }
    const sessionId = typeof params['sessionId'] === 'string' ? params['sessionId'] : '';
    const toolCall = isRecord(params['toolCall']) ? params['toolCall'] : {};
    const toolCallId = typeof toolCall['toolCallId'] === 'string' ? toolCall['toolCallId'] : undefined;
    const acpOptions = asArray(params['options'])
      .filter((item): item is Record<string, unknown> => isRecord(item))
      .map((item) => ({
        optionId: typeof item['optionId'] === 'string' ? item['optionId'] : '',
        name: typeof item['name'] === 'string' ? item['name'] : '',
        kind: typeof item['kind'] === 'string' ? item['kind'] : '',
      }))
      .filter((item) => item.optionId !== '');
    const callInfo = toolCallId === undefined ? undefined : this.sessions.get(sessionId)?.toolCalls.get(toolCallId);
    const tool = callInfo?.tool;
    const payload = { sessionId, toolCallId, options: acpOptions, toolInput: callInfo?.input ?? null };
    const now = Date.now();
    const approvalTimeoutMs = this.options.approvalTimeoutMs ?? 10 * 60_000;
    this.approvalCounter += 1;
    const approvalId = `apr_${Date.now().toString(36)}_${this.approvalCounter}`;
    const state = this.sessions.get(sessionId);
    const request: ApprovalRequest = {
      approvalId,
      taskId: state?.turn?.taskId ?? 'unknown',
      source: 'acp_permission',
      ...(toolCallId === undefined ? {} : { toolCallId }),
      ...(tool === undefined ? {} : { tool }),
      approvalType: 'acp_permission',
      permissionLevel: 6,
      riskLevel: 'high',
      actionHash: sha256(canonicalJson({ sessionId, toolCallId, options: acpOptions, toolInput: callInfo?.input ?? null })),
      actionSummary:
        tool === undefined
          ? 'Harness 请求执行一个需要确认的动作'
          : `Harness 请求执行工具「${tool}」${summarizeToolInput(callInfo?.input)}`,
      payload,
      options: acpOptions.map((option) => ({
        optionId: option.optionId,
        label: option.name !== '' ? option.name : option.optionId,
        kind: option.kind === 'reject_once' ? 'reject_once' : 'allow_once',
      })),
      expiresAt: new Date(now + approvalTimeoutMs).toISOString(),
    };

    const resultPromise = new Promise<unknown>((resolve) => {
      const timer = setTimeout(() => {
        this.logger.warn('acp.approval.timeout', { approvalId, sessionId, toolCallId });
        this.settlePending(pending, 'expired');
      }, approvalTimeoutMs);
      timer.unref?.();
      const pending: PendingApproval = { request, acpOptions, resolve, timer };
      this.pendingApprovals.set(approvalId, pending);
      if (toolCallId !== undefined) this.pendingByToolCall.set(toolCallId, approvalId);
      this.emitForSessionById(sessionId, { type: 'approval_request', request, at: new Date().toISOString() });
      this.logger.info('acp.approval.request', {
        approvalId,
        sessionId,
        toolCallId,
        tool,
        options: acpOptions.map((option) => option.optionId),
      });

      const policy = this.options.permissionPolicy ?? 'ask';
      if (policy === 'allow-once') this.settlePending(pending, 'approved');
      else if (policy === 'reject-once') this.settlePending(pending, 'denied');
    });
    return resultPromise;
  }

  private settlePending(pending: PendingApproval, status: 'approved' | 'denied' | 'expired' | 'cancelled'): void {
    const approvalId = pending.request.approvalId;
    if (!this.pendingApprovals.has(approvalId)) return;
    clearTimeout(pending.timer);
    this.pendingApprovals.delete(approvalId);
    if (pending.request.toolCallId !== undefined) this.pendingByToolCall.delete(pending.request.toolCallId);

    let result: unknown;
    if (status === 'approved') {
      const option = pending.acpOptions.find((item) => item.kind === 'allow_once') ?? pending.acpOptions[0];
      result = { outcome: { outcome: 'selected', optionId: option?.optionId ?? 'allow-once' } };
    } else if (status === 'denied') {
      const option = pending.acpOptions.find((item) => item.kind === 'reject_once') ?? pending.acpOptions[1];
      result = { outcome: { outcome: 'selected', optionId: option?.optionId ?? 'reject-once' } };
    } else {
      result = { outcome: { outcome: 'cancelled' } };
    }
    this.logger.info('acp.approval.settled', { approvalId, status });
    pending.resolve(result);
  }

  // ---------------------------------------------------------------- 文件（诚实不可用）

  async getWorkspaces(): Promise<ReadonlyArray<WorkspaceInfo>> {
    throw new HarnessError('UNSUPPORTED_CAPABILITY', 'Harness 无官方工作区接口（H-06），由 M1 的 WorkspaceService 本地实现');
  }

  async getWorkspaceFiles(_workspacePath: string, _relativeDir?: string): Promise<ReadonlyArray<WorkspaceFile>> {
    throw new HarnessError('UNSUPPORTED_CAPABILITY', 'Harness 无官方文件接口（H-06），由 M1 的 WorkspaceService 本地实现');
  }

  async readFile(_workspacePath: string, _relativePath: string, _maxBytes: number): Promise<{ content: string; sha256: string; truncated: boolean }> {
    throw new HarnessError('UNSUPPORTED_CAPABILITY', 'Harness 无官方文件接口（H-06），由 M1 的 WorkspaceService 本地实现');
  }

  async writeFile(_workspacePath: string, _relativePath: string, _content: string, _expectedSha256?: string): Promise<{ sha256: string }> {
    throw new HarnessError('UNSUPPORTED_CAPABILITY', 'Harness 无官方文件接口（H-06），由 M1 的 WorkspaceService 本地实现');
  }

  // ---------------------------------------------------------------- 事件

  subscribe(listener: (event: HarnessEvent) => void): Unsubscribe {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  private emit(event: HarnessEvent): void {
    for (const listener of this.listeners) {
      try {
        listener(event);
      } catch (error) {
        this.logger.warn('acp.listener.error', { message: error instanceof Error ? error.message : String(error) });
      }
    }
  }

  private emitForSession(state: SessionState, event: HarnessEvent): void {
    state.seq += 1;
    state.events.push({ seq: state.seq, event });
    if (state.events.length > 1000) state.events.shift();
    this.emit(event);
  }

  private emitForSessionById(sessionId: string, event: HarnessEvent): void {
    const state = this.sessions.get(sessionId);
    if (state !== undefined) this.emitForSession(state, event);
    else this.emit(event);
  }

  private handleNotification(method: string, params: unknown): void {
    if (method === 'session/update') {
      const mapped = mapSessionUpdate(params);
      const sessionId = mapped.sessionId;
      if (sessionId === null) {
        for (const event of mapped.events) this.emit(event);
        return;
      }
      const state = this.sessions.get(sessionId);
      if (state === undefined) {
        for (const event of mapped.events) this.emit(event);
        return;
      }
      for (const event of mapped.events) {
        if (event.type === 'tool_call') state.toolCalls.set(event.callId, { tool: event.tool, input: event.input });
        if (event.type === 'output' && state.turn !== null) state.turn.answerParts.push(event.text);
        this.emitForSession(state, event);
      }
      if (mapped.events.length === 0 && mapped.kind !== null) {
        this.logger.debug('acp.update.ignored', { kind: mapped.kind });
      }
      return;
    }
    this.logger.debug('acp.notification.unknown', { method });
  }

  private failAllTurns(error: HarnessError): void {
    for (const state of this.sessions.values()) {
      const turn = state.turn;
      if (turn === null) continue;
      turn.settle({ stopReason: 'error', summary: turn.answerParts.join(''), error });
      state.turn = null;
    }
  }

  private requirePeer(operation: string): JsonRpcPeer {
    if (!this.running || this.peer === null) {
      throw new HarnessError('ACP_PROCESS_EXIT', `ACP 未连接，无法执行 ${operation}`, { retryable: true });
    }
    return this.peer;
  }

  // ---------------------------------------------------------------- 排障辅助

  getInstallInfo(): DshInstall | null {
    return this.install;
  }

  getInitializeResult(): unknown {
    return this.initializeResult;
  }

  getHarnessVersion(): string | null {
    return this.harnessVersion;
  }
}

function summarizeToolInput(input: unknown): string {
  if (input === null || input === undefined) return '';
  if (typeof input === 'string') return `：${truncateText(input, 120)}`;
  if (isRecord(input)) {
    const command = input['command'];
    if (typeof command === 'string') return `：${truncateText(command, 120)}`;
    const path = input['path'] ?? input['file_path'];
    if (typeof path === 'string') return `：${path}`;
  }
  return '';
}
