/**
 * M2.6 项目同步：工作区文件系统访问（契约 docs/design/M2_6_PROJECT_SYNC_DELTA.md §2）。
 * M2.8 追加写入：约定见 docs/design/M2_8_FILE_WRITE_DELTA.md §3。
 *
 * 暴露「列目录 + 读文本文件 + 写文本文件」三件事，全部路径必须落在授权根内；
 * 写入受忽略目录、512 KiB 上限、二进制拒绝与 sha256 乐观锁约束，并保证原子落盘。
 * 所有错误用 [WorkspaceFsError] 带契约错误码抛出。
 */
import { createHash, randomBytes } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { open, readdir, readFile, rename, stat, unlink, writeFile } from 'node:fs/promises';
import { basename, dirname, isAbsolute, relative, resolve, sep } from 'node:path';

/** 契约 §2.2：浏览时忽略的目录（不返回，只计入 ignoredCount）。 */
export const IGNORED_DIRS: ReadonlySet<string> = new Set([
  '.git',
  '.svn',
  'node_modules',
  '.dart_tool',
  'build',
  'dist',
  '.gradle',
  'out',
  '.idea',
  '__pycache__',
  '.venv',
]);

export const MAX_DIR_ENTRIES = 500;
export const DEFAULT_MAX_BYTES = 256 * 1024;
export const HARD_MAX_BYTES = 1024 * 1024;
/** M2.8：单次写入上限（512 KiB），避免手机端误传大文件。 */
export const MAX_WRITE_BYTES = 512 * 1024;
const BINARY_SNIFF_BYTES = 8 * 1024;

export type WorkspaceFsErrorCode =
  | 'BAD_REQUEST'
  | 'PATH_NOT_ALLOWED'
  | 'DIR_NOT_FOUND'
  | 'NOT_A_DIRECTORY'
  | 'FILE_NOT_FOUND'
  | 'FILE_EXISTS'
  | 'IS_A_DIRECTORY'
  | 'CONFLICT'
  | 'BINARY_FILE'
  | 'TOO_LARGE'
  | 'INTERNAL';

export class WorkspaceFsError extends Error {
  readonly code: WorkspaceFsErrorCode;

  constructor(code: WorkspaceFsErrorCode, message: string) {
    super(message);
    this.name = 'WorkspaceFsError';
    this.code = code;
  }
}

export interface WorkspaceEntry {
  name: string;
  /** 相对工作区根的路径，统一用 `/` 分隔。 */
  path: string;
  isDir: boolean;
  size: number;
  modifiedAt: string;
}

export interface WorkspaceListing {
  workspacePath: string;
  relativePath: string;
  entries: WorkspaceEntry[];
  truncated: boolean;
  ignoredCount: number;
}

export interface WorkspaceFileContent {
  relativePath: string;
  content: string;
  size: number;
  sha256: string;
  truncated: boolean;
  binary: boolean;
  modifiedAt: string;
}

/** M2.8：写入结果（`file.write.result` 的 payload）。 */
export interface WorkspaceWriteResult {
  workspacePath: string;
  relativePath: string;
  size: number;
  sha256: string;
  /** 本次是否新建了文件。 */
  created: boolean;
  modifiedAt: string;
}

export interface WorkspaceWriteOptions {
  /** 打开文件时拿到的 sha256；编辑保存必须带，新建文件不带。 */
  baseSha256?: string | null;
  /** 跳过存在性/乐观锁检查（仍需满足路径、大小、二进制规则）。 */
  force?: boolean;
}

function isPathInside(target: string, root: string): boolean {
  const caseFold = process.platform === 'win32';
  const normalizedRoot = root.endsWith(sep) ? root : root + sep;
  const t = caseFold ? target.toLowerCase() : target;
  const r = caseFold ? normalizedRoot.toLowerCase() : normalizedRoot;
  const base = caseFold ? root.toLowerCase() : root;
  return t === base || t.startsWith(r);
}

function toPosixPath(value: string): string {
  return value.split(sep).join('/');
}

