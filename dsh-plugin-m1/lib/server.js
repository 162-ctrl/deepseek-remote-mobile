// M1 中继的 HTTP 面：健康检查、配对、以及配网页（局域网 + 公网双二维码 + 匹配码）。
import { createServer } from 'node:http';
import { readFileSync } from 'node:fs';
import { mkdir, writeFile } from 'node:fs/promises';
import { basename, join } from 'node:path';
import { networkInterfaces } from 'node:os';
import { gzipSync } from 'node:zlib';
import { HubError } from './hub.js';
import { LIVE_PATH } from './live-hub.js';

const MAX_BODY_BYTES = 64 * 1024;

/** 手机上传附件（照片/文档）的大小上限。 */
const MAX_UPLOAD_BYTES = 20 * 1024 * 1024;

/** 配对失败限流：60s 内 5 次失败就锁 60s（公网暴露时挡暴力猜 6 位码）。 */
const WINDOW_MS = 60_000;
const MAX_FAILURES = 5;

/**
 * 判断一个 IPv4 属于哪类网络。
 *
 * - `tailscale`：`100.64.0.0/10`（Tailscale 给的固定地址，跨网络也能用）；
 * - `virtual`：VMware / VirtualBox / Hyper-V / WSL 这类网卡，手机连不上；
 * - `lan`：普通局域网。
 */
export function classifyAddress(address, name = '') {
  if (/^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\./.test(address)) return 'tailscale';
  if (/vmware|virtualbox|vethernet|wsl|loopback/i.test(String(name))) return 'virtual';
  return 'lan';
}

/** 本机所有可用于手机连接的 IPv4（排除回环与链路本地）。 */
export function lanAddresses() {
  const list = [];
  const interfaces = networkInterfaces();
  for (const [name, entries] of Object.entries(interfaces)) {
    for (const entry of entries ?? []) {
      if (entry.family !== 'IPv4' || entry.internal) continue;
      if (/^169\.254\./.test(entry.address)) continue;
      const kind = classifyAddress(entry.address, name);
      list.push({ name, address: entry.address, kind, virtual: kind === 'virtual' });
    }
  }
  // 优先级：Tailscale（跨网络固定地址）→ 普通局域网 → 虚拟网卡
  const rank = (item) => (item.kind === 'tailscale' ? 0 : item.kind === 'virtual' ? 2 : 1);
  list.sort((a, b) => rank(a) - rank(b));
  return list;
}

function readJsonBody(request, maxBytes = MAX_BODY_BYTES) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    request.on('data', (chunk) => {
      size += chunk.length;
      if (size > maxBytes) {
        reject(new HubError('BAD_REQUEST', 'body too large', 400));
        request.destroy();
        return;
      }
      chunks.push(chunk);
    });
    request.on('end', () => {
      if (chunks.length === 0) {
        resolve(null);
        return;
      }
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString('utf8')));
      } catch {
        reject(new HubError('BAD_REQUEST', 'invalid json', 400));
      }
    });
    request.on('error', reject);
  });
}

// M4.43（指令第 7 条）：大响应按需 gzip。
//
// 会话直播首屏实测 175~253 KB 明文，走隧道往返 1~2.4 秒，是「经常连接超时」
// 的主因之一。只压 ≥4 KB 的响应——几百字节的东西 gzip 后可能更大，白烧 CPU。
// `request` 是可选尾参，不传就是老行为（其余 30 来个调用点不用改）。
const GZIP_MIN_BYTES = 4096;

function sendJson(response, status, payload, extraHeaders = {}, request = null) {
  let body = Buffer.from(JSON.stringify(payload), 'utf8');
  const acceptEncoding = request?.headers?.['accept-encoding'];
  const acceptsGzip =
    typeof acceptEncoding === 'string' && acceptEncoding.includes('gzip');
  if (acceptsGzip && body.length >= GZIP_MIN_BYTES) {
    const zipped = gzipSync(body, { level: 6 });
    if (zipped.length < body.length) {
      body = zipped;
      response.writeHead(status, {
        'content-type': 'application/json; charset=utf-8',
        'content-length': body.length,
        'content-encoding': 'gzip',
        vary: 'accept-encoding',
        'cache-control': 'no-store',
        ...extraHeaders,
      });
      response.end(body);
      return;
    }
  }
  response.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': body.length,
    'cache-control': 'no-store',
    ...extraHeaders,
  });
  response.end(body);
}

/** 公网请求经过 cloudflared 转发，真实来源在 CF-Connecting-IP 里。 */
function clientIp(request) {
  const header = request.headers['cf-connecting-ip'];
  const fromHeader = Array.isArray(header) ? header[0] : header;
  if (typeof fromHeader === 'string' && fromHeader.trim().length > 0) return fromHeader.trim();
  const forwarded = request.headers['x-forwarded-for'];
  const fromForwarded = Array.isArray(forwarded) ? forwarded[0] : forwarded;
  if (typeof fromForwarded === 'string' && fromForwarded.trim().length > 0) return fromForwarded.split(',')[0].trim();
  return request.socket.remoteAddress ?? 'unknown';
}

/**
 * 配网页会显示匹配码，只能在本机看。
 * 公网/LAN 进来的请求（带 CF-Connecting-IP 或来自非回环地址）一律不给看。
 */
function isLocalRequest(request) {
  const ip = clientIp(request);
  if (ip === '127.0.0.1' || ip === '::1' || ip === '::ffff:127.0.0.1') return true;
  const raw = request.socket.remoteAddress ?? '';
  return (raw === '127.0.0.1' || raw === '::1' || raw === '::ffff:127.0.0.1') && !request.headers['cf-connecting-ip'];
}

