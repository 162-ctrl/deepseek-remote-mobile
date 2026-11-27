// M4.59 探路：在插件进程内当一次「浏览器客户端」。
//
// DSH 的提问事件是 agent 作用域派发的，插件从根 ctx 注册监听器收不到（M4.58 结论）。
// 但浏览器客户端能收到——它走的是 `/api/remote.mux` 这条 WebSocket 流：
//   { type: 'open', streamId, endpoint: '$events', payload: { args: {} } }
// 收到 `waterfall` 帧后，用 HTTP 回 `$events/result`：
//   POST /api/$events/result  { type:'client-request', rpcId, method:'$events/result',
//                               payload: { clientId, eventId, outcome: { kind:'result', value } } }
//
// 这一步只用来验证「插件能不能替手机收事件」，验证完再决定怎么接到 App 上。

import { randomUUID } from 'node:crypto'
import { request as httpRequest } from 'node:http'

const MUX_PATH = '/api/remote.mux'
const EVENTS_ENDPOINT = '$events'
const RESULT_ENDPOINT = '$events/result'

/** Open one authenticated browser session against the loopback Web server. */
async function login(baseUrl, trace) {
  const response = await fetch(baseUrl, { redirect: 'manual' })
  const cookies = typeof response.headers.getSetCookie === 'function'
    ? response.headers.getSetCookie()
    : []
  if (typeof trace === 'function') {
    trace(`LOGIN status=${response.status} setCookie=${cookies.length} url=${baseUrl.replace(/token=[^&]+/, 'token=***')}`)
  }
  if (cookies.length === 0) return ''
  return cookies.map((item) => item.split(';')[0]).join('; ')
}

/** Upgrade one HTTP request to a WebSocket and hand back the raw duplex socket. */
function openSocket({ port, path, cookie }) {
  return new Promise((resolve, reject) => {
    const request = httpRequest({
      host: '127.0.0.1',
      port,
      path,
      headers: {
        Connection: 'Upgrade',
        Upgrade: 'websocket',
        'Sec-WebSocket-Version': '13',
        'Sec-WebSocket-Key': Buffer.from(randomUUID().replaceAll('-', ''), 'hex').toString('base64'),
        ...(cookie.length > 0 ? { Cookie: cookie } : {}),
      },
    })
    request.on('upgrade', (response, socket) => resolve(socket))
    request.on('response', (response) => {
      response.resume()
      reject(new Error(`upgrade refused: HTTP ${response.statusCode}`))
    })
    request.on('error', reject)
    request.end()
  })
}

/** Encode one client frame for the raw socket (text frame, masked). */
function encodeFrame(text) {
  const payload = Buffer.from(text, 'utf8')
  const mask = Buffer.from([1, 2, 3, 4])
  const length = payload.length
  let header
  if (length < 126) {
    header = Buffer.from([0x81, 0x80 | length])
  } else if (length < 65536) {
    header = Buffer.alloc(4)
    header[0] = 0x81
    header[1] = 0x80 | 126
    header.writeUInt16BE(length, 2)
  } else {
    header = Buffer.alloc(10)
    header[0] = 0x81
    header[1] = 0x80 | 127
    header.writeBigUInt64BE(BigInt(length), 2)
  }
  const masked = Buffer.allocUnsafe(length)
  for (let index = 0; index < length; index += 1) masked[index] = payload[index] ^ mask[index % 4]
  return Buffer.concat([header, mask, masked])
}

/** Encode one masked control frame (ping/pong/close). */
function encodeControlFrame(opcode, payload = Buffer.alloc(0)) {
  const mask = Buffer.from([5, 6, 7, 8])
  const header = Buffer.from([0x80 | opcode, 0x80 | payload.length])
  const masked = Buffer.allocUnsafe(payload.length)
  for (let index = 0; index < payload.length; index += 1) masked[index] = payload[index] ^ mask[index % 4]
  return Buffer.concat([header, mask, masked])
}

