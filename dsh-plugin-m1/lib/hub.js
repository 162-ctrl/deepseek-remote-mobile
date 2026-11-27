// M1 中继服务端（Hub）：复刻 backend RelayHub + PairingController 的对外契约，
// 让既有的 Flutter 手机端（app/）零改动连上来。
//
// 契约来源：
//   backend/src/main/java/com/deepseek/remote/api/PairingController.java
//   backend/src/main/java/com/deepseek/remote/ws/RelayHub.java
//   backend/src/main/java/com/deepseek/remote/ws/RelayWebSocketHandler.java
import { createHash, randomBytes, randomInt } from 'node:crypto';
import { WsPeer } from './ws.js';

export const RELAY_PROTOCOL_VERSION = 1;

export const APP_FORWARD_TYPES = new Set([
  'conversation.create',
  'prompt.send',
  'task.cancel',
  'approval.decide',
  'workspace.list',
  'file.read',
  'file.write',
]);

export const AGENT_BROADCAST_TYPES = new Set([
  'conversation.created',
  'session.update',
  'task.state',
  'approval.request',
  'approval.resolved',
  'device.status',
  'error',
  'workspace.list.result',
  'file.read.result',
  'file.write.result',
]);

export const CLOSE_UNAUTHORIZED = 4401;
export const CLOSE_AGENT_REPLACED = 4409;

const CROCKFORD = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

/** 26 位 ULID（与后端 conversationId 形状一致）。 */
export function ulid(now = Date.now()) {
  let time = '';
  let remaining = now;
  for (let index = 0; index < 10; index += 1) {
    time = CROCKFORD[remaining % 32] + time;
    remaining = Math.floor(remaining / 32);
  }
  let randomness = '';
  for (let index = 0; index < 16; index += 1) {
    randomness += CROCKFORD[randomInt(0, 32)];
  }
  return time + randomness;
}

export function createEnvelope(type, payload) {
  const envelope = { v: RELAY_PROTOCOL_VERSION, type, ts: new Date().toISOString() };
  if (payload !== undefined) envelope.payload = payload;
  return envelope;
}

export function parseEnvelope(raw) {
  let value;
  try {
    value = JSON.parse(raw);
  } catch {
    return null;
  }
  if (value === null || typeof value !== 'object') return null;
  if (typeof value.type !== 'string' || value.type.length === 0) return null;
  if (value.v !== undefined && value.v !== RELAY_PROTOCOL_VERSION) return null;
  return value;
}

/** `yyyy-MM-dd'T'HH:mm:ss'Z'`，与后端 expiresAt 完全同形。 */
function isoTimestamp(date) {
  return `${date.toISOString().slice(0, 19)}Z`;
}

export class HubError extends Error {
  constructor(code, message, status = 400) {
    super(message);
    this.code = code;
    this.status = status;
  }
}

export class M1Hub {
  #pairingCode;
  #version;
  #log;
  // M4.44：key 是 token 的 sha256（不再存明文），value 是 { role, clientName, deviceId, expiresAt }
  #tokens = new Map();
  #apps = new Set(); // WsPeer
  #agent = null; // WsPeer
  #agentStatus = null; // 最近一次 agent 上报的 device.status（含 workspaceRoots）
  #nextDeviceId = 1;
  #conversations = new Map(); // conversationId -> { seq, busy }
  #disposed = false;
  #tokenStore = null; // 可选：{ load(): row[], save(rows) }，让 token 跨插件重启存活

  constructor({ pairingCode, version = '0.1.0', log = () => {}, tokenStore = null }) {
    this.#pairingCode = String(pairingCode ?? '');
    this.#version = version;
    this.#log = log;
    this.#tokenStore = tokenStore;
    this.#restoreTokens();
  }

