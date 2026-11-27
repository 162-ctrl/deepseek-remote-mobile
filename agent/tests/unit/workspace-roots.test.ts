/**
 * M4.20 授权目录刷新单测（node --test，Node 24 直接跑 .ts）。
 *
 * 背景：Agent 是插件在 DSH 刚启动、工作区注册表还没就绪时拉起来的，那时只有
 * `homedir()`。手机上「工作区」因此整页只剩一个 `C:\Users\…`，项目和会话全没了，
 * 而且直到进程重启都不会自愈。这里锁住 `setWorkspaceRoots()` 的行为：
 *   - 新目录覆盖旧目录，并补发一次 device.status；
 *   - 目录没变就不发（避免每 20 秒刷一次手机）；
 *   - 空数组不覆盖（插件偶尔返回空，不能把授权根清空）；
 *   - Windows 大小写不同视为同一个目录。
 */
import assert from 'node:assert/strict';
import { test } from 'node:test';

import { Logger } from '../../src/infra/logger.ts';
import type {
  HarnessCapabilities,
  HarnessSession,
  TaskHandle,
  TaskInput,
  TurnSettlement,
} from '../../src/harness/adapter.ts';
import type { HarnessEvent } from '../../src/harness/adapter.ts';
import type { RelayEnvelope, RelayTransport } from '../../src/relay/protocol.ts';
import { RelayAgent } from '../../src/relay/relay-agent.ts';

class SilentTransport implements RelayTransport {
  readonly sent: RelayEnvelope<unknown>[] = [];

  send(envelope: RelayEnvelope<unknown>): void {
    this.sent.push(envelope);
  }

  onMessage(): () => void {
    return () => undefined;
  }

  isConnected(): boolean {
    return true;
  }

  clear(): void {
    this.sent.length = 0;
  }
}

/** 只实现 RelayAgent 会用到的那几个方法。 */
const fakeHarness = {
  async getCapabilities(): Promise<HarnessCapabilities> {
    return { values: { chat: true, cancel: true, approvalIntercept: true, sessionResume: true } } as HarnessCapabilities;
  },
  getHarnessVersion(): string | null {
    return 'fake-harness';
  },
  async createSession(): Promise<HarnessSession> {
    throw new Error('not used');
  },
  async sendMessage(_sessionId: string, _input: TaskInput): Promise<TaskHandle> {
    throw new Error('not used');
  },
  async cancelTask(_handle: TaskHandle): Promise<never> {
    throw new Error('not used');
  },
  async waitForTurn(_sessionId: string, _timeoutMs?: number): Promise<TurnSettlement> {
    throw new Error('not used');
  },
  decideApproval(): boolean {
    return false;
  },
  async getSessionEvents(): Promise<readonly HarnessEvent[]> {
    return [];
  },
  subscribe(): () => void {
    return () => undefined;
  },
};

function buildAgent(roots: readonly string[], transport: SilentTransport): RelayAgent {
  return new RelayAgent({
    harness: fakeHarness as never,
    transport,
    workspaceRoot: roots[0] ?? 'C:\\fallback',
    workspaceRoots: roots,
    logger: new Logger({ level: 'error' }),
    deviceName: 'unit-agent',
    agentVersion: '0.1.0-m1',
  });
}

function firstStatusRoots(transport: SilentTransport): readonly string[] {
  const envelope = transport.sent.find((item) => item.type === 'device.status');
  assert.ok(envelope, '应发出 device.status');
  const payload = envelope.payload as { workspaceRoots?: readonly string[] };
  return payload.workspaceRoots ?? [];
}

test('M4.20 setWorkspaceRoots 覆盖 homedir 并补发 device.status', async () => {
  const transport = new SilentTransport();
  const agent = buildAgent(['C:\\Users\\user'], transport);
  await agent.start();
  transport.clear();

  const changed = agent.setWorkspaceRoots(['D:\\项目\\demo', 'C:\\Users\\user']);

  assert.equal(changed, true, '目录变了应返回 true');
  assert.deepEqual(firstStatusRoots(transport), ['D:\\项目\\demo', 'C:\\Users\\user']);
  assert.equal(agent.buildDeviceStatus().workspaceRoots[0], 'D:\\项目\\demo', '首个根是默认工作区');
});

test('M4.20 目录没变时不重复上报', async () => {
  const transport = new SilentTransport();
  const agent = buildAgent(['D:\\项目\\demo'], transport);
  await agent.start();
  transport.clear();

  const changed = agent.setWorkspaceRoots(['D:\\项目\\demo']);

  assert.equal(changed, false);
  assert.equal(transport.sent.length, 0, '没变化不该发消息');
});

test('M4.20 空数组与空白项不覆盖已有授权根', async () => {
  const transport = new SilentTransport();
  const agent = buildAgent(['D:\\项目\\demo'], transport);
  await agent.start();
  transport.clear();

  assert.equal(agent.setWorkspaceRoots([]), false);
  assert.equal(agent.setWorkspaceRoots(['   ', '']), false);
  assert.equal(transport.sent.length, 0);
  assert.deepEqual(agent.buildDeviceStatus().workspaceRoots, ['D:\\项目\\demo']);
});

test('M4.20 去重并忽略大小写差异（Windows 语义）', async () => {
  const transport = new SilentTransport();
  const agent = buildAgent(['d:\\项目\\demo'], transport);
  await agent.start();
  transport.clear();

  const changed = agent.setWorkspaceRoots(['d:\\项目\\demo', 'D:\\项目\\DEMO', 'D:\\项目\\demo']);

  assert.equal(changed, false, '只有大小写差异应视为没变');
  assert.equal(transport.sent.length, 0);

  const grew = agent.setWorkspaceRoots(['d:\\项目\\demo', 'D:\\项目\\another']);
  assert.equal(grew, true);
  assert.deepEqual(firstStatusRoots(transport), ['d:\\项目\\demo', 'D:\\项目\\another']);
});
