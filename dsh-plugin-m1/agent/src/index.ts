/**
 * Remote Agent 内核（M0）。
 * 对外只暴露 HarnessAdapter 抽象 + ACP 实现 + 工具函数，上层（Transport/TaskService）不得直接依赖 ACP 细节。
 */
export type * from './harness/adapter.ts';
export { AcpAdapter } from './harness/acp/acp-adapter.ts';
export type { AcpAdapterOptions, PermissionPolicy, TurnSettlement } from './harness/acp/acp-adapter.ts';
export { discoverDshInstall, buildAcpEnv, detectHarnessVersion, launchAcp } from './harness/acp/launcher.ts';
export type { DshInstall } from './harness/acp/launcher.ts';
export { JsonRpcPeer, NdjsonDecoder } from './harness/acp/jsonrpc.ts';
export { mapSessionUpdate, extractText, summarizeConfigOptions } from './harness/acp/mapper.ts';
export { HarnessError, toHarnessError, mapJsonRpcError } from './harness/errors.ts';
export type { HarnessErrorCode } from './harness/errors.ts';
export { Logger, memoryLogger } from './infra/logger.ts';
export { redactDeep, truncateText, safeErrorMessage } from './infra/redact.ts';
