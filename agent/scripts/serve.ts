/**
 * M1-α Agent 进程入口（唯一契约 docs/design/M1_PROTOCOL.md §5）。
 *
 * 流程：
 *   1) POST {REMOTE_SERVER_URL}/api/v1/auth/pair（role=agent）换取 token；
 *   2) 用全局 WebSocket 连 wss/ws://<host>/ws?role=agent&token=...；
 *   3) 连接建立（含重连成功）后上报 device.status（真实 harnessVersion + capabilities）；
 *   4) 事件循环：下行信封 → RelayAgent → ACP；上行事件 → RelayClient；
 *   5) SIGINT / SIGTERM 优雅退出（停心跳、断 WS、停 ACP 进程）。
 *
 * 用法：
 *   node scripts/serve.ts
 *
 * 环境变量：
 *   REMOTE_SERVER_URL  后端基址，默认 http://127.0.0.1:8080
 *   M1_PAIRING_CODE    配对码，默认 824613
 *   DEVICE_NAME        设备名，默认 os.hostname()
 *   M1_WORKSPACE_ROOT  允许的工作区根，默认 <agent>/.m1ws
 *   M1_WORKSPACE_ROOTS 多个授权根（分号或换行分隔），设置后优先于 M1_WORKSPACE_ROOT；
 *                      第一个根作为默认工作区。
 *   M1_WORKSPACE_REFRESH_MS 每隔多久向插件核对一次授权目录，默认 20000；0 表示关闭。
 *   LOG_LEVEL          debug|info|warn|error，默认 info
 */
import { mkdirSync, readFileSync } from 'node:fs';
import { hostname } from 'node:os';
import { join, resolve } from 'node:path';

import { AcpAdapter } from '../src/harness/acp/acp-adapter.ts';
import { Logger } from '../src/infra/logger.ts';
import type { LogLevel } from '../src/infra/logger.ts';
import { safeErrorMessage } from '../src/infra/redact.ts';
import { createEnvelope, isRecord, readString } from '../src/relay/protocol.ts';
import { RelayAgent } from '../src/relay/relay-agent.ts';
import {
  RelayClient,
  buildRelayWebSocketUrl,
  maskRelayUrl,
} from '../src/relay/relay-client.ts';

const AGENT_ROOT = resolve(import.meta.dirname, '..');
const DEFAULT_SERVER_URL = 'http://127.0.0.1:8080';
const DEFAULT_PAIRING_CODE = '824613';
const DEFAULT_WORKSPACE_ROOT = join(AGENT_ROOT, '.m1ws');

const SERVER_URL = (process.env.REMOTE_SERVER_URL ?? DEFAULT_SERVER_URL).replace(/\/+$/, '');
const PAIRING_CODE = process.env.M1_PAIRING_CODE ?? DEFAULT_PAIRING_CODE;
const DEVICE_NAME = process.env.DEVICE_NAME?.trim() || hostname();
function parseWorkspaceRoots(): readonly string[] {
  const raw = process.env.M1_WORKSPACE_ROOTS?.trim();
  const list = raw
    ? raw.split(/[;\n\r]+/).map((item) => item.trim()).filter((item) => item.length > 0)
    : [];
  if (list.length > 0) {
    return list.map((item) => resolve(item));
  }
  const single = process.env.M1_WORKSPACE_ROOT?.trim();
  return [single ? resolve(single) : DEFAULT_WORKSPACE_ROOT];
}

const WORKSPACE_ROOTS = parseWorkspaceRoots();
const WORKSPACE_ROOT = WORKSPACE_ROOTS[0];
const WORKSPACE_REFRESH_MS = parseRefreshInterval(process.env.M1_WORKSPACE_REFRESH_MS);
const LOG_LEVEL = parseLogLevel(process.env.LOG_LEVEL);
const AGENT_VERSION = readAgentVersion();

const logger = new Logger({ level: LOG_LEVEL, scope: 'serve' });

function parseLogLevel(value: string | undefined): LogLevel {
  const normalized = (value ?? 'info').trim().toLowerCase();
  if (normalized === 'debug' || normalized === 'info' || normalized === 'warn' || normalized === 'error') {
    return normalized;
  }
  return 'info';
}

/**
 * M4.20：授权目录的核对间隔。
 *
 * 插件在 DSH 刚启动时拉起 Agent，那一刻工作区注册表往往还没就绪，插件只能把
 * `homedir()` 递进来 —— 手机上「工作区」只剩一个 `C:\Users\…`，项目和会话全没了。
 * 所以 Agent 自己定期向插件要一次真实目录（`GET /api/v1/agent/workspaces`）并覆盖，
 * 有变化就补发 device.status。默认 20 秒，设成 0 可关闭。
 */
