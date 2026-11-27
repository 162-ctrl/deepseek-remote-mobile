// M4.49：Agent 子进程启动后要 spawn `dsh --profile acp`，得先知道 DSH 装在哪。
//
// 现象（2026-11-23 22:13 手机端「工作区怎么没有了」）：Agent 反复启动失败，
// 日志是 `未找到 DeepSeek Harness 安装（可通过 DSH_INSTALL_ROOT 指定）`，
// 于是主机永远 agentOnline=false、device.status 里没有目录。
// 根因：agent 侧发现顺序（agent/src/harness/acp/launcher.ts discoverDshInstall）
// 只有 显式参数 → DSH_EXE+DSH_CLI → DSH_INSTALL_ROOT → PATH 的 dsh.cmd →
// %LOCALAPPDATA%\Programs\DeepSeek Harness 这五条；而 DSH 是**便携版**装在
// <DSH 安装目录>，既没进 PATH，也不在默认安装位，五条全落空。
//
// 插件自己就活在 Harness 主进程里，process.execPath 就是
// `<安装根>\DeepSeek Harness.exe`，直接取 dirname 最可靠。
import { existsSync } from 'node:fs';
import { basename, dirname, join } from 'node:path';

const EXE_NAME = 'deepseek harness.exe';
const ASAR_RELATIVE = join('resources', 'app.asar');

/** 这个目录像不像一个 Harness 安装根（`resources/app.asar` 在）。 */
export function looksLikeDshRoot(root, exists = existsSync) {
  if (typeof root !== 'string' || root.trim().length === 0) return false;
  return exists(join(root.trim(), ASAR_RELATIVE));
}

/**
 * 解析 DSH 安装根：显式环境变量 → 当前进程所在目录。
 *
 * 返回空串表示推不出来（比如开发态是 `node dsh.js web` 起的），
 * 这时不要乱猜，交给 agent 侧自己的发现逻辑。
 */
export function resolveDshInstallRoot({ env = process.env, execPath = process.execPath, exists = existsSync } = {}) {
  const explicit = typeof env?.DSH_INSTALL_ROOT === 'string' ? env.DSH_INSTALL_ROOT.trim() : '';
  // 用户显式指定就照用：目录不对时让 agent 报它自己的错，别在这里悄悄改掉。
  if (explicit.length > 0) return explicit;
  if (typeof execPath !== 'string' || execPath.length === 0) return '';
  if (basename(execPath).toLowerCase() !== EXE_NAME) return '';
  const root = dirname(execPath);
  return looksLikeDshRoot(root, exists) ? root : '';
}
