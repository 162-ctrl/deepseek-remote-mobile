// 托管 ACP Agent 子进程：插件只做中继，真正的 Harness 会话由项目里已验证的
// `agent/scripts/serve.ts` 建立（配对 → WS → spawn `dsh --profile acp`）。
import { spawn, spawnSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { delimiter, join } from 'node:path';

/** 找可用的 Node：显式配置 → DSH_NODE → PATH → 当前进程（Electron 需 RUN_AS_NODE）。 */
export function resolveNode(explicit) {
  if (typeof explicit === 'string' && explicit.length > 0 && existsSync(explicit)) {
    return { exe: explicit, label: explicit, env: {} };
  }
  const shim = process.env.DSH_NODE;
  if (typeof shim === 'string' && shim.length > 0 && existsSync(shim)) {
    return { exe: shim, label: shim, env: {} };
  }
  const envPath = process.env.PATH ?? process.env.Path ?? '';
  for (const dir of envPath.split(delimiter)) {
    if (!dir) continue;
    const candidate = join(dir, process.platform === 'win32' ? 'node.exe' : 'node');
    if (existsSync(candidate)) {
      const probe = spawnSync(candidate, ['-v'], { encoding: 'utf8', windowsHide: true });
      const version = (probe.stdout ?? '').trim();
      if (probe.status === 0 && /^v(2[2-9]|[3-9]\d)\./.test(version)) {
        return { exe: candidate, label: `${candidate} (${version})`, env: {} };
      }
    }
  }
  return {
    exe: process.execPath,
    label: `${process.execPath} (ELECTRON_RUN_AS_NODE)`,
    env: { ELECTRON_RUN_AS_NODE: '1' },
  };
}

export class AgentSupervisor {
  #config;
  #log;
  #child = null;
  #stopped = false;
  #restartTimer = null;
  #attempts = 0;
  #starts = 0;
  #lastExit = null;

  constructor({ entry, cwd, serverUrl, pairingCode, workspaceRoots, deviceName, nodePath, tokenFilePath, dshInstallRoot, log }) {
    this.#config = {
      entry,
      cwd,
      serverUrl,
      pairingCode,
      workspaceRoots,
      deviceName,
      nodePath,
      tokenFilePath,
      // M4.49：便携版 DSH 不在 PATH 也不在默认安装位，agent 自己找不到，得由我们告诉它。
      dshInstallRoot,
    };
    this.#log = log ?? (() => {});
  }

  /**
   * 读上次存下的 agent token（M4.43）。
   * 有了它，agent 重启不用再 pair 一次——token 就不会只增不减。
   * 读不到、坏掉、或已过期都返回空串，调用方照旧走配对流程。
   */
  readAgentToken() {
    const path = this.#config.tokenFilePath;
    if (typeof path !== 'string' || path.length === 0) return '';
    try {
      if (!existsSync(path)) return '';
      const parsed = JSON.parse(readFileSync(path, 'utf8'));
      const token = String(parsed?.token ?? '');
      const expiresAt = new Date(String(parsed?.expiresAt ?? ''));
      if (token.length === 0) return '';
      if (!Number.isNaN(expiresAt.getTime()) && expiresAt.getTime() <= Date.now()) return '';
      return token;
    } catch {
      return '';
    }
  }

  get running() {
    return this.#child !== null && this.#child.exitCode === null;
  }

  status() {
    return { running: this.running, starts: this.#starts, attempts: this.#attempts, lastExit: this.#lastExit };
  }

  start() {
    if (this.#child !== null || this.#stopped) return;
    const node = resolveNode(this.#config.nodePath);
    const dshInstallRoot = typeof this.#config.dshInstallRoot === 'string' ? this.#config.dshInstallRoot.trim() : '';
    if (this.#starts === 0) {
      this.#log(`agent 启动器：${node.label}`);
      // M4.49：没有这一条，便携版 DSH 下 agent 会一直报「未找到 DeepSeek Harness 安装」。
      this.#log(
        dshInstallRoot.length > 0
          ? `DSH 安装目录：${dshInstallRoot}`
          : '没从进程路径推出 DSH 安装目录（可用 DSH_INSTALL_ROOT 指定）',
      );
    }
    const roots = this.#config.workspaceRoots.join(';');
    const agentToken = this.readAgentToken();
    const env = {
      ...process.env,
      ...node.env,
      REMOTE_SERVER_URL: this.#config.serverUrl,
      M1_PAIRING_CODE: this.#config.pairingCode,
      DEVICE_NAME: this.#config.deviceName,
      M1_WORKSPACE_ROOTS: roots,
      M1_WORKSPACE_ROOT: this.#config.workspaceRoots[0] ?? process.cwd(),
      LOG_LEVEL: process.env.LOG_LEVEL ?? 'info',
      ...(dshInstallRoot.length > 0 ? { DSH_INSTALL_ROOT: dshInstallRoot } : {}),
      // M4.43：带上上次的 token，agent 侧优先复用它；同时也告诉它存哪儿。
      ...(agentToken.length > 0 ? { M1_AGENT_TOKEN: agentToken } : {}),
      ...(typeof this.#config.tokenFilePath === 'string' && this.#config.tokenFilePath.length > 0
        ? { M1_AGENT_TOKEN_FILE: this.#config.tokenFilePath }
        : {}),
    };
    const child = spawn(node.exe, [this.#config.entry], {
      cwd: this.#config.cwd,
      env,
      stdio: ['ignore', 'pipe', 'pipe'],
      windowsHide: true,
    });
    this.#child = child;
    this.#starts += 1;
    const pipe = (stream, prefix) => {
      stream.setEncoding('utf8');
      let pending = '';
      stream.on('data', (chunk) => {
        pending += chunk;
        const lines = pending.split(/\r?\n/);
        pending = lines.pop() ?? '';
        for (const line of lines) {
          if (line.trim().length > 0) this.#log(`[${prefix}] ${line}`);
        }
      });
    };
    pipe(child.stdout, 'agent');
    pipe(child.stderr, 'agent!');
    child.on('error', (error) => {
      this.#log(`agent 启动失败：${error?.message ?? error}`);
    });
    child.on('exit', (code, signal) => {
      this.#lastExit = { code, signal, at: new Date().toISOString() };
      this.#child = null;
      if (this.#stopped) return;
      this.#attempts += 1;
      const delay = Math.min(30_000, 1000 * 2 ** Math.min(this.#attempts, 5));
      this.#log(`agent 退出 code=${code} signal=${signal}，${Math.round(delay / 1000)}s 后重启`);
      this.#restartTimer = setTimeout(() => {
        this.#restartTimer = null;
        this.start();
      }, delay);
      this.#restartTimer.unref?.();
    });
  }

  stop() {
    this.#stopped = true;
    if (this.#restartTimer !== null) {
      clearTimeout(this.#restartTimer);
      this.#restartTimer = null;
    }
    const child = this.#child;
    this.#child = null;
    if (child === null) return;
    try {
      child.kill();
    } catch {
      /* 已退出 */
    }
  }
}