/** Pull complete frames out of the buffered socket stream. */
function createFrameReader(onFrame) {
  let buffer = Buffer.alloc(0)
  return (chunk) => {
    buffer = Buffer.concat([buffer, chunk])
    for (;;) {
      if (buffer.length < 2) return
      const first = buffer[0]
      const second = buffer[1]
      const opcode = first & 0x0f
      const masked = (second & 0x80) !== 0
      let length = second & 0x7f
      let offset = 2
      if (length === 126) {
        if (buffer.length < 4) return
        length = buffer.readUInt16BE(2)
        offset = 4
      } else if (length === 127) {
        if (buffer.length < 10) return
        length = Number(buffer.readBigUInt64BE(2))
        offset = 10
      }
      const maskOffset = offset
      if (masked) offset += 4
      if (buffer.length < offset + length) return
      const mask = masked ? buffer.subarray(maskOffset, maskOffset + 4) : undefined
      const payload = Buffer.from(buffer.subarray(offset, offset + length))
      if (mask) for (let index = 0; index < payload.length; index += 1) payload[index] ^= mask[index % 4]
      buffer = buffer.subarray(offset + length)
      onFrame(opcode, payload)
    }
  }
}

/**
 * Start the spike client. Returns a handle even when DSH internals are missing,
 * so callers never need to branch on availability.
 * @param root0 - plugin services and observers.
 */
export async function startRemoteEventClient({ ctx, log, onFrame, trace }) {
  const connection = ctx.get('connection')
  const webServer = ctx.get('webServer')
  if (!connection?.authenticatedUrl || !webServer?.port) {
    throw new Error('remote-events: connection/webServer 还没准备好')
  }
  const port = webServer.port
  const base = connection.authenticatedUrl(`http://127.0.0.1:${port}/`)
  const cookie = await login(base, trace)
  if (typeof trace === 'function') trace(`LOGIN-DONE cookie=${cookie.length > 0 ? 'yes' : 'no'} port=${port}`)
  let socket
  try {
    socket = await openSocket({ port, path: MUX_PATH, cookie })
  } catch (error) {
    if (typeof trace === 'function') trace(`WS 失败: ${String(error?.message ?? error)}`)
    throw error
  }
  const streamId = `m1-${randomUUID()}`
  let clientId = ''
  let closed = false

  const send = (message) => socket.write(encodeFrame(JSON.stringify(message)))

  socket.on('data', createFrameReader((opcode, payload) => {
    if (opcode === 0x9) {
      socket.write(encodeControlFrame(0xa, payload))
      return
    }
    if (opcode === 0x8) {
      if (typeof trace === 'function') trace('WS 收到服务端关闭帧')
      socket.end()
      return
    }
    if (opcode !== 0x1) return
    let message
    try { message = JSON.parse(payload.toString('utf8')) } catch { return }
    if (message?.type === 'item' && message.streamId === streamId) {
      const value = message.value ?? {}
      if (value.type === 'ready') clientId = String(value.clientId ?? '')
      if (typeof onFrame === 'function') onFrame(value, { clientId, answer: (eventId, result) => reply(eventId, result) })
      return
    }
    if (message?.type === 'end' && message.streamId === streamId) log('remote-events: 事件流被服务端结束')
  }))

  const reply = async (eventId, value) => {
    const body = {
      type: 'client-request',
      rpcId: randomUUID(),
      method: RESULT_ENDPOINT,
      payload: {
        args: {
          clientId,
          eventId,
          outcome: value === undefined ? { kind: 'next' } : { kind: 'result', value },
        },
      },
    }
    const response = await fetch(`http://127.0.0.1:${port}/api/${RESULT_ENDPOINT}`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', ...(cookie.length > 0 ? { cookie } : {}) },
      body: JSON.stringify(body),
    })
    const text = await response.text().catch(() => '')
    if (typeof trace === 'function') trace(`REPLY ${eventId} → HTTP ${response.status} ${text.slice(0, 200)}`)
    return response.status
  }

  send({ type: 'open', streamId, endpoint: EVENTS_ENDPOINT, payload: { args: {} } })
  socket.on('close', (code, reason) => {
    if (closed) return
    closed = true
    if (typeof trace === 'function') trace(`WS 关闭 code=${code} reason=${String(reason ?? '')}`)
  })
  socket.on('error', (error) => log(`remote-events: WebSocket 出错 ${error?.message ?? error}`))
  log(`remote-events: 已连上 ${MUX_PATH}（port=${port}, cookie=${cookie.length > 0 ? 'yes' : 'no'}）`)

  return {
    close() {
      closed = true
      try { send({ type: 'cancel', streamId }) } catch {}
      try { socket.destroy() } catch {}
    },
  }
}
