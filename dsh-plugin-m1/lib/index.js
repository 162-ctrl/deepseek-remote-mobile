// dsh-plugin-m1 —— 把 DeepSeek Harness 变成「手机端可以直接扫码/输匹配码连上」的中继服务。
//
// 结构：
//   手机 App ──HTTP/WS(:8787)──▶ 本插件（M1 中继 + 配网页 + 二维码）
//                                  └─ spawned ─▶ node agent/scripts/serve.ts ─stdio─▶ dsh --profile acp
//
// 也就是说：手机端协议（M1 信封）与后端契约被原样复刻进插件，App 不需要改协议；
// 原来那套 Spring Boot 后端 + cloudflared 隧道 + 手工拉起 agent 的三件套全部省掉。
import { randomInt } from 'node:crypto';
import {
  appendFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  statSync,
  unlinkSync,
  writeFileSync,
} from 'node:fs';
import { zstdDecompressSync } from 'node:zlib';
import { homedir } from 'node:os';
import { join, dirname, basename, extname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createContext, runInContext } from 'node:vm';

import { M1Hub } from './hub.js';
import { hardenPath } from './token-acl.js';
import { AppUpdate, readUpdateNoteList } from './appupdate.js';
import { createRelayHttpServer, lanAddresses } from './server.js';
import { createLiveHub } from './live-hub.js';
import { startRemoteEventClient } from './remote-events.js';
import { contentText, partText } from './assistant-text.js';
// M4.16：注入消息与 reasoning 的过滤规则集中在这里，直播流与存档共用。
import { chatText, isInjectedEvent, isInjectedUserText } from './chat-filter.js';
import { labelAndSortTasks } from './task-rows.js';
import { AgentSupervisor } from './supervisor.js';
// M4.49：便携版 DSH 不在 PATH/默认安装位，得把安装目录递给 agent，否则它找不到 dsh CLI。
import { resolveDshInstallRoot } from './dsh-install.js';
import { CloudflaredTunnel, resolveCloudflared, staticPublicEndpoint } from './tunnel.js';

export const name = 'dsh-plugin-m1';

const DEFAULT_PORT = 8787;
const DEFAULT_DEVICE_NAME = 'DeepSeek Harness (插件直连)';
const PAIRING_CODE_RE = /^[A-Za-z0-9]{4,32}$/;

const bundleRoot = fileURLToPath(new URL('../', import.meta.url));
const pkg = JSON.parse(readFileSync(join(bundleRoot, 'package.json'), 'utf8'));

/**
 * 当前插件版本。ESM 模块被缓存时 `pkg` 可能是旧值，这里每次从磁盘重读，
 * 保证热重载后 health / 设置页显示的是新版本。
 */
function pluginVersion() {
  try {
    return JSON.parse(readFileSync(join(bundleRoot, 'package.json'), 'utf8')).version ?? pkg.version;
  } catch {
    return pkg.version;
  }
}

function stateDirPath(config) {
  if (typeof config?.stateDir === 'string' && config.stateDir.length > 0) return config.stateDir;
  const home = process.env.DSH_HOME ?? join(homedir(), '.dsh');
  return join(home, 'dsh-plugin-m1');
}

/**
 * 把 `<url>#c=<code>` 画成 SVG 二维码，供设置页内嵌（不依赖外网服务）。
 * qrcode.js 是浏览器用的老式脚本（只挂全局 `qrcode`，UMD 导出拿不到），
 * 所以放进 vm 里执行一次，取出全局函数缓存起来。
 */
let qrcodeLib;
function qrSvg(text) {
  try {
    if (!qrcodeLib) {
      const source = readFileSync(join(bundleRoot, 'assets', 'qrcode.js'), 'utf8');
      const sandbox = {};
      createContext(sandbox);
      qrcodeLib = runInContext(`${source}; qrcode;`, sandbox);
    }
    const qr = qrcodeLib(0, 'M');
    qr.addData(text);
    qr.make();
    return qr.createSvgTag({ cellSize: 4, margin: 8, scalable: true });
  } catch {
    return null;
  }
}

function readPairingCode(dir) {
  try {
    const text = readFileSync(join(dir, 'pairing-code'), 'utf8').trim();
    if (PAIRING_CODE_RE.test(text)) return text;
  } catch {
    /* 没有就用新码 */
  }
  return null;
}

function writePairingCode(dir, code) {
  try {
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, 'pairing-code'), `${code}\n`, { mode: 0o600 });
  } catch {
    /* 写不进去也不影响本次运行 */
  }
}

function newPairingCode() {
  return String(randomInt(100_000, 1_000_000));
}

/** 调试用：把事件 data 压成可读的短预览，避免循环引用与超长文本。 */
function safePreview(value, depth = 0) {
  if (value === null || value === undefined) return value ?? null;
  if (typeof value === 'string') return value.length > 160 ? `${value.slice(0, 160)}…` : value;
  if (typeof value === 'number' || typeof value === 'boolean') return value;
  if (depth > 2) return '…';
  if (Array.isArray(value)) return value.slice(0, 3).map((item) => safePreview(item, depth + 1));
  if (typeof value === 'object') {
    const out = {};
    for (const key of Object.keys(value).slice(0, 12)) {
      out[key] = safePreview(value[key], depth + 1);
    }
    return out;
  }
  return String(value);
}

function normalizeRoots(value) {
  const raw = Array.isArray(value) ? value : typeof value === 'string' ? value.split(/[;\n]/) : [];
  // M4.20：去重。DSH 的注册表可能同时以 `list()` 和 `entities` 两种形态暴露同一批
  // 目录，两条路都读就会拿到 9 个目录各两遍 —— Agent 上报给手机的授权目录变成 18 条，
  // 手机「工作区」于是出现重影的项目卡。首个出现的顺序保留（它是默认工作区）。
  const seen = new Set();
  const out = [];
  for (const item of raw) {
    const text = String(item ?? '').trim();
    if (text.length === 0 || !existsSync(text)) continue;
    const key = canonicalPath(text);
    if (key.length === 0 || seen.has(key)) continue;
    seen.add(key);
    out.push(text);
  }
  return out;
}

