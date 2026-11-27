/**
 * M1 WSS relay 协议类型（v1）。
 *
 * 唯一契约：docs/design/M1_PROTOCOL.md §3（消息目录）与 §5（Agent 端职责）。
 *
 * 本模块只做纯类型 / 信封构造 / 校验解析，不包含任何 IO：
 *  - 上行（Agent → 后端 → App）：conversation.created / session.update / task.state /
 *    approval.request / approval.resolved / device.status / error / ping
 *  - 下行（App → 后端 → Agent）：conversation.create / prompt.send / task.cancel /
 *    approval.decide / pong / error
 *
 * 约定：
 *  - 信封固定 `{ v: 1, type, id?, ts?, payload }`；心跳特例只有 `{ v: 1, type: 'ping' }`。
 *  - 所有 payload 均为 JSON 对象；跨端字段名一律 camelCase。
 *  - payload 内可能包含模型产出的敏感文本，上报前由 relay-agent 统一 redact。
 */

/** 协议版本号；信封 `v` 必须严格等于该值。 */
export const RELAY_PROTOCOL_VERSION = 1 as const;

/** §3 规定的缺省配对码（App 未携带时后端/Agent 侧使用的约定值）。 */
export const DEFAULT_PAIRING_CODE = '824613';

/** 单帧 JSON 文本上限，超出直接丢弃，防止异常大帧拖垮进程。 */
export const RELAY_MAX_FRAME_BYTES = 8 * 1024 * 1024;

/* -------------------------------------------------------------------------- */
/* 信封                                                                        */
/* -------------------------------------------------------------------------- */

/** relay 信封。`id`/`ts` 可选；心跳 ping/pong 不带 payload。 */
export interface RelayEnvelope<T = unknown> {
  v: number;
  type: string;
  id?: string;
  ts?: string;
  payload?: T;
}

/** 后端错误码全集（§3 错误码）。 */
export type RelayErrorCode =
  | 'AUTH_FAILED'
  | 'BAD_REQUEST'
  | 'DEVICE_OFFLINE'
  | 'CONVERSATION_NOT_FOUND'
  | 'SESSION_BUSY'
  | 'PATH_NOT_ALLOWED'
  | 'INTERNAL';

/** 任务状态（§3 task.state.state）。 */
export type TaskState = 'queued' | 'running' | 'completed' | 'failed' | 'cancelled';

/** session.update 的 kind（§3）。 */
export type SessionUpdateKind = 'output' | 'thinking' | 'tool_call' | 'tool_call_update' | 'usage';

/** ACP tool_call 状态（§3 tool_call_update.status）。 */
export type ToolCallStatus = 'pending' | 'in_progress' | 'completed' | 'failed';

/** 审批按钮种类（§3 approval.request.options[].kind）。 */
export type ApprovalOptionKind = 'allow_once' | 'reject_once';

/** 手机端裁决结果（§3 approval.resolved.decision）。 */
export type ApprovalDecision = 'approved' | 'denied' | 'expired' | 'cancelled';

/** approval.resolved.decidedBy（§3）。 */
export type ApprovalDecidedBy = 'phone' | 'timeout' | 'policy';

/* -------------------------------------------------------------------------- */
/* 下行：App/后端 → Agent                                                       */
/* -------------------------------------------------------------------------- */

/** conversation.create：后端分配 conversationId 后转发给 Agent。 */
export interface ConversationCreatePayload {
  /** 后端分配的会话 id；直接连 Agent 的调试入口可省略，由 Agent 生成。 */
  conversationId?: string;
  /** 工作区绝对路径，必须落在 M1_WORKSPACE_ROOT 内。 */
  workspacePath?: string;
  title?: string;
}

/** prompt.send：向会话追加一轮用户输入。 */
export interface PromptSendPayload {
  conversationId: string;
  text: string;
}

/** task.cancel：请求取消会话当前进行中的 turn。 */
export interface TaskCancelPayload {
  conversationId: string;
}

/** approval.decide：手机端对审批请求的裁决。 */
export interface ApprovalDecidePayload {
  conversationId?: string;
  approvalId: string;
  decision: 'approved' | 'denied' | string;
}

/* -------------------------------------------------------------------------- */
/* 上行：Agent → 后端 → App                                                    */
/* -------------------------------------------------------------------------- */

/** conversation.created：会话创建成功。 */
export interface ConversationCreatedPayload {
  conversationId: string;
  sessionId: string;
  workspacePath: string;
  title?: string;
}

/** session.update 公共字段：会话 id + 单调递增序号（从 1 起）。 */
interface SessionUpdateBase {
  conversationId: string;
  seq: number;
}

/** session.update 内容（不含会话上下文，便于内部构造）。 */
export type SessionUpdateBody =
  | { kind: 'output'; text: string }
  | { kind: 'thinking'; text: string }
  | { kind: 'tool_call'; callId: string; tool: string; input: unknown }
  | {
      kind: 'tool_call_update';
      callId: string;
      status: ToolCallStatus;
      resultExcerpt?: string;
    }
  | { kind: 'usage'; contextUsed?: number; contextSize?: number };

/** session.update：流式增量上报，按 kind 区分。 */
export type SessionUpdatePayload =
  | (SessionUpdateBase & { kind: 'output'; text: string })
  | (SessionUpdateBase & { kind: 'thinking'; text: string })
  | (SessionUpdateBase & { kind: 'tool_call'; callId: string; tool: string; input: unknown })
  | (SessionUpdateBase & {
      kind: 'tool_call_update';
      callId: string;
      status: ToolCallStatus;
      resultExcerpt?: string;
    })
  | (SessionUpdateBase & {
      kind: 'usage';
      contextUsed?: number;
      contextSize?: number;
    });