function parseRefreshInterval(value: string | undefined): number {
  const raw = (value ?? '').trim();
  if (raw.length === 0) {
    return 20_000;
  }
  const parsed = Number(raw);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    return 0;
  }
  return Math.round(parsed);
}

function readAgentVersion(): string {
  try {
    const raw = readFileSync(join(AGENT_ROOT, 'package.json'), 'utf8');
    const parsed = JSON.parse(raw) as unknown;
    if (isRecord(parsed)) {
      const version = readString(parsed, 'version');
      if (version !== null) {
        return version;
      }
    }
  } catch {
    // 读不到就用兜底版本号
  }
  return '0.1.0-m1';
}

/** POST /api/v1/auth/pair，返回 token。 */
async function pairAgent(clientName: string): Promise<string> {
  const response = await fetch(`${SERVER_URL}/api/v1/auth/pair`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ pairingCode: PAIRING_CODE, clientName, role: 'agent' }),
    signal: AbortSignal.timeout(15_000),
  });
  if (!response.ok) {
    const text = await response.text().catch(() => '');
    throw new Error(`pair 失败：HTTP ${response.status} ${text.slice(0, 300)}`);
  }
  const parsed = (await response.json()) as unknown;
  const token = isRecord(parsed) ? readString(parsed, 'token') : null;
  if (token === null || token.length === 0) {
    throw new Error('pair 响应缺少 token');
  }
  return token;
}

/** 配对失败重试（本地开发时后端启动略慢是常态）。 */
async function pairWithRetry(clientName: string, attempts = 3): Promise<string> {
  let lastError: unknown = new Error('pair 未执行');
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      return await pairAgent(clientName);
    } catch (error) {
      lastError = error;
      logger.warn('m1.agent.pair.failed', {
        attempt,
        attempts,
        message: safeErrorMessage(error),
      });
      if (attempt < attempts) {
        await new Promise<void>((resolveDelay) => setTimeout(resolveDelay, 1_000 * attempt));
      }
    }
  }
  throw new Error(`配对失败（已重试 ${attempts} 次）：${safeErrorMessage(lastError)}`);
}

let shuttingDown = false;