/** 规范化根目录列表：至少一个根，默认取第一个。 */
function normalizeRoots(root: string | readonly string[]): readonly string[] {
  const list = (Array.isArray(root) ? root : [root])
    .map((item) => (typeof item === 'string' ? item.trim() : ''))
    .filter((item) => item.length > 0)
    .map((item) => resolve(item));
  if (list.length === 0) {
    throw new WorkspaceFsError('PATH_NOT_ALLOWED', '没有配置允许的工作区根目录');
  }
  return list;
}

/** 把 (workspacePath, relativePath) 解析成绝对路径，并做越界校验；支持多个授权根。 */
export function resolveWorkspacePath(
  root: string | readonly string[],
  workspacePath: string | null | undefined,
  relativePath: string | null | undefined,
): { workspaceRootAbs: string; workspaceAbs: string; absPath: string; relPath: string } {
  const roots = normalizeRoots(root);
  const rootAbs = roots[0];
  const workspaceAbs = resolve(workspacePath && workspacePath.trim().length > 0 ? workspacePath : rootAbs);
  if (!roots.some((candidate) => isPathInside(workspaceAbs, candidate))) {
    throw new WorkspaceFsError('PATH_NOT_ALLOWED', `工作区不在允许范围内：${workspaceAbs}`);
  }
  const requested = (relativePath ?? '').trim();
  if (requested.includes('\0')) {
    throw new WorkspaceFsError('PATH_NOT_ALLOWED', '路径包含非法字符');
  }
  if (isAbsolute(requested)) {
    throw new WorkspaceFsError('PATH_NOT_ALLOWED', '相对路径不能是绝对路径');
  }
  const absPath = resolve(workspaceAbs, requested);
  if (!isPathInside(absPath, workspaceAbs)) {
    throw new WorkspaceFsError('PATH_NOT_ALLOWED', '路径越界：不允许访问工作区之外的路径');
  }
  return {
    workspaceRootAbs: rootAbs,
    workspaceAbs,
    absPath,
    relPath: toPosixPath(relative(workspaceAbs, absPath)),
  };
}

function toFsError(error: unknown, codeIfMissing: WorkspaceFsErrorCode, message: string): WorkspaceFsError {
  if (error instanceof WorkspaceFsError) return error;
  const errno = (error as NodeJS.ErrnoException | null)?.code;
  if (errno === 'ENOENT') {
    return new WorkspaceFsError(codeIfMissing, message);
  }
  if (errno === 'EACCES' || errno === 'EPERM') {
    return new WorkspaceFsError('PATH_NOT_ALLOWED', '没有权限访问该路径');
  }
  return new WorkspaceFsError('INTERNAL', error instanceof Error ? error.message : String(error));
}

/** 列目录（契约 §2.2）。目录在前，名称不区分大小写升序。 */
export async function listDirectory(
  root: string | readonly string[],
  workspacePath: string | null | undefined,
  relativePath: string | null | undefined,
): Promise<WorkspaceListing> {
  const { workspaceAbs, absPath, relPath } = resolveWorkspacePath(root, workspacePath, relativePath);
  let info;
  try {
    info = await stat(absPath);
  } catch (error) {
    throw toFsError(error, 'DIR_NOT_FOUND', `目录不存在：${relPath || '(根目录)'}`);
  }
  if (!info.isDirectory()) {
    throw new WorkspaceFsError('NOT_A_DIRECTORY', `不是目录：${relPath}`);
  }

  const dirents = await readdir(absPath, { withFileTypes: true });
  const entries: WorkspaceEntry[] = [];
  let ignoredCount = 0;
  let truncated = false;

  for (const dirent of dirents) {
    if (dirent.isDirectory() && IGNORED_DIRS.has(dirent.name)) {
      ignoredCount += 1;
      continue;
    }
    if (entries.length >= MAX_DIR_ENTRIES) {
      truncated = true;
      break;
    }
    const childAbs = resolve(absPath, dirent.name);
    const childRel = relPath.length > 0 ? `${relPath}/${dirent.name}` : dirent.name;
    let size = 0;
    let modifiedAt = new Date(0).toISOString();
    try {
      const childInfo = await stat(childAbs);
      size = childInfo.isDirectory() ? 0 : childInfo.size;
      modifiedAt = childInfo.mtime.toISOString();
    } catch {
      // 单个条目 stat 失败不影响整个目录列表。
    }
    entries.push({ name: dirent.name, path: childRel, isDir: dirent.isDirectory(), size, modifiedAt });
  }

  entries.sort((a, b) => {
    if (a.isDir !== b.isDir) return a.isDir ? -1 : 1;
    return a.name.localeCompare(b.name, undefined, { sensitivity: 'accent' });
  });

  return { workspacePath: workspaceAbs, relativePath: relPath, entries, truncated, ignoredCount };
}

