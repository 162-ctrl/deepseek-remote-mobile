/**
 * 发现并启动 DeepSeek Harness 的 ACP 服务（`dsh --profile acp`）。
 *
 * 实测事实（docs/research/HARNESS_INTERFACES.md）：
 * - dsh.cmd 等价于：设置 ELECTRON_RUN_AS_NODE=1，再执行
 *   "<安装根>\DeepSeek Harness.exe" --expose-internals "<安装根>\resources\app.asar\dsh\node_modules\@deepseek-ai\dsh-desktop-host\lib\cli.js" %*
 * - 因此 Agent 不需要用户 PATH 里有 dsh，按安装目录直接 spawn 更可靠。
 * - 不注入 DEEPSEEK_API_KEY / 任何密钥环境变量：凭证由 Harness 自己从 DSH_HOME 读取。
 */
import { execFile, spawn, spawnSync } from 'node:child_process';
import type { ChildProcessWithoutNullStreams } from 'node:child_process';
import { existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { promisify } from 'node:util';
import { HarnessError } from '../errors.ts';

const execFileAsync = promisify(execFile);

export interface DshInstall {
  /** Electron 可执行文件（DeepSeek Harness.exe） */
  readonly exe: string;
  /** dsh CLI 入口（app.asar 内 cli.js） */
  readonly cli: string;
  /** 安装根目录 */
  readonly root: string;
  /** 发现来源，便于排障 */
  readonly source: 'env_override' | 'path' | 'default' | 'root_override' | 'parent';
}

export interface DiscoverOptions {
  readonly exe?: string;
  readonly cli?: string;
  readonly root?: string;
  readonly env?: NodeJS.ProcessEnv;
}

const CLI_RELATIVE = join('resources', 'app.asar', 'dsh', 'node_modules', '@deepseek-ai', 'dsh-desktop-host', 'lib', 'cli.js');
const EXE_RELATIVE = 'DeepSeek Harness.exe';

/**
 * 路径存在性判断。
 * 注意：cli.js 位于 app.asar（Electron 归档文件）内部，普通 Node 的 fs.existsSync 看不到归档内的条目，
 * 因此对 .asar 内路径改为校验归档文件本身存在。
 */
function pathExists(path: string): boolean {
  if (existsSync(path)) return true;
  const asarIndex = path.toLowerCase().indexOf('.asar');
  if (asarIndex >= 0) {
    const archive = path.slice(0, asarIndex + '.asar'.length);
    return existsSync(archive);
  }
  return false;
}

function installFromRoot(root: string, source: DshInstall['source']): DshInstall | null {
  const exe = join(root, EXE_RELATIVE);
  const cli = join(root, CLI_RELATIVE);
  if (!pathExists(exe) || !pathExists(cli)) return null;
  return { exe, cli, root, source };
}

function rootFromDshCmd(dshCmdPath: string): string {
  // <root>\resources\runtime\cli\bin\dsh.cmd → <root>
  const binDir = dirname(dshCmdPath);
  return resolve(binDir, '..', '..', '..', '..');
}

/** 从 PATH 里找 dsh.cmd（不调用 shell，避免引号/注入问题） */
export function findDshCmdOnPath(env: NodeJS.ProcessEnv = process.env): string | null {
  const pathValue = env['PATH'] ?? env['Path'] ?? '';
  const candidates = pathValue
    .split(';')
    .filter((entry) => entry.trim() !== '')
    .map((entry) => join(entry.trim(), 'dsh.cmd'));
  for (const candidate of candidates) {
    if (existsSync(candidate)) return candidate;
  }
  return null;
}

/**
 * Windows：从父进程可执行文件推断安装根（M4.49 便携版兜底）。
 *
 * 插件场景里 agent 由 Harness 主进程直接 spawn，父进程可执行文件就是
 * `<安装根>\DeepSeek Harness.exe`。便携版既不在 PATH、也不在 `%LOCALAPPDATA%`
 * 的默认安装位时，前面四条全落空——2026-11-23 就是这样一直报
 * 「未找到 DeepSeek Harness 安装」。查不到/超时/权限不足一律返回 null，不抛。
 */
export function installRootFromParentExe(
  platform: string = process.platform,
  parentPid: number = process.ppid,
): string | null {
  if (platform !== 'win32') return null;
  if (!Number.isInteger(parentPid) || parentPid <= 0) return null;
  try {
    const probe = spawnSync(
      'powershell.exe',
      [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        `(Get-CimInstance Win32_Process -Filter "ProcessId=${parentPid}").ExecutablePath`,
      ],
      { encoding: 'utf8', timeout: 8_000, windowsHide: true },
    );
    const lines = (probe.stdout ?? '')
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter((line) => line.length > 0);
    const exePath = lines.length > 0 ? lines[lines.length - 1]! : '';
    if (!exePath.toLowerCase().endsWith(EXE_RELATIVE.toLowerCase())) return null;
    return dirname(exePath);
  } catch {
    return null;
  }
}

/**
 * 发现顺序：显式参数 → 环境变量(DSH_INSTALL_ROOT / DSH_EXE+DSH_CLI) → PATH 中的 dsh.cmd →
 * LOCALAPPDATA 默认路径 → 父进程 exe 推断（便携版兜底）。
 * 找不到时抛 HARNESS_NOT_INSTALLED，不静默降级（探测顺序由 CapabilityRegistry 负责）。
 */
export function discoverDshInstall(options: DiscoverOptions = {}): DshInstall {
  const env = options.env ?? process.env;

  if (options.exe !== undefined && options.cli !== undefined && pathExists(options.exe) && pathExists(options.cli)) {
    return { exe: options.exe, cli: options.cli, root: options.root ?? dirname(options.exe), source: 'env_override' };
  }

  const envExe = env['DSH_EXE'];
  const envCli = env['DSH_CLI'];
  if (envExe !== undefined && envCli !== undefined && pathExists(envExe) && pathExists(envCli)) {
    return { exe: envExe, cli: envCli, root: env['DSH_INSTALL_ROOT'] ?? dirname(envExe), source: 'env_override' };
  }

  const rootOverride = options.root ?? env['DSH_INSTALL_ROOT'];
  if (rootOverride !== undefined) {
    const found = installFromRoot(rootOverride, 'root_override');
    if (found !== null) return found;
  }

  const dshCmd = findDshCmdOnPath(env);
  if (dshCmd !== null) {
    const found = installFromRoot(rootFromDshCmd(dshCmd), 'path');
    if (found !== null) return found;
  }

  const localAppData = env['LOCALAPPDATA'];
  if (localAppData !== undefined) {
    const found = installFromRoot(join(localAppData, 'Programs', 'DeepSeek Harness'), 'default');
    if (found !== null) return found;
  }

  // 便携版兜底（M4.49）：由 Harness 主进程拉起的 agent，父进程就是那个 exe。
  const parentRoot = installRootFromParentExe();
  if (parentRoot !== null) {
    const found = installFromRoot(parentRoot, 'parent');
    if (found !== null) return found;
  }

  throw new HarnessError('HARNESS_NOT_INSTALLED', '未找到 DeepSeek Harness 安装（可通过 DSH_INSTALL_ROOT 指定）', {
    details: { triedPath: dshCmd, triedDefault: localAppData !== undefined },
  });
}

/** 子进程环境：只透传非敏感的进程运行必需变量（REMOTE_AGENT.md §4.3 环境行） */
export function buildAcpEnv(parentEnv: NodeJS.ProcessEnv = process.env, extra: Readonly<Record<string, string>> = {}): NodeJS.ProcessEnv {
  const keepKeys = [
    'PATH',
    'Path',
    'PATHEXT',
    'HOME',
    'USERPROFILE',
    'TEMP',
    'TMP',
    'APPDATA',
    'LOCALAPPDATA',
    'SYSTEMROOT',
    'SystemRoot',
    'WINDIR',
    'COMSPEC',
    'NUMBER_OF_PROCESSORS',
    'PROCESSOR_ARCHITECTURE',
    'LANG',
    // Harness 自己的配置根：只透传，不新建
    'DSH_HOME',
  ] as const;
  const env: NodeJS.ProcessEnv = {};
  for (const key of keepKeys) {
    const value = parentEnv[key];
    if (value !== undefined) env[key] = value;
  }
  env['ELECTRON_RUN_AS_NODE'] = '1';
  env['NO_COLOR'] = '1';
  for (const [key, value] of Object.entries(extra)) env[key] = value;
  return env;
}

export interface LaunchOptions {
  readonly install?: DshInstall;
  readonly env?: NodeJS.ProcessEnv;
  readonly cwd?: string;
  readonly extraEnv?: Readonly<Record<string, string>>;
}

export interface AcpProcess {
  readonly child: ChildProcessWithoutNullStreams;
  readonly install: DshInstall;
}

export const ACP_COMMAND_ARGS = (cli: string): readonly string[] => ['--expose-internals', cli, '--profile', 'acp'];

/** 启动常驻 ACP 子进程；零选项（cwd 由 session/new 决定，见 REMOTE_AGENT.md §4.3） */
export function launchAcp(options: LaunchOptions = {}): AcpProcess {
  const install = options.install ?? discoverDshInstall({ env: options.env });
  const env = buildAcpEnv(options.env, options.extraEnv);
  const child = spawn(install.exe, ACP_COMMAND_ARGS(install.cli), {
    cwd: options.cwd ?? install.root,
    env,
    stdio: ['pipe', 'pipe', 'pipe'],
    shell: false,
    windowsHide: true,
  });
  child.stdin.setDefaultEncoding('utf8');
  return { child, install };
}

/** 探测 Harness 版本：exe --expose-internals cli --version（失败返回 null，不视为致命） */
export async function detectHarnessVersion(install: DshInstall, env: NodeJS.ProcessEnv = buildAcpEnv()): Promise<string | null> {
  try {
    const { stdout } = await execFileAsync(install.exe, ['--expose-internals', install.cli, '--version'], {
      env,
      timeout: 20_000,
      windowsHide: true,
      encoding: 'utf8',
    });
    const match = /(\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?)/.exec(stdout);
    return match?.[1] ?? null;
  } catch {
    return null;
  }
}