async function main(): Promise<number> {
  logger.info('m1.agent.boot', {
    serverUrl: SERVER_URL,
    deviceName: DEVICE_NAME,
    workspaceRoot: WORKSPACE_ROOT,
    workspaceRoots: WORKSPACE_ROOTS,
    agentVersion: AGENT_VERSION,
    logLevel: LOG_LEVEL,
    node: process.version,
  });
  mkdirSync(WORKSPACE_ROOT, { recursive: true });
  // 1) 配对拿 token
  let token = await pairWithRetry(DEVICE_NAME);
  logger.info('m1.agent.paired', { serverUrl: SERVER_URL, deviceName: DEVICE_NAME });

  // 2) 启动 ACP harness（permissionPolicy='ask'，审批经 relay 转发给手机端）
  const adapter = new AcpAdapter({
    logger: logger.child('acp'),
    permissionPolicy: 'ask',
  });
  await adapter.connect();
  const status = await adapter.getStatus();
  logger.info('m1.agent.acp.connected', {
    running: status.running,
    version: status.version,
    harnessVersion: adapter.getHarnessVersion(),
    adapter: status.adapter,
  });

  // 3) 组装 relay：RelayClient（传输）+ RelayAgent（业务）
  const client = new RelayClient({
    url: buildRelayWebSocketUrl(SERVER_URL, 'agent', token),
    logger: logger.child('relay-client'),
    // token 过期（关闭码 4401）时重新配对换新 url。
    urlRefresher: async () => {
      token = await pairAgent(DEVICE_NAME);
      return buildRelayWebSocketUrl(SERVER_URL, 'agent', token);
    },
  });
  const agent = new RelayAgent({
    harness: adapter,
    transport: client,
    workspaceRoot: WORKSPACE_ROOT,
    workspaceRoots: WORKSPACE_ROOTS,
    logger: logger.child('relay-agent'),
    deviceName: DEVICE_NAME,
    agentVersion: AGENT_VERSION,
  });
  await agent.start();

  // M4.20：Agent 可能是插件在「工作区注册表还没就绪」时拉起来的，那时只有一个
  // homedir。定期向插件要一次真实目录，变了就覆盖并补发 device.status。
  const refreshWorkspaceRoots = async (): Promise<void> => {
    if (WORKSPACE_REFRESH_MS === 0) {
      return;
    }
    try {
      const response = await fetch(`${SERVER_URL}/api/v1/agent/workspaces`, {
        headers: { authorization: `Bearer ${token}` },
        signal: AbortSignal.timeout(8_000),
      });
      if (!response.ok) {
        logger.debug('m1.agent.workspace_roots.refused', { status: response.status });
        return;
      }
      const parsed = (await response.json()) as unknown;
      const rows = isRecord(parsed) && Array.isArray(parsed.workspaces) ? parsed.workspaces : [];
      const paths = rows
        .map((row) => (isRecord(row) ? readString(row, 'path') : null))
        .filter((item): item is string => item !== null && item.trim().length > 0);
      if (paths.length === 0) {
        return;
      }
      agent.setWorkspaceRoots(paths);
    } catch (error) {
      logger.debug('m1.agent.workspace_roots.refresh_failed', { message: safeErrorMessage(error) });
    }
  };
  const rootsTimer =
    WORKSPACE_REFRESH_MS > 0
      ? setInterval(() => {
          void refreshWorkspaceRoots();
        }, WORKSPACE_REFRESH_MS)
      : null;
  rootsTimer?.unref?.();

  // 每次（重）连成功后都补发一次 device.status，保证后端 online 状态可信。
  client.onOpen(() => {
    logger.info('m1.agent.connected', {
      url: maskRelayUrl(buildRelayWebSocketUrl(SERVER_URL, 'agent', '***')),
    });
    agent.sendDeviceStatus();
    // 重连后立刻核对一次授权目录（插件可能已经重新注册过工作区）。
    void refreshWorkspaceRoots();
  });
  client.onClose((info) => {
    logger.warn('m1.agent.disconnected', { code: info.code, reason: info.reason });
  });
  client.onMessage((envelope) => {
    void agent.handleEnvelope(envelope).catch((error: unknown) => {
      logger.warn('m1.agent.envelope.failed', {
        type: envelope.type,
        message: safeErrorMessage(error),
      });
    });
  });

  // 4) 连接并保持运行
  client.connect();
  try {
    await client.waitForOpen(20_000);
  } catch (error) {
    // 不退出：RelayClient 会按指数退避持续重连，恢复后自动补发 device.status。
    logger.warn('m1.agent.first_connect.timeout', { message: safeErrorMessage(error) });
  }

  const shutdown = async (signal: string): Promise<void> => {
    if (shuttingDown) {
      return;
    }
    shuttingDown = true;
    logger.info('m1.agent.shutdown.begin', { signal });
    if (rootsTimer !== null) {
      clearInterval(rootsTimer);
    }
    try {
      await client.close();
    } catch (error) {
      logger.warn('m1.agent.shutdown.relay.failed', { message: safeErrorMessage(error) });
    }
    try {
      agent.stop();
    } catch (error) {
      logger.warn('m1.agent.shutdown.agent.failed', { message: safeErrorMessage(error) });
    }
    try {
      await adapter.disconnect();
    } catch (error) {
      logger.warn('m1.agent.shutdown.acp.failed', { message: safeErrorMessage(error) });
    }
    logger.info('m1.agent.shutdown.done', { stats: client.getStats() });
  };

  process.on('SIGINT', () => {
    void shutdown('SIGINT').then(() => {
      process.exit(0);
    });
  });
  process.on('SIGTERM', () => {
    void shutdown('SIGTERM').then(() => {
      process.exit(0);
    });
  });
  process.on('unhandledRejection', (reason) => {
    logger.error('m1.agent.unhandled_rejection', { message: safeErrorMessage(reason) });
  });
  process.on('uncaughtException', (error) => {
    logger.error('m1.agent.uncaught_exception', { message: safeErrorMessage(error) });
    void shutdown('uncaughtException').then(() => {
      process.exit(1);
    });
  });

  logger.info('m1.agent.ready', {
    serverUrl: SERVER_URL,
    deviceName: DEVICE_NAME,
    workspaceRoot: WORKSPACE_ROOT,
    wsUrl: maskRelayUrl(buildRelayWebSocketUrl(SERVER_URL, 'agent', token)),
    hint: 'Ctrl+C 退出',
  });

  // 事件循环由 WS/ACP/重连定时器保持；这里挂起直到信号触发退出。
  await new Promise<void>(() => {
    // 永不 resolve：由 SIGINT/SIGTERM 处理器调用 process.exit(0)
  });
  return 0;
}

main()
  .then((code) => {
    process.exit(code);
  })
  .catch((error: unknown) => {
    logger.error('m1.agent.fatal', { message: safeErrorMessage(error) });
    console.error(`M1 Agent 启动失败：${safeErrorMessage(error)}`);
    process.exit(2);
  });

// 供静态检查/文档引用：上行信封构造工具（serve 自身目前只用下行的 handleEnvelope 路径）。
export { createEnvelope, pairAgent, SERVER_URL, WORKSPACE_ROOT, WORKSPACE_ROOTS, DEVICE_NAME };
