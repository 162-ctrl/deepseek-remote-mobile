// M4.44 / 用户三阶段计划第 1 阶段第 3 条：tokens.json 的 Windows ACL 收口。
//
// 背景：`writeFileSync(..., { mode: 0o600 })` 在 Windows 上基本无效——POSIX 权限位
// 落不到 NTFS ACL 上，文件通常继承父目录（用户目录）的权限，于是同机的其他账户、
// 备份软件、同步盘都可能读到 token 文件。现在文件里只有 sha256，但仍是敏感元数据
// （设备名、角色、过期时间），而且旧安装里可能还有明文 token，所以顺手把 ACL 收紧：
//
//   1. 断掉继承（`/inheritance:r`）——不再从父目录继承
//   2. 只授予当前用户完全控制（`/grant:r "<user>:(F)"`）
//   3. 系统与管理员保留（它们本来就有，`/inheritance:r` 之后需要显式补回，
//      否则系统备份/服务读不到）
//
// 非 Windows 返回 `{ supported: false }`，调用方按「尽力而为」处理，不因为
// 收紧失败而让配对失败。
import { execFileSync } from 'node:child_process';

/** icacls 输出里一行授权项，例如 `DESKTOP-1\user:(F)` 或 `NT AUTHORITY\SYSTEM:(OI)(CI)(F)`。 */
const PRINCIPAL_LINE = /^(.+?):((?:\([A-Za-z]+\))+)\s*$/;

/** 归一化主体名：去掉首尾空白、全大写（Windows 账户名大小写不敏感）。 */
export function normalizePrincipal(raw) {
  const text = String(raw ?? '').trim();
  if (text === '') return '';
  return text.toUpperCase();
}

/**
 * 从 icacls 输出里解析出授权主体列表（去重、保持出现顺序）。
 * `icacls <file>` 会把文件名和第一条授权项打在同一行，所以传入 `target` 时先剥掉前缀。
 */
export function parsePrincipals(stdout, { target = '' } = {}) {
  const found = [];
  const seen = new Set();
  const prefix = String(target ?? '').toUpperCase();
  for (const line of String(stdout ?? '').split(/\r?\n/)) {
    const trimmed = line.trim();
    const match = PRINCIPAL_LINE.exec(trimmed);
    if (match === null) continue;
    let raw = match[1];
    if (prefix !== '' && raw.toUpperCase().startsWith(prefix)) {
      raw = raw.slice(String(target).length).trim();
    }
    // 去掉「文件名 + 两个空格」这种残留（没传 target 时的兜底）
    const principal = normalizePrincipal(raw);
    if (principal === '' || seen.has(principal)) continue;
    seen.add(principal);
    found.push(principal);
  }
  return found;
}

/** 系统级主体：这些保留是安全的（它们本来就等于本机管理员）。 */
export function isSystemPrincipal(principal) {
  const name = normalizePrincipal(principal);
  return (
    name.includes('NT AUTHORITY\\SYSTEM') ||
    name.includes('NT AUTHORITY\\LOCAL SERVICE') ||
    name.includes('NT AUTHORITY\\NETWORK SERVICE') ||
    name.endsWith('\\ADMINISTRATORS') ||
    name === 'ADMINISTRATORS'
  );
}

/**
 * 判断某个主体是不是「当前登录用户」。
 * icacls 可能写成 `DESKTOP-1\user`，也可能只写 `user`，所以按末段比较。
 */
export function isCurrentUser(principal, username = process.env.USERNAME ?? '') {
  const name = normalizePrincipal(principal);
  const user = normalizePrincipal(username);
  if (user === '') return false;
  return name === user || name.endsWith(`\\${user}`);
}

function runIcacls(args) {
  return execFileSync('icacls', args, { encoding: 'utf8', windowsHide: true });
}

function runWhoami(args) {
  return execFileSync('whoami', args, { encoding: 'utf8', windowsHide: true });
}

/** 当前进程身份：`/user` 让"我是谁"由系统回答，而不是猜环境变量。 */
export function resolveIdentity({ run = runWhoami, platform = process.platform } = {}) {
  const username = String(process.env.USERNAME ?? '').trim();
  if (platform !== 'win32') return { username, sid: '' };
  let sid = '';
  try {
    const output = run(['/user', '/fo', 'csv', '/nh']);
    const match = /"(S-\d-(?:[0-9]+-)+\d+)"/i.exec(String(output ?? ''));
    if (match !== null) sid = match[1];
  } catch {
    /* whoami 不可用时退回环境变量 */
  }
  return { username, sid };
}

/**
 * 收紧一个文件/目录的 ACL。
 *
 * 顺序很关键：**先授权，再断继承**。反过来（先 `/inheritance:r` 再授权）一旦授权
 * 那一步失败——例如账户名解析不出来、组名是本地化的——文件就会变成「谁都不许读」，
 * 连自己都打不开（2026-11-23 真发生过：一个 tokens.json 被锁死只能靠改目录名绕开）。
 *
 * 收尾还要真读一次做验证；读不了就退回继承，宁可松一点也不要把文件锁死。
 */
export function hardenPath(
  target,
  { run = runIcacls, platform = process.platform, probe = null, identity = null } = {},
) {
  if (platform !== 'win32') return { supported: false, principals: [], locked: false };
  const who = identity ?? resolveIdentity({ run, platform });
  if (who.username === '' && who.sid === '') return { supported: false, principals: [], locked: false };

  const grants = [];
  if (who.username !== '') grants.push(`${who.username}:(F)`);
  if (who.sid !== '') grants.push(`*${who.sid}:(F)`);
  // 系统与管理员用 SID 授权，避免中文系统上 "Administrators" 解析不出来
  grants.push('*S-1-5-18:(F)', '*S-1-5-32-544:(F)');

  try {
    for (const grant of grants) {
      try {
        run([target, '/grant:r', grant]);
      } catch {
        /* 单个主体授予失败不致命：只要还有一条能读就行 */
      }
    }
    run([target, '/inheritance:r']);

    const output = run([target]);
    const principals = parsePrincipals(output, { target });
    const readable = probe === null ? true : probe(target);
    if (!readable) {
      // 兜底：把继承放回去，避免文件变成死文件
      try {
        run([target, '/inheritance:e']);
        run([target, '/grant:r', 'Everyone:(R)']);
      } catch {
        /* 兜底也失败就只能如实报告 */
      }
      return { supported: false, principals, locked: true };
    }
    return { supported: true, principals, locked: false };
  } catch {
    return { supported: false, principals: [], locked: false };
  }
}

/** 审计：除了当前用户与系统主体，还有谁能读这个文件。 */
export function foreignPrincipals(principals, username = process.env.USERNAME ?? '') {
  return principals.filter(
    (principal) => !isCurrentUser(principal, username) && !isSystemPrincipal(principal),
  );
}