/** 读文本文件（契约 §2.4）。 */
export async function readTextFile(
  root: string | readonly string[],
  workspacePath: string | null | undefined,
  relativePath: string | null | undefined,
  maxBytes?: number | null,
): Promise<WorkspaceFileContent> {
  const { absPath, relPath } = resolveWorkspacePath(root, workspacePath, relativePath);
  if (relPath.length === 0) {
    throw new WorkspaceFsError('IS_A_DIRECTORY', '请指定要读取的文件路径');
  }

  let info;
  try {
    info = await stat(absPath);
  } catch (error) {
    throw toFsError(error, 'FILE_NOT_FOUND', `文件不存在：${relPath}`);
  }
  if (info.isDirectory()) {
    throw new WorkspaceFsError('IS_A_DIRECTORY', `这是一个目录：${relPath}`);
  }

  const requested = typeof maxBytes === 'number' && Number.isFinite(maxBytes) && maxBytes > 0
    ? Math.floor(maxBytes)
    : DEFAULT_MAX_BYTES;
  if (requested > HARD_MAX_BYTES) {
    throw new WorkspaceFsError('TOO_LARGE', `单次最多读取 ${HARD_MAX_BYTES} 字节`);
  }

  let buffer: Buffer;
  const truncated = info.size > requested;
  if (truncated) {
    const handle = await open(absPath, 'r');
    try {
      const chunk = Buffer.alloc(requested);
      const { bytesRead } = await handle.read(chunk, 0, requested, 0);
      buffer = chunk.subarray(0, bytesRead);
    } finally {
      await handle.close();
    }
  } else {
    try {
      buffer = await readFile(absPath);
    } catch (error) {
      throw toFsError(error, 'FILE_NOT_FOUND', `读取失败：${relPath}`);
    }
  }

  const sniff = buffer.subarray(0, Math.min(BINARY_SNIFF_BYTES, buffer.length));
  if (sniff.includes(0)) {
    throw new WorkspaceFsError('BINARY_FILE', '这是二进制文件，暂不支持在手机上预览');
  }

  return {
    relativePath: relPath,
    content: buffer.toString('utf8'),
    size: info.size,
    sha256: createHash('sha256').update(buffer).digest('hex'),
    truncated,
    binary: false,
    modifiedAt: info.mtime.toISOString(),
  };
}

/* -------------------------------------------------------------------------- */
/* M2.8 写入                                                                  */
/* -------------------------------------------------------------------------- */

const SHA256_PATTERN = /^[0-9a-f]{64}$/;

/** 忽略目录里的内容不允许写：避免手机端改构建产物或依赖。 */
function assertNotIgnoredPath(relPath: string): void {
  const segments = relPath.split('/');
  // 最后一段是文件名，只有它前面的目录段需要检查。
  for (const segment of segments.slice(0, -1)) {
    if (IGNORED_DIRS.has(segment.toLowerCase())) {
      throw new WorkspaceFsError('PATH_NOT_ALLOWED', `不允许写入忽略目录：${segment}`);
    }
  }
}

function hashFile(absPath: string): Promise<string> {
  return new Promise((resolvePromise, reject) => {
    const hash = createHash('sha256');
    const stream = createReadStream(absPath);
    stream.on('data', (chunk) => hash.update(chunk));
    stream.on('error', reject);
    stream.on('end', () => resolvePromise(hash.digest('hex')));
  });
}

/**
 * 写文本文件（契约 M2_8_FILE_WRITE_DELTA §3.3）。
 *
 * 顺序：根内校验 → 忽略目录 → 父目录/目标类型 → 内容大小与二进制 → 乐观锁 → 临时文件 + rename。
 * 任一步失败都不留下半截文件（临时文件会被清理）。
 */
