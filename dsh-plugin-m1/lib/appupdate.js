// 应用内在线更新（M2.5 契约）：插件自己当更新服务器，手机不必再连 Java 后端。
//
//   GET  /api/v1/app/version  -> {versionCode, versionName, size, sha256, notes, url, publishedAt}
//   GET  /api/v1/app/apk      -> 整包流式下载（HEAD 只回头）
//
// 版本号解析顺序：插件配置 → 项目 `app/android/local.properties` → `app/pubspec.yaml`。
import { createHash } from 'node:crypto';
import { createReadStream, existsSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';

const APK_CONTENT_TYPE = 'application/vnd.android.package-archive';
const APK_NAME = 'DeepSeek-Remote-latest.apk';

/** 候选 APK 位置：配置 → 状态目录 → 项目 dist/。 */
export function resolveApkPath({ apkPath, stateDir, projectDir }) {
  const candidates = [];
  if (typeof apkPath === 'string' && apkPath.trim()) candidates.push(apkPath.trim());
  if (stateDir) candidates.push(join(stateDir, 'app', APK_NAME), join(stateDir, APK_NAME));
  if (projectDir) candidates.push(join(projectDir, 'dist', APK_NAME));
  candidates.push(join(process.cwd(), 'dist', APK_NAME));
  for (const candidate of candidates) {
    try {
      if (existsSync(candidate) && statSync(candidate).isFile()) return candidate;
    } catch {
      /* 继续找下一个 */
    }
  }
  return null;
}

function readText(path) {
  try {
    return readFileSync(path, 'utf8');
  } catch {
    return null;
  }
}

/** 从 `app/android/local.properties` / `app/pubspec.yaml` 里读版本号。
 *
 * 两份可能不同步（local.properties 是上一次构建的残留，pubspec 才是下一次构建的输入），
 * 取 versionCode 较大的那一份——它代表磁盘上这个 APK 的实际版本。 */
export function readProjectVersion(projectDir) {
  if (!projectDir) return null;
  const candidates = [];
  const props = readText(join(projectDir, 'app', 'android', 'local.properties'));
  if (props) {
    const code = /^flutter\.versionCode\s*=\s*(\d+)\s*$/m.exec(props);
    const name = /^flutter\.versionName\s*=\s*(\S+)\s*$/m.exec(props);
    if (code) candidates.push({ versionCode: Number(code[1]), versionName: name ? name[1] : '' });
  }
  const pubspec = readText(join(projectDir, 'app', 'pubspec.yaml'));
  if (pubspec) {
    const match = /^version:\s*([0-9][^\s+]*)\+(\d+)\s*$/m.exec(pubspec);
    if (match) candidates.push({ versionCode: Number(match[2]), versionName: match[1] });
  }
  if (candidates.length === 0) return null;
  const best = candidates.reduce((a, b) => (b.versionCode > a.versionCode ? b : a));
  // Gradle 里的 versionName 更完整（例如 `0.1.9-m2.8`），pubspec 只有 `0.1.9`。
  const gradle = readText(join(projectDir, 'app', 'android', 'app', 'build.gradle.kts'));
  const gradleName = gradle ? /versionName\s*=\s*"([^"]+)"/.exec(gradle) : null;
  if (gradleName && best.versionName && gradleName[1].startsWith(best.versionName)) {
    best.versionName = gradleName[1];
  }
  return best;
}

/**
 * 从 `docs/UPDATE_NOTES.md` 里取当前版本的更新说明。
 *
 * 约定：每次发版都在那个文件顶上加一段 `## <版本号> — <标题>`，
 * 这里按版本名前两段（如 `0.4.58`）匹配，手机/桌面更新弹窗就能直接显示。
 */
