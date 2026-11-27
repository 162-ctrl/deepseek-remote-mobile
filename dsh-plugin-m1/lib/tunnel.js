// 公网接入：把本机的 M1 中继通过 cloudflared 快速隧道暴露成一个 https 地址。
//
// 不做任何隧道协议实现——只负责「找到 cloudflared → 跑起来 → 从日志里认出公网 URL → 管好它的生死」。
// 也可以不跑隧道：配 publicUrl 指向自建域名（cloudflared 命名隧道 / Nginx / frp 都行）。
import { spawn } from 'node:child_process';
import { EventEmitter } from 'node:events';
import { existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { delimiter, join } from 'node:path';

const URL_RE = /https:\/\/[a-z0-9][a-z0-9-]*\.trycloudflare\.com/i;

/** 依次找：显式配置 → 环境变量 → PATH → 常见安装目录。找不到返回 null。 */
export function resolveCloudflared(explicitPath) {
  const candidates = [];
  if (typeof explicitPath === 'string' && explicitPath.trim().length > 0) candidates.push(explicitPath.trim());
  if (process.env.DSH_CLOUDFLARED) candidates.push(process.env.DSH_CLOUDFLARED);
  const exeName = process.platform === 'win32' ? 'cloudflared.exe' : 'cloudflared';
  for (const dir of (process.env.PATH ?? '').split(delimiter)) {
    if (dir) candidates.push(join(dir, exeName));
  }
  const localAppData = process.env.LOCALAPPDATA ?? '';
  if (localAppData) candidates.push(join(localAppData, 'dsh-tools', 'cloudflared', exeName));
  candidates.push(join(homedir(), 'dsh-tools', 'cloudflared', exeName));
  candidates.push(join(homedir(), 'dsh-tools', 'bin', exeName));

  for (const candidate of candidates) {
    try {
      if (existsSync(candidate)) return candidate;
    } catch {
      /* 权限不足之类直接跳过 */
    }
  }
  return null;
}

export class CloudflaredTunnel extends EventEmitter {
  constructor({ binPath, localPort, log = () => {} }) {
    super();
    this.binPath = binPath;
    this.localPort = localPort;
    this.log = log;
    this.url = null;
    this.error = null;
    this.running = false;
    this.child = null;
    this.stopped = false;
    this.attempts = 0;
    this.retryTimer = null;
    this.url = null;
  }

  start() {
    if (this.child || this.stopped) return;
    if (!this.binPath) {
      this.error = '找不到 cloudflared（可配置 cloudflaredPath，或把 cloudflared 放进 PATH）';
      this.log(`公网隧道未启动：${this.error}`);
      this.emit('unavailable', this.error);
      return;
    }
    const args = [
      'tunnel',
      '--url',
      `http://127.0.0.1:${this.localPort}`,
      '--no-autoupdate',
      '--protocol',
      'http2',
      '--loglevel',
      'info',
    ];
    this.log(`启动公网隧道：${this.binPath} ${args.join(' ')}`);
    let child;
    try {
      child = spawn(this.binPath, args, { stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true });
    } catch (error) {
      this.error = `cloudflared 启动失败：${error?.message ?? error}`;
      this.log(this.error);
      this.emit('unavailable', this.error);
      return;
    }
    this.child = child;
    this.running = true;

    const onChunk = (chunk) => {
      const text = String(chunk);
      const match = URL_RE.exec(text);
      if (match && !this.url) {
        this.url = match[0].replace(/\/+$/, '');
        this.log(`公网地址就绪：${this.url}`);
        this.emit('url', this.url);
      }
    };
    child.stdout?.on('data', onChunk);
    child.stderr?.on('data', (chunk) => {
      onChunk(chunk);
      const text = String(chunk).trim();
      if (text.length > 0 && /error|failed|warn/i.test(text)) this.log(`cloudflared: ${text.slice(0, 400)}`);
    });

    child.on('exit', (code) => {
      this.running = false;
      this.child = null;
      if (this.stopped) return;
      this.url = null;
      this.error = `cloudflared 退出（code=${code}）`;
      this.log(this.error);
      this.emit('exit', code);
      this.scheduleRetry();
    });
    child.on('error', (error) => {
      this.error = `cloudflared 异常：${error?.message ?? error}`;
      this.log(this.error);
      this.emit('unavailable', this.error);
    });
  }

  /** 快速隧道会自己断，断了就重开；换地址后网页会跟着刷新。 */
  scheduleRetry() {
    if (this.stopped || this.retryTimer) return;
    if (this.attempts >= 5) {
      this.log('公网隧道连续失败 5 次，停止重试（可用 publicUrl 走自建隧道）');
      return;
    }
    const delay = 5_000 * 2 ** this.attempts;
    this.attempts += 1;
    this.log(`公网隧道 ${delay / 1000}s 后重试（第 ${this.attempts} 次）`);
    this.retryTimer = setTimeout(() => {
      this.retryTimer = null;
      if (this.stopped) return;
      this.start();
    }, delay);
    this.retryTimer.unref?.();
  }

  stop() {
    this.stopped = true;
    this.running = false;
    if (this.retryTimer) {
      clearTimeout(this.retryTimer);
      this.retryTimer = null;
    }
    if (!this.child) return;
    const child = this.child;
    this.child = null;
    try {
      child.kill();
    } catch {
      /* 已经退出了 */
    }
  }

  status() {
    return { enabled: true, running: this.running, url: this.url, error: this.error };
  }
}

/** 不用隧道、只用一个固定公网地址（自建域名）时的占位实现。 */
export function staticPublicEndpoint(url) {
  const normalized = String(url).replace(/\/+$/, '');
  return {
    status: () => ({ enabled: true, running: true, url: normalized, error: null }),
    stop: () => {},
    start: () => {},
  };
}