export function createRelayHttpServer({ hub, version, log = () => {}, qrcodeAssetPath, pageContext, appUpdate = null, liveHub = null }) {
  const asset = qrcodeAssetPath ? readFileSync(qrcodeAssetPath) : null;
  const failures = new Map();

  const publicStatus = () => {
    const status = pageContext?.publicEndpoint?.status?.() ?? null;
    return status ?? { enabled: false, running: false, url: null, error: null };
  };

  const pairInfo = () => {
    const port = pageContext.port;
    const addresses = lanAddresses();
    const toUrl = (item) => `http://${item.address}:${port}`;
    const lanUrls = addresses.map(toUrl);
    const tailscaleUrls = addresses.filter((item) => item.kind === 'tailscale').map(toUrl);
    const publicUrl = publicStatus().url ?? null;
    return {
      pairingCode: hub.pairingCode,
      urls: lanUrls,
      lanUrls,
      // M4.74：Tailscale 给的 100.64/10 地址单独列出来——跨网络时它比公网隧道更快，也不依赖 cloudflared。
      tailscaleUrls,
      publicUrl,
      publicUrls: publicUrl ? [publicUrl] : [],
      tunnel: publicStatus(),
      agentOnline: hub.agentOnline,
      version,
    };
  };

  function limitState(ip) {
    const now = Date.now();
    const entry = failures.get(ip);
    if (!entry) return { blocked: false };
    if (entry.blockedUntil && now < entry.blockedUntil) {
      return { blocked: true, retryAfterSeconds: Math.ceil((entry.blockedUntil - now) / 1000) };
    }
    if (now - entry.windowStart > WINDOW_MS) {
      failures.delete(ip);
      return { blocked: false };
    }
    return { blocked: false };
  }

  function noteFailure(ip) {
    const now = Date.now();
    const entry = failures.get(ip) ?? { windowStart: now, count: 0, blockedUntil: 0 };
    if (now - entry.windowStart > WINDOW_MS) {
      entry.windowStart = now;
      entry.count = 0;
      entry.blockedUntil = 0;
    }
    entry.count += 1;
    if (entry.count >= MAX_FAILURES) entry.blockedUntil = now + WINDOW_MS;
    failures.set(ip, entry);
  }

  const server = createServer((request, response) => {
    handle(request, response).catch((error) => {
      log(`http error ${request.method} ${request.url}: ${error?.message ?? error}`);
      if (response.headersSent) {
        response.end();
        return;
      }
      // readJsonBody 抛的是 HubError（BAD_REQUEST / 400）。以前各路由在 try 之外 await 它，
      // 异常直接冒到这里被一律当 500，客户端拿到「服务器内部错误」，其实只是请求体写坏了。
      // 这里按 HubError 自己的状态码回，路由内部无需逐个改。
      if (error instanceof HubError) {
        sendJson(response, error.status ?? 400, {
          code: error.code ?? 'BAD_REQUEST',
          message: String(error.message ?? error),
        });
        return;
      }
      sendJson(response, 500, { code: 'INTERNAL', message: 'internal error' });
    });
  });

  // M4.62：手机直播页订阅 `/api/v1/desktop/live`，插件把 DSH 远程事件里的会话活动
  // 直接推下来，省掉轮询等待。鉴权用 query 里的 app token（WebSocket 带不了自定义头）。
  // 注意：同一个 server 上还挂着中继自己的 upgrade（`/ws?role=app|agent`），
  // 这里只接自己那条路径，其它一律放行给后面的监听器。
  server.on('upgrade', (request, socket) => {
    const url = new URL(request.url ?? '/', 'http://localhost');
    if (url.pathname !== LIVE_PATH || !liveHub) return;
    // 标记一下，让中继自己的 upgrade 监听器跳过这条（否则同一个 socket 会被握手两次）。
    request.__m1Live = true;
    liveHub.handleUpgrade(request, socket);
  });

  async function handle(request, response) {
    const url = new URL(request.url ?? '/', 'http://localhost');
    const path = url.pathname;

    if (request.method === 'GET' && (path === '/api/v1/health' || path === '/health')) {
      const info = pairInfo();
      sendJson(response, 200, {
        status: 'ok',
        version,
        agentOnline: hub.agentOnline,
        apps: hub.appCount,
        publicUrl: info.publicUrl,
        live: liveHub?.size ?? 0,
        liveSent: liveHub?.sent ?? 0,
      });
      return;
    }

    if (request.method === 'POST' && path === '/api/v1/auth/pair') {
      const ip = clientIp(request);
      const limit = limitState(ip);
      if (limit.blocked) {
        sendJson(
          response,
          429,
          { code: 'TOO_MANY_ATTEMPTS', message: `配对尝试过多，请 ${limit.retryAfterSeconds}s 后再试` },
          { 'retry-after': String(limit.retryAfterSeconds) },
        );
        return;
      }
      const body = await readJsonBody(request);
      if (body === null || typeof body !== 'object') {
        sendJson(response, 400, { code: 'BAD_REQUEST', message: 'body required' });
        return;
      }
      try {
        const result = hub.pair({
          pairingCode: typeof body.pairingCode === 'string' ? body.pairingCode : '',
          clientName: body.clientName,
          role: body.role,
        });
        failures.delete(ip);
        sendJson(response, 200, result);
      } catch (error) {
        if (error instanceof HubError) {
          noteFailure(ip);
          sendJson(response, error.status, { code: error.code, message: error.message });
          return;
        }
        throw error;
      }
      return;
    }

    if (request.method === 'POST' && path === '/api/v1/auth/revoke') {
      // M4.43：主动撤销。能拿出这个 token 本身就有权撤销它，不再额外鉴权。
      const header = request.headers.authorization ?? '';
      const revokeToken = header.startsWith('Bearer ') ? header.slice(7) : '';
      if (!hub.revokeToken(revokeToken)) {
        sendJson(response, 404, { code: 'TOKEN_NOT_FOUND', message: 'token not found' });
        return;
      }
      sendJson(response, 200, { ok: true });
      return;
    }

    if (request.method === 'GET' && path === '/api/v1/pair/info') {
      if (!isLocalRequest(request)) {
        // 公网/局域网访问者不该看到匹配码；只给非敏感的状态。
        sendJson(response, 200, {
          urls: [],
          publicUrl: publicStatus().url ?? null,
          agentOnline: hub.agentOnline,
          version,
          restricted: true,
        });
        return;
      }
      sendJson(response, 200, pairInfo());
      return;
    }

    if (request.method === 'POST' && path === '/api/v1/pair/rotate') {
      const ip = clientIp(request);
      // 换码只允许本机或已连上的设备点，避免公网随便把别人的码换掉。
      const local = ip === '127.0.0.1' || ip === '::1' || ip === '::ffff:127.0.0.1';
      if (!local && hub.appCount === 0) {
        sendJson(response, 403, { code: 'AUTH_FAILED', message: '只允许本机换码' });
        return;
      }
      const next = pageContext.rotatePairingCode();
      sendJson(response, 200, { pairingCode: next });
      return;
    }

    if (request.method === 'GET' && path === '/assets/qrcode.js') {
      if (asset === null) {
        response.writeHead(404).end();
        return;
      }
      response.writeHead(200, {
        'content-type': 'application/javascript; charset=utf-8',
        'content-length': asset.length,
        'cache-control': 'public, max-age=86400',
      });
      response.end(asset);
      return;
    }

    if (request.method === 'GET' && path === '/api/v1/desktop/_debug' && isLocalRequest(request)) {
      sendJson(response, 200, pageContext.debugSession?.() ?? {});
      return;
    }

    const sessionEventsMatch =
      request.method === 'GET' ? path.match(/^\/api\/v1\/desktop\/sessions\/([^/]+)\/events$/) : null;
    if (sessionEventsMatch) {
      // M2.9.3：桌面会话直播流（只读）——手机用来「看着电脑在干活」。
      const header = request.headers.authorization ?? '';
      const token = header.startsWith('Bearer ')
        ? header.slice(7)
        : (url.searchParams.get('token') ?? '');
      if (!hub.authorizeToken(token)) {
        sendJson(response, 401, { code: 'AUTH_FAILED', message: 'unauthorized' });
        return;
      }
      const sessionId = decodeURIComponent(sessionEventsMatch[1]);
      // M4.43：非法 afterSeq/limit 不能静默降级成「没传」——那样会把一整包
      // 最多 600 条事件（弱网实测 253 KB）回给以为自己在做增量补齐的调用方。
      const rawAfterSeq = url.searchParams.get('afterSeq');
      let afterSeq;
      if (rawAfterSeq !== null) {
        const parsed = Number(rawAfterSeq);
        if (!Number.isInteger(parsed) || parsed < 0) {
          sendJson(response, 400, {
            code: 'BAD_REQUEST',
            message: `afterSeq 必须是非负整数，收到：${rawAfterSeq}`,
          });
          return;
        }
        afterSeq = parsed;
      }
      const rawLimit = url.searchParams.get('limit');
      let limit = 80;
      if (rawLimit !== null) {
        const parsed = Number(rawLimit);
        if (!Number.isInteger(parsed) || parsed <= 0) {
          sendJson(response, 400, {
            code: 'BAD_REQUEST',
            message: `limit 必须是正整数，收到：${rawLimit}`,
          });
          return;
        }
        limit = Math.min(parsed, 600);
      }
      const feed =
        typeof pageContext.desktopSessionEvents === 'function'
          ? pageContext.desktopSessionEvents(sessionId, { afterSeq, limit })
          : null;
      if (!feed) {
        sendJson(response, 404, { code: 'SESSION_NOT_FOUND', message: 'session not found' });
        return;
      }
      // M4.43（指令第 7 条）：几百 KB 的 live feed 走 gzip，压完通常只剩 1/3。
      sendJson(response, 200, feed, {}, request);
      return;
    }

    if (request.method === 'GET' && path === '/api/v1/desktop/plugins') {
      // M3.5：已安装插件清单（手机端「插件」页）。
      const authHeader = request.headers.authorization ?? '';
      const token = authHeader.startsWith('Bearer ')
        ? authHeader.slice(7)
        : (url.searchParams.get('token') ?? '');
      if (!hub.authorizeToken(token)) {
        sendJson(response, 401, { code: 'AUTH_FAILED', message: 'unauthorized' });
        return;
      }
      try {
        const plugins = await pageContext.plugins();
        sendJson(response, 200, { plugins });
      } catch (error) {
        sendJson(response, 501, {
          code: 'PLUGIN_MANAGER_UNAVAILABLE',
          message: String(error?.message ?? error),
        });
      }
      return;
    }

    if (request.method === 'POST' && path === '/api/v1/desktop/workspaces') {
      // M4：手机端新建工作区。M4.13 起可带 `parentDir`，指定建在哪个父目录下
      // （手机端固定用「项目根」，如 <项目根>）。
      const authHeader = request.headers.authorization ?? '';
      const token = authHeader.startsWith('Bearer ')
        ? authHeader.slice(7)
        : (url.searchParams.get('token') ?? '');
      if (!hub.authorizeToken(token)) {
        sendJson(response, 401, { code: 'AUTH_FAILED', message: 'unauthorized' });
        return;
      }
      const body = await readJsonBody(request);
      const parentDir = typeof body?.parentDir === 'string' ? body.parentDir : '';
      try {
        const created = await pageContext.createDesktopWorkspace(body?.name, parentDir);
        sendJson(response, 200, { ok: true, ...(created ?? {}) });
      } catch (error) {
        sendJson(response, 400, {
          code: 'WORKSPACE_CREATE_FAILED',
          message: String(error?.message ?? error),
        });
      }
      return;
    }

    if (request.method === 'POST' && path === '/api/v1/desktop/plugins/enabled') {
      // M3.5：手机端开关插件（PC 端会按 HMR 规则重载）。
      const authHeader = request.headers.authorization ?? '';
      const token = authHeader.startsWith('Bearer ')
        ? authHeader.slice(7)
        : (url.searchParams.get('token') ?? '');
      if (!hub.authorizeToken(token)) {
        sendJson(response, 401, { code: 'AUTH_FAILED', message: 'unauthorized' });
        return;
      }
      const body = await readJsonBody(request);
      const id = typeof body?.id === 'string' ? body.id : '';
      if (!id || typeof body?.enabled !== 'boolean') {
        sendJson(response, 400, { code: 'BAD_REQUEST', message: 'id 与 enabled 必填' });
        return;
      }
      try {
        const result = await pageContext.setPluginEnabled(id, body.enabled);
        sendJson(response, 200, { ok: true, ...(result ?? {}) });
      } catch (error) {
        sendJson(response, 400, {
          code: 'PLUGIN_TOGGLE_FAILED',
          message: String(error?.message ?? error),
        });
      }
      return;
    }

    if (request.method === 'GET' && path === '/api/v1/desktop/plugins/bundles') {
      // M3.6：插件包（bundle）清单——电脑端「设置 → 插件」的分组层级。
      const authHeader = request.headers.authorization ?? '';
      const token = authHeader.startsWith('Bearer ')
        ? authHeader.slice(7)
        : (url.searchParams.get('token') ?? '');
      if (!hub.authorizeToken(token)) {
        sendJson(response, 401, { code: 'AUTH_FAILED', message: 'unauthorized' });
        return;
      }
      try {
        const bundles = await pageContext.pluginBundles();
        sendJson(response, 200, { bundles: Array.isArray(bundles) ? bundles : [] });
      } catch (error) {
        sendJson(response, 501, {
          code: 'PLUGIN_MANAGER_UNAVAILABLE',
          message: String(error?.message ?? error),
        });
      }
      return;
    }

    if (request.method === 'POST' && path === '/api/v1/desktop/plugins/bundles/enabled') {
      const authHeader = request.headers.authorization ?? '';
      const token = authHeader.startsWith('Bearer ')
        ? authHeader.slice(7)
        : (url.searchParams.get('token') ?? '');
      if (!hub.authorizeToken(token)) {
        sendJson(response, 401, { code: 'AUTH_FAILED', message: 'unauthorized' });
        return;
      }
      const body = await readJsonBody(request);
      const bundleName = typeof body?.name === 'string' ? body.name : '';
      if (!bundleName || typeof body?.enabled !== 'boolean') {
        sendJson(response, 400, { code: 'BAD_REQUEST', message: 'name 与 enabled 必填' });
        return;
      }
      try {
        const result = await pageContext.setBundleEnabled(bundleName, body.enabled);
        sendJson(response, 200, { ok: true, ...(result ?? {}) });
      } catch (error) {
        sendJson(response, 400, {
          code: 'PLUGIN_BUNDLE_TOGGLE_FAILED',
          message: String(error?.message ?? error),
        });
      }
      return;
    }

    if (request.method === 'GET' && path === '/api/v1/desktop/plugins/gallery') {
      // M4.1：手机「浏览本地插件」——内置配置 / 实验性 / 其他 分组 + 启用开关。
      const authHeader = request.headers.authorization ?? '';
      const token = authHeader.startsWith('Bearer ')
        ? authHeader.slice(7)
        : (url.searchParams.get('token') ?? '');
      if (!hub.authorizeToken(token)) {
        sendJson(response, 401, { code: 'AUTH_FAILED', message: 'unauthorized' });
        return;
      }
      try {
        const data = await pageContext.pluginGallery();
        sendJson(response, 200, data ?? {});
      } catch (error) {
        sendJson(response, 501, {
          code: 'PLUGIN_GALLERY_UNAVAILABLE',
          message: String(error?.message ?? error),
        });
      }
      return;
    }

    if (request.method === 'GET' && path === '/api/v1/desktop/plugins/market') {
      // M3.6：插件市场（Host pluginMarket 索引 + 搜索）。
      const authHeader = request.headers.authorization ?? '';
      const token = authHeader.startsWith('Bearer ')
        ? authHeader.slice(7)
        : (url.searchParams.get('token') ?? '');
      if (!hub.authorizeToken(token)) {
        sendJson(response, 401, { code: 'AUTH_FAILED', message: 'unauthorized' });
        return;
      }
      try {
        const data = await pageContext.pluginMarket({
          url: url.searchParams.get('url') ?? '',
          query: url.searchParams.get('query') ?? '',
        });
        sendJson(response, 200, data ?? {});
      } catch (error) {
        sendJson(response, 501, {
          code: 'PLUGIN_MARKET_UNAVAILABLE',
          message: String(error?.message ?? error),
        });
      }
      return;
    }

    if (request.method === 'GET' && path === '/api/v1/desktop/plugins/catalog') {
      // M4.18：电脑端插件市场目录（pluginManager.listBundles()）。手机显示的就是
      // 电脑上同一份「可安装 / 已安装」清单，不再依赖「设置 → 插件市场」里手配的
      // 第三方索引——这台电脑一个索引都没配，旧接口因此永远返回空。
      const authHeader = request.headers.authorization ?? '';
      const token = authHeader.startsWith('Bearer ')
        ? authHeader.slice(7)
        : (url.searchParams.get('token') ?? '');
      if (!hub.authorizeToken(token)) {
        sendJson(response, 401, { code: 'AUTH_FAILED', message: 'unauthorized' });
        return;
      }
      try {
        const data = await pageContext.pluginCatalog({
          language: url.searchParams.get('language') ?? 'zh-CN',
        });
        sendJson(response, 200, data ?? { supported: false, bundles: [] });
      } catch (error) {
        sendJson(response, 501, {
          code: 'PLUGIN_CATALOG_UNAVAILABLE',
          message: String(error?.message ?? error),
        });
      }
      return;
    }

    if (request.method === 'POST' && path === '/api/v1/desktop/plugins/market/install') {
      const authHeader = request.headers.authorization ?? '';
      const token = authHeader.startsWith('Bearer ')
        ? authHeader.slice(7)
        : (url.searchParams.get('token') ?? '');
      if (!hub.authorizeToken(token)) {
        sendJson(response, 401, { code: 'AUTH_FAILED', message: 'unauthorized' });
        return;
      }
      const body = await readJsonBody(request);
      const spec = typeof body?.spec === 'string' ? body.spec.trim() : '';
      if (!spec) {
        sendJson(response, 400, { code: 'BAD_REQUEST', message: 'spec 必填' });
        return;
      }
      const approvedBuilds = Array.isArray(body?.approvedBuilds)
        ? body.approvedBuilds.map(String).filter((item) => item.length > 0)
        : [];
      try {
        const result = await pageContext.installPlugin(
          spec,
          approvedBuilds.length > 0 ? { approvedBuilds } : {},
        );
        sendJson(response, 200, { ok: true, ...(result ?? {}) });
      } catch (error) {
        sendJson(response, 400, {
          code: 'PLUGIN_INSTALL_FAILED',
          message: String(error?.message ?? error),
        });
      }
      return;
    }

    if (request.method === 'POST' && path === '/api/v1/desktop/plugins/market/remove') {
      const authHeader = request.headers.authorization ?? '';
      const token = authHeader.startsWith('Bearer ')
        ? authHeader.slice(7)
        : (url.searchParams.get('token') ?? '');
      if (!hub.authorizeToken(token)) {
        sendJson(response, 401, { code: 'AUTH_FAILED', message: 'unauthorized' });
        return;
      }
      const body = await readJsonBody(request);
      const bundleName = typeof body?.name === 'string' ? body.name.trim() : '';
      if (!bundleName) {
        sendJson(response, 400, { code: 'BAD_REQUEST', message: 'name 必填' });
        return;
      }
      try {
        const result = await pageContext.removePlugin(bundleName);
        sendJson(response, 200, { ok: true, ...(result ?? {}) });
      } catch (error) {
        sendJson(response, 400, {
          code: 'PLUGIN_REMOVE_FAILED',
          message: String(error?.message ?? error),
        });
      }
      return;
    }

    const sessionPromptMatch =
      request.method === 'POST' ? path.match(/^\/api\/v1\/desktop\/sessions\/([^/]+)\/prompt$/) : null;
    if (sessionPromptMatch) {
      // M2.9.4：手机给桌面会话补一句话（排队进入当前或下一轮）。
      const authHeader = request.headers.authorization ?? '';
      const token = authHeader.startsWith('Bearer ')
        ? authHeader.slice(7)
        : (url.searchParams.get('token') ?? '');
      if (!hub.authorizeToken(token)) {
        sendJson(response, 401, { code: 'AUTH_FAILED', message: 'unauthorized' });
        return;
      }
      const sessionId = decodeURIComponent(sessionPromptMatch[1]);
      const body = await readJsonBody(request);
      try {
        const result = await pageContext.desktopPrompt(sessionId, body?.text);
        sendJson(response, 200, { ok: true, ...(result ?? {}) });
      } catch (error) {
        // M4.19：存档会话被清理掉时给 404，手机端据此提示「这个会话已经没了」，
        // 而不是笼统的「发送失败」。
        const notFound = error?.code === 'SESSION_NOT_FOUND';
        sendJson(response, notFound ? 404 : 400, {
          code: notFound ? 'SESSION_NOT_FOUND' : 'PROMPT_FAILED',
          message: String(error?.message ?? error),
        });
      }
      return;
    }

    // M4.21：排队消息。GET 读队列（每 1.5 秒轮询带上），POST 改一条（删除 / 改字 / 插话）。
    const desktopQueueMatch = path.match(/^\/api\/v1\/desktop\/sessions\/([^/]+)\/queue$/);
    if (desktopQueueMatch && (request.method === 'GET' || request.method === 'POST')) {
      const authHeader = request.headers.authorization ?? '';
      const token = authHeader.startsWith('Bearer ')
        ? authHeader.slice(7)
        : (url.searchParams.get('token') ?? '');
      if (!hub.authorizeToken(token)) {
        sendJson(response, 401, { code: 'AUTH_FAILED', message: 'unauthorized' });
        return;
      }
      const sessionId = decodeURIComponent(desktopQueueMatch[1]);
      if (request.method === 'GET') {
        const queue = await pageContext.desktopQueue(sessionId);
        sendJson(response, 200, { ok: true, ...(queue ?? {}) });
        return;
      }
      const body = await readJsonBody(request);
      try {
        const queue = await pageContext.desktopQueueUpdate(
          sessionId,
          body?.itemId,
          body?.action,
          body?.text,
        );
        sendJson(response, 200, { ok: true, ...(queue ?? {}) });
      } catch (error) {
        const badRequest = error?.code === 'QUEUE_BAD_REQUEST';
        sendJson(response, badRequest ? 400 : 500, {
          code: String(error?.code ?? 'QUEUE_FAILED'),
          message: String(error?.message ?? error),
        });
      }
      return;
    }

    const desktopApprovalMatch =
      request.method === 'POST'
        ? path.match(/^\/api\/v1\/desktop\/sessions\/([^/]+)\/approvals\/([^/]+)$/)
        : null;
    if (desktopApprovalMatch) {
      // M2.9.4：手机替电脑应答一次授权（只对「正在被手机观看」的会话生效）。
      const authHeader = request.headers.authorization ?? '';
      const token = authHeader.startsWith('Bearer ')
        ? authHeader.slice(7)
        : (url.searchParams.get('token') ?? '');
      if (!hub.authorizeToken(token)) {
        sendJson(response, 401, { code: 'AUTH_FAILED', message: 'unauthorized' });
        return;
      }
      const sessionId = decodeURIComponent(desktopApprovalMatch[1]);
      const approvalId = decodeURIComponent(desktopApprovalMatch[2]);
      const body = await readJsonBody(request);
      const decision = body?.decision === 'approve' ? 'approve' : 'reject';
      const ok = pageContext.desktopApproval?.(sessionId, approvalId, decision) === true;
      if (!ok) {
        sendJson(response, 404, { code: 'APPROVAL_NOT_FOUND', message: 'approval not found' });
        return;
      }
      sendJson(response, 200, { ok: true, decision });
      return;
    }

    const desktopQuestionMatch =
      request.method === 'POST'
        ? path.match(/^\/api\/v1\/desktop\/sessions\/([^/]+)\/questions\/([^/]+)$/)
        : null;
    if (desktopQuestionMatch) {
      // M4.23：手机回答「确认需求」卡片。answers 是 [{ id, selected: [], custom? }]，
      // 空数组等于「跳过」（Host 会按用户没选任何东西继续）。
      const authHeader = request.headers.authorization ?? '';
      const token = authHeader.startsWith('Bearer ')
        ? authHeader.slice(7)
        : (url.searchParams.get('token') ?? '');
      if (!hub.authorizeToken(token)) {
        sendJson(response, 401, { code: 'AUTH_FAILED', message: 'unauthorized' });
        return;
      }
      const sessionId = decodeURIComponent(desktopQuestionMatch[1]);
      const questionId = decodeURIComponent(desktopQuestionMatch[2]);
      const body = await readJsonBody(request);
      const answers = Array.isArray(body?.answers) ? body.answers : [];
      const ok = pageContext.desktopQuestion?.(sessionId, questionId, answers) === true;
      if (!ok) {
        // M4.58：带上插件给出的失败原因（提问没了 / Agent 不在 / 答案不被接受），
        // 手机端才能说清是哪种情况，而不是一句「接口不存在」。
        const reason = pageContext.desktopQuestionError?.();
        // 409 而不是 404：手机端对 404 只显示「接口不存在」，看不出真正原因；
        // 409 会把 `message` 原样带到提示里（「请求失败（HTTP 409）：<原因>」）。
        sendJson(response, 409, {
          code: reason?.code ?? 'QUESTION_NOT_FOUND',
          message: reason?.message ?? 'question not found',
        });
        return;
      }
      sendJson(response, 200, { ok: true, answered: answers.length });
      return;
    }

    if (request.method === 'GET' && path === '/api/v1/received') {
      // M4.57：手机「功能 → 接收文件」列表。电脑端（或 AI）把做好的文件放进插件的
      // received 目录，手机端只读浏览；按修改时间倒序，最多 200 条。
      const authHeader = request.headers.authorization ?? '';
      const token = authHeader.startsWith('Bearer ')
        ? authHeader.slice(7)
        : (url.searchParams.get('token') ?? '');
      if (!hub.authorizeToken(token)) {
        sendJson(response, 401, { code: 'AUTH_FAILED', message: 'unauthorized' });
        return;
      }
      sendJson(response, 200, { files: pageContext.receivedFiles?.() ?? [] });
      return;
    }

    const receivedMatch = path.match(/^\/api\/v1\/received\/([^/]+)$/);
    if (receivedMatch) {
      // M4.57：下载 / 删除 received 目录里的一个文件。文件名只认最后一段，防目录穿越。
      const authHeader = request.headers.authorization ?? '';
      const token = authHeader.startsWith('Bearer ')
        ? authHeader.slice(7)
        : (url.searchParams.get('token') ?? '');
      if (!hub.authorizeToken(token)) {
        sendJson(response, 401, { code: 'AUTH_FAILED', message: 'unauthorized' });
        return;
      }
      const name = decodeURIComponent(receivedMatch[1]);
      if (request.method === 'DELETE') {
        const deleted = pageContext.deleteReceivedFile?.(name) === true;
        if (!deleted) {
          sendJson(response, 404, { code: 'NOT_FOUND', message: 'file not found' });
          return;
        }
        sendJson(response, 200, { ok: true });
        return;
      }
      if (request.method !== 'GET') {
        sendJson(response, 405, { code: 'METHOD_NOT_ALLOWED', message: 'method not allowed' });
        return;
      }
      const file = pageContext.receivedFile?.(name);
      if (!file) {
        sendJson(response, 404, { code: 'NOT_FOUND', message: 'file not found' });
        return;
      }
      let data;
      try {
        data = readFileSync(file.path);
      } catch (error) {
        sendJson(response, 500, {
          code: 'READ_FAILED',
          message: String(error?.message ?? error),
        });
        return;
      }
      response.writeHead(200, {
        'content-type': 'application/octet-stream',
        'content-length': String(data.length),
        'cache-control': 'no-store',
      });
      response.end(data);
      return;
    }

    if (request.method === 'GET' && path === '/api/v1/desktop/pending') {
      // M4.31：手机在别的页面时也要知道「电脑在等你选一项」。
      // 只回摘要，完整选项仍然从 /sessions/<id>/events 的 questions 拿。
      const header = request.headers.authorization ?? '';
      const token = header.startsWith('Bearer ')
        ? header.slice(7)
        : (url.searchParams.get('token') ?? '');
      if (!hub.authorizeToken(token)) {
        sendJson(response, 401, { code: 'AUTH_FAILED', message: 'unauthorized' });
        return;
      }
      if (typeof pageContext.desktopPending !== 'function') {
        sendJson(response, 501, {
          code: 'PENDING_UNAVAILABLE',
          message: '这台电脑的插件版本太旧，看不到待回答的提问',
        });
        return;
      }
      const pending = await pageContext.desktopPending();
      sendJson(response, 200, pending ?? { questions: [], approvals: [] });
      return;
    }

    if (request.method === 'GET' && path === '/api/v1/desktop/account/balance') {
      // M4.25：手机「我的」页的账户余额。Host 只让 Host 侧服务拿凭据，
      // 这里代理一次，只回钱包数字，不下发任何 token。
      const header = request.headers.authorization ?? '';
      const token = header.startsWith('Bearer ')
        ? header.slice(7)
        : (url.searchParams.get('token') ?? '');
      if (!hub.authorizeToken(token)) {
        sendJson(response, 401, { code: 'AUTH_FAILED', message: 'unauthorized' });
        return;
      }
      if (typeof pageContext.accountBalance !== 'function') {
        sendJson(response, 501, {
          code: 'ACCOUNT_BALANCE_UNAVAILABLE',
          message: '这台电脑的插件版本太旧，读不到账户余额',
        });
        return;
      }
      const balance = await pageContext.accountBalance();
      sendJson(response, 200, balance ?? {});
      return;
    }

    if (request.method === 'GET' && path === '/api/v1/desktop/workspaces') {
      const header = request.headers.authorization ?? '';
      const token = header.startsWith('Bearer ')
        ? header.slice(7)
        : (url.searchParams.get('token') ?? '');
      if (!hub.authorizeToken(token)) {
        sendJson(response, 401, { code: 'AUTH_FAILED', message: 'unauthorized' });
        return;
      }
      const list =
        typeof pageContext.desktopWorkspaces === 'function' ? pageContext.desktopWorkspaces() : [];
      sendJson(response, 200, { workspaces: list });
      return;
    }

    if (request.method === 'GET' && path === '/api/v1/agent/workspaces') {
      // M4.20：给自家 Agent 用的授权目录核对接口。
      //
      // Agent 是插件在 DSH 刚启动时拉起来的，那一刻工作区注册表往往还没就绪，
      // 插件只能把 homedir 递进去 —— 手机上「工作区」整页就只剩一个 C:\Users\…。
      // Agent 现在每 20 秒（以及每次重连后）来这里要一次真实目录，变了就覆盖并
      // 补发 device.status。走 role=agent 的 token，手机端的 token 调不动。
      const header = request.headers.authorization ?? '';
      const token = header.startsWith('Bearer ')
        ? header.slice(7)
        : (url.searchParams.get('token') ?? '');
      if (!hub.authorizeToken(token, 'agent')) {
        sendJson(response, 401, { code: 'AUTH_FAILED', message: 'unauthorized' });
        return;
      }
      const list =
        typeof pageContext.desktopWorkspaces === 'function' ? pageContext.desktopWorkspaces() : [];
      sendJson(response, 200, { workspaces: list });
      return;
    }

    if (request.method === 'GET' && path === '/api/v1/desktop/sessions') {
      const header = request.headers.authorization ?? '';
      const token = header.startsWith('Bearer ')
        ? header.slice(7)
        : (url.searchParams.get('token') ?? '');
      if (!hub.authorizeToken(token)) {
        sendJson(response, 401, { code: 'AUTH_FAILED', message: 'unauthorized' });
        return;
      }
      const workspace = url.searchParams.get('workspace') ?? '';
      const all = typeof pageContext.desktopTasks === 'function' ? pageContext.desktopTasks() : [];
      const sessions = workspace ? all.filter((task) => task.workspace === workspace) : all;
      sendJson(response, 200, { workspace, sessions });
      return;
    }

    if (request.method === 'GET' && path === '/api/v1/desktop/tasks') {
      // M2.9.2：桌面 GUI 里发起的任务不经过 relay agent，手机任务页改从这份只读镜像拿。
      const header = request.headers.authorization ?? '';
      const token = header.startsWith('Bearer ')
        ? header.slice(7)
        : (url.searchParams.get('token') ?? '');
      if (!hub.authorizeToken(token)) {
        sendJson(response, 401, { code: 'AUTH_FAILED', message: 'unauthorized' });
        return;
      }
      const tasks = typeof pageContext.desktopTasks === 'function' ? pageContext.desktopTasks() : [];
      // M3.5：顺带给出工作区清单，手机任务页可按工作区筛。
      const workspaces = [];
      const seen = new Map();
      for (const task of tasks) {
        const workspacePath = task?.workspace ?? '';
        if (!workspacePath) continue;
        const entry = seen.get(workspacePath);
        if (entry) {
          entry.count += 1;
          if (task.status === 'running') entry.running += 1;
        } else {
          const fresh = {
            path: workspacePath,
            count: 1,
            running: task.status === 'running' ? 1 : 0,
          };
          seen.set(workspacePath, fresh);
          workspaces.push(fresh);
        }
      }
      sendJson(response, 200, { tasks, workspaces });
      return;
    }

    // M4.10：会话存档。DSH 重启后会话会从列表里消失（Host 只认「已物化」的日志），
    // 手机端靠这份存档继续看到「以前跑过、现在电脑列表里没有」的会话。
    if (request.method === 'GET' && path === '/api/v1/desktop/archive/sessions') {
      const header = request.headers.authorization ?? '';
      const token = header.startsWith('Bearer ')
        ? header.slice(7)
        : (url.searchParams.get('token') ?? '');
      if (!hub.authorizeToken(token)) {
        sendJson(response, 401, { code: 'AUTH_FAILED', message: 'unauthorized' });
        return;
      }
      if (typeof pageContext.archivedSessions !== 'function') {
        sendJson(response, 501, { code: 'ARCHIVE_UNAVAILABLE', message: 'archive disabled' });
        return;
      }
      try {
        const sessions = await pageContext.archivedSessions();
        sendJson(response, 200, { sessions: Array.isArray(sessions) ? sessions : [] });
      } catch (error) {
        sendJson(response, 500, { code: 'ARCHIVE_FAILED', message: String(error?.message ?? error) });
      }
      return;
    }

    const archivedOne =
      request.method === 'GET' ? path.match(/^\/api\/v1\/desktop\/archive\/sessions\/([^/]+)$/) : null;
    if (archivedOne) {
      const header = request.headers.authorization ?? '';
      const token = header.startsWith('Bearer ')
        ? header.slice(7)
        : (url.searchParams.get('token') ?? '');
      if (!hub.authorizeToken(token)) {
        sendJson(response, 401, { code: 'AUTH_FAILED', message: 'unauthorized' });
        return;
      }
      const sessionId = decodeURIComponent(archivedOne[1]);
      const record =
        typeof pageContext.archivedSession === 'function' ? pageContext.archivedSession(sessionId) : null;
      if (!record) {
        sendJson(response, 404, { code: 'ARCHIVE_NOT_FOUND', message: 'session not archived' });
        return;
      }
      sendJson(response, 200, {
        sessionId: record.id,
        // M4.16：以前这里只回 sessionId/running/lastSeq，App 只能回落成
        // 「桌面会话 / 电脑上的会话」，每个存档看起来都一样。补上真实元信息。
        title: String(record.title ?? '').trim(),
        cwd: String(record.workspace ?? '').trim(),
        lastTime: Number(record.lastTime) || 0,
        messageCount: Number(record.messageCount) || 0,
        // 存档只读：running 恒为 false，手机端会显示「已存档」。
        running: false,
        lastSeq: Number(record.lastSeq) || 0,
        events: Array.isArray(record.events) ? record.events : [],
      }, {}, request);
      return;
    }

    if (request.method === 'POST' && path === '/api/v1/desktop/archive/sessions') {
      const header = request.headers.authorization ?? '';
      const token = header.startsWith('Bearer ')
        ? header.slice(7)
        : (url.searchParams.get('token') ?? '');
      if (!hub.authorizeToken(token)) {
        sendJson(response, 401, { code: 'AUTH_FAILED', message: 'unauthorized' });
        return;
      }
      if (typeof pageContext.saveArchivedSession !== 'function') {
        sendJson(response, 501, { code: 'ARCHIVE_UNAVAILABLE', message: 'archive disabled' });
        return;
      }
      const body = await readJsonBody(request, MAX_UPLOAD_BYTES * 2);
      try {
        const saved = await pageContext.saveArchivedSession(body);
        sendJson(response, 200, { ok: true, ...(saved ?? {}) });
      } catch (error) {
        sendJson(response, 400, { code: 'ARCHIVE_SAVE_FAILED', message: String(error?.message ?? error) });
      }
      return;
    }

    if (request.method === 'POST' && path === '/api/v1/desktop/upload') {
      // M3.0：手机把照片/文档传到电脑，返回落盘路径，再由 prompt 文本引用。
      const header = request.headers.authorization ?? '';
      const token = header.startsWith('Bearer ')
        ? header.slice(7)
        : (url.searchParams.get('token') ?? '');
      if (!hub.authorizeToken(token)) {
        sendJson(response, 401, { code: 'AUTH_FAILED', message: 'unauthorized' });
        return;
      }
      const defaultUploadDir = typeof pageContext.uploadDir === 'string' ? pageContext.uploadDir : '';
      if (!defaultUploadDir) {
        sendJson(response, 501, { code: 'UPLOAD_UNAVAILABLE', message: 'upload disabled' });
        return;
      }
      const body = await readJsonBody(request, MAX_UPLOAD_BYTES * 2);
      // M4.2：附件落到手机当前选中的工作区（body.workspace 是工作区名），
      // 这样电脑端的 AI 能直接在会话目录里看到文件；没有工作区时退回默认目录。
      const uploadDir =
        typeof pageContext.resolveUploadDir === 'function'
          ? pageContext.resolveUploadDir(body?.workspace)
          : defaultUploadDir;
      const rawName = String(body?.name ?? '').trim();
      const data = String(body?.data ?? '');
      if (!rawName || !data) {
        sendJson(response, 400, { code: 'BAD_REQUEST', message: 'name and data are required' });
        return;
      }
      const buffer = Buffer.from(data, 'base64');
      if (buffer.length === 0) {
        sendJson(response, 400, { code: 'BAD_REQUEST', message: 'empty file' });
        return;
      }
      if (buffer.length > MAX_UPLOAD_BYTES) {
        sendJson(response, 413, { code: 'TOO_LARGE', message: 'file too large (max 20 MiB)' });
        return;
      }
      const safeName =
        basename(rawName)
          .replace(/[\\/:*?"<>|]/g, '_')
          .replace(/[\u0000-\u001f]/g, '')
          .slice(0, 120) || 'upload.bin';
      const stamp = new Date().toISOString().replace(/[:.]/g, '-');
      const storedName = `${stamp}-${safeName}`;
      const absPath = join(uploadDir, storedName);
      await mkdir(uploadDir, { recursive: true });
      await writeFile(absPath, buffer);
      log(`收到手机附件：${storedName} (${buffer.length} B)`);
      sendJson(response, 200, { ok: true, name: safeName, path: absPath, size: buffer.length });
      return;
    }

    if (request.method === 'GET' && path === '/api/v1/desktop/file/raw') {
      // M4.9：手机端在工作区里点开图片 / PDF / Office 时取原始字节。
      // GET ?workspace=<授权根绝对路径>&path=<相对路径>，成功直接回流（content-type 由扩展名决定）。
      const header = request.headers.authorization ?? '';
      const token = header.startsWith('Bearer ')
        ? header.slice(7)
        : (url.searchParams.get('token') ?? '');
      if (!hub.authorizeToken(token)) {
        sendJson(response, 401, { code: 'AUTH_FAILED', message: 'unauthorized' });
        return;
      }
      if (typeof pageContext.readWorkspaceFileBytes !== 'function') {
        sendJson(response, 501, { code: 'FILE_UNAVAILABLE', message: 'file download unavailable' });
        return;
      }
      try {
        const file = await pageContext.readWorkspaceFileBytes(
          url.searchParams.get('workspace') ?? '',
          url.searchParams.get('path') ?? '',
        );
        // M4.43（指令第 6 条）：支持 Range，让 PDF 阅读器能跳页、图片能续传。
        // 注意 `/api/v1/app/apk` 是**有意**不支持 Range 的（App 每次整包拉取），
        // 别照着这里去改它。
        const range = request.headers.range;
        if (typeof range === 'string' && range.startsWith('bytes=')) {
          const match = /^bytes=(\d*)-(\d*)$/.exec(range.trim());
          if (match) {
            const size = file.size;
            let start = match[1] === '' ? NaN : Number(match[1]);
            let end = match[2] === '' ? NaN : Number(match[2]);
            if (!(Number.isNaN(start) && Number.isNaN(end))) {
              if (Number.isNaN(start)) {
                // bytes=-500：最后 500 字节
                start = Math.max(0, size - end);
                end = size - 1;
              }
              if (Number.isNaN(end)) end = size - 1;
              if (start < 0 || start >= size || end < start) {
                response.writeHead(416, { 'content-range': `bytes */${size}` });
                response.end();
                return;
              }
              end = Math.min(end, size - 1);
              const chunk = file.buffer.subarray(start, end + 1);
              response.writeHead(206, {
                'content-type': contentTypeOf(file.absPath),
                'content-length': chunk.length,
                'content-range': `bytes ${start}-${end}/${size}`,
                'accept-ranges': 'bytes',
                'cache-control': 'no-store',
              });
              response.end(chunk);
              return;
            }
          }
        }
        // 无 Range，或 Range 解析不出来：老行为整包 200，但补上 accept-ranges。
        response.writeHead(200, {
          'content-type': contentTypeOf(file.absPath),
          'content-length': file.size,
          'accept-ranges': 'bytes',
          'cache-control': 'no-store',
        });
        response.end(file.buffer);
      } catch (error) {
        sendJson(response, 400, { code: 'FILE_READ_FAILED', message: String(error?.message ?? error) });
      }
      return;
    }

    if (request.method === 'POST' && path === '/api/v1/desktop/file/read') {
      // M4.9：手机解析不了 PDF / Word / Excel，交给电脑读成文字再回传。
      const header = request.headers.authorization ?? '';
      const token = header.startsWith('Bearer ')
        ? header.slice(7)
        : (url.searchParams.get('token') ?? '');
      if (!hub.authorizeToken(token)) {
        sendJson(response, 401, { code: 'AUTH_FAILED', message: 'unauthorized' });
        return;
      }
      if (typeof pageContext.readDesktopFileText !== 'function') {
        sendJson(response, 501, { code: 'FILE_READ_UNAVAILABLE', message: 'file read unavailable' });
        return;
      }
      const body = await readJsonBody(request, MAX_UPLOAD_BYTES * 2);
      try {
        const text = await pageContext.readDesktopFileText({
          name: String(body?.name ?? ''),
          data: String(body?.data ?? ''),
        });
        sendJson(response, 200, { ok: true, name: String(body?.name ?? ''), text });
      } catch (error) {
        sendJson(response, 400, { code: 'FILE_READ_FAILED', message: String(error?.message ?? error) });
      }
      return;
    }

    if (request.method === 'GET' && path === '/api/v1/app/notes') {
      // M4.66：手机「功能 → 更新日志」直接读电脑上的 docs/UPDATE_NOTES.md。
      const header = request.headers.authorization ?? '';
      const token = header.startsWith('Bearer ')
        ? header.slice(7)
        : (url.searchParams.get('token') ?? '');
      if (!hub.authorizeToken(token)) {
        sendJson(response, 401, { code: 'AUTH_FAILED', message: 'unauthorized' });
        return;
      }
      const notes = typeof pageContext.appNotes === 'function' ? pageContext.appNotes() : null;
      sendJson(response, 200, { notes: Array.isArray(notes) ? notes : [] });
      return;
    }

    if (request.method === 'GET' && path === '/api/v1/app/version') {
      // 应用内更新：插件自己就是更新源，不依赖后端。
      const payload = appUpdate?.versionPayload?.() ?? null;
      if (!payload) {
        sendJson(response, 404, { code: 'APP_UPDATE_UNAVAILABLE', message: 'APK 不存在' });
        return;
      }
      sendJson(response, 200, payload);
      return;
    }

    if ((request.method === 'GET' || request.method === 'HEAD') && path === '/api/v1/app/apk') {
      if (!appUpdate) {
        sendJson(response, 404, { code: 'APP_UPDATE_UNAVAILABLE', message: 'APK 不存在' });
        return;
      }
      appUpdate.streamApk(request, response);
      return;
    }

    if (request.method === 'GET' && (path === '/' || path === '/pair' || path === '/index.html')) {
      if (!isLocalRequest(request)) {
        // 配网页带匹配码，公网打开只给一张说明页，避免把码暴露出去。
        const notice = Buffer.from(
          `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8" /><meta name="viewport" content="width=device-width, initial-scale=1" /><title>DeepSeek 手机端直连</title><style>body{margin:0;min-height:100vh;display:grid;place-items:center;background:#0b0f19;color:#cfe0ff;font-family:-apple-system,"Segoe UI","Microsoft YaHei",sans-serif}.box{max-width:420px;padding:26px;border:1px solid rgba(120,160,255,.2);border-radius:18px;background:rgba(16,22,36,.9);line-height:1.9}code{color:#7dd3fc}</style></head><body><div class="box"><h2 style="margin:0 0 8px;font-size:18px">请在电脑上打开这个页面</h2><div style="color:#8fa1bd;font-size:13px">配对信息包含匹配码，只在本机显示。<br/>手机端请打开 App，用扫码或手输匹配码连接；也可以先让电脑上的浏览器访问 <code>http://127.0.0.1:${pageContext.port}/</code>。</div></div></body></html>`,
          'utf8',
        );
        response.writeHead(200, {
          'content-type': 'text/html; charset=utf-8',
          'content-length': notice.length,
          'cache-control': 'no-store',
        });
        response.end(notice);
        return;
      }
      const page = Buffer.from(
        renderPairPage({ hub, version, port: pageContext.port, tunnel: publicStatus() }),
        'utf8',
      );
      response.writeHead(200, {
        'content-type': 'text/html; charset=utf-8',
        'content-length': page.length,
        'cache-control': 'no-store',
      });
      response.end(page);
      return;
    }

    // M4.43：404 就该配 NOT_FOUND —— 以前写的是 BAD_REQUEST，
    // 客户端按 code 判类型会把「路由不存在」误当成「参数错了」。
    sendJson(response, 404, { code: 'NOT_FOUND', message: 'not found' });
  }

  return server;
}

function contentTypeOf(filePath) {
  // M4.9：给手机端直接预览/打开的原始文件定 content-type，未知类型走下载。
  const lower = String(filePath ?? '').toLowerCase();
  const map = {
    '.png': 'image/png',
    '.jpg': 'image/jpeg',
    '.jpeg': 'image/jpeg',
    '.gif': 'image/gif',
    '.webp': 'image/webp',
    '.bmp': 'image/bmp',
    '.svg': 'image/svg+xml',
    '.pdf': 'application/pdf',
    '.txt': 'text/plain; charset=utf-8',
    '.md': 'text/plain; charset=utf-8',
    '.json': 'application/json; charset=utf-8',
  };
  const ext = lower.slice(lower.lastIndexOf('.'));
  return map[ext] ?? 'application/octet-stream';
}

function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, (char) => ({
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    '"': '&quot;',
    "'": '&#39;',
  })[char]);
}