/** 统一路径写法：反斜杠、大小写、末尾分隔符都不影响比较。 */
function canonicalPath(value) {
  const text = String(value ?? '').trim();
  if (!text) return '';
  return text.replace(/\//g, '\\').replace(/\\+$/, '').toLowerCase();
}

/**
 * 授权目录的解析顺序：插件配置 → 环境变量 → DSH 工作区注册表 → 用户主目录。
 * 接上工作区注册表后，手机端能访问的正是桌面侧边栏里的那些项目。
 *
 * M4.11：注册表可能在 `apply` 时还没就绪（`ctx.get` 返回 undefined），或者实体不是
 * 普通对象（getter/Proxy），直接走会被静默忽略、退回 `homedir()` —— 手机上就会出现
 * 「工作区列表里有目录，但点开文件说 workspace not authorized」。这里把几种结构都试一遍。
 */
function rootsFromRegistry(registry) {
  if (!registry) return [];
  const picked = [];
  const pushPath = (value) => {
    if (typeof value === 'string' && value.trim()) picked.push(value.trim());
    else if (value && typeof value === 'object') {
      const path = value.path ?? value.root ?? value.cwd ?? value.directory;
      if (typeof path === 'string' && path.trim()) picked.push(path.trim());
    }
  };
  const call = (method) => {
    try {
      if (typeof registry[method] !== 'function') return undefined;
      return registry[method]();
    } catch {
      return undefined;
    }
  };
  const list = call('list') ?? call('all') ?? call('snapshot');
  if (Array.isArray(list)) list.forEach(pushPath);
  else if (list && typeof list === 'object') {
    if (Array.isArray(list.workspaces)) list.workspaces.forEach(pushPath);
    if (Array.isArray(list.entries)) list.entries.forEach(pushPath);
    if (Array.isArray(list.items)) list.items.forEach(pushPath);
  }
  // `entities` 是 Map（Map.get / Map.size），只读地取出它的值。
  const entities = (() => {
    try {
      return registry.entities;
    } catch {
      return undefined;
    }
  })();
  if (entities && typeof entities.values === 'function') {
    try {
      for (const entity of entities.values()) pushPath(entity);
    } catch {
      /* 忽略：拿不到就交给调用方回退 */
    }
  }
  return picked;
}

function resolveWorkspaceRoots(config, ctx) {
  const explicit = normalizeRoots(config?.workspaceRoots);
  if (explicit.length > 0) return explicit;
  const fromEnv = normalizeRoots(process.env.M1_WORKSPACE_ROOTS);
  if (fromEnv.length > 0) return fromEnv;
  const registry = (() => {
    try {
      return ctx.get?.('workspaceRegistry') ?? ctx.workspaceRegistry;
    } catch {
      return undefined;
    }
  })();
  const fromRegistry = normalizeRoots(rootsFromRegistry(registry));
  if (fromRegistry.length > 0) return fromRegistry;
  return [homedir()];
}

/**
 * Host 不同版本返回结构不一致（数组 / {entries} / {plugins} / {bundles}）。
 * 统一取数组，避免插件包列表在手机上变空。
 */
function asArray(value, ...keys) {
  if (Array.isArray(value)) return value;
  for (const key of keys) {
    if (Array.isArray(value?.[key])) return value[key];
  }
  return [];
}

/**
 * M4.18：插件包的多语言元信息。`meta` 的形状在 Host 各版本间不一致——
 * 可能是 `{name, description}` 平铺，也可能是 `{'zh-CN': {name, ...}, en: {...}}`。
 * 手机只关心「当前语言下最像人话的那条」，取不到就交回调用方兜底。
 */
function localizedMetaText(meta, field, language) {
  if (!meta || typeof meta !== 'object') return '';
  const want = String(language ?? '').trim();
  const short = want.split('-')[0];
  const read = (value) => {
    if (typeof value === 'string') return value.trim();
    if (value && typeof value === 'object') {
      const inner = value[field];
      return typeof inner === 'string' ? inner.trim() : '';
    }
    return '';
  };
  for (const key of [want, short, 'zh-CN', 'zh', 'en']) {
    if (!key) continue;
    const text = read(meta[key]);
    if (text) return text;
  }
  return read(meta) || '';
}

export function apply(ctx, config = {}) {
  const log = (line) => {
    try {
      ctx.logger(name)?.info?.(line);
    } catch {
      /* logger 不可用时静默 */
    }
  };
  const stateDir = stateDirPath(config);
  const port = Number.isInteger(config.port) ? config.port : DEFAULT_PORT;
  const host = typeof config.host === 'string' && config.host ? config.host : '0.0.0.0';
  // M4.11：授权目录不能在 `apply` 时定死。`workspaceRegistry` 是 async Service
  // （init 里要等 storageDomain + sessionPersistence），插件挂载时它往往还是
  // undefined，于是会永久缓存成 `[homedir()]` —— 手机上「工作区」列表里有目录、
  // 点开文件却 workspace not authorized 就是这么来的。改成懒解析 + 短缓存。
  const ROOTS_TTL_MS = 5_000;
  let rootsCache = null;
  let rootsCachedAt = 0;
  const workspaceRootsNow = () => {
    const now = Date.now();
    if (rootsCache && now - rootsCachedAt < ROOTS_TTL_MS) return rootsCache;
    rootsCache = resolveWorkspaceRoots(config, ctx);
    rootsCachedAt = now;
    return rootsCache;
  };
  const agentDir = typeof config.agentDir === 'string' && config.agentDir ? config.agentDir : join(bundleRoot, 'agent');
  const entry = join(agentDir, 'scripts', 'serve.ts');

  let pairingCode =
    typeof config.pairingCode === 'string' && PAIRING_CODE_RE.test(config.pairingCode)
      ? config.pairingCode
      : readPairingCode(stateDir);
  if (pairingCode === null) {
    pairingCode = newPairingCode();
    writePairingCode(stateDir, pairingCode);
  }

  // 手机端的配对 token 落盘：插件重载/重启后不必重新配对。
  const tokenFilePath = join(stateDir, 'tokens.json');
  const tokenStore = {
    load: () => {
      try {
        const rows = JSON.parse(readFileSync(tokenFilePath, 'utf8'));
        return Array.isArray(rows) ? rows : [];
      } catch {
        return [];
      }
    },
    save: (rows) => {
      try {
        mkdirSync(stateDir, { recursive: true });
        writeFileSync(tokenFilePath, JSON.stringify(rows), { mode: 0o600 });
        // M4.44：Windows 不认 mode 0o600，必须真的收紧 NTFS ACL——
        // 否则 tokens.json 会继承用户目录权限，同机其它账户/备份工具都能读。
        const acl = hardenPath(tokenFilePath, {
          probe: (file) => {
            try {
              readFileSync(file);
              return true;
            } catch {
              return false;
            }
          },
        });
        if (acl.locked) log('tokens.json ACL 收紧失败并已回退继承（文件仍可读）');
        else if (acl.supported) log(`tokens.json ACL 已收紧：${acl.principals.join(', ')}`);
      } catch {
        /* 写不进去只影响下次重启 */
      }
    },
  };

  const hub = new M1Hub({ pairingCode, version: pluginVersion(), log, tokenStore });

  // 公网接入：publicUrl（自建固定域名）优先；否则按需起 cloudflared 快速隧道。
  const staticPublicUrl = typeof config.publicUrl === 'string' ? config.publicUrl.trim() : '';
  const publicEndpoint = (() => {
    if (staticPublicUrl) return staticPublicEndpoint(staticPublicUrl);
    if (config.publicAccess === false) {
      return { status: () => ({ enabled: false, running: false, url: null, error: null }), start() {}, stop() {} };
    }
    const bin = resolveCloudflared(config.cloudflaredPath);
    if (!bin) log('未找到 cloudflared：公网访问不可用（可配 cloudflaredPath 或设 publicUrl）');
    return new CloudflaredTunnel({ binPath: bin, localPort: port, log });
  })();

  // 应用内更新：插件自己当更新源（GET /api/v1/app/version + /api/v1/app/apk）。
  // projectDir 默认取插件的上一级目录——profile 里是 junction，Node 会解析到真实路径，
  // 所以这里通常就是手机端项目根（`...\deepseek手机端`），`dist/` 与 `app/` 都在下面。
  const projectDir =
    typeof config.appProjectDir === 'string' && config.appProjectDir
      ? config.appProjectDir
      : dirname(bundleRoot);
  const appUpdate = new AppUpdate({
    apkPath: config.appApkPath,
    stateDir,
    projectDir,
    versionCode: config.appVersionCode,
    versionName: config.appVersionName,
    notes: config.appNotes,
    log,
  });

  // M2.9.2：桌面任务镜像。桌面 GUI 里发起的会话不经过 relay agent，
  // 这里订阅 Host 的 api-session 事件，把会话与运行状态汇成只读列表给手机任务页。
  const desktopTaskState = new Map();
  const markDesktopTask = (sessionId, patch) => {
    const id = String(sessionId ?? '');
    if (!id) return;
    desktopTaskState.set(id, { ...(desktopTaskState.get(id) ?? {}), ...patch });
  };
  ctx.on('api-session/status', (sessionId, running) =>
    markDesktopTask(sessionId, { running: running === true, error: null }),
  );
  ctx.on('api-session/activity', (sessionId, updatedAt) =>
    markDesktopTask(sessionId, { updatedAt: Number(updatedAt) || Date.now() }),
  );
  ctx.on('api-session/error', (sessionId, message) =>
    markDesktopTask(sessionId, { running: false, error: String(message ?? '') }),
  );

  // 插件重载会丢掉内存里的运行状态；用事件日志兜底推断：
  // 最后一条不是 turn/end 且发生在 10 分钟内，就认为还在跑。
  const inferRunning = (session, tracked) => {
    const log = Array.isArray(session?.log) ? session.log : [];
    const last = log.at(-1);
    // 没有日志时只能信宿主上报的状态。
    if (!last) return tracked?.running === true;
    if (last.type === 'turn/end') return false;
    if (tracked?.running === false) return false;
    const time = Number(last.time) || 0;
    // 事件太旧说明上一轮早就停了，宿主状态可能是插件重载前的残留。
    return time > 0 && Date.now() - time < 10 * 60 * 1000;
  };

  // M2.9.4：接管。手机正在看某个会话时，允许它替电脑发指令、应答授权；
  // 没人看的时候一切照旧（授权仍由桌面弹窗处理）。
  // M4.14：「在看」的有效期原来是 2 分钟。手机 App 切后台或锁屏后轮询会停，
  // 用户回来时看着页面却已经「不算在看」，再来的授权一律交回桌面弹窗 ——
  // 手机上既不出现也不提醒。放宽到 10 分钟（轮询每 1.5 秒刷新一次，前台时一直是新的）。
  const WATCH_WINDOW_MS = 10 * 60 * 1000;
  // 接管后给手机的时间从 90 秒放宽到 2 分钟（要解锁、切回 App）；超时退回电脑。
  const APPROVAL_TIMEOUT_MS = 2 * 60 * 1000;
  const watchedSessions = new Map(); // sessionId -> 最近一次手机观看时间
  const pendingApprovals = new Map(); // approvalId -> { sessionId, toolName, reason, finish }
  const isWatching = (sessionId) => Date.now() - (watchedSessions.get(String(sessionId)) ?? 0) < WATCH_WINDOW_MS;

  ctx.on('approval/request', async (req, next) => {
    const sessionId = String(req?.agent?.id ?? '');
    if (!sessionId || !isWatching(sessionId)) return next();
    const approvalId = String(
      req.callId ?? `a_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 6)}`,
    );
    const outcome = await new Promise((resolve) => {
      let timer;
      const cleanup = () => {
        pendingApprovals.delete(approvalId);
        clearTimeout(timer);
        req.signal?.removeEventListener?.('abort', onAbort);
      };
      const finish = (value) => {
        cleanup();
        resolve(value);
      };
      const onAbort = () => finish('cancelled');
      timer = setTimeout(() => {
        // M4.14：超时不能一声不响——手机没应答就退回电脑，并留下一条可说出口的记录。
        log(`接管授权超时，已退回电脑：${sessionId} · ${req.toolName ?? 'tool'}`);
        finish('unavailable');
      }, APPROVAL_TIMEOUT_MS);
      req.signal?.addEventListener?.('abort', onAbort, { once: true });
      pendingApprovals.set(approvalId, {
        sessionId,
        approvalId,
        toolName: String(req.toolName ?? ''),
        reason: String(req.reason ?? ''),
        createdAt: Date.now(),
        finish,
      });
      log(`接管授权：${sessionId} · ${req.toolName ?? 'tool'} · 等待手机应答`);
    });
    return outcome;
  });

  const decideDesktopApproval = (sessionId, approvalId, decision) => {
    const entry = pendingApprovals.get(String(approvalId));
    if (!entry || entry.sessionId !== String(sessionId)) return false;
    entry.finish(decision === 'approve' ? 'allowed-once' : 'rejected');
    log(`手机应答授权：${sessionId} · ${decision === 'approve' ? '允许一次' : '拒绝'}`);
    return true;
  };

  // M4.23：手机也要能回答「确认需求」卡片（`ask_user_question` 那类问题）。
  // 授权走的是 `approval/request`，提问走的是另一条 waterfall：`user-questions/request`，
  // 回一个 `{ answers: [{ id, selected, custom }] }` 就算接管，回 `next()` 则交回桌面弹窗。
  // 以前没接这条，所以手机上永远看不到这类卡片 —— 用户在电脑前坐着，手机上却没有任何提示。
  const QUESTION_TIMEOUT_MS = 5 * 60 * 1000;
  const pendingQuestions = new Map(); // questionId -> { sessionId, questions, finish }

  const normalizeQuestionAnswers = (raw) => {
    const list = Array.isArray(raw) ? raw : [];
    const answers = [];
    for (const item of list) {
      const id = String(item?.id ?? '').trim();
      if (!id) continue;
      const selected = Array.isArray(item?.selected)
        ? item.selected.map((value) => String(value ?? '')).filter((value) => value.trim().length > 0)
        : [];
      const custom = String(item?.custom ?? '').trim();
      if (selected.length === 0 && !custom) continue;
      answers.push(custom ? { id, selected, custom } : { id, selected });
    }
    return answers;
  };

  // M4.31：手机没停在这条会话的直播页时，提问以前一律交回电脑弹窗。
  // 但用户要的是「手机上也能选」——只要手机 App 还连着（App 在前台或后台保活），
  // 就由手机接管；手机彻底断开（appCount === 0）才让电脑弹窗兜底，避免把提问
  // 挂在一个没人能答的地方等到超时。
  //
  // M4.53：这条「手机连着就接管」把电脑上的卡片吃掉了——用户坐在电脑前，
  // 只看到会话卡住、屏幕上没有任何提问卡。改回与授权一致的口径：
  // **只有手机正停在这条会话的直播页（isWatching）才接管**，其余时候交给电脑弹窗。
  //
  // M4.54：用户要「两边同时都有」，这不需要改 DSH 本体——DSH 的 Web 客户端本来就
  // 支持多个客户端同时挂着同一个 pending 请求（客户端 README：谁先答用谁，后到的
  // 提交被 gateway 静默丢弃；卡片是否还在由 Session 的 `userQuestions` 投影决定，
  // 投影不再列出这个 call 时卡片自己收掉）。所以接管时先把 `next()` 叫起来，让电脑
  // 上照常挂出原生提问卡，同时给手机挂一张，两边赛跑：
  // - 电脑先答 → 用电脑的答案，顺手把手机上那张摘掉；
  // - 手机先答 → 用手机的答案，工具调用结束、投影关闭，电脑那张自己消失；
  // - 手机卡先超时 → 只收手机那张，电脑那张还能继续答；
  // - 两边都没人答 → 到 QUESTION_TIMEOUT_MS 按「跳过」放行，不让会话挂死。
  // M4.55：手机连着就接管，不再要求「正看着这条会话」。M4.53/M4.54 的门禁是
  // `isWatching`：手机停在别的页（工作区、AI 助手）时插件直接 next()，桌面上有卡，
  // 但手机既没有卡片、工作区也没有「待回答」横幅，用户看到的就是「手机上还是没有」。
  // 桌面那张卡不受影响——接管之后照样先 next()（M4.54 的赛跑）。
  const phoneConnected = () => Number(hub?.appCount ?? 0) > 0;
  async function onDesktopQuestion(req, next) {
    const sessionId = String(req?.agent?.id ?? this?.agent?.id ?? '');
    if (!sessionId) return next();
    if (!isWatching(sessionId) && !phoneConnected()) return next();
    const questions = Array.isArray(req?.questions) ? req.questions : [];
    if (questions.length === 0) return next();
    const questionId = String(
      req?.wait?.callId ?? `q_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 6)}`,
    );
    traceAnswer(
      `EVENT session=${sessionId} question=${questionId} wait=${JSON.stringify(req?.wait ?? null)} items=${questions.length} ids=${JSON.stringify(questions.map((item) => item?.id ?? null))}`,
    );

    // 先把电脑那张卡挂出来：next() 把问题交给桌面默认问答器。
    let desktopAnswered = false;
    let desktopPending;
    try {
      desktopPending = Promise.resolve(next());
    } catch {
      desktopPending = Promise.resolve({ answers: [] });
    }
    const desktopAnswer = desktopPending.then(
      (value) => {
        desktopAnswered = true;
        return value;
      },
      () => {
        desktopAnswered = true;
        return { answers: [] };
      },
    );

    const answer = await new Promise((resolve) => {
      let timer;
      let phoneTimer;
      const cleanup = () => {
        pendingQuestions.delete(questionId);
        clearTimeout(timer);
        clearTimeout(phoneTimer);
        req?.signal?.removeEventListener?.('abort', onAbort);
      };
      const finish = (value) => {
        traceAnswer(`FINISH question=${questionId} answers=${JSON.stringify(value?.answers ?? value)}`);
        cleanup();
        resolve(value);
      };
      const onAbort = () => {
        traceAnswer(`ABORT question=${questionId}`);
        finish({ answers: [] });
      };
      timer = setTimeout(() => {
        if (desktopAnswered) return;
        log(`接管提问超时，已按「跳过」放行：${sessionId} · ${questions.length} 个问题`);
        finish({ answers: [] });
      }, QUESTION_TIMEOUT_MS);
      timer?.unref?.();
      // 手机这张卡挂太久就收掉，别让手机上一直挂着一个没人再答的问题卡。
      phoneTimer = setTimeout(() => {
        if (!pendingQuestions.has(questionId)) return;
        pendingQuestions.delete(questionId);
        log(`手机上的提问卡已超时收起：${sessionId} · 电脑上仍可回答`);
      }, QUESTION_TIMEOUT_MS);
      phoneTimer?.unref?.();
      req?.signal?.addEventListener?.('abort', onAbort, { once: true });
      desktopAnswer.then((value) => {
        traceAnswer(`DESKTOP question=${questionId} answers=${JSON.stringify(value?.answers ?? value)}`);
        finish(value);
      });
      pendingQuestions.set(questionId, {
        sessionId,
        questionId,
        questions,
        createdAt: Date.now(),
        finish,
      });
      log(`接管提问：${sessionId} · ${questions.length} 个问题 · 电脑和手机都能答`);
    });
    return answer;
  }

  ctx.on('user-questions/request', onDesktopQuestion);
  // 早先以为提问事件是 agent 作用域派发的、根 ctx 监听器永远收不到，试过在 `agent/created`
  // 里用 `this` 拿作用域再挂一份——实测 `this` 是 undefined，那套代码已删除（M4.61）。
  // 现在真正让手机能答提问的是下面的远程事件客户端（M4.59 起），这条路对它可见。

  // M4.56：回答失败要能说清是哪一步不行。以前只回 false，服务端一律 404
  // 「question not found」，手机端看到的就是「接口不存在」——查不出是提问没了、
  // Agent 没了，还是 DSH 不认这个答案。
  let questionAnswerFailure = null;

  // M4.58c：手机点一次「提交」可能发两次请求（重试 / 卡片和横幅各发一次）。
  // 第一次已经把提问答掉、第二次再来就会拿到 409「已经不在等待回答」——
  // 答案其实已经到了，红条却像是失败。刚答过的同一提问按成功处理。
  const answeredQuestions = new Map();
  const ANSWERED_TTL_MS = 10 * 60 * 1000;

  // M4.61：诊断日志默认关。排查时插件配置 `debug: true` 或环境变量 `M1_DEBUG=1`
  // 才会往 `<stateDir>/q-answers.log` 追加一行，平时不写盘。
  const debugEnabled = process.env.M1_DEBUG === '1' || config.debug === true;
  const traceAnswer = (line) => {
    if (!debugEnabled) return;
    try {
      appendFileSync(join(stateDir, 'q-answers.log'), `${new Date().toISOString()} ${line}\n`, 'utf8');
    } catch {
      // 诊断日志写不进去就算了
    }
  };

  // M4.59：插件自己当一个「浏览器客户端」，连 `/api/remote.mux` 的 $events 流。
  // 提问会以 waterfall 帧送到这里，手机点「提交」时把答案原样回给 Host——
  // 这是手机能原生回答提问的唯一一条路（`userQuestions.answer()` 只认 continued 提问）。
  // M4.62：手机直播页订阅 `/api/v1/desktop/live`，插件把 DSH 远程事件里的会话活动
  // 直接推给 App，省掉 1.5–5 秒的轮询等待。用 app token 鉴权（WebSocket 带不了自定义头）。
  // 热载会重新执行 apply，但端口上还可能是上一个实例的 server；把 hub 放在 globalThis 上，
  // 保证「接受的连接」和「广播的事件」永远是同一个对象。
  const liveHub = globalThis.__m1LiveHub ?? (globalThis.__m1LiveHub = createLiveHub({
    authorize: (token) => hub.authorizeToken(token),
    log,
  }));

  const remoteQuestions = new Map();

  const remoteQuestionEntries = () => [...remoteQuestions.values()].map((entry) => ({
    sessionId: String(entry.sessionId ?? ''),
    questionId: String(entry.questionId ?? ''),
    createdAt: entry.createdAt,
    questions: entry.questions ?? [],
    fromRemote: true,
  }));

  const dropRemoteQuestion = (questionId) => {
    remoteQuestions.delete(String(questionId));
  };

  // M4.60：远程事件客户端默认开启。要关掉：插件配置 `remoteClient: false`，
  // 或环境变量 `M1_REMOTE_CLIENT=0`；`M1_REMOTE_CLIENT=1` 可强制打开（现场排查用）。
  const remoteClientEnabled =
    process.env.M1_REMOTE_CLIENT === '1'
    || (process.env.M1_REMOTE_CLIENT !== '0' && config.remoteClient !== false);


  const onRemoteFrame = (frame, handle) => {
    traceAnswer(`REMOTE ${frame?.type ?? '?'} ${String(frame?.event ?? '')} eventId=${String(frame?.eventId ?? '')}`);
    // M4.62：把会话活动推给手机直播页（没有连着的手机时 broadcast 会直接返回 0）。
    if (frame?.type === 'emit') {
      const event = String(frame?.event ?? '');
      if (event.startsWith('api-session/')) {
        const args = frame?.args ?? {};
        liveHub.broadcast({
          type: 'session',
          event,
          sessionId: String(args.sessionId ?? args.session?.id ?? args.id ?? ''),
          at: Date.now(),
        });
      }
      return;
    }
    if (frame?.type === 'cancel') {
      dropRemoteQuestion(String(frame?.eventId ?? ''));
      liveHub.broadcast({ type: 'question', sessionId: '', questionId: String(frame?.eventId ?? ''), state: 'gone' });
      return;
    }
    if (frame?.type !== 'waterfall' || String(frame?.event ?? '') !== 'user-questions/request') return;
    const request = frame?.request ?? {};
    const questions = Array.isArray(request.questions) ? request.questions : [];
    const sessionId = String(request.sessionId ?? request.session ?? frame?.agentId ?? '');
    traceAnswer(`WATERFALL keys=${Object.keys(request).join(',')} session=${sessionId} items=${questions.length}`);
    if (sessionId.length === 0 || questions.length === 0) return;
    remoteQuestions.set(String(frame.eventId), { sessionId, questionId: String(frame.eventId), createdAt: Date.now(), questions, handle });
    liveHub.broadcast({ type: 'question', sessionId, questionId: String(frame.eventId), state: 'open' });
  };


  if (remoteClientEnabled) {
    // 热载会重新执行 apply，但旧模块建立的 WebSocket 还活着，同一提问会被两边各答一次。
    // 把手柄挂在 globalThis 上，新实例启动前先把上一个关掉。
    const previous = globalThis.__m1RemoteClient;
    if (previous && typeof previous.close === 'function') {
      try {
        previous.close();
        traceAnswer('REMOTE 上一个远程客户端已关闭');
      } catch (error) {
        traceAnswer(`REMOTE 关闭旧客户端失败：${String(error?.message ?? error)}`);
      }
    }
    globalThis.__m1RemoteClient = null;
    const connectRemote = (attempt) => {
      startRemoteEventClient({
        ctx,
        log,
        trace: traceAnswer,
        onFrame: onRemoteFrame,
      }).then((handle) => {
        globalThis.__m1RemoteClient = handle;
        // 插件被卸载/热载时把这条 WebSocket 一起关掉，别留成「僵尸客户端」。
        try {
          ctx.effect?.(() => () => {
            try { handle.close(); } catch { /* 已经断了 */ }
            if (globalThis.__m1RemoteClient === handle) globalThis.__m1RemoteClient = null;
          });
        } catch (error) {
          traceAnswer(`REMOTE 注册卸载回调失败：${String(error?.message ?? error)}`);
        }
        traceAnswer(`REMOTE 客户端已连上（第 ${attempt + 1} 次尝试）`);
        return handle;
      }).catch((error) => {
        traceAnswer(`REMOTE 连接失败（第 ${attempt + 1} 次）：${String(error?.message ?? error)}`);
        if (attempt < 60) {
          const timer = setTimeout(() => connectRemote(attempt + 1), 3000);
          timer.unref?.();
        }
      });
    };
    connectRemote(0);
  }

  const answerDesktopQuestion = (sessionId, questionId, rawAnswers) => {
    questionAnswerFailure = null;
    traceAnswer(`POST session=${sessionId} question=${questionId} answers=${JSON.stringify(rawAnswers)}`);
    const fail = (code, message) => {
      questionAnswerFailure = { code, message };
      log(`手机回答提问失败：${sessionId} · ${code} · ${message}`);
      return false;
    };
    const answeredAt = answeredQuestions.get(String(questionId));
    if (answeredAt !== undefined && Date.now() - answeredAt < ANSWERED_TTL_MS) {
      log(`手机回答提问：${sessionId} · 这条提问刚答过（${Math.round((Date.now() - answeredAt) / 1000)} 秒前），按成功处理`);
      return true;
    }
    const markAnswered = () => answeredQuestions.set(String(questionId), Date.now());
    // M4.59：远程事件流里收到的提问——这才是手机能真正答上的那条路，
    // 直接把答案作为 waterfall 的返回值回给 Host（和浏览器客户端做的事一样）。
    const remote = remoteQuestions.get(String(questionId));
    if (remote && remote.sessionId === String(sessionId)) {
      const normalizedAnswers = normalizeQuestionAnswers(rawAnswers);
      const answers =
        normalizedAnswers.length > 0
          ? normalizedAnswers
          : (remote.questions ?? []).map((item) => ({ id: String(item?.id ?? ''), selected: [] }));
      dropRemoteQuestion(String(questionId));
      markAnswered();
      Promise.resolve(remote.handle?.answer?.(String(questionId), { answers }))
        .then((status) => log(`手机回答提问（远程事件路径）：${sessionId} · ${answers.length} 个问题 · HTTP ${status}`))
        .catch((error) => log(`手机回答提问（远程事件路径）失败：${error?.message ?? error}`));
      return true;
    }
    const entry = pendingQuestions.get(String(questionId));
    if (entry && entry.sessionId === String(sessionId)) {
      const answers = normalizeQuestionAnswers(rawAnswers);
      entry.finish({ answers });
      markAnswered();
      log(`手机回答提问：${sessionId} · ${answers.length} 个问题${answers.length === 0 ? '（跳过）' : ''}`);
      return true;
    }
    // M4.56：从会话日志认出来的提问，走官方的 userQuestions.answer() 回给会话本身。
    // 这条路径上手机就是那个「客户端」，所以电脑上那张卡也会随请求结束一起收掉。
    const pending = collectLogQuestions(sessionId).find(
      (item) => String(item.questionId) === String(questionId),
    );
    if (!pending) {
      // M4.58d：电脑先答了，手机上的卡片还没刷掉——按成功处理，别弹「已经不在等待回答」。
      if (logCallSettled(sessionId, questionId)) {
        markAnswered();
        log(`手机回答提问：${sessionId} · 这条提问已经在电脑上答过，按成功处理`);
        return true;
      }
      return fail('QUESTION_NOT_FOUND', '会话日志里已经没有这条待答提问（可能已经答过，或这条会话已经结束）');
    }
    const userQuestions = ctx.get('userQuestions');
    // M4.58b：open 提问只能由 waterfall 的返回值来答，`answer()` 只认 continued
    // （超时之后的）提问。waterfall 那边的键是插件自己生成的 `q_…`，手机点提交
    // 传的却是日志里的真实 callId —— 这里按「会话 + 题面」把两边对上，直接 finish，
    // 让 waterfall 带着答案返回。
    const contentKey = questionContentKey(pending);
    const waterfallEntry = [...pendingQuestions.values()].find(
      (item) =>
        String(item?.sessionId) === String(sessionId) &&
        questionContentKey({ sessionId: item.sessionId, questions: item.questions }) === contentKey,
    );
    if (waterfallEntry) {
      const normalized = normalizeQuestionAnswers(rawAnswers);
      // 「跳过」也要给每题留一条空 selected，否则 waterfall 只拿到空批次。
      const answers =
        normalized.length > 0
          ? normalized
          : (waterfallEntry.questions ?? []).map((item) => ({ id: String(item?.id ?? ''), selected: [] }));
      waterfallEntry.finish({ answers });
      markAnswered();
      log(`手机回答提问（waterfall 路径）：${sessionId} · ${answers.length} 个问题${normalized.length === 0 ? '（跳过）' : ''}`);
      return true;
    }
    const agents = ctx.get('agents');
    const agent =
      agents?.get?.(String(sessionId)) ??
      (typeof agents?.list === 'function'
        ? (agents.list() ?? []).find((item) => String(item?.id) === String(sessionId))
        : undefined);
    if (!userQuestions || typeof userQuestions.answer !== 'function') {
      return fail('NO_QUESTION_SERVICE', '这个 DSH 版本没有提供 userQuestions.answer()');
    }
    if (!agent) {
      return fail('NO_AGENT', '这条会话的 Agent 已经不在运行，提问没法再回答了');
    }
    const answers = normalizeQuestionAnswers(rawAnswers);
    // 每题都要有一条；「跳过」就是每题空 selected。
    const items =
      answers.length > 0
        ? answers
        : (pending.questions ?? []).map((item) => ({ id: String(item?.id ?? ''), selected: [] }));
    try {
      const ok = userQuestions.answer(agent, String(questionId), { answers: items });
      if (!ok) {
        // M4.58e：`answer()` 只在提问「已经 continued」时才接答案；返回 false 的真实含义
        // 是「这条提问已经结束了」——多半是电脑那边先答了。答案早就有，不该在手机上弹红条。
        markAnswered();
        log(`手机回答提问：${sessionId} · 这条提问已经结束（多半是电脑先答了），按成功处理`);
        return true;
      }
      markAnswered();
      log(
        `手机回答提问（日志路径）：${sessionId} · ${items.length} 个问题${answers.length === 0 ? '（跳过）' : ''}`,
      );
      return true;
    } catch (error) {
      return fail(String(error?.code ?? error?.name ?? 'ANSWER_FAILED'), String(error?.message ?? error));
    }
  };

  // M4.31：手机不在那条会话的直播页时，也要能「看到」有提问等着。
  // 这个接口只回标题级别的摘要（会话 id、标题、问题数、第一条问题的 header/question），
  // 完整选项仍然走 /sessions/<id>/events 的 questions 字段 —— 避免两处各存一份。
  const listPendingDesktop = () => {
    const titleOf = (sessionId) => {
      const session = getDesktopSession(sessionId);
      const title = String(session?.title ?? session?.header?.title ?? '').trim();
      if (title) return title;
      const archived = getArchivedSession(sessionId);
      return String(archived?.title ?? '').trim();
    };
    // M4.56：日志里认出来的提问也要进这张清单，否则手机停在「工作区」时看不到横幅。
    const logEntries = [];
    const sessions = ctx.get('sessions');
    const liveSessions = typeof sessions?.list === 'function' ? sessions.list() : [];
    for (const session of Array.isArray(liveSessions) ? liveSessions : []) {
      const sessionId = String(session?.id ?? '');
      if (sessionId.length === 0) continue;
      logEntries.push(...collectLogQuestions(sessionId));
    }
    return {
      questions: mergeQuestionEntries(logEntries, remoteQuestionEntries(), [...pendingQuestions.values()])
        .map((entry) => {
          const first = entry.questions?.[0] ?? {};
          return {
            sessionId: String(entry.sessionId ?? ''),
            questionId: String(entry.questionId ?? ''),
            count: Array.isArray(entry.questions) ? entry.questions.length : 0,
            createdAt: Number(entry.createdAt) || 0,
            header: String(first?.header ?? '').trim(),
            question: String(first?.question ?? '').trim(),
            title: titleOf(entry.sessionId),
          };
        })
        .filter((item) => item.sessionId.length > 0 && item.questionId.length > 0),
      approvals: [...pendingApprovals.values()]
        .map((entry) => ({
          sessionId: String(entry.sessionId ?? ''),
          approvalId: String(entry.approvalId ?? ''),
          createdAt: Number(entry.createdAt) || 0,
          title: titleOf(entry.sessionId),
          toolName: String(entry.toolName ?? ''),
        }))
        .filter((item) => item.sessionId.length > 0 && item.approvalId.length > 0),
    };
  };

  // M4.24：存档会话要能在**原来那条对话里**继续，不是新开一条。
  // 根因在 DSH 自己的 ArchivedSessionGate：被归档的会话每一步 pre-step 都会被
  // `{ kind: 'reject' }` 拒掉，agent 主循环把它记成 `turn/end {kind:'blocked'}`——
  // 这正是 M4.19 那次「唤醒后日志里只有 turn/start 和 turn/end、一条消息都没有」的真相。
  // 门由 workspaceController.unarchiveSession() 抬起（源码注释：unarchiving lifts the
  // gate for the whole lineage），抬起之后原会话就能正常跑一轮，不需要新开会话。
  const resumeArchivedSession = async (sessionId) => {
    const workspaces = ctx.get('workspaceController');
    if (typeof workspaces?.unarchiveSession !== 'function') {
      return { ok: false, code: 'SESSION_UNARCHIVE_UNSUPPORTED' };
    }
    try {
      const result = await workspaces.unarchiveSession({ sessionId });
      const remaining = Array.isArray(result?.archivedSessionIds) ? result.archivedSessionIds : [];
      if (remaining.includes(sessionId)) return { ok: false, code: 'session/still-archived' };
      return { ok: true, code: '' };
    } catch (error) {
      return { ok: false, code: String(error?.code ?? 'session/unarchive-failed') };
    }
  };

  const promptDesktopSession = async (sessionId, text) => {
    const controller = ctx.get('sessionController');
    if (typeof controller?.prompt !== 'function') throw new Error('sessionController 不可用');
    const value = typeof text === 'string' ? text.trim() : '';
    if (!value) throw new Error('内容不能为空');
    const timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone;
    const send = (targetId, body) =>
      controller.prompt(
        {
          requestId: `desk-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`,
          sessionId: targetId,
          mode: 'queue',
          content: [{ type: 'text', text: body }],
          clientTimeZone: timeZone,
        },
        new AbortController().signal,
      );
    // 活跃会话一步不多走：直接发。
    if (getDesktopSession(sessionId)) return send(sessionId, value);
    // 存档里也没有 → 这条会话是真的没了，别凭空新开一条空会话糊弄用户。
    if (!getArchivedSession(sessionId)) {
      const error = new Error('电脑上已经找不到这个会话了（可能被清理或换了目录）');
      error.code = 'SESSION_NOT_FOUND';
      throw error;
    }
    const resumed = await resumeArchivedSession(sessionId);
    if (!resumed.ok) {
      const unsupported = resumed.code === 'SESSION_UNARCHIVE_UNSUPPORTED';
      const error = new Error(
        unsupported
          ? '这台电脑的 Harness 太旧，没法把存档会话接着聊下去'
          : `这条存档会话现在接不上：${resumed.code}`,
      );
      error.code = unsupported ? 'SESSION_UNARCHIVE_UNSUPPORTED' : 'SESSION_NOT_RESUMABLE';
      throw error;
    }
    log(`存档会话已恢复到原会话继续：${sessionId}`);
    const result = await send(sessionId, value);
    // resumed=true 告诉手机端「就在这条会话里」，不需要跳转。
    return { ...(result ?? {}), resumed: true, resumedFrom: sessionId, sessionId };
  };

  // M4.21：电脑端对话里那排「N 条排队消息（编辑 / 删除 / 插话）」也要能上手机。
  // 数据源是 Host sessionController.state()：{ active, running, queue: SessionQueuedItem[] | null,
  // pendingInput }，队列项形如 { id, placement: 'queued' | 'steering' | 'context', rpcId?, content: Part[] }。
  // 改队列走 updateQueue({ sessionId, itemId, action })，action 只有三种：
  // { kind: 'edit', content: [{ type: 'text', text }] } / { kind: 'remove' } / { kind: 'steer' }。
  const queueItemText = (item) => {
    const content = Array.isArray(item?.content) ? item.content : [];
    const texts = [];
    let attachments = 0;
    for (const part of content) {
      const text = partText(part);
      if (text) texts.push(text);
      else attachments += 1;
    }
    const body = texts.join('').trim();
    if (attachments === 0) return body;
    return body ? `${body}（另有 ${attachments} 个附件）` : `（${attachments} 个附件）`;
  };

  const readDesktopQueue = async (sessionId) => {
    const controller = ctx.get('sessionController');
    if (typeof controller?.state !== 'function') {
      return { supported: false, running: false, items: [], error: '这台电脑的 Harness 没有暴露会话状态' };
    }
    try {
      // Host 的 state(request, signal) 第二个参数必填，内部会 signal.throwIfAborted()。
      const state = await controller.state({ sessionId }, new AbortController().signal);
      const queue = Array.isArray(state?.queue) ? state.queue : [];
      return {
        supported: true,
        running: Boolean(state?.running),
        active: Boolean(state?.active),
        items: queue.map((item) => ({
          id: String(item?.id ?? ''),
          placement: String(item?.placement ?? 'queued'),
          text: queueItemText(item),
        })),
        error: '',
      };
    } catch (error) {
      return {
        supported: true,
        running: false,
        items: [],
        error: String(error?.code ?? error?.message ?? '读取排队消息失败'),
      };
    }
  };

  // action 由手机端传语义化字符串，这里翻译成 Host 的 QueueAction。
  const mutateDesktopQueue = async (sessionId, itemId, action, text) => {
    const controller = ctx.get('sessionController');
    if (typeof controller?.updateQueue !== 'function') {
      const error = new Error('这台电脑的 Harness 太旧，改不了排队消息');
      error.code = 'QUEUE_UNSUPPORTED';
      throw error;
    }
    const id = typeof itemId === 'string' ? itemId.trim() : '';
    if (!id) {
      const error = new Error('缺少排队消息 id');
      error.code = 'QUEUE_BAD_REQUEST';
      throw error;
    }
    let payload;
    if (action === 'remove') {
      payload = { kind: 'remove' };
    } else if (action === 'steer') {
      payload = { kind: 'steer' };
    } else if (action === 'edit') {
      const value = typeof text === 'string' ? text.trim() : '';
      if (!value) {
        const error = new Error('改过的内容不能为空');
        error.code = 'QUEUE_BAD_REQUEST';
        throw error;
      }
      payload = { kind: 'edit', content: [{ type: 'text', text: value }] };
    } else {
      const error = new Error(`不认识的排队操作：${action}`);
      error.code = 'QUEUE_BAD_REQUEST';
      throw error;
    }
    try {
      await controller.updateQueue({ sessionId, itemId: id, action: payload });
    } catch (error) {
      const wrapped = new Error(String(error?.message ?? '改排队消息失败'));
      wrapped.code = String(error?.code ?? 'QUEUE_FAILED');
      throw wrapped;
    }
    const label = action === 'remove' ? '删除' : action === 'steer' ? '插话' : '改字';
    log(`手机改排队消息：${sessionId} · ${label}`);
    return readDesktopQueue(sessionId);
  };

  // M4.25：账户余额。Host 的 deepseekAccount.getBalance() 明确只让 Host 消费者
  // 拿凭据，所以必须由插件代理一次，手机只看到钱包数字，看不到任何 token。
  const readAccountBalance = async () => {
    const account = ctx.get('deepseekAccount');
    const blank = { supported: false, signedIn: false, failed: false, wallets: [], bonusWallets: [], error: '' };
    if (typeof account?.getBalance !== 'function') {
      return { ...blank, error: '这台电脑的 Harness 没有暴露账户服务' };
    }
    const walletsOf = (list) =>
      (Array.isArray(list) ? list : [])
        .map((wallet) => ({
          currency: String(wallet?.currency ?? ''),
          balance: String(wallet?.balance ?? ''),
        }))
        .filter((wallet) => wallet.currency.length > 0 || wallet.balance.length > 0);
    try {
      const details = await account.getBalance({
        version: pluginVersion(),
        locale: 'zh-CN',
        timezoneOffsetSeconds: -new Date().getTimezoneOffset() * 60,
      });
      // 未登录（或授权已失效）时 Host 直接回 null，这不是错误。
      if (!details) {
        return { ...blank, supported: true };
      }
      if (details.status !== 'ready') {
        return { ...blank, supported: true, signedIn: true, failed: true, error: '账户余额查询失败' };
      }
      return {
        supported: true,
        signedIn: true,
        failed: false,
        wallets: walletsOf(details.value),
        bonusWallets: walletsOf(details.bonusWallets),
        error: '',
      };
    } catch (error) {
      return { ...blank, supported: true, error: String(error?.code ?? error?.message ?? '账户余额查询失败') };
    }
  };

  // M3.6：会话列表按「最后一条事件时间」倒序；同名会话补时间，手机上不会再点错。
  // 具体排序/补时间逻辑在 ./task-rows.js（纯函数，可单测）。
  const sessionLastTime = (session, tracked) => {
    const log = Array.isArray(session?.log) ? session.log : [];
    const last = log[log.length - 1];
    const candidates = [
      Number(last?.time),
      Number(tracked?.updatedAt),
      Number(session?.header?.updatedAt),
      Number(session?.header?.createdAt),
      Number(session?.metadata?.updatedAt),
    ];
    for (const value of candidates) {
      if (Number.isFinite(value) && value > 0) return value;
    }
    return 0;
  };

  const countMessages = (session) => {
    const log = Array.isArray(session?.log) ? session.log : [];
    let count = 0;
    for (const event of log) {
      if (event?.type === 'user/message' || event?.type === 'assistant/message') count += 1;
    }
    return count;
  };

  // ---- M4.10 会话存档：DSH 重启后会话会从列表里消失，手机端不能跟着一起清空 ----
  //
  // DSH 把每个会话存成 `~/.dsh/sessions/<项目>/<会话>/session.vN.jsonl.zstd`
  // （标准 Zstandard 帧拼接）。插件不会读它的容器格式 —— 只有 Host 能正确解帧。
  // 所以这里做两件事：
  //   1. 每 30 秒把当前列表里的会话（含手机端参与过的）存一份精简存档到
  //      `<stateDir>/session-archive.json`，标记 source='live'；
  //   2. 扫描 DSH 的会话目录，把**当前列表里没有**的会话读成精简存档
  //      （source='disk'），手机端于是能看到「以前跑过但已经从列表消失」的会话。
  const ARCHIVE_FILE = join(stateDir, 'session-archive.json');
  const ARCHIVE_VERSION = 1;
  const ARCHIVE_INTERVAL_MS = 30_000;
  const ARCHIVE_MAX_EVENTS = 1500;
  const ARCHIVE_TEXT_MAX = 4000;
  /**
   * M4.16：事件清洗规则版本。老版本写进 session-archive.json 的事件里混着 Host 注入的
   * 运行时上下文和整段英文 reasoning（当时 `archiveEvent` 没过滤），而且事件里只剩
   * `{kind,text,time}`、类型信息已经丢了，没法就地洗。带这个版本号的记录才是干净的；
   * 没带的老记录在刷新时按磁盘日志重读一遍（日志里 part 类型还在）。
   */
  const ARCHIVE_EVENT_SCHEMA = 2;
  const ARCHIVE_RECORD_MAX = 400;
  const sessionArchive = new Map();
  let archiveTimer = null;
  let archiveScanAt = 0;

  const readArchiveFile = () => {
    try {
      const parsed = JSON.parse(readFileSync(ARCHIVE_FILE, 'utf8'));
      if (parsed?.version !== ARCHIVE_VERSION || !Array.isArray(parsed.records)) return;
      for (const record of parsed.records) {
        if (!record?.id) continue;
        sessionArchive.set(String(record.id), record);
      }
    } catch {
      // 首次运行 / 文件损坏：重新积累即可，不打扰用户。
    }
  };

  const writeArchiveFile = () => {
    try {
      const records = [...sessionArchive.values()]
        .sort((a, b) => (Number(b.lastTime) || 0) - (Number(a.lastTime) || 0))
        .slice(0, ARCHIVE_RECORD_MAX);
      mkdirSync(stateDir, { recursive: true });
      writeFileSync(ARCHIVE_FILE, JSON.stringify({ version: ARCHIVE_VERSION, records }));
      sessionArchive.clear();
      for (const record of records) sessionArchive.set(String(record.id), record);
    } catch (error) {
      log?.(`会话存档写入失败：${error?.message ?? error}`);
    }
  };

  const clipText = (text, max = ARCHIVE_TEXT_MAX) => {
    const value = String(text ?? '');
    return value.length > max ? `${value.slice(0, max)}…` : value;
  };

  /** 把 Host 的原始事件翻成手机直播能渲染的 {kind, text, time}。 */
  const archiveEvent = (event) => {
    const time = Number(event?.time) || 0;
    const type = String(event?.type ?? '');
    if (type === 'user/message') {
      const text = contentText(event?.data?.message?.content ?? event?.data?.content).trim();
      // M4.16：注入的运行时上下文/提醒不是人说的话，存进存档就再也洗不掉了。
      if (!text || isInjectedUserText(text)) return null;
      return { kind: 'user', time, text: clipText(text) };
    }
    if (type === 'assistant/message') {
      // M4.16：只存正文，纯 reasoning 的消息不进存档（旧版这里会退回推理整段下发）。
      const text = chatText(event?.data?.message?.content ?? event?.data?.content).trim();
      return text ? { kind: 'assistant', time, text: clipText(text) } : null;
    }
    if (type === 'turn/start') return { kind: 'turn-start', time };
    if (type === 'turn/end') return { kind: 'turn-end', time, reason: String(event?.data?.reason?.kind ?? 'completed') };
    return null;
  };

  const emptyArchive = () => ({ events: [], lastTime: 0, lastSeq: 0 });

  /** 从当前 live 会话刷新存档（只动事件，不动 source）。 */
  const absorbLiveSession = (session) => {
    const id = String(session?.id ?? session?.header?.id ?? '');
    if (!id) return;
    const header = session?.header ?? {};
    const log = Array.isArray(session?.log) ? session.log : [];
    const existing = sessionArchive.get(id) ?? emptyArchive();
    const events = [];
    let lastSeq = 0;
    for (const event of log) {
      const seq = Number(event?.seq) || 0;
      if (seq > lastSeq) lastSeq = seq;
      const mapped = archiveEvent(event);
      if (mapped) events.push(mapped);
    }
    // M4.11：重开 DSH 后 live 会话的 log 只从 0 重新累积，直接覆盖会把已经
    // 存档的历史线程清空（自检里 events 从 1500 掉到三百多就是这么来的）。
    // 已经存过的会话只刷新元信息，事件保留更完整的旧版本。
    const liveEvents = events.slice(-ARCHIVE_MAX_EVENTS);
    const kept = Array.isArray(existing.events) ? existing.events : [];
    const trimmed = kept.length > liveEvents.length ? kept : liveEvents;
    const cwd = typeof header.cwd === 'string' ? header.cwd : '';
    sessionArchive.set(id, {
      id,
      source: 'live',
      title: String(header.title ?? '').trim() || String(existing.title ?? ''),
      workspace: cwd,
      createdAt: Number(header.createdAt) || 0,
      lastTime: sessionLastTime(session, desktopTaskState.get(id)) || Number(existing.lastTime) || 0,
      messageCount: countMessages(session),
      lastSeq,
      runtimeRunning: inferRunning(session, desktopTaskState.get(id)),
      events: trimmed,
      archivedAt: new Date().toISOString(),
      // M4.11 保留了更长的旧事件；只有「旧事件本身干净」时才算清洗完成，
      // 否则留给 migrateLegacyArchiveEvents() 按磁盘日志重读（M4.16）。
      eventSchema: existing.eventSchema === ARCHIVE_EVENT_SCHEMA || trimmed === liveEvents
        ? ARCHIVE_EVENT_SCHEMA
        : undefined,
    });
  };

  // ---- 读 DSH 的会话日志（只支持标准 Zstandard 帧拼接） ----

  const ZSTD_MAGIC = 0xfd2fb528;

  /** 按 Zstandard 帧头逐帧切分；遇到被截断的尾帧就停在它前面。 */
  const splitZstdFrames = (buffer) => {
    const frames = [];
    let offset = 0;
    while (offset + 4 <= buffer.length) {
      const start = offset;
      if (buffer.readUInt32LE(offset) !== ZSTD_MAGIC) throw new Error(`invalid zstd magic at ${offset}`);
      offset += 4;
      if (offset >= buffer.length) break;
      const descriptor = buffer.readUInt8(offset);
      offset += 1;
      const contentSizeFlag = descriptor >>> 6;
      const singleSegment = (descriptor & 32) !== 0;
      const checksum = (descriptor & 4) !== 0;
      const dictionaryFlag = descriptor & 3;
      const dictionaryBytes = dictionaryFlag === 3 ? 4 : dictionaryFlag;
      const contentSizeBytes = contentSizeFlag === 0 ? (singleSegment ? 1 : 0) : 1 << contentSizeFlag;
      offset += (singleSegment ? 0 : 1) + dictionaryBytes + contentSizeBytes;
      let broken = false;
      for (;;) {
        if (offset + 3 > buffer.length) {
          broken = true;
          break;
        }
        const blockHeader = buffer.readUIntLE(offset, 3);
        offset += 3;
        const lastBlock = (blockHeader & 1) !== 0;
        const blockType = (blockHeader >>> 1) & 3;
        const blockSize = blockHeader >>> 3;
        offset += blockType === 1 ? 1 : blockSize;
        if (lastBlock) break;
      }
      if (checksum) offset += 4;
      if (broken || offset > buffer.length) break;
      frames.push({ start, end: offset });
    }
    return frames;
  };

  const readSessionLogText = (file) => {
    const buffer = readFileSync(file);
    const parts = [];
    for (const { start, end } of splitZstdFrames(buffer)) {
      parts.push(zstdDecompressSync(buffer.subarray(start, end)));
    }
    return Buffer.concat(parts).toString('utf8');
  };

  const archiveFromLogFile = (id, file) => {
    let text;
    try {
      text = readSessionLogText(file);
    } catch {
      return null;
    }
    let header = null;
    let title = '';
    const events = [];
    for (const line of text.split('\n')) {
      if (!line.trim()) continue;
      let value;
      try {
        value = JSON.parse(line);
      } catch {
        continue;
      }
      if (value?.type === 'session') {
        header = value;
        continue;
      }
      if (value?.type === 'session/title') {
        const next = value?.data?.title ?? value?.data;
        if (typeof next === 'string' && next.trim()) title = next.trim();
        continue;
      }
      // 头部之外的「会话元信息」行（工作区/模型/设置等）不是对话内容，别当成事件。
      if (typeof value?.type === 'string' && value.type.startsWith('session')) continue;
      const mapped = archiveEvent(value);
      if (mapped) events.push(mapped);
    }
    if (!header) return null;
    const trimmed = events.slice(-ARCHIVE_MAX_EVENTS);
    const lastEvent = trimmed[trimmed.length - 1];
    const users = events.filter((event) => event.kind === 'user');
    const computedTitle = title || (users.length > 0 ? users[0].text.split('\n')[0].slice(0, 40) : '');
    return {
      id,
      source: 'disk',
      title: computedTitle,
      workspace: typeof header.cwd === 'string' ? header.cwd : '',
      createdAt: Number(header.createdAt) || 0,
      lastTime: Number(lastEvent?.time) || Number(header.createdAt) || 0,
      messageCount: events.filter((event) => event.kind === 'user' || event.kind === 'assistant').length,
      lastSeq: 0,
      runtimeRunning: false,
      events: trimmed,
      archivedAt: new Date().toISOString(),
      eventSchema: ARCHIVE_EVENT_SCHEMA,
    };
  };

  /** 按会话 id 找到磁盘上最新的那份日志文件（会话目录名就是 id）。 */
  const findSessionLogFile = (id) => {
    const wanted = String(id ?? '');
    if (!wanted) return null;
    const root = dshSessionsRoot();
    let projects;
    try {
      projects = readdirSync(root, { withFileTypes: true }).filter((entry) => entry.isDirectory());
    } catch {
      return null;
    }
    for (const project of projects) {
      const dir = join(root, project.name, wanted);
      let files;
      try {
        files = readdirSync(dir).filter((name) => /^session\.v\d+\.jsonl(\.zstd)?$/.test(name));
      } catch {
        continue;
      }
      if (files.length === 0) continue;
      return join(dir, files.sort().reverse()[0]);
    }
    return null;
  };

  /**
   * M4.16：把老存档里的事件按磁盘日志重读一遍。
   *
   * 只在「这条记录明显脏」（用户事件里含 Host 注入）时才动手，避免每次刷新去读上百个
   * 日志文件；找不到日志就保持原样，下次刷新再试。
   */
  const migrateLegacyArchiveEvents = () => {
    for (const [id, record] of sessionArchive) {
      if (record?.eventSchema === ARCHIVE_EVENT_SCHEMA) continue;
      const events = Array.isArray(record?.events) ? record.events : [];
      const dirty = events.some(
        (event) => event?.kind === 'user' && isInjectedUserText(event?.text),
      );
      if (!dirty) {
        record.eventSchema = ARCHIVE_EVENT_SCHEMA;
        continue;
      }
      const file = findSessionLogFile(id);
      if (!file) continue;
      const rebuilt = archiveFromLogFile(id, file);
      if (!rebuilt || rebuilt.events.length === 0) continue;
      sessionArchive.set(id, {
        ...record,
        events: rebuilt.events,
        messageCount: rebuilt.messageCount || record.messageCount,
        title: String(record.title ?? '').trim() || rebuilt.title,
        workspace: String(record.workspace ?? '').trim() || rebuilt.workspace,
        eventSchema: ARCHIVE_EVENT_SCHEMA,
      });
      log?.(`会话存档已按新规则重读：${id}（${rebuilt.events.length} 条事件）`);
    }
  };

  /** DSH 会话根目录：`<DSH 主目录>/sessions`。 */
  const dshSessionsRoot = () => {
    const explicit = config?.sessionsDir;
    if (typeof explicit === 'string' && explicit) return explicit;
    return join(config?.dshHome ?? join(homedir(), '.dsh'), 'sessions');
  };

  /**
   * 只有 header、没有任何事件的会话不算「内容」。
   * M4.10：DSH 的 JSONL 后端对这类会话整条 invisible（`readGenerationHeader` 返回 undefined），
   * 手机端要是把它们也列出来，工作区页会多出一堆没有标题的空行 —— 直接跳过。
   */
  const archiveHasContent = (record) =>
    Boolean(record) &&
    (String(record.title ?? '').trim() !== '' || (record.events?.length ?? 0) > 0);

  /**
   * M4.11：插件自测、e2e、契约测试在 `agent\.m1ws\...`、`agent\.workspaces\contract-...`
   * 这类临时目录里跑出过上百个会话。它们不是用户的真实项目，混进「已存档」分组只会
   * 把真正的项目淹掉（实测 141 条里 38 条是 `.m1ws`）。
   */
  const ARCHIVE_SKIP_SEGMENTS = [
    '.m1ws',
    '.workspaces',
    '.tmp',
    'node_modules',
    '.dart_tool',
    '.git',
  ];
  const ARCHIVE_SKIP_PREFIXES = ['contract-', 'e2e-', 'probe-', 'reject-trigger-', 'probe-approval-'];

  /** 会话 cwd 是不是测试/构建临时目录（按路径分段判断，避免误伤正常项目）。 */
  const isScratchWorkspace = (workspace) => {
    const segments = String(workspace ?? '')
      .split(/[\\/]+/)
      .map((segment) => segment.trim().toLowerCase())
      .filter(Boolean);
    if (segments.length === 0) return false;
    if (segments.some((segment) => ARCHIVE_SKIP_SEGMENTS.includes(segment))) return true;
    const leaf = segments[segments.length - 1];
    return ARCHIVE_SKIP_PREFIXES.some((prefix) => leaf.startsWith(prefix));
  };

  /** 扫描 DSH 磁盘上的会话目录，把 live 列表里没有的会话补进存档。 */
  const scanSessionsOnDisk = ({ force = false } = {}) => {
    const now = Date.now();
    if (!force && now - archiveScanAt < ARCHIVE_INTERVAL_MS) return;
    archiveScanAt = now;
    const root = dshSessionsRoot();
    let projects;
    try {
      projects = readdirSync(root, { withFileTypes: true }).filter((entry) => entry.isDirectory());
    } catch {
      return;
    }
    for (const project of projects) {
      const projectDir = join(root, project.name);
      let sessions;
      try {
        sessions = readdirSync(projectDir, { withFileTypes: true }).filter((entry) => entry.isDirectory());
      } catch {
        continue;
      }
      for (const session of sessions) {
        const id = session.name;
        if (sessionArchive.has(id)) continue;
        const dir = join(projectDir, id);
        let files;
        try {
          files = readdirSync(dir).filter((name) => /^session\.v\d+\.jsonl(\.zstd)?$/.test(name));
        } catch {
          continue;
        }
        if (files.length === 0) continue;
        const latest = files.sort().reverse()[0];
        const record = archiveFromLogFile(id, join(dir, latest));
        if (!archiveHasContent(record)) continue;
        // M4.11：测试/e2e 跑出来的临时目录不进存档，否则真正的项目会被淹掉。
        if (isScratchWorkspace(record.workspace)) continue;
        sessionArchive.set(id, record);
      }
    }
  };

  const listArchivedSessions = () => [...sessionArchive.values()]
    .filter((record) => archiveHasContent(record))
    // M4.11：旧版本已经写进 session-archive.json 的临时目录记录也要挡在列表外
    // （文件里的存量记录不会被删，只是不展示，用户的项目记录不受影响）。
    .filter((record) => !isScratchWorkspace(record.workspace))
    .map(({ events, ...rest }) => ({ ...rest, eventCount: events.length }));

  // M4.16：老存档里已经躺着注入消息和英文推理（写入端当时没过滤），读取时再洗一遍，
  // 不用改文件、也不丢历史——用户点开看到的就该是对话。
  const getArchivedSession = (id) => {
    const record = sessionArchive.get(String(id));
    if (!record) return null;
    const events = Array.isArray(record.events) ? record.events : [];
    return { ...record, events: events.filter((event) => !isInjectedEvent(event)) };
  };

  const refreshSessionArchive = ({ scan = false } = {}) => {
    const sessions = ctx.get('sessions');
    const live = typeof sessions?.list === 'function' ? sessions.list() : [];
    for (const session of Array.isArray(live) ? live : []) absorbLiveSession(session);
    if (scan) scanSessionsOnDisk();
    // M4.16：老存档里的事件带着注入消息与英文 reasoning，按磁盘日志重读一遍。
    try {
      migrateLegacyArchiveEvents();
    } catch (error) {
      log?.(`会话存档重读失败：${error?.message ?? error}`);
    }
    // 旧版本写进存档的「只有 header」的记录也要清掉，否则手机端会列出一堆空行。
    for (const [id, record] of sessionArchive) {
      if (!archiveHasContent(record)) sessionArchive.delete(id);
    }
    writeArchiveFile();
    return listArchivedSessions();
  };

  const startSessionArchive = () => {
    readArchiveFile();
    refreshSessionArchive({ scan: true });
    archiveTimer = setInterval(() => {
      try {
        refreshSessionArchive();
      } catch (error) {
        log?.(`会话存档刷新失败：${error?.message ?? error}`);
      }
    }, ARCHIVE_INTERVAL_MS);
    archiveTimer.unref?.();
  };

  const stopSessionArchive = () => {
    if (archiveTimer) clearInterval(archiveTimer);
    archiveTimer = null;
  };

  /** 手机端补传一份会话（用户手动恢复用）。 */
  const saveArchivedSession = (input) => {
    const id = String(input?.id ?? '').trim();
    if (!id) throw new Error('缺少会话 id');
    const events = (Array.isArray(input?.events) ? input.events : [])
      .filter((event) => event && typeof event === 'object')
      .slice(0, ARCHIVE_MAX_EVENTS)
      .map((event) => ({
        kind: String(event.kind ?? ''),
        time: Number(event.time) || 0,
        ...(event.text == null ? {} : { text: clipText(event.text) }),
        ...(event.reason == null ? {} : { reason: String(event.reason) }),
      }))
      .filter((event) => event.kind);
    const record = {
      id,
      source: String(input?.source ?? 'imported').slice(0, 20),
      title: String(input?.title ?? '').slice(0, 120),
      workspace: String(input?.workspace ?? ''),
      createdAt: Number(input?.createdAt) || 0,
      lastTime: Number(input?.lastTime) || events.at(-1)?.time || Date.now(),
      messageCount: events.filter((event) => event.kind === 'user' || event.kind === 'assistant').length,
      lastSeq: 0,
      runtimeRunning: false,
      events,
      archivedAt: new Date().toISOString(),
    };
    sessionArchive.set(id, record);
    writeArchiveFile();
    return { ok: true, events: events.length };
  };

  // M4.13：手机端新建项目默认落在「项目根」（D:\Projects\项目 这类），而不是随便哪个
  // 授权根的第一个。找不到项目根时退回第一个授权根，老行为不变。
  const DEFAULT_PROJECT_PARENT = 'D:\\Projects\\项目';
  /** 父目录必须是某个授权根本身或它的直接子目录，否则拒绝——防止手机端写到任意路径。 */
  const resolveParentDir = (requested) => {
    const roots = (workspaceRootsNow() ?? []).filter((root) => typeof root === 'string' && root.trim());
    const wanted = String(requested ?? '').trim();
    if (!wanted) return roots[0] ?? '';
    const wantedKey = canonicalPath(wanted);
    for (const root of roots) {
      const rootKey = canonicalPath(root);
      if (rootKey === wantedKey) return root;
      if (wantedKey.startsWith(`${rootKey}\\`)) {
        return root;
      }
    }
    // 项目根不在授权列表里时，只要它自己是个目录也放行（用户显式指定了路径）。
    try {
      if (existsSync(wanted) && statSync(wanted).isDirectory()) return wanted;
    } catch {
      /* 目录不可读就当没指定 */
    }
    return roots[0] ?? '';
  };
  const projectParentPath = () => {
    const wanted = resolveParentDir(DEFAULT_PROJECT_PARENT);
    return wanted || resolveParentDir('');
  };

  // M4.45：DSH 的工作区列表来自 workspaceRegistry，不是磁盘扫描。
  // 只在磁盘上建目录 = 手机端能看见、电脑端列表里没有，用户以为没建成。
  // 注册失败不影响建目录本身（老插件/受限环境仍可用），但要留日志。
  const registerDesktopWorkspace = async (workspacePath, title) => {
    let registry;
    try {
      registry = ctx.get?.('workspaceRegistry') ?? ctx.workspaceRegistry;
    } catch {
      registry = undefined;
    }
    if (!registry || typeof registry.create !== 'function') return false;
    try {
      await registry.create(workspacePath, title);
      return true;
    } catch (error) {
      log(`工作区注册失败（${workspacePath}）：${error?.message ?? error}`);
      return false;
    }
  };

  // 工作区列表：授权根目录 + 会话里出现过的 cwd，带会话数与运行数。
  // M4.13：支持 `parentDir`，手机端新建项目时可以指定落在哪个父目录下。
  const createDesktopWorkspace = async (name, parentDir) => {
    const clean = String(name ?? '').trim().replace(/[\\/:*?"<>|]+/g, '-');
    if (!clean || clean === '.' || clean === '..') {
      throw new Error('invalid workspace name');
    }
    const parent = parentDir ? resolveParentDir(parentDir) : '';
    // 已存在就复用（不新建、不清空），重复调用幂等。
    const searchRoots = parent ? [parent] : (workspaceRootsNow() ?? []);
    const existing = searchRoots.find((root) => {
      if (typeof root !== 'string' || !root) return false;
      const path = join(root, clean);
      return existsSync(path) && statSync(path).isDirectory();
    });
    if (existing) {
      const reused = join(existing, clean);
      const registered = await registerDesktopWorkspace(reused, clean);
      return { path: reused, name: clean, parent: existing, registered };
    }
    const root = parent || (workspaceRootsNow() ?? [])[0];
    if (!root) throw new Error('no workspace root');
    const target = join(root, clean);
    mkdirSync(target, { recursive: true });
    // 建完立刻注册，电脑端的「工作区 / 最近项目」马上能看到。
    const registered = await registerDesktopWorkspace(target, clean);
    return { path: target, name: clean, parent: root, registered };
  };

  // M4.2：手机附件落到「当前工作区」下，而不是插件状态目录里——否则电脑端的 AI
  // 根本不知道文件在哪，只能看到一串 %APPDATA% 路径。用户给了工作区名就找同名目录，
  // 再退回当前会话的 cwd，最后才用状态目录。
  const UPLOAD_DIR_NAME = '手机附件';
  // M4.12：优先用和「工作区」列表同一份数据去匹配（末段名 / 完整路径都对得上），
  // 再退回授权根。授权根在注册表刚就绪时可能只剩 `homedir()` 或顺序漂移，
  // 只认授权根会让附件悄悄落回状态目录，用户以为传到了项目里其实没有。
  const knownWorkspacePaths = () => {
    const paths = [];
    const push = (value) => {
      if (typeof value === 'string' && value.trim()) paths.push(value.trim());
      else if (value && typeof value === 'object') {
        const path = value.path ?? value.root ?? value.cwd ?? value.directory;
        if (typeof path === 'string' && path.trim()) paths.push(path.trim());
      }
    };
    try {
      listDesktopWorkspaces().forEach(push);
    } catch {
      /* 列表不可用时只用授权根 */
    }
    (workspaceRootsNow() ?? []).forEach(push);
    return [...new Set(paths)];
  };
  /** 名字（末段名或完整路径）命中某个已知工作区时返回它的绝对路径。 */
  const findWorkspaceByName = (wanted) => {
    const key = canonicalPath(wanted);
    const sameName = (path) => basename(path) === wanted;
    const match = (path) => canonicalPath(path) === key || sameName(path);
    return knownWorkspacePaths().find((path) => {
      if (match(path)) return true;
      try {
        return statSync(join(path, wanted)).isDirectory();
      } catch {
        return false;
      }
    });
  };
  const resolveUploadDir = (requested) => {
    const wanted = String(requested ?? '').trim();
    if (wanted) {
      // M4.11：手机端传的是「工作区名」（路径末段，见 _uploadWorkspace），
      // 也可能直接传完整路径。逐个授权根试：root/同名子目录、root 自身
      // （工作区就是授权根本身时，末段名 == 根目录名）、或 wanted 本身就是该根。
      const wantedKey = canonicalPath(wanted);
      const hit = findWorkspaceByName(wanted);
      if (hit) {
        const base = canonicalPath(hit) === wantedKey || basename(hit) === wanted ? hit : join(hit, wanted);
        const target = join(base, UPLOAD_DIR_NAME);
        try {
          mkdirSync(target, { recursive: true });
          return target;
        } catch {
          /* 建不出来就继续往下退 */
        }
      }
    }
    const cwd = String(ctx.get('sessions')?.current?.()?.header?.cwd ?? '').trim();
    if (cwd) {
      try {
        if (statSync(cwd).isDirectory()) return join(cwd, UPLOAD_DIR_NAME);
      } catch {
        /* 会话目录不在了，退回状态目录 */
      }
    }
    return join(stateDir, 'uploads');
  };

  // M4.9：手机端在「工作区」里点开文件时，按授权根拼绝对路径并检查边界。
  // M4.11：`workspaceRootsNow()` 有时只剩 `homedir()`（注册表在 apply 时还没就绪），
  // 而手机上的工作区列表来自「授权根 ∪ 会话 cwd」，两边对不上就会出现
  // 「列表里有目录、点开却说 workspace not authorized」。所以这里再兜一层：
  // 当前会话 cwd、以及注册表里的目录，同样算授权。
  const liveWorkspacePaths = () => {
    const paths = [];
    try {
      const current = ctx.get?.('sessions')?.current?.()?.header?.cwd;
      if (typeof current === 'string' && current) paths.push(current);
    } catch {
      /* 忽略 */
    }
    try {
      paths.push(...rootsFromRegistry(ctx.get?.('workspaceRegistry') ?? ctx.workspaceRegistry));
    } catch {
      /* 忽略 */
    }
    return paths;
  };

  const resolveWorkspaceFile = (workspacePath, relativePath) => {
    const root = String(workspacePath ?? '').trim();
    const rel = String(relativePath ?? '').trim().replace(/^[\\/]+/, '');
    const wanted = canonicalPath(root);
    const candidates = [...(workspaceRootsNow() ?? []), ...liveWorkspacePaths()];
    const rootHit = candidates.find((item) => {
      if (typeof item !== 'string' || !item) return false;
      return canonicalPath(item) === wanted || canonicalPath(join(item, '.')) === wanted;
    });
    if (!rootHit) throw new Error('workspace not authorized');
    if (!rel || rel.split(/[\\/]/).includes('..')) throw new Error('invalid relative path');
    const absPath = join(rootHit, rel);
    return { absPath: absPath, root: rootHit, relativePath: rel };
  };

  // 读文件原文给手机端（手机解析不了 PDF/Word/Excel，让电脑读成文字再回传）。
  const MAX_READ_BYTES = 2 * 1024 * 1024;
  const MAX_WORKSPACE_FILE_BYTES = 20 * 1024 * 1024;
  const TEXT_EXTENSIONS = new Set([
    '.txt', '.md', '.markdown', '.json', '.jsonc', '.csv', '.tsv', '.log', '.yml', '.yaml',
    '.xml', '.ini', '.toml', '.conf', '.env', '.dart', '.js', '.mjs', '.cjs', '.ts', '.tsx',
    '.jsx', '.py', '.java', '.kt', '.kts', '.c', '.h', '.cc', '.cpp', '.hpp', '.cs', '.go',
    '.rs', '.m', '.sh', '.ps1', '.bat', '.sql', '.html', '.htm', '.css', '.scss', '.less',
    '.vue', '.svelte', '.gradle', '.properties', '.gitignore', '.editorconfig',
  ]);
  const extractText = async (buffer, ext) => {
    const runs = (text) => String(text).replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/g, '');
    if (ext === '.pdf') {
      const pdfParse = (await import('pdf-parse')).default;
      const parsed = await pdfParse(buffer);
      return runs(parsed?.text ?? '');
    }
    if (ext === '.docx' || ext === '.pptx' || ext === '.xlsx') {
      const JSZip = (await import('jszip')).default;
      const zip = await JSZip.loadAsync(buffer);
      const chunks = [];
      const xmlToText = (xml) =>
        runs(
          String(xml)
            .replace(/<w:p[ >]/g, '\n<w:p ')
            .replace(/<a:p[ >]/g, '\n<a:p ')
            .replace(/<\/(w:p|a:p)>/g, '\n')
            .replace(/<[^>]+>/g, ''),
        );
      const names = Object.keys(zip.files).filter((name) => {
        if (ext === '.xlsx') return /^xl\/sharedStrings\.xml$/.test(name);
        return /^(word\/document\.xml|word\/footnotes\.xml|ppt\/slides\/slide\d+\.xml)$/.test(name);
      });
      for (const name of names.sort()) {
        const xml = await zip.files[name].async('string');
        const text = xmlToText(xml).trim();
        if (text) chunks.push(text);
      }
      return chunks.join('\n\n');
    }
    if (ext === '.doc' || ext === '.xls' || ext === '.ppt') {
      throw new Error('旧版 Office 格式（.doc/.xls/.ppt）暂不支持，请在电脑上另存为 docx/xlsx 后再试');
    }
    try {
      return runs(buffer.toString('utf8'));
    } catch {
      throw new Error('这个文件不是文本，手机端暂时读不了');
    }
  };
  const runsText = (buffer) =>
    String(buffer.toString('utf8')).replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/g, '');
  const readDesktopFileText = async ({ name, data } = {}) => {
    const base64 = String(data ?? '').trim();
    const fileName = String(name ?? '').trim();
    if (!base64) throw new Error('empty file');
    const buffer = Buffer.from(base64, 'base64');
    if (!buffer.length) throw new Error('empty file');
    if (buffer.length > MAX_READ_BYTES) throw new Error('文件太大（上限 2 MB）');
    const ext = extname(fileName).toLowerCase();
    if (TEXT_EXTENSIONS.has(ext)) return runsText(buffer);
    const text = await extractText(buffer, ext);
    if (!text.trim()) throw new Error('没能从这个文件里读出文字');
    return text;
  };
  const readWorkspaceFileBytes = async (workspacePath, relativePath) => {
    const resolved = resolveWorkspaceFile(workspacePath, relativePath);
    const info = statSync(resolved.absPath);
    if (!info.isFile()) throw new Error('not a file');
    if (info.size > MAX_WORKSPACE_FILE_BYTES) {
      throw new Error(`文件太大（${Math.round(info.size / 1024 / 1024)} MB，上限 ${MAX_WORKSPACE_FILE_BYTES / 1024 / 1024} MB）`);
    }
    return { ...resolved, buffer: readFileSync(resolved.absPath), size: info.size };
  };
  // M4.13：`parent` 让手机端能按「项目根」分组（D:\Projects\项目 下的都算项目）。
  const listDesktopWorkspaces = () => {
    const seen = new Map();
    for (const root of workspaceRootsNow() ?? []) {
      if (typeof root !== 'string' || !root) continue;
      seen.set(root, { path: root, sessions: 0, running: 0 });
    }
    for (const task of listDesktopTasks()) {
      const path = task.workspace;
      if (!path) continue;
      const row = seen.get(path) ?? { path, sessions: 0, running: 0 };
      row.sessions += 1;
      if (task.running) row.running += 1;
      seen.set(path, row);
    }
    const projectParent = canonicalPath(projectParentPath());
    return [...seen.values()]
      .map((row) => ({
        ...row,
        name: basename(row.path) || row.path,
        parent: dirname(row.path) || '',
        isProject: projectParent !== '' && canonicalPath(dirname(row.path)) === projectParent,
      }))
      .sort((a, b) => b.running - a.running || b.sessions - a.sessions || a.path.localeCompare(b.path));
  };

  const listDesktopTasks = () => {
    const sessions = ctx.get('sessions');
    const live = typeof sessions?.list === 'function' ? sessions.list() : [];
    const rows = [];
    for (const session of Array.isArray(live) ? live : []) {
      const header = session?.header ?? {};
      const id = String(session?.id ?? header.id ?? '');
      if (!id) continue;
      const cwd = typeof header.cwd === 'string' ? header.cwd : '';
      const tracked = desktopTaskState.get(id) ?? {};
      const log = Array.isArray(session?.log) ? session.log : [];
      const lastTime = sessionLastTime(session, tracked);
      const title =
        (typeof header.title === 'string' && header.title.trim()) ||
        (typeof session?.title === 'string' && session.title.trim()) ||
        (cwd ? basename(cwd) : `会话 ${id.slice(-6)}`);
      const running = inferRunning(session, tracked);
      const status = tracked.error ? 'failed' : running ? 'running' : 'completed';
      rows.push({
        id,
        title,
        workspace: cwd,
        status,
        progress: status === 'running' ? 0.5 : 1,
        running,
        updatedAt: new Date(lastTime || Date.now()).toISOString(),
        lastTime,
        messageCount: countMessages(session),
        lastSeq: Number(log[log.length - 1]?.seq) || 0,
      });
    }
    return labelAndSortTasks(rows, 50);
  };

  // M2.9.3：把桌面会话的事件日志翻成手机能直接渲染的「直播流」。
  const truncate = (text, max = 600) => {
    const value = typeof text === 'string' ? text : String(text ?? '');
    return value.length > max ? `${value.slice(0, max)}…` : value;
  };

  // 手机直播只展示人真正说的话；注入规则与存档共用 ./chat-filter.js（M4.16）。

  // 正文 part 过滤在 ./assistant-text.js（M3.6：别把 reasoning 当回复下发）。

  const mapDesktopEvent = (event) => {
    const data = event?.data ?? {};
    const seq = Number(event?.seq) || 0;
    const time = Number(event?.time) || 0;
    switch (event?.type) {
      case 'user/message': {
        if (data?.source?.kind === 'time-context') return null;
        const text = contentText(data?.content).trim();
        if (!text) return null;
        if (isInjectedUserText(text)) return null;
        return { seq, time, kind: 'user', text: truncate(text, 2000) };
      }
      case 'assistant/message': {
        const text = chatText(data?.message?.content);
        return text ? { seq, time, kind: 'assistant', text: truncate(text, 8000) } : null;
      }
      case 'tool/call':
        return {
          seq,
          time,
          kind: 'tool-call',
          callId: String(data?.callId ?? ''),
          name: String(data?.name ?? 'tool'),
          args: truncate(data?.arguments ?? '', 600),
        };
      case 'tool/result':
        return {
          seq,
          time,
          kind: 'tool-result',
          callId: String(data?.message?.toolCallId ?? ''),
          ok: data?.message?.isError !== true,
          text: truncate(contentText(data?.message?.content).trim(), 600),
        };
      case 'turn/start':
        return { seq, time, kind: 'turn-start' };
      case 'turn/end':
        return { seq, time, kind: 'turn-end', reason: String(data?.reason?.kind ?? '') };
      default:
        if (String(event?.type ?? '').startsWith('approval/')) {
          return { seq, time, kind: 'approval', text: truncate(JSON.stringify(safePreview(data)), 400) };
        }
        return null;
    }
  };

  const getDesktopSession = (sessionId) => {
    const sessions = ctx.get('sessions');
    const live = typeof sessions?.list === 'function' ? sessions.list() : [];
    const wanted = String(sessionId ?? '');
    return (Array.isArray(live) ? live : []).find(
      (session) => String(session?.id ?? session?.header?.id ?? '') === wanted,
    );
  };

  // M4.56：插件那条 `user-questions/request` 只有 `userQuestions.ask()` 会派发；DSH 的问答工具
  // 走的是 askTimed（「Foreground wait whose first settlement the Client decides」），压根不到插件。
  // 实测两次热载后监听器一次都没被叫到，所以改从会话日志里认：
  // 一条 `tool/call`（name 为 ask_user_question）没有配对的 `tool/result`，就是「还在等回答」。
  const ASK_TOOL_NAMES = new Set(['ask_user_question']);
  const collectLogQuestions = (sessionId) => {
    const session = getDesktopSession(sessionId);
    const entries = Array.isArray(session?.log) ? session.log : [];
    if (entries.length === 0) return [];
    const typeOf = (entry) => entry?.type ?? entry?.event?.type;
    const dataOf = (entry) => entry?.data ?? entry?.event?.data ?? {};
    const settled = new Set();
    const calls = [];
    for (const entry of entries) {
      const data = dataOf(entry);
      if (typeOf(entry) === 'tool/result') {
        // 实测日志里结果事件用的是 `toolCallId`（`data.callId` 是空的），
        // 只认 callId 的话已经答过的提问会永远算「待回答」，手机上会堆一串空卡。
        const resultId = data.toolCallId ?? data.callId ?? data.message?.source?.callId;
        if (resultId) settled.add(String(resultId));
      }
      if (typeOf(entry) === 'tool/call' && ASK_TOOL_NAMES.has(String(data.name ?? ''))) calls.push(entry);
    }
    const found = [];
    for (const entry of calls) {
      const data = dataOf(entry);
      const callId = String(data.callId ?? '');
      if (!callId || settled.has(callId)) continue;
      let args;
      try {
        args = JSON.parse(String(data.arguments ?? '{}'));
      } catch {
        continue;
      }
      const items = Array.isArray(args?.questions) ? args.questions : [];
      if (items.length === 0) continue;
      found.push({
        sessionId: String(sessionId),
        questionId: callId,
        createdAt: Number(entry?.time ?? entry?.event?.time) || Date.now(),
        questions: items,
        fromLog: true,
      });
    }
    return found;
  };

  // M4.58d：电脑上已经答过的提问，日志里会有一条配对的 `tool/result`。
  // 手机上的卡片还没轮询掉、又点了「提交」时，这种情况不该报错——答案早就有了。
  const logCallSettled = (sessionId, callId) => {
    const session = getDesktopSession(sessionId);
    const entries = Array.isArray(session?.log) ? session.log : [];
    const typeOf = (entry) => entry?.type ?? entry?.event?.type;
    const dataOf = (entry) => entry?.data ?? entry?.event?.data ?? {};
    for (const entry of entries) {
      if (typeOf(entry) !== 'tool/result') continue;
      const data = dataOf(entry);
      const resultId = data.toolCallId ?? data.callId ?? data.message?.source?.callId;
      if (String(resultId ?? '') === String(callId)) return true;
    }
    return false;
  };

  const serializeQuestionItems = (questions) =>
    (Array.isArray(questions) ? questions : []).map((item) => ({
      id: String(item?.id ?? ''),
      header: String(item?.header ?? ''),
      question: String(item?.question ?? ''),
      detail: String(item?.detail ?? ''),
      multiSelect: item?.multiSelect === true,
      options: (Array.isArray(item?.options) ? item.options : []).map((option) => ({
        label: String(option?.label ?? ''),
        description: String(option?.description ?? ''),
      })),
    }));

  // 同一个提问可能既有 waterfall 来的、又有日志里的，按 callId 去重，先到先得。
  // M4.58b：waterfall 的 request 不带 `wait.callId`，插件只能用自己生成的 `q_…`
  // 当键，于是同一个问题会有两个 id、两张卡。这里再加一层「会话 + 题面」去重。
  const questionContentKey = (entry) =>
    `${String(entry?.sessionId ?? '')}|${(Array.isArray(entry?.questions) ? entry.questions : [])
      .map((item) => `${String(item?.id ?? '')}:${String(item?.question ?? item?.header ?? '')}`)
      .join('~')}`;

  const mergeQuestionEntries = (...groups) => {
    const merged = new Map();
    const seenContent = new Set();
    for (const group of groups) {
      for (const entry of Array.isArray(group) ? group : []) {
        const key = String(entry?.questionId ?? '');
        if (!key || merged.has(key)) continue;
        const content = questionContentKey(entry);
        if (seenContent.has(content)) continue;
        seenContent.add(content);
        merged.set(key, entry);
      }
    }
    return [...merged.values()];
  };

  const listDesktopSessionEvents = (sessionId, options = {}) => {
    const session = getDesktopSession(sessionId);
    if (!session) return null;
    watchedSessions.set(String(sessionId), Date.now());
    const log = Array.isArray(session.log) ? session.log : [];
    const limit = Math.min(Math.max(Number(options.limit) || 80, 1), 200);
    // M4.14：窗口要「够到对话」。以前首屏只取最后 80 条事件，而一个忙会话里
    // 80 条可能全是 tool-call / tool-result（实测一次 41 步的会话就是这样），
    // 手机端过滤后一条正文都没有 —— 用户看到的就是「这个会话还没有可展示的内容」。
    // 现在往回扫时，除了凑满 limit，还要至少拿到 MIN_CHAT_EVENTS 条对话事件，
    // 上限 MAX_TAIL_EVENTS 兜底，避免老会话一次传几千条。
    const MIN_CHAT_EVENTS = 12;
    const MAX_TAIL_EVENTS = 600;
    const CHAT_KINDS = new Set(['user', 'assistant']);
    const afterSeq = Number(options.afterSeq);
    const events = [];
    if (Number.isFinite(afterSeq) && afterSeq >= 0) {
      // 增量拉取：要的是游标之后**最新**的一段。以前从头往后扫并在 limit 处 break，
      // 一次积压几百条时手机只会收到最早那几条，后面的永远追不上。
      for (let i = log.length - 1; i >= 0 && events.length < limit; i -= 1) {
        if ((Number(log[i]?.seq) || 0) <= afterSeq) break;
        const mapped = mapDesktopEvent(log[i]);
        if (mapped) events.push(mapped);
      }
      events.reverse();
    } else {
      let chat = 0;
      for (let i = log.length - 1; i >= 0 && events.length < MAX_TAIL_EVENTS; i -= 1) {
        if (events.length >= limit && chat >= MIN_CHAT_EVENTS) break;
        const mapped = mapDesktopEvent(log[i]);
        if (!mapped) continue;
        events.push(mapped);
        if (CHAT_KINDS.has(mapped.kind)) chat += 1;
      }
      events.reverse();
    }
    const header = session.header ?? {};
    const tracked = desktopTaskState.get(String(sessionId)) ?? {};
    const cwd = typeof header.cwd === 'string' ? header.cwd : '';
    const title =
      (typeof header.title === 'string' && header.title.trim()) ||
      (typeof session?.title === 'string' && session.title.trim()) ||
      (cwd ? basename(cwd) : `会话 ${String(sessionId).slice(-6)}`);
    return {
      sessionId: String(sessionId),
      title,
      cwd,
      running: inferRunning(session, tracked),
      lastSeq: Number(log.at(-1)?.seq) || 0,
      events,
      approvals: [...pendingApprovals.values()]
        .filter((entry) => entry.sessionId === String(sessionId))
        .map(({ approvalId, toolName, reason, createdAt }) => ({ approvalId, toolName, reason, createdAt })),
      // M4.23：待回答的「确认需求」卡片。只下发可序列化的字段（finish 是函数）。
      // M4.56：监听器收不到的提问改从会话日志里认（见 collectLogQuestions），两路按 callId 去重。
      questions: mergeQuestionEntries(
        remoteQuestionEntries().filter((entry) => entry.sessionId === String(sessionId)),
        collectLogQuestions(sessionId),
        [...pendingQuestions.values()].filter((entry) => entry.sessionId === String(sessionId)),
      ).map(({ questionId, createdAt, questions }) => ({
        questionId,
        createdAt,
        items: serializeQuestionItems(questions),
      })),
    };
  };

  // M4.57：手机「功能 → 接收文件」。
  //
  // 电脑端把做好的文件放进插件的状态目录（默认 `~/.dsh/dsh-plugin-m1/received`），
  // 手机端就能在「功能 → 接收文件」里看到并打开：图片、PDF、Office、文本都走
  // 已有的文件预览。目录由插件自己建，AI 只要把文件复制进去即可。
  const receivedDir = join(stateDir, 'received');
  const RECEIVED_LIST_LIMIT = 200;
  const ensureReceivedDir = () => {
    try {
      mkdirSync(receivedDir, { recursive: true });
    } catch (error) {
      log(`接收文件目录创建失败：${receivedDir}（${error?.message ?? error}）`);
    }
  };
  ensureReceivedDir();

  const listReceivedFiles = () => {
    let entries = [];
    try {
      entries = readdirSync(receivedDir, { withFileTypes: true });
    } catch {
      return [];
    }
    const files = [];
    for (const entry of entries) {
      if (typeof entry?.isFile !== 'function' || !entry.isFile()) continue;
      const name = String(entry.name ?? '');
      if (!name || name.startsWith('.')) continue;
      try {
        const info = statSync(join(receivedDir, name));
        files.push({ name, size: info.size, updatedAt: info.mtimeMs });
      } catch {
        continue;
      }
    }
    files.sort((a, b) => b.updatedAt - a.updatedAt);
    return files.slice(0, RECEIVED_LIST_LIMIT);
  };

  const resolveReceivedFile = (name) => {
    const safe = basename(String(name ?? '').trim());
    if (!safe || safe === '.' || safe === '..' || safe.startsWith('.')) return null;
    const full = join(receivedDir, safe);
    try {
      const info = statSync(full);
      if (!info.isFile()) return null;
      return { name: safe, path: full, size: info.size };
    } catch {
      return null;
    }
  };

  const deleteReceivedFile = (name) => {
    const resolved = resolveReceivedFile(name);
    if (resolved === null) return false;
    try {
      unlinkSync(resolved.path);
      return true;
    } catch {
      return false;
    }
  };

  const server = createRelayHttpServer({
    hub,
    version: pluginVersion(),
    log,
    qrcodeAssetPath: join(bundleRoot, 'assets', 'qrcode.js'),
    appUpdate,
    liveHub,
    pageContext: {
      port,
      publicEndpoint,
      uploadDir: join(stateDir, 'uploads'),
      resolveUploadDir,
      desktopTasks: () => listDesktopTasks(),
      // M4.66：手机「功能 → 更新日志」读电脑上的 docs/UPDATE_NOTES.md。
      appNotes: () => readUpdateNoteList(projectDir),
      desktopWorkspaces: () => listDesktopWorkspaces(),
      createDesktopWorkspace,
      // M4.9：手机端「工作区」里预览图片 / PDF / Office 文件。
      readWorkspaceFileBytes,
      readDesktopFileText,
      resolveWorkspaceFile,
      desktopSessionEvents: (sessionId, options) => listDesktopSessionEvents(sessionId, options),
      // M4.10：DSH 重启后仍能在手机上看到以前跑过的会话。
      archivedSessions: () => refreshSessionArchive({ scan: true }),
      archivedSession: (sessionId) => getArchivedSession(sessionId),
      saveArchivedSession: (input) => saveArchivedSession(input),
      desktopPrompt: (sessionId, text) => promptDesktopSession(sessionId, text),
      // M4.21：排队消息（电脑端那排「N 条排队消息 / 编辑 / 删除 / 插话」）。
      desktopQueue: (sessionId) => readDesktopQueue(sessionId),
      desktopQueueUpdate: (sessionId, itemId, action, text) =>
        mutateDesktopQueue(sessionId, itemId, action, text),
      desktopApproval: (sessionId, approvalId, decision) =>
        decideDesktopApproval(sessionId, approvalId, decision),
      desktopQuestion: (sessionId, questionId, answers) =>
        answerDesktopQuestion(sessionId, questionId, answers),
      // M4.58：把「为什么答不上」的原因带给手机，而不是一律 404 question not found。
      desktopQuestionError: () => questionAnswerFailure,
      // M4.25：手机「我的」页里的账户余额（Platform 充值/赠送钱包）。
      accountBalance: () => readAccountBalance(),
      // M4.31：跨会话的「电脑在等你」摘要（手机在别的页也能弹提示）。
      desktopPending: () => listPendingDesktop(),
      // M4.57：「功能 → 接收文件」：电脑端发过来的文件列表 / 下载 / 删除。
      receivedFiles: () => listReceivedFiles(),
      receivedFile: (name) => resolveReceivedFile(name),
      deleteReceivedFile: (name) => deleteReceivedFile(name),
      // M3.5：手机端查看/启用/停用已安装插件（与电脑端「设置 → 插件」同源）。
      // M3.6：Host 返回的是 {entryId, moduleName, meta.title} 结构；这里归一化成
      // 手机能直接显示的 {id, name, enabled}，否则手机上全是空白行。
      plugins: async () => {
        const manager = ctx.get('pluginManager');
        if (!manager?.listPlugins) throw new Error('plugin manager unavailable');
        const rows = asArray(await manager.listPlugins(), 'entries', 'plugins', 'items');
        return rows
          .map((row) => {
            const moduleName = String(row?.moduleName ?? '');
            const title = row?.meta?.title;
            const localized =
              typeof title === 'string'
                ? title
                : title && typeof title === 'object'
                  ? String(title.zh ?? title.en ?? Object.values(title)[0] ?? '')
                  : '';
            const id = String(row?.entryId ?? row?.patchId ?? '');
            return {
              id,
              name: localized || moduleName || id,
              moduleName,
              enabled: row?.enabled !== false,
              phase: row?.fiberPhase ?? null,
              patchId: row?.patchId ?? null,
              readOnlyReason: row?.readOnlyReason ?? null,
            };
          })
          .filter((item) => item.id.length > 0);
      },
      setPluginEnabled: async (id, enabled) => {
        const manager = ctx.get('pluginManager');
        if (!manager?.setPluginEnabled) throw new Error('plugin manager unavailable');
        return await manager.setPluginEnabled(id, enabled);
      },
      // M3.6：Bundle（插件包）层，手机端按电脑端「设置 → 插件」的分组展示。
      pluginBundles: async () => {
        const manager = ctx.get('pluginManager');
        if (!manager?.listBundles) throw new Error('plugin manager unavailable');
        const bundles = asArray(await manager.listBundles(), 'bundles', 'entries', 'items');
        return bundles
          .map((bundle) => {
            const rows = Array.isArray(bundle?.rows) ? bundle.rows : [];
            return {
              name: String(bundle?.name ?? ''),
              version: String(bundle?.version ?? ''),
              description: String(bundle?.description ?? ''),
              enabled: bundle?.enabled !== false,
              installed: bundle?.installed !== false,
              removable: bundle?.removable !== false,
              plugins: rows
                .map((row) => ({
                  id: String(row?.entryId ?? ''),
                  name: String(row?.moduleName ?? row?.rowId ?? ''),
                  rowId: row?.rowId ?? null,
                  // Host 的 listBundles 行不保证带 enabled；没有就不显示开关。
                  enabled: typeof row?.enabled === 'boolean' ? row.enabled : null,
                }))
                .filter((row) => row.id.length > 0),
            };
          })
          .filter((bundle) => bundle.name.length > 0);
      },
      setBundleEnabled: async (name, enabled) => {
        const manager = ctx.get('pluginManager');
        if (!manager?.setBundleEnabled) throw new Error('plugin manager unavailable');
        return await manager.setBundleEnabled(name, enabled);
      },
      // M3.6：插件市场——直接复用 Host 的 pluginMarket（索引/搜索）与 pluginManager（安装/卸载）。
      pluginMarket: async (options = {}) => {
        const market = ctx.get('pluginMarket');
        const manager = ctx.get('pluginManager');
        const bundles = typeof manager?.listBundles === 'function'
          ? asArray(await manager.listBundles(), 'bundles', 'entries', 'items')
          : [];
        const installed = new Map();
        const installedBundles = [];
        for (const bundle of Array.isArray(bundles) ? bundles : []) {
          const name = String(bundle?.name ?? '');
          if (!name) continue;
          installed.set(name, bundle);
          installedBundles.push({
            name,
            version: String(bundle?.version ?? ''),
            enabled: bundle?.enabled !== false,
          });
        }
        // M4.1：Host 的 pluginMarket 索引源就是「设置 → 插件市场」里配置的那几个 URL，
        // 默认可能一个都没配（浏览器版默认只有「最近收录」，没有索引源）。没有配置时
        // 用 DSH 默认索引兜底，否则手机上永远是空的「插件市场」。
        const readIndexes = async () => {
          const raw = typeof market?.listIndexes === 'function' ? await market.listIndexes() : [];
          return asArray(raw, 'indexes', 'entries', 'items')
            .map((item) => ({
              url: String(item?.url ?? item?.indexUrl ?? item?.id ?? ''),
              title: String(item?.title ?? item?.name ?? item?.label ?? ''),
              description: String(item?.description ?? ''),
              error: typeof item?.error === 'string' && item.error ? item.error : '',
            }))
            .filter((item) => item.url.length > 0);
        };
        let indexes = await readIndexes();
        const defaultIndexUrl =
          typeof market?.defaultIndexUrl === 'function' ? String(market.defaultIndexUrl() ?? '') : '';
        let defaultIndex = false;
        if (indexes.length === 0 && defaultIndexUrl) {
          indexes = [{ url: defaultIndexUrl, title: '', description: '', error: '' }];
          defaultIndex = true;
        }
        const requestedUrl = typeof options?.url === 'string' && options.url ? options.url : '';
        const url = requestedUrl || indexes[0]?.url || '';
        const query = typeof options?.query === 'string' ? options.query.trim() : '';
        let entries = [];
        let marketError = null;
        if (url && typeof market?.search === 'function') {
          try {
            // Host 的 search(url, {query:{text,limit,offset,order}, refresh})；旧版可能是 search(url, 字符串)。
            // 兜底索引源不在「已配置」里，Host 会拒绝（unknown-index），用 refresh 让 Host 先抓取它。
            const runSearch = async (text) => {
              const first = await market.search(url, {
                query: { text, limit: 200, offset: 0 },
                ...(defaultIndex ? { refresh: true } : {}),
              });
              if (asArray(first, 'entries', 'items').length > 0 || !text) return first;
              return market.search(url, { query: { text, limit: 200, offset: 0, order: 'stars' }, refresh: false });
            };
            let result;
            try {
              result = await runSearch(query);
            } catch (firstError) {
              if (!defaultIndex) throw firstError;
              // unknown-index / fetch-failed：再去要一次 refresh（索引被 Host 丢弃或过期）。
              result = await market.search(url, { query: { text: query, limit: 200, offset: 0 }, refresh: true });
            }
            const raw = asArray(result, 'entries', 'items', 'plugins');
            entries = raw.map((entry) => {
              const name = String(entry?.name ?? entry?.id ?? '');
              const hit = installed.get(name);
              const meta = entry?.meta && typeof entry.meta === 'object' ? entry.meta : {};
              const title = entry?.title ?? entry?.displayName ?? entry?.name ?? name;
              const localized =
                typeof title === 'string'
                  ? title
                  : title && typeof title === 'object'
                    ? String(title.zh ?? title.en ?? Object.values(title)[0] ?? name)
                    : name;
              return {
                name,
                title: localized,
                version: String(entry?.version ?? entry?.latestVersion ?? meta.version ?? ''),
                description: String(entry?.description ?? entry?.summary ?? meta.description ?? ''),
                author: String(entry?.author ?? entry?.publisher ?? meta.author ?? ''),
                tags: Array.isArray(entry?.tags)
                  ? entry.tags.map(String).slice(0, 6)
                  : Array.isArray(meta.keywords)
                    ? meta.keywords.map(String).slice(0, 6)
                    : [],
                installed: Boolean(hit) || entry?.installed === true,
                installedVersion: hit ? String(hit.version ?? '') : '',
                // M4.1：电脑端市场卡片上的下载量/星标（没有就留空，手机端不显示）。
                downloads: Number(entry?.downloads ?? entry?.downloadCount ?? entry?.meta?.downloads) || 0,
                stars: Number(entry?.stars ?? entry?.starsCount ?? entry?.github?.stars) || 0,
              };
            });
          } catch (error) {
            marketError = String(error?.message ?? error);
          }
        }
        return { indexes, source: url || null, query, entries, installedBundles, error: marketError, defaultIndex };
      },
      // M4.18：插件市场与电脑端同步。
      //
      // 以前的「市场」只读 `pluginMarket.listIndexes()`（也就是「设置 → 插件市场」里
      // 手动加的那几个第三方索引）。这台电脑一个索引都没配，手机上就永远是空的——
      // 而电脑端自己的插件市场明明有四十多个插件包。现在直接把
      // `pluginManager.listBundles()` 的目录交给手机：官方目录、可安装版本、
      // 是否已安装/已启用，全都是电脑端此刻看到的同一份数据。
      pluginCatalog: async (options = {}) => {
        const manager = ctx.get('pluginManager');
        if (!manager || typeof manager.listBundles !== 'function') {
          return { supported: false, bundles: [] };
        }
        const language = String(options?.language ?? 'zh-CN');
        const rows = await manager.listBundles();
        const bundles = asArray(rows).map((bundle) => {
          const meta = bundle?.meta && typeof bundle.meta === 'object' ? bundle.meta : {};
          const target = bundle?.installTarget && typeof bundle.installTarget === 'object'
            ? bundle.installTarget
            : {};
          return {
            name: String(bundle?.name ?? ''),
            title: localizedMetaText(meta, 'name', language),
            description:
              localizedMetaText(meta, 'description', language) ||
              String(bundle?.description ?? ''),
            official: bundle?.official === true,
            availability: String(bundle?.availability ?? ''),
            // 装的时候要用「包名@精确版本」，只用包名会在电脑端重新解析一遍版本。
            spec: String(target.spec ?? bundle?.name ?? ''),
            version: String(target.version ?? bundle?.version ?? ''),
            installed: bundle?.installed === true,
            enabled: bundle?.enabled === true,
            optional: bundle?.optional === true,
            removable: bundle?.removable === true,
            updatable: bundle?.updatable === true,
            listedByDefault: bundle?.listedByDefault !== false,
            source: String(bundle?.source ?? ''),
          };
        }).filter((bundle) => bundle.name.length > 0);
        return { supported: true, language, bundles };
      },
      // M4.1：手机「浏览本地插件」——Host pluginManager 已装插件按「内置配置 / 实验性 / 其他」分组，
      // 每行带名称、说明、启用状态（对应电脑端「设置 → 插件」的画廊卡片）。
      pluginGallery: async () => {
        const manager = ctx.get('pluginManager');
        if (!manager?.listPlugins) throw new Error('plugin manager unavailable');
        const rows = asArray(await manager.listPlugins(), 'entries', 'plugins', 'items');
        const localized = (value) => {
          if (typeof value === 'string') return value.trim();
          if (value && typeof value === 'object') {
            return String(value.zh ?? value.en ?? Object.values(value).find((item) => typeof item === 'string') ?? '');
          }
          return '';
        };
        const groups = [
          { key: 'builtin', title: '内置插件配置' },
          { key: 'experimental', title: '实验性插件' },
          { key: 'other', title: '其他插件' },
        ];
        const buckets = new Map(groups.map((group) => [group.key, []]));
        for (const row of Array.isArray(rows) ? rows : []) {
          const moduleName = String(row?.moduleName ?? '');
          const meta = row?.meta && typeof row.meta === 'object' ? row.meta : {};
          const id = String(row?.entryId ?? row?.patchId ?? moduleName);
          const name = localized(meta.title) || moduleName || id;
          if (!name) continue;
          const experimental = meta.experimental === true || /experimental/.test(moduleName);
          const builtin = /^(?:@deepseek-ai\/)?dsh-(?:ui-|client-ui-|agent-|permission|sandbox|tool-|web-|base|core)/.test(moduleName)
            && !experimental;
          const key = experimental ? 'experimental' : builtin ? 'builtin' : 'other';
          buckets.get(key).push({
            id,
            name,
            description: localized(meta.description),
            experimental,
            enabled: row?.enabled !== false,
            configurable: Boolean(manager?.listSettings) || row?.hasConfig === true,
            version: String(row?.version ?? meta.version ?? ''),
          });
        }
        const sorted = [];
        for (const group of groups) {
          const items = buckets.get(group.key);
          if (!items.length) continue;
          items.sort((a, b) => a.name.localeCompare(b.name));
          sorted.push({ key: group.key, title: group.title, plugins: items });
        }
        return { groups: sorted, total: sorted.reduce((sum, group) => sum + group.plugins.length, 0) };
      },
      installPlugin: async (spec, options = {}) => {
        const manager = ctx.get('pluginManager');
        if (!manager?.installBundle) throw new Error('plugin manager unavailable');
        return await manager.installBundle(spec, options);
      },
      removePlugin: async (name) => {
        const manager = ctx.get('pluginManager');
        if (!manager?.removeBundle) throw new Error('plugin manager unavailable');
        return await manager.removeBundle(name);
      },
      debugSession: () => {
        const first = ctx.get('sessions')?.list?.()[0];
        if (!first) return { error: 'no session' };
        return {
          keys: Object.keys(first),
          protoKeys: Object.getOwnPropertyNames(Object.getPrototypeOf(first)),
          headerKeys: first.header ? Object.keys(first.header) : null,
          header: first.header ?? null,
          eventsType: typeof first.events,
          eventsLength: first.events?.length ?? null,
          lastSeq: first.lastSeq ?? first.seq ?? null,
          logKeys: first.log ? Object.keys(first.log).length : null,
          logProto: first.log ? Object.getOwnPropertyNames(Object.getPrototypeOf(first.log)).slice(0, 6) : null,
          logLength: first.log?.length ?? null,
          logTail: (() => {
            try {
              const arr = Array.isArray(first.log) ? first.log : null;
              if (!arr) return null;
              return arr.slice(-6).map((e) => ({
                seq: e?.seq ?? null,
                type: e?.type ?? null,
                topKeys: Object.keys(e ?? {}),
                payloadKeys: e?.payload ? Object.keys(e.payload) : null,
              }));
            } catch (error) {
              return String(error);
            }
          })(),
          assistantParts: (() => {
            try {
              const arr = Array.isArray(first.log) ? first.log : [];
              const event = [...arr].reverse().find((item) => item?.type === 'assistant/message');
              const content = event?.data?.message?.content;
              if (!Array.isArray(content)) return null;
              return content.map((part) => ({
                type: part?.type ?? null,
                keys: part && typeof part === 'object' ? Object.keys(part) : [],
                textHead: typeof part?.text === 'string' ? part.text.slice(0, 60) : null,
              }));
            } catch (error) {
              return String(error);
            }
          })(),
          logSamples: (() => {
            try {
              const arr = Array.isArray(first.log) ? first.log : [];
              const counts = new Map();
              for (const event of arr) counts.set(event?.type, (counts.get(event?.type) ?? 0) + 1);
              const wanted = [
                'user/message',
                'assistant/message',
                'tool/call',
                'tool/call/start',
                'tool/result',
                'approval/request',
                'approval/requested',
                'permission/request',
                'turn/start',
                'turn/end',
                'step/start',
              ];
              const out = [];
              for (const type of wanted) {
                if (!counts.has(type)) continue;
                const event = [...arr].reverse().find((item) => item?.type === type);
                out.push({
                  type,
                  count: counts.get(type),
                  dataKeys: event?.data ? Object.keys(event.data) : null,
                  sample: safePreview(event?.data),
                });
              }
              return {
                counts: [...counts.entries()].sort((a, b) => b[1] - a[1]).slice(0, 40),
                wanted: out,
              };
            } catch (error) {
              return String(error);
            }
          })(),
        };
      },
      rotatePairingCode: () => {
        const next = newPairingCode();
        hub.setPairingCode(next);
        writePairingCode(stateDir, next);
        log(`匹配码已更换：${next}`);
        return next;
      },
    },
  });

  let supervisor = null;
  let closed = false;

  const shutdown = () => {
    if (closed) return;
    closed = true;
    stopSessionArchive();
    supervisor?.stop();
    try {
      publicEndpoint.stop();
    } catch {
      /* 隧道可能没起来 */
    }
    hub.dispose();
    try {
      server.close();
    } catch {
      /* already closed */
    }
  };

  ctx.effect(() => {
    server.on('upgrade', (request, socket, head) => {
      void head;
      // M4.62：直播推送那条已经由 liveHub 握过手了，别再握一次。
      if (request.__m1Live) return;
      hub.acceptUpgrade(request, socket);
    });
    server.on('error', (error) => {
      log(`中继监听失败（${host}:${port}）：${error?.message ?? error}`);
    });
    server.listen(port, host, () => {
      const urls = lanAddresses()
        .filter((item) => !item.virtual)
        .map((item) => `http://${item.address}:${port}`);
      log(`M1 中继已启动：http://127.0.0.1:${port}  匹配码 ${pairingCode}`);
      log(`授权目录：${workspaceRootsNow().join('  ')}`);
      if (urls.length > 0) log(`手机可用地址：${urls.join('  ')}`);
      log(`配网页（含二维码）：http://127.0.0.1:${port}/`);
      const updateInfo = appUpdate.versionPayload();
      if (updateInfo) {
        log(`应用内更新：v${updateInfo.versionName} (${updateInfo.versionCode}) · ${(updateInfo.size / 1048576).toFixed(1)} MB`);
      } else {
        log('应用内更新：未找到 APK（可用 appApkPath 指定，或把 APK 放到 dist/）');
      }
      // 本地监听就绪后再起隧道，免得 cloudflared 连到还没起来的端口。
      try {
        publicEndpoint.start();
      } catch (error) {
        log(`公网隧道启动失败：${error?.message ?? error}`);
      }
    });

    if (config.autoStartAgent !== false) {
      if (!existsSync(entry)) {
        log(`找不到 Agent 入口：${entry}（可用 config.agentDir 指向项目里的 agent 目录）`);
      } else {
        supervisor = new AgentSupervisor({
          entry,
          cwd: workspaceRootsNow()[0],
          serverUrl: `http://127.0.0.1:${port}`,
          pairingCode,
          workspaceRoots: workspaceRootsNow(),
          deviceName: typeof config.deviceName === 'string' && config.deviceName ? config.deviceName : DEFAULT_DEVICE_NAME,
          nodePath: config.nodePath,
          // M4.49：agent 要用 `dsh --profile acp`，便携版得有人告诉它装在哪儿。
          dshInstallRoot: resolveDshInstallRoot(),
          // M4.43：agent 复用 token，避免每次重启都 pair 出新的一条（token 只增不减）。
          tokenFilePath: join(stateDir, 'agent-token.json'),
          log,
        });
        supervisor.start();
      }
    }

    // M4.10：会话存档立刻起跑（先把当前会话和 DSH 磁盘上已消失的会话收进来）。
    try {
      startSessionArchive();
    } catch (error) {
      log(`会话存档启动失败：${error?.message ?? error}`);
    }

    return shutdown;
  }, 'dsh-plugin-m1.relay');

  // 供其它插件 / 控制台排查：暴露只读状态
  try {
    ctx.set?.('m1Relay', {
      status: () => ({
        port,
        pairingCode,
        agentOnline: hub.agentOnline,
        apps: hub.appCount,
        publicAccess: publicEndpoint.status?.() ?? null,
        appUpdate: appUpdate.versionPayload(),
        supervisor: supervisor?.status() ?? null,
      }),
    });
  } catch {
    /* 老版本 ctx 没有 set 就算了 */
  }

  // 设置页数据口：client 半和 Host 同源，避免再开一个端口或处理 CORS。
  const statusPayload = () => {
    const update = appUpdate.versionPayload();
    const code = hub.pairingCode;
    const lanUrls = lanAddresses()
      .filter((item) => !item.virtual)
      .map((item) => `http://${item.address}:${port}`);
    const publicUrl = publicEndpoint.status?.()?.url ?? null;
    // Tailscale 固定地址优先：手机在任何网络下都能用同一个地址连回来。
    const tailnetUrls = lanUrls.filter((url) => /\/\/100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\./.test(url));
    const qrFor = (base) => {
      if (!base) return null;
      const target = `${base}#c=${encodeURIComponent(code)}`;
      return { url: target, svg: qrSvg(target) };
    };
    return {
      ok: true,
      pluginVersion: pluginVersion(),
      port,
      pairingCode: code,
      deviceName:
        typeof config.deviceName === 'string' && config.deviceName ? config.deviceName : DEFAULT_DEVICE_NAME,
      lanUrls,
      tailnetUrls,
      publicUrl,
      qr: { tailnet: qrFor(tailnetUrls[0]), lan: qrFor(lanUrls.find((u) => !tailnetUrls.includes(u))), public: qrFor(publicUrl) },
      agentOnline: hub.agentOnline,
      apps: hub.appCount,
      workspaces: workspaceRootsNow(),
      appUpdate: update
        ? { versionCode: update.versionCode, versionName: update.versionName, size: update.size }
        : null,
    };
  };

  //
  // `ctx.get('webServer')` 在 apply 时往往是 undefined：插件先于浏览器半启动，
  // 直接读会静默跳过注册（重启后设置页就只剩「中继未运行」）。用 inject 等到
  // 服务真正可用再挂路由，服务被替换时也会重新挂。
  ctx.inject(['webServer'], (scoped) => {
    const webServer = scoped.webServer;
    if (!webServer?.register) return;
    scoped.effect(
      () =>
        webServer.register({
          kind: 'exact',
          path: '/deepseek-remote/api/status',
          handler: (request, response) => {
            void request;
            const body = JSON.stringify(statusPayload());
            response.writeHead(200, {
              'content-type': 'application/json; charset=utf-8',
              'cache-control': 'no-store',
              'content-length': Buffer.byteLength(body),
            });
            response.end(body);
          },
        }),
      'dsh-plugin-m1.status-route',
    );
    log('设置页状态口已挂载：/deepseek-remote/api/status');
  });
}
