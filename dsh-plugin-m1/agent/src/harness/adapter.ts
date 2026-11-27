/**
 * Remote Agent 对 Harness 的唯一依赖面 + 事件/能力类型（v1）。
 * 与 docs/design/REMOTE_AGENT.md §4.1 保持一致；改动此文件必须同步设计文档。
 */

export type AdapterKind = 'acp' | 'headless' | 'desktop_automation';

export type HarnessCapability =
  | 'chat'
  | 'streaming'
  | 'structuredResult'
  | 'cancel'
  | 'pause'
  | 'continue'
  | 'sessions'
  | 'sessionResume'
  | 'toolCallDetail'
  | 'workspaceList'
  | 'fileRead'
  | 'fileWrite'
  | 'terminal'
  | 'approvalIntercept'
  | 'modelSwitch'
  | 'usageReport';

export interface HarnessCapabilities {
  readonly adapter: AdapterKind;
  readonly harnessVersion: string | null;
  readonly values: Readonly<Record<HarnessCapability, boolean>>;
  /** 每个能力的探测依据（排障与契约测试用） */
  readonly evidence: Readonly<Record<HarnessCapability, string>>;
  readonly probedAt: string;
}

export interface HarnessStatus {
  readonly running: boolean;
  readonly version: string | null;
  readonly busy: boolean;
  readonly activeSessions: number;
  readonly lastProbeAt: string;
  readonly degraded: boolean;
  readonly adapter: AdapterKind;
  readonly detail?: string;
}

export interface ConfigOptionValueView {
  readonly value: string;
  readonly name: string;
  readonly description?: string;
  /** 分组名（如模型按 provider 分组），无分组时缺省。 */
  readonly group?: string;
}

/** ACP `configOptions` 的 UI 友好视图（M2.7：模型 / reasoning_effort 选择）。 */
export interface ConfigOptionView {
  readonly id: string;
  readonly name: string;
  readonly category: string | null;
  readonly type: string | null;
  readonly currentValue: string | null;
  readonly options: ReadonlyArray<ConfigOptionValueView>;
}

export interface HarnessSession {
  readonly sessionId: string;
  readonly workspacePath: string;
  readonly createdAt: string;
  readonly lastActiveAt: string;
  readonly title?: string;
  /** ACP session/new 返回的 configOptions（含显示名，供手机端做模型/思考强度选择）。 */
  readonly configOptionsRich?: ReadonlyArray<ConfigOptionView>;
}

export interface TaskInput {
  readonly taskId: string;
  readonly conversationId: string;
  readonly prompt: string;
  readonly workspacePath: string;
  readonly timeoutSec: number;
  readonly attachments?: ReadonlyArray<{ fileId: string; localPath: string }>;
  readonly env?: Readonly<Record<string, string>>;
}

export interface TaskHandle {
  readonly taskId: string;
  readonly harnessRef: string | null;
  readonly startedAt: string;
  cancel(): Promise<CancelResult>;
}

export type CancelMechanism = 'native' | 'signal_term' | 'signal_kill' | 'detach';

export interface CancelResult {
  readonly accepted: boolean;
  /** Harness 是否确认已真正中止（做不到时必须为 false，UI 如实展示） */
  readonly harnessAck: boolean;
  readonly mechanism: CancelMechanism;
  readonly detail?: string;
}

export type HarnessEvent =
  | { readonly type: 'output'; readonly stream: 'answer' | 'stdout' | 'stderr' | 'log'; readonly text: string; readonly at: string }
  | { readonly type: 'progress'; readonly progress: number; readonly stage: string; readonly message?: string; readonly at: string }
  | { readonly type: 'thinking'; readonly text: string; readonly at: string }
  | { readonly type: 'tool_call'; readonly callId: string; readonly tool: string; readonly input: unknown; readonly at: string }
  | {
      readonly type: 'tool_call_update';
      readonly callId: string;
      readonly status: 'pending' | 'in_progress' | 'completed' | 'failed';
      readonly resultExcerpt?: string;
      readonly at: string;
    }
  | {
      readonly type: 'usage';
      readonly contextUsed?: number;
      readonly contextSize?: number;
      readonly inputTokens?: number;
      readonly outputTokens?: number;
      readonly at: string;
    }
  | { readonly type: 'approval_request'; readonly request: ApprovalRequest; readonly at: string }
  | { readonly type: 'session_message'; readonly role: 'user' | 'assistant'; readonly content: string; readonly at: string }
  | { readonly type: 'completed'; readonly summary: string; readonly files: ReadonlyArray<ResultFile>; readonly at: string }
  | { readonly type: 'failed'; readonly errorCode: string; readonly message: string; readonly retryable: boolean; readonly at: string };

export interface ResultFile {
  readonly path: string;
  readonly change: 'created' | 'modified' | 'deleted';
}

export interface WorkspaceInfo {
  readonly workspacePath: string;
  readonly displayName: string;
  readonly isGitRepo: boolean;
  readonly branch?: string;
}

export interface WorkspaceFile {
  readonly relativePath: string;
  readonly sizeBytes: number;
  readonly modifiedAt: string;
  readonly isDirectory: boolean;
}

export type Unsubscribe = () => void;

export type ApprovalOptionKind = 'allow_once' | 'reject_once';

export interface ApprovalRequest {
  readonly approvalId: string;
  readonly taskId: string;
  readonly source: 'acp_permission' | 'preflight_rule';
  readonly toolCallId?: string;
  readonly tool?: string;
  readonly approvalType: string;
  readonly permissionLevel: 1 | 2 | 3 | 4 | 5 | 6;
  readonly riskLevel: 'low' | 'medium' | 'high' | 'critical';
  readonly actionHash: string;
  readonly actionSummary: string;
  readonly payload: unknown;
  readonly options?: ReadonlyArray<{ optionId: string; label: string; kind: ApprovalOptionKind }>;
  readonly expiresAt: string;
}

export interface ApprovalOutcome {
  readonly status: 'approved' | 'denied' | 'expired' | 'cancelled';
  readonly ticket?: string;
  readonly decidedAt?: string;
}

export interface HarnessAdapter {
  readonly kind: AdapterKind;
  connect(): Promise<HarnessStatus>;
  disconnect(): Promise<void>;
  getStatus(): Promise<HarnessStatus>;
  getCapabilities(): Promise<HarnessCapabilities>;

  getSessions(): Promise<ReadonlyArray<HarnessSession>>;
  createSession(workspacePath: string, title?: string): Promise<HarnessSession>;
  getSessionEvents(sessionId: string, sinceSeq?: number): Promise<ReadonlyArray<HarnessEvent>>;

  sendMessage(sessionId: string, input: TaskInput): Promise<TaskHandle>;
  continueTask(sessionId: string, input: TaskInput): Promise<TaskHandle>;
  cancelTask(handle: TaskHandle): Promise<CancelResult>;
  pauseTask?(handle: TaskHandle): Promise<void>;
  resumeTask?(handle: TaskHandle): Promise<void>;

  getWorkspaces(): Promise<ReadonlyArray<WorkspaceInfo>>;
  getWorkspaceFiles(workspacePath: string, relativeDir?: string): Promise<ReadonlyArray<WorkspaceFile>>;
  readFile(workspacePath: string, relativePath: string, maxBytes: number): Promise<{ content: string; sha256: string; truncated: boolean }>;
  writeFile(workspacePath: string, relativePath: string, content: string, expectedSha256?: string): Promise<{ sha256: string }>;

  subscribe(listener: (event: HarnessEvent) => void): Unsubscribe;
  requestApproval(request: ApprovalRequest): Promise<ApprovalOutcome>;
}
