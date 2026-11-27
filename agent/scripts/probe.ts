/**
 * M0 探针：只做「能连上、能跑一个真实 turn、能优雅退出」的最小验证。
 * 用法：node scripts/probe.ts [--prompt "只回复：收到"]
 * 输出：stdout 打印结论；完整事件写 evidence/probe-<时间戳>.jsonl
 */
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { AcpAdapter } from '../src/harness/acp/acp-adapter.ts';
import type { HarnessEvent } from '../src/harness/adapter.ts';
import { Logger } from '../src/infra/logger.ts';

function argValue(name: string, fallback: string): string {
  const index = process.argv.indexOf(name);
  if (index >= 0) {
    const value = process.argv[index + 1];
    if (value !== undefined) return value;
  }
  return fallback;
}

async function main(): Promise<void> {
  const prompt = argValue('--prompt', '只回复两个字：收到');
  const logger = new Logger({ level: 'debug', scope: 'probe' });
  const evidenceDir = join(import.meta.dirname, '..', 'evidence');
  mkdirSync(evidenceDir, { recursive: true });
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const evidenceFile = join(evidenceDir, `probe-${stamp}.jsonl`);
  const lines: string[] = [];
  const record = (entry: unknown): void => {
    lines.push(JSON.stringify(entry));
    writeFileSync(evidenceFile, lines.join('\n') + '\n', 'utf8');
  };

  const adapter = new AcpAdapter({ logger, permissionPolicy: 'ask' });
  const events: HarnessEvent[] = [];
  adapter.subscribe((event) => {
    events.push(event);
    record({ at: new Date().toISOString(), event });
    if (event.type === 'output') process.stdout.write(`[output] ${event.text.slice(0, 200)}\n`);
    else if (event.type === 'tool_call') process.stdout.write(`[tool] ${event.tool}\n`);
    else if (event.type === 'tool_call_update') process.stdout.write(`[tool:${event.status}] ${event.callId}\n`);
    else if (event.type === 'thinking') process.stdout.write(`[thinking] ${event.text.slice(0, 120)}\n`);
    else if (event.type === 'usage') process.stdout.write(`[usage] ${event.contextUsed ?? '?'}/${event.contextSize ?? '?'}\n`);
    else if (event.type === 'approval_request') process.stdout.write(`[approval] ${event.request.actionSummary}\n`);
    else if (event.type === 'completed') process.stdout.write(`[completed] ${event.summary.slice(0, 200)}\n`);
    else if (event.type === 'failed') process.stdout.write(`[failed] ${event.errorCode} ${event.message}\n`);
  });

  const startedAt = Date.now();
  const status = await adapter.connect();
  const version = adapter.getHarnessVersion();
  console.log(`connected: running=${status.running} version=${String(version)} install=${adapter.getInstallInfo()?.root ?? '?'}`);
  const caps = await adapter.getCapabilities();
  console.log(`capabilities: ${JSON.stringify(Object.fromEntries(Object.entries(caps.values).filter(([, v]) => v === true)))}`);

  const workspace = join(import.meta.dirname, '..', '.workspaces', `probe-${stamp}`);
  mkdirSync(workspace, { recursive: true });
  const session = await adapter.createSession(workspace, 'M0 probe');
  console.log(`session: ${session.sessionId}`);
  const handle = await adapter.sendMessage(session.sessionId, {
    taskId: `probe-${stamp}`,
    conversationId: `conv-${stamp}`,
    prompt,
    workspacePath: workspace,
    timeoutSec: 180,
  });
  const settlement = await adapter.waitForTurn(session.sessionId, 180_000);
  console.log(
    `turn: stopReason=${settlement.stopReason} summary=${JSON.stringify(settlement.summary.slice(0, 200))} events=${events.length}`,
  );
  record({
    kind: 'summary',
    finishedAt: new Date().toISOString(),
    elapsedMs: Date.now() - startedAt,
    version,
    install: adapter.getInstallInfo()?.root ?? null,
    protocolVersion: (adapter.getInitializeResult() as Record<string, unknown> | null)?.['protocolVersion'] ?? null,
    sessionId: session.sessionId,
    taskId: handle.taskId,
    settlement,
    eventCount: events.length,
    evidenceFile,
  });
  await adapter.disconnect();
  console.log(`evidence: ${evidenceFile}`);
  if (settlement.stopReason !== 'end_turn') {
    process.exitCode = 1;
  }
}

main().catch((error: unknown) => {
  console.error('probe failed:', error);
  process.exitCode = 1;
});