function readReleaseNotes(projectDir, versionName) {
  if (!projectDir || !versionName) return '';
  const text = readText(join(projectDir, 'docs', 'UPDATE_NOTES.md'));
  if (!text) return '';
  const short = (String(versionName).match(/^\d+\.\d+\.\d+/) ?? [])[0];
  if (!short) return '';
  const start = text.indexOf(`## ${short}`);
  if (start < 0) return '';
  const next = text.indexOf('\n## ', start + 3);
  const body = text.slice(start, next < 0 ? undefined : next);
  return body
    .replace(/^##[^\n]*\n/, '')
    .replace(/^>\s?/gm, '')
    .trim()
    .slice(0, 1500);
}

/**
 * M4.66：把 `docs/UPDATE_NOTES.md` 整份解析成版本列表，给 App 的「更新日志」页用。
 *
 * 每段形如 `## 0.4.59+80（2026-11-27）— 文件能分享出去了`，下面是正文。
 * 只做宽松解析：缺日期或标题也能用，正文保留换行。
 */
export function readUpdateNoteList(projectDir) {
  if (!projectDir) return [];
  const text = readText(join(projectDir, 'docs', 'UPDATE_NOTES.md'));
  if (!text) return [];
  const lines = text.split(/\r?\n/);
  const notes = [];
  let current = null;
  for (const line of lines) {
    const head = /^##\s+(.+?)\s*$/.exec(line);
    if (head) {
      if (current) notes.push(current);
      const raw = head[1];
      const version = (raw.match(/\d+\.\d+\.\d+(?:\+\d+)?/) ?? [])[0] ?? raw.trim();
      const date = (raw.match(/(\d{4}-\d{2}-\d{2})/) ?? [])[1] ?? '';
      const title = raw
        .replace(version, '')
        .replace(date, '')
        .replace(/[（）()]/g, '')
        .replace(/^[\s—–-]+/, '')
        .trim();
      current = { version, date, title, body: '' };
      continue;
    }
    if (!current) continue;
    if (line.startsWith('#')) continue;
    current.body += `${line}\n`;
  }
  if (current) notes.push(current);
  return notes
    .map((note) => ({ ...note, body: note.body.replace(/^>\s?/gm, '').trim().slice(0, 4000) }))
    .filter((note) => note.version.length > 0 || note.body.length > 0);
}

export class AppUpdate {
  constructor({ apkPath, stateDir, projectDir, versionCode, versionName, notes, log = () => {} }) {
    this.apkPath = resolveApkPath({ apkPath, stateDir, projectDir });
    this.projectDir = projectDir ?? null;
    this.notes = typeof notes === 'string' ? notes : '';
    this.log = log;
    // 显式配置优先；没有配置时每次取快照都重读项目版本，
    // 这样手机端/桌面端升级后不必重启插件。
    this.explicitVersionCode = Number.isInteger(versionCode) && versionCode > 0 ? versionCode : null;
    this.explicitVersionName = typeof versionName === 'string' && versionName.trim() ? versionName.trim() : null;
    this.cache = null;
    this.lastError = null;
  }

  /** 当前 APK 的快照；文件缺失或版本号未知时返回 null。 */
  snapshot() {
    if (!this.apkPath) return null;
    let stat;
    try {
      stat = statSync(this.apkPath);
    } catch (error) {
      this.lastError = error?.message ?? String(error);
      return null;
    }
    const resolved = this.explicitVersionCode === null ? readProjectVersion(this.projectDir) : null;
    const versionCode = this.explicitVersionCode ?? resolved?.versionCode ?? 0;
    const versionName = this.explicitVersionName ?? resolved?.versionName ?? '';
    const notes = this.notes || readReleaseNotes(this.projectDir, versionName);
    const key = `${stat.mtimeMs}:${stat.size}:${versionCode}:${versionName}:${notes.length}`;
    if (this.cache?.key === key) return this.cache.info;
    let sha256 = null;
    try {
      sha256 = createHash('sha256').update(readFileSync(this.apkPath)).digest('hex');
    } catch (error) {
      this.log(`计算 APK 摘要失败：${error?.message ?? error}`);
    }
    const info = {
      versionCode,
      versionName: versionName || '未知版本',
      size: stat.size,
      sha256,
      notes,
      url: '/api/v1/app/apk',
      publishedAt: new Date(stat.mtimeMs).toISOString(),
      file: this.apkPath,
    };
    this.cache = { key, info };
    return info;
  }

  /** 版本信息（去掉内部字段）。 */
  versionPayload() {
    const info = this.snapshot();
    if (!info) return null;
    const { file, ...rest } = info;
    return rest;
  }

  /** 流式下载；不实现 Range，App 每次都整包拉取。 */
  streamApk(request, response) {
    const info = this.snapshot();
    if (!info) {
      response.writeHead(404, { 'content-type': 'application/json; charset=utf-8' });
      response.end(JSON.stringify({ code: 'APP_UPDATE_UNAVAILABLE', message: 'APK 不存在' }));
      return;
    }
    const headers = {
      'content-type': APK_CONTENT_TYPE,
      'content-length': String(info.size),
      'content-disposition': `attachment; filename="${APK_NAME}"`,
      'cache-control': 'no-store',
      'accept-ranges': 'none',
    };
    if (request.method === 'HEAD') {
      response.writeHead(200, headers);
      response.end();
      return;
    }
    response.writeHead(200, headers);
    const stream = createReadStream(info.file);
    stream.on('error', (error) => {
      this.log(`APK 读取失败：${error?.message ?? error}`);
      response.destroy(error);
    });
    stream.pipe(response);
  }
}