/** task.state：任务生命周期状态。failed 必须带 detail。 */
export interface TaskStateDetail {
  code: string;
  message: string;
}

export interface TaskStatePayload {
  conversationId: string;
  state: TaskState;
  detail?: TaskStateDetail;
}

/** approval.request：ACP 审批请求（permissionPolicy='ask' 时必现）。 */
export interface ApprovalOption {
  kind: ApprovalOptionKind;
  label: string;
}

export interface ApprovalRequestPayload {
  conversationId: string;
  approvalId: string;
  tool: string;
  input: unknown;
  workspace: string;
  options: ApprovalOption[];
  permissionLevel: number;
  riskLevel: string;
  expiresAt: string;
}

/** approval.resolved：审批结算。超时由 Agent 判定并上报 decidedBy='timeout'。 */
export interface ApprovalResolvedPayload {
  conversationId: string;
  approvalId: string;
  decision: ApprovalDecision;
  decidedBy: ApprovalDecidedBy;
}

/** 设备能力布尔位（§3 device.status.capabilities）。 */
export interface DeviceCapabilitiesPayload {
  chat: boolean;
  cancel: boolean;
  approvalIntercept: boolean;
  sessionResume: boolean;
  /** M2.6：工作区目录浏览（由 Agent 本地文件系统实现，不依赖 Harness）。 */
  workspaceList?: boolean;
  fileRead: boolean;
  /** M2.8：手机端写文件（授权根内、带 sha256 乐观锁与人工确认）。 */
  fileWrite?: boolean;
}

/** device.status：Agent 上线 / 周期性上报。 */
export interface DeviceStatusPayload {
  online: boolean;
  deviceName: string;
  agentVersion: string;
  harnessVersion: string | null;
  capabilities: DeviceCapabilitiesPayload;
  workspaceRoots: string[];
  lastSeen: string;
}

/** error：上行错误通知。 */
export interface ErrorPayload {
  code: RelayErrorCode;
  message: string;
  conversationId?: string;
}

/* -------------------------------------------------------------------------- */
/* 构造 / 解析 / 读值辅助                                                       */
/* -------------------------------------------------------------------------- */

let envelopeCounter = 0;

/**
 * 构造一个 v1 信封。自动填入 id 与 ts；payload 为 undefined 时省略该字段
 * （心跳 ping 即为 `{v:1,type:'ping',id,ts}`）。
 */
export function createEnvelope<T = unknown>(type: string, payload?: T): RelayEnvelope<T> {
  envelopeCounter += 1;
  const envelope: RelayEnvelope<T> = {
    v: RELAY_PROTOCOL_VERSION,
    type,
    id: `msg_${Date.now().toString(36)}_${envelopeCounter.toString(36)}`,
    ts: new Date().toISOString(),
  };
  if (payload !== undefined) {
    envelope.payload = payload;
  }
  return envelope;
}

/** 判断值是否为非数组普通对象。 */
export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/**
 * 解析一帧文本为协议信封。
 * 非法 JSON / 非对象 / v 不匹配 / type 非法 / 超长 → 返回 null（调用方自行记日志）。
 */
export function parseEnvelope(raw: string): RelayEnvelope<unknown> | null {
  if (typeof raw !== 'string' || raw.length === 0 || raw.length > RELAY_MAX_FRAME_BYTES) {
    return null;
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return null;
  }
  if (!isRecord(parsed)) {
    return null;
  }
  if (parsed.v !== RELAY_PROTOCOL_VERSION) {
    return null;
  }
  const type = parsed.type;
  if (typeof type !== 'string' || type.length === 0 || type.length > 128) {
    return null;
  }
  const envelope: RelayEnvelope<unknown> = { v: RELAY_PROTOCOL_VERSION, type };
  if (typeof parsed.id === 'string') {
    envelope.id = parsed.id;
  }
  if (typeof parsed.ts === 'string') {
    envelope.ts = parsed.ts;
  }
  if ('payload' in parsed && parsed.payload !== undefined) {
    envelope.payload = parsed.payload;
  }
  return envelope;
}

/** 以对象形式读取 payload（非对象返回 null）。 */
export function readPayloadRecord(envelope: RelayEnvelope<unknown>): Record<string, unknown> | null {
  return isRecord(envelope.payload) ? envelope.payload : null;
}

/** payload 字段读取：字符串，否则 null。 */
export function readString(record: Record<string, unknown> | null, key: string): string | null {
  if (record === null) {
    return null;
  }
  const value = record[key];
  return typeof value === 'string' ? value : null;
}

/** payload 字段读取：有限数字，否则 null。 */
export function readNumber(record: Record<string, unknown> | null, key: string): number | null {
  if (record === null) {
    return null;
  }
  const value = record[key];
  return typeof value === 'number' && Number.isFinite(value) ? value : null;
}

/** 以 JSON 文本估算信封字节数，仅用于日志。 */
export function envelopeByteSize(envelope: RelayEnvelope<unknown>): number {
  try {
    return JSON.stringify(envelope).length;
  } catch {
    return 0;
  }
}

/* -------------------------------------------------------------------------- */
/* 传输抽象                                                                     */
/* -------------------------------------------------------------------------- */

/** 注销回调。 */
export type RelayUnsubscribe = () => void;

/**
 * RelayAgent 只依赖该最小传输接口，便于测试注入假 transport。
 * 实现方需保证 send 在未连接时排队（见 relay-client.ts）。
 */
export interface RelayTransport {
  send(envelope: RelayEnvelope<unknown>): void;
  onMessage(listener: (envelope: RelayEnvelope<unknown>) => void): RelayUnsubscribe;
  isConnected(): boolean;
}