export async function writeTextFile(
  root: string | readonly string[],
  workspacePath: string | null | undefined,
  relativePath: string | null | undefined,
  content: string,
  options: WorkspaceWriteOptions = {},
): Promise<WorkspaceWriteResult> {
  const { workspaceAbs, absPath, relPath } = resolveWorkspacePath(root, workspacePath, relativePath);
  if (relPath.length === 0) {
    throw new WorkspaceFsError('PATH_NOT_ALLOWED', '请指定要写入的文件路径');
  }
  assertNotIgnoredPath(relPath);
  if (typeof content !== 'string') {
    throw new WorkspaceFsError('INTERNAL', 'content 必须是字符串');
  }

  const bytes = Buffer.from(content, 'utf8');
  if (bytes.length > MAX_WRITE_BYTES) {
    throw new WorkspaceFsError('TOO_LARGE', `单次最多写入 ${MAX_WRITE_BYTES} 字节（本次 ${bytes.length}）`);
  }
  if (bytes.subarray(0, BINARY_SNIFF_BYTES).includes(0)) {
    throw new WorkspaceFsError('BINARY_FILE', '内容包含 NUL 字节，不支持写入二进制文件');
  }

  const parentAbs = dirname(absPath);
  let parentInfo;
  try {
    parentInfo = await stat(parentAbs);
  } catch (error) {
    throw toFsError(error, 'DIR_NOT_FOUND', `目录不存在：${toPosixPath(relative(workspaceAbs, parentAbs)) || '(根目录)'}`);
  }
  if (!parentInfo.isDirectory()) {
    throw new WorkspaceFsError('NOT_A_DIRECTORY', `路径中有一级不是目录：${toPosixPath(relative(workspaceAbs, parentAbs))}`);
  }

  let exists = false;
  try {
    const info = await stat(absPath);
    if (info.isDirectory()) {
      throw new WorkspaceFsError('IS_A_DIRECTORY', `这是一个目录：${relPath}`);
    }
    exists = true;
  } catch (error) {
    if (error instanceof WorkspaceFsError) throw error;
    if ((error as NodeJS.ErrnoException | null)?.code !== 'ENOENT') {
      throw toFsError(error, 'FILE_NOT_FOUND', `无法访问文件：${relPath}`);
    }
  }

  const force = options.force === true;
  const rawBase = typeof options.baseSha256 === 'string' ? options.baseSha256.trim().toLowerCase() : '';
  const baseSha256 = rawBase.length > 0 ? rawBase : null;
  if (baseSha256 !== null && !SHA256_PATTERN.test(baseSha256)) {
    throw new WorkspaceFsError('CONFLICT', '基线 sha256 格式不正确');
  }

  if (!force) {
    if (exists) {
      if (baseSha256 === null) {
        throw new WorkspaceFsError('FILE_EXISTS', `文件已存在：${relPath}（请先打开再保存）`);
      }
      let current: string;
      try {
        current = await hashFile(absPath);
      } catch (error) {
        throw toFsError(error, 'FILE_NOT_FOUND', `读取原文件失败：${relPath}`);
      }
      if (current !== baseSha256) {
        throw new WorkspaceFsError(
          'CONFLICT',
          `文件已在电脑上被改动（当前 ${current.slice(0, 8)}，基线 ${baseSha256.slice(0, 8)}）`,
        );
      }
    } else if (baseSha256 !== null) {
      throw new WorkspaceFsError('FILE_NOT_FOUND', `文件已不存在：${relPath}`);
    }
  }

  const tempPath = resolve(
    parentAbs,
    `.${basename(absPath)}.${process.pid}-${randomBytes(4).toString('hex')}.tmp`,
  );
  try {
    await writeFile(tempPath, bytes, { flag: 'wx' });
    await rename(tempPath, absPath);
  } catch (error) {
    await unlink(tempPath).catch(() => {});
    throw toFsError(error, 'INTERNAL', `写入失败：${relPath}`);
  }

  let modifiedAt = new Date().toISOString();
  try {
    const info = await stat(absPath);
    modifiedAt = info.mtime.toISOString();
  } catch {
    // 时间戳读取失败不影响写入结果。
  }

  return {
    workspacePath: workspaceAbs,
    relativePath: relPath,
    size: bytes.length,
    sha256: createHash('sha256').update(bytes).digest('hex'),
    created: !exists,
    modifiedAt,
  };
}