export function renderPairPage({ hub, version, port, tunnel }) {
  const addresses = lanAddresses();
  const primary = addresses.find((item) => !item.virtual) ?? addresses[0];
  const primaryUrl = primary ? `http://${primary.address}:${port}` : `http://127.0.0.1:${port}`;
  const tailscale = addresses.find((item) => item.kind === 'tailscale');
  const tailscaleUrl = tailscale ? `http://${tailscale.address}:${port}` : null;
  const otherUrls = addresses
    .map((item) => `http://${item.address}:${port}`)
    .filter((url) => url !== primaryUrl);
  const code = hub.pairingCode;
  const publicUrl = tunnel?.url ?? null;
  const tunnelText = publicUrl
    ? '公网隧道在线'
    : tunnel?.error
      ? `公网隧道：${tunnel.error}`
      : tunnel?.enabled === false
        ? '未开启公网访问'
        : '公网隧道启动中…';
  const statusColor = hub.agentOnline ? '#22c55e' : '#f59e0b';
  const publicDot = publicUrl ? '#22c55e' : '#64748b';
  return `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>DeepSeek 手机端直连</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body { margin: 0; min-height: 100vh; padding: 28px 16px; background: radial-gradient(circle at 20% 0%, #1b2a4a 0%, #0b0f19 55%, #05070c 100%); color: #e7ecf5; font-family: -apple-system, "Segoe UI", "Microsoft YaHei", sans-serif; }
  .card { width: min(760px, 100%); margin: 0 auto; background: rgba(16, 22, 36, 0.86); border: 1px solid rgba(120, 160, 255, 0.18); border-radius: 22px; padding: 26px 28px 22px; box-shadow: 0 30px 80px rgba(0, 0, 0, 0.55); }
  h1 { font-size: 21px; margin: 0 0 6px; letter-spacing: .5px; }
  .sub { color: #8fa1bd; font-size: 13px; margin-bottom: 20px; line-height: 1.7; }
  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 14px; }
  .tile { background: rgba(255, 255, 255, 0.035); border: 1px solid rgba(255, 255, 255, 0.07); border-radius: 16px; padding: 14px; text-align: center; }
  .tag { display: inline-flex; align-items: center; gap: 6px; font-size: 12px; color: #b6c4da; margin-bottom: 10px; }
  .dot { width: 7px; height: 7px; border-radius: 99px; }
  .qr { display: grid; place-items: center; background: #fff; border-radius: 12px; padding: 10px; width: 200px; height: 200px; margin: 0 auto 10px; }
  .qr img, .qr canvas { width: 176px !important; height: 176px !important; display: block; }
  .qr.pending { background: rgba(255,255,255,.06); color: #64748b; font-size: 12px; }
  .addr { font-family: ui-monospace, Consolas, monospace; font-size: 12.5px; color: #cfe0ff; word-break: break-all; min-height: 18px; }
  .hint { margin-top: 6px; font-size: 11.5px; color: #64748b; }
  .row { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 12px 16px; border-radius: 14px; background: rgba(255, 255, 255, 0.04); border: 1px solid rgba(255, 255, 255, 0.06); margin-top: 10px; }
  .label { font-size: 13px; color: #93a5c0; }
  .code { font-family: ui-monospace, Consolas, monospace; font-size: 26px; letter-spacing: 7px; color: #7dd3fc; font-weight: 600; }
  .pill { display: inline-flex; align-items: center; gap: 7px; font-size: 12px; color: #b6c4da; }
  button { background: rgba(125, 211, 252, 0.12); color: #7dd3fc; border: 1px solid rgba(125, 211, 252, 0.35); border-radius: 10px; padding: 7px 12px; font-size: 12px; cursor: pointer; }
  button:hover { background: rgba(125, 211, 252, 0.2); }
  ol { margin: 16px 0 0; padding-left: 20px; color: #8fa1bd; font-size: 12.5px; line-height: 1.9; }
  .urls { margin-top: 12px; font-size: 12px; color: #6f8099; line-height: 1.8; font-family: ui-monospace, Consolas, monospace; }
  .foot { margin-top: 16px; padding-top: 12px; border-top: 1px solid rgba(255,255,255,.06); display: flex; justify-content: space-between; font-size: 11.5px; color: #64748b; }
</style>
</head>
<body>
  <div class="card">
    <h1>DeepSeek 手机端直连</h1>
    <div class="sub">三张码任选：同一 Wi-Fi 用左边的局域网码；装过 Tailscale（手机和电脑在同一个 Tailnet）就用下面那条 100.x 地址；人在外面、没有 Tailscale 才用右边公网码。App 里扫码会自动填好地址和匹配码，也可以手输。</div>
    <div class="grid">
      <section class="tile">
        <div class="tag"><span class="dot" style="background:#22c55e"></span>局域网 / Tailscale（同一网络）</div>
        <div class="qr" id="qr-lan"></div>
        <div class="addr" id="lan-addr">${escapeHtml(primaryUrl)}</div>
        <div class="hint">${tailscaleUrl ? '当前优先用 Tailscale 地址，跨网络也能连' : '不走公网，速度最快'}</div>
      </section>
      <section class="tile">
        <div class="tag"><span class="dot" id="wan-dot" style="background:${publicDot}"></span>公网（任何网络）</div>
        <div class="qr${publicUrl ? '' : ' pending'}" id="qr-wan">${publicUrl ? '' : '隧道启动中…'}</div>
        <div class="addr" id="wan-addr">${escapeHtml(publicUrl ?? '等待 cloudflared…')}</div>
        <div class="hint" id="wan-hint">${escapeHtml(tunnelText)}</div>
      </section>
    </div>
    <div class="row">
      <div>
        <div class="label">匹配码</div>
        <div class="code" id="code">${escapeHtml(code)}</div>
      </div>
      <button id="rotate">换一个</button>
    </div>
    <div class="row">
      <div class="pill"><span class="dot" style="background:${statusColor}"></span><span>${hub.agentOnline ? '中继在线' : '等待 Harness 侧启动'}</span></div>
      <div class="pill">插件 v${escapeHtml(version)}</div>
    </div>
    <ol>
      <li>手机打开「DeepSeek Remote AI」，点「扫码连接」扫上面任意一个码</li>
      <li>或者手输：地址填二维码下面那行，匹配码填 ${escapeHtml(code)}</li>
      <li>连上后即可对话、看执行过程、批准工具调用</li>
    </ol>
    ${tailscaleUrl ? `<div class="row"><div><div class="label">Tailscale（同一 Tailnet，跨网络可用）</div><div class="addr" id="tailscale-addr">${escapeHtml(tailscaleUrl)}</div></div><div class="hint">比公网隧道快，也不依赖 cloudflared</div></div>` : ''}
    <div class="urls">${[primaryUrl, ...otherUrls].map((url) => escapeHtml(url)).join('<br/>')}</div>
    <div class="foot"><span>二维码 = 地址 + 匹配码（#c=）</span><span>局域网 · Tailscale · 公网隧道，任选其一</span></div>
  </div>
  <script src="/assets/qrcode.js"></script>
  <script>
    (function () {
      var lanUrl = ${JSON.stringify(primaryUrl)};
      var code = ${JSON.stringify(code)};
      var publicUrl = ${JSON.stringify(publicUrl)};

      function drawInto(id, text, placeholder) {
        var host = document.getElementById(id);
        if (!text) {
          host.className = 'qr pending';
          host.textContent = placeholder || '等待地址…';
          return;
        }
        host.className = 'qr';
        try {
          var qr = qrcode(0, 'M');
          qr.addData(text);
          qr.make();
          host.innerHTML = qr.createImgTag(5, 10);
        } catch (error) {
          host.textContent = text;
        }
      }

      function paint() {
        drawInto('qr-lan', lanUrl + '#c=' + encodeURIComponent(code));
        drawInto('qr-wan', publicUrl ? publicUrl + '#c=' + encodeURIComponent(code) : null, '隧道启动中…');
        document.getElementById('code').textContent = code;
        document.getElementById('lan-addr').textContent = lanUrl;
        document.getElementById('wan-addr').textContent = publicUrl || '等待 cloudflared…';
      }

      function refresh() {
        fetch('/api/v1/pair/info', { cache: 'no-store' })
          .then(function (response) { return response.json(); })
          .then(function (data) {
            var changed = data.pairingCode !== code || (data.publicUrl || null) !== (publicUrl || null);
            code = data.pairingCode;
            publicUrl = data.publicUrl || null;
            if (data.lanUrls && data.lanUrls.length > 0) lanUrl = data.lanUrls[0];
            if (changed) paint();
            var hint = document.getElementById('wan-hint');
            var dot = document.getElementById('wan-dot');
            dot.style.background = publicUrl ? '#22c55e' : '#64748b';
            if (publicUrl) hint.textContent = '公网隧道在线';
            else if (data.tunnel && data.tunnel.error) hint.textContent = data.tunnel.error;
          })
          .catch(function () {});
      }

      document.getElementById('rotate').addEventListener('click', function () {
        fetch('/api/v1/pair/rotate', { method: 'POST' })
          .then(function (response) { return response.json(); })
          .then(function (data) { if (data.pairingCode) { code = data.pairingCode; paint(); } })
          .catch(function () {});
      });

      paint();
      setInterval(refresh, 3000);
    })();
  </script>
</body>
</html>`;
}