  /**
   * M4.44：tokens.json 里只存 token 的 sha256，不存明文。
   *
   * 以前这个文件是「谁读到谁就是那台设备」——223 条明文 token 全是完整权限，
   * 备份、同步盘、误发一次文件就等于全部泄漏。现在内存与磁盘都只认哈希，
   * 配对时把明文返回一次给客户端，之后服务端只做哈希查找。
   */
  #hashToken(token) {
    return createHash('sha256').update(String(token ?? '')).digest('hex');
  }

  /** 从磁盘恢复未过期的 token（兼容老的明文文件，读到后一次性迁移成哈希）。 */
  #restoreTokens() {
    const rows = this.#tokenStore?.load?.();
    if (!Array.isArray(rows)) return;
    let restored = 0;
    let dropped = 0;
    let migrated = 0;
    for (const row of rows) {
      const plain = String(row?.token ?? '');
      let tokenHash = String(row?.tokenHash ?? '');
      if (!tokenHash && plain) {
        tokenHash = this.#hashToken(plain);
        migrated += 1;
      }
      const expiresAt = new Date(String(row?.expiresAt ?? ''));
      if (!tokenHash || Number.isNaN(expiresAt.getTime())) {
        dropped += 1;
        continue;
      }
      if (expiresAt.getTime() <= Date.now()) {
        dropped += 1;
        continue;
      }
      const deviceId = row?.deviceId;
      this.#tokens.set(tokenHash, {
        role: row?.role === 'agent' ? 'agent' : 'app',
        clientName: String(row?.clientName ?? ''),
        deviceId: typeof deviceId === 'string' ? deviceId : Number(deviceId) || 0,
        expiresAt,
      });
      restored += 1;
    }
    if (restored > 0) this.#log(`恢复 ${restored} 个已配对 token`);
    if (migrated > 0) this.#log(`把 ${migrated} 个明文 token 迁移成哈希`);
    // 过期/坏掉的记录不能永远躺在文件里：剔过就回写一次；迁移也必须立刻落盘。
    if (dropped > 0) this.#log(`清理 ${dropped} 条过期 token`);
    if (dropped > 0 || migrated > 0) this.#persistTokens();
  }

  #persistTokens() {
    if (this.#tokenStore === null) return;
    try {
      this.#tokenStore.save?.(
        [...this.#tokens].map(([tokenHash, record]) => ({
          tokenHash,
          role: record.role,
          clientName: record.clientName,
          deviceId: record.deviceId,
          expiresAt: record.expiresAt.toISOString(),
        })),
      );
    } catch {
      /* 写不进去只影响下次重启，不影响本次连接 */
    }
  }

  get pairingCode() {
    return this.#pairingCode;
  }

  setPairingCode(code) {
    this.#pairingCode = String(code);
  }

  get agentOnline() {
    return this.#agent !== null && !this.#agent.closed;
  }

  get appCount() {
    return this.#apps.size;
  }

  /** POST /api/v1/auth/pair */
  pair({ pairingCode, clientName, role }) {
    if (role !== 'app' && role !== 'agent') {
      throw new HubError('AUTH_FAILED', 'role invalid', 401);
    }
    if (typeof pairingCode !== 'string' || pairingCode.trim() !== this.#pairingCode) {
      throw new HubError('AUTH_FAILED', 'pairing code invalid', 401);
    }
    const token = randomBytes(24).toString('hex');
    const expiresAt = new Date(Date.now() + 30 * 24 * 3600_000);
    // M4.43：agent 的 deviceId 必须是稳定值——以前每次 pair 都新生成 ulid()，
    // 于是同一个电脑每次重连都被当成新设备，token 只增不减（实测攒到 210 条）。
    const stableName = String(clientName ?? '').trim();
    const deviceId =
      role === 'agent' ? `agent:${stableName || 'agent'}` : `dev_${this.#nextDeviceId++}`;
    const record = {
      role,
      clientName: typeof clientName === 'string' && clientName ? clientName : role,
      deviceId,
      expiresAt,
    };
    this.#tokens.set(this.#hashToken(token), record);
    // M4.43：同一设备只保留最新 2 条 token——老连接可能还在用上一条，
    // 但更早的必然已经废弃，留着只是把 tokens.json 变成 token 垃圾场。
    const sameDevice = [...this.#tokens]
      .filter(([, row]) => row.role === role && row.deviceId === deviceId)
      .sort((left, right) => right[1].expiresAt.getTime() - left[1].expiresAt.getTime());
    for (const [oldToken] of sameDevice.slice(2)) this.#tokens.delete(oldToken);
    this.#persistTokens();
    this.#log(`pair ok role=${role} device=${deviceId}`);
    return { token, role, deviceId, expiresAt: isoTimestamp(expiresAt) };
  }

  /** /ws?role=app|agent&token=... —— 先接受 upgrade，再校验（与后端一致，错误用关闭码表达）。 */
  acceptUpgrade(request, socket) {
    const peer = WsPeer.accept(request, socket);
    if (peer === null) return null;
    let url;
    try {
      url = new URL(request.url ?? '/', 'http://localhost');
    } catch {
      peer.close(1008, 'bad request');
      return null;
    }
    const role = url.searchParams.get('role') ?? '';
    const token = url.searchParams.get('token') ?? '';
    const record = this.#tokens.get(this.#hashToken(token));
    const valid =
      record !== undefined &&
      record.role === role &&
      (role === 'app' || role === 'agent') &&
      record.expiresAt.getTime() > Date.now();
    if (!valid) {
      peer.close(CLOSE_UNAUTHORIZED, 'unauthorized');
      return null;
    }
    if (role === 'agent') this.#attachAgent(peer, record);
    else this.#attachApp(peer, record);
    return peer;
  }

  #attachApp(peer, record) {
    this.#apps.add(peer);
    peer.on('close', () => {
      this.#apps.delete(peer);
    });
    peer.on('text', (raw) => this.#onAppMessage(peer, record, raw));
    this.#send(peer, createEnvelope('device.status', this.#deviceStatus()));
    // M2.8：agent 的 device.status 带 workspaceRoots / 能力位；补发给后连上的手机，
    // 否则手机只拿到 Hub 的骨架状态，项目页会显示「没有工作区」。
    if (this.#agentStatus !== null) {
      this.#send(peer, createEnvelope('device.status', this.#agentStatus));
    }
    this.#log(`app connected: ${record.clientName}`);
  }

  #attachAgent(peer, record) {
    if (this.#agent !== null && !this.#agent.closed) {
      this.#agent.close(CLOSE_AGENT_REPLACED, 'agent replaced');
    }
    this.#agent = peer;
    peer.on('close', () => {
      if (this.#agent === peer) this.#agent = null;
      this.#agentStatus = null;
      // agent 断线时把它名下所有会话的 busy 复位：置锁只发生在 prompt.send，
      // 解锁原本只依赖 task.state 终态事件；agent 在任务中途掉线就不会再发终态，
      // 那个会话会永久返回 SESSION_BUSY，用户发什么都发不出去，只能重启插件。
      this.#releaseAllBusy();
      this.broadcast('device.status', this.#deviceStatus());
      this.#log('agent disconnected');
    });
    peer.on('text', (raw) => this.#onAgentMessage(raw));
    this.broadcast('device.status', this.#deviceStatus());
    this.#log(`agent connected: ${record.clientName}`);
  }

  /** agent 掉线时把所有会话的 busy 放掉（否则会话会被永久锁死）。 */
  #releaseAllBusy() {
    let released = 0;
    for (const conversation of this.#conversations.values()) {
      if (conversation.busy === true) {
        conversation.busy = false;
        released += 1;
      }
    }
    if (released > 0) this.#log(`agent 断线，已放行 ${released} 个会话的 busy 锁`);
  }

  #deviceStatus() {
    return {
      online: this.agentOnline,
      deviceName: 'DeepSeek Harness',
      agentVersion: this.#version,
      harnessVersion: this.#version,
      capabilities: {
        chat: true,
        cancel: true,
        approvalIntercept: true,
        sessionResume: true,
        workspaceList: true,
        fileRead: true,
        fileWrite: true,
      },
      lastSeen: new Date().toISOString(),
    };
  }

  #onAppMessage(peer, record, raw) {
    const envelope = parseEnvelope(raw);
    if (envelope === null) {
      this.#send(peer, createEnvelope('error', { code: 'BAD_REQUEST', message: 'invalid frame' }));
      return;
    }
    if (envelope.type === 'ping') {
      this.#send(peer, createEnvelope('pong', envelope.payload));
      return;
    }
    if (!APP_FORWARD_TYPES.has(envelope.type)) {
      this.#send(peer, createEnvelope('error', { code: 'BAD_REQUEST', message: `unsupported type: ${envelope.type}` }));
      return;
    }
    const payload = envelope.payload && typeof envelope.payload === 'object' ? { ...envelope.payload } : {};

    if (envelope.type === 'conversation.create') {
      const conversationId = typeof payload.conversationId === 'string' && payload.conversationId
        ? payload.conversationId
        : ulid();
      payload.conversationId = conversationId;
      this.#conversations.set(conversationId, { seq: 0, busy: false });
      this.#forwardToAgent(createEnvelope('conversation.create', payload));
      return;
    }

    if (envelope.type === 'prompt.send' || envelope.type === 'task.cancel') {
      const conversationId = payload.conversationId;
      let conversation = typeof conversationId === 'string' ? this.#conversations.get(conversationId) : undefined;
      // ACP 侧的会话 id 由 agent 自己生成并回传；客户端可能先拿到它再发 prompt。
      // 这里对未知 id 采取「在线即登记」的宽松策略，避免因为一次 id 对不上就整条链路卡死。
      if (
        conversation === undefined &&
        envelope.type === 'prompt.send' &&
        typeof conversationId === 'string' &&
        conversationId.length > 0 &&
        this.agentOnline
      ) {
        conversation = { seq: 0, busy: false };
        this.#conversations.set(conversationId, conversation);
      }
      if (conversation === undefined) {
        this.#send(peer, createEnvelope('error', { code: 'CONVERSATION_NOT_FOUND', message: 'unknown conversation' }));
        return;
      }
      if (envelope.type === 'prompt.send') {
        if (conversation.busy) {
          this.#send(peer, createEnvelope('error', { code: 'SESSION_BUSY', message: 'session busy' }));
          return;
        }
        conversation.busy = true;
        conversation.seq += 1;
        payload.seq = conversation.seq;
        const forwarded = createEnvelope('prompt.send', payload);
        forwarded.seq = conversation.seq;
        this.#forwardToAgent(forwarded);
        return;
      }
      this.#forwardToAgent(createEnvelope('task.cancel', payload));
      return;
    }

    this.#forwardToAgent(createEnvelope(envelope.type, payload));
  }

  #onAgentMessage(raw) {
    const envelope = parseEnvelope(raw);
    if (envelope === null) return;
    if (!AGENT_BROADCAST_TYPES.has(envelope.type)) return;
    const payload = envelope.payload && typeof envelope.payload === 'object' ? { ...envelope.payload } : {};

    if (envelope.type === 'device.status') {
      this.#agentStatus = payload;
    }

    // 采纳 agent 侧回传的 conversationId（ACP sessionId 由它生成）
    const echoedId = payload.conversationId;
    if (
      typeof echoedId === 'string' &&
      echoedId.length > 0 &&
      !this.#conversations.has(echoedId) &&
      (envelope.type === 'conversation.created' || envelope.type === 'error')
    ) {
      this.#conversations.set(echoedId, { seq: 0, busy: false });
    }

    if (envelope.type === 'task.state') {
      const conversationId = payload.conversationId;
      const conversation = typeof conversationId === 'string' ? this.#conversations.get(conversationId) : undefined;
      if (conversation !== undefined) {
        const state = String(payload.state ?? '');
        if (state === 'queued' || state === 'running') conversation.busy = true;
        if (state === 'completed' || state === 'failed' || state === 'cancelled') conversation.busy = false;
      }
    }

    if (envelope.type === 'session.update' || envelope.type === 'task.state') {
      const conversationId = payload.conversationId;
      const conversation = typeof conversationId === 'string' ? this.#conversations.get(conversationId) : undefined;
      if (conversation !== undefined && typeof payload.seq !== 'number') {
        conversation.seq += 1;
        payload.seq = conversation.seq;
      }
    }

    this.broadcast(envelope.type, payload);
  }

  #forwardToAgent(envelope) {
    if (!this.agentOnline) {
      this.broadcast('error', { code: 'DEVICE_OFFLINE', message: 'agent offline' });
      return;
    }
    this.#send(this.#agent, envelope);
  }

  /** HTTP 辅助：校验已配对设备的 token（只读镜像接口用）。 */
  authorizeToken(token, role = 'app') {
    const record = this.#tokens.get(this.#hashToken(token));
    if (!record || record.role !== role) return false;
    return record.expiresAt.getTime() > Date.now();
  }

  /** 主动撤销一个 token（用户「断开这台设备」时调用）。 */
  revokeToken(token) {
    const key = this.#hashToken(token);
    if (!this.#tokens.has(key)) return false;
    this.#tokens.delete(key);
    this.#persistTokens();
    return true;
  }

  broadcast(type, payload) {
    const envelope = createEnvelope(type, payload);
    const text = JSON.stringify(envelope);
    for (const peer of this.#apps) {
      if (!peer.closed) peer.sendText(text);
    }
  }

  #send(peer, envelope) {
    if (peer === null || peer.closed) return;
    peer.sendText(JSON.stringify(envelope));
  }

  dispose() {
    if (this.#disposed) return;
    this.#disposed = true;
    for (const peer of this.#apps) peer.close(1001, 'server shutdown');
    this.#apps.clear();
    if (this.#agent !== null) {
      this.#agent.close(1001, 'server shutdown');
      this.#agent = null;
    }
    this.#tokens.clear();
  }
}
