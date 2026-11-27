import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'pairing_api.dart';
import 'relay_protocol.dart';

/// 中继客户端连接状态。
enum RelayClientState { idle, connecting, connected, reconnecting, error }

/// 一条 WebSocket 连接的最小抽象：真实实现包 `dart:io WebSocket`，
/// 单测里注入假实现，因此重连/解析逻辑可以不联网测试。
abstract class RelaySocket {
  /// 文本帧流。
  Stream<String> get messages;

  /// 对端关闭码（正常关闭前为 null）。
  int? get closeCode;

  /// 对端关闭原因。
  String? get closeReason;

  void send(String data);

  Future<void> close([int? code, String? reason]);
}

/// 建连函数，可注入。
typedef RelaySocketConnector = Future<RelaySocket> Function(Uri uri);

/// 连接/建连失败。message 已是中文人话。
class RelayClientException implements Exception {
  const RelayClientException(this.message, {this.fatal = false});

  final String message;

  /// 认证失败等「重试也没用」的错误。
  final bool fatal;

  @override
  String toString() => 'RelayClientException: $message';
}

/// 中继 WebSocket 客户端：建连、事件广播、发送、指数退避重连、主动断开。
class RelayClient {
  RelayClient({
    RelaySocketConnector? connector,
    this.role = 'app',
    this.initialRetryDelay = const Duration(seconds: 1),
    this.maxRetryDelay = const Duration(seconds: 30),
    this.maxRetries = 0,
    this.connectTimeout = const Duration(seconds: 15),
    this.heartbeatInterval = const Duration(seconds: 20),
    this.heartbeatTimeout = const Duration(seconds: 55),
  }) : _connector = connector ?? _dartIoConnector;

  final RelaySocketConnector _connector;
  final String role;
  final Duration initialRetryDelay;
  final Duration maxRetryDelay;

  /// 0 表示无限重试（手机端默认），>0 时到达次数后放弃。
  final int maxRetries;
  final Duration connectTimeout;

  /// 心跳：每隔 [heartbeatInterval] 发一次 ping，超过 [heartbeatTimeout]
  /// 没收到任何消息就判定连接已死并重连（Cloudflare 隧道静默断流时靠它发现）。
  final Duration heartbeatInterval;
  final Duration heartbeatTimeout;

  final StreamController<RelayEvent> _events =
      StreamController<RelayEvent>.broadcast();
  final StreamController<RelayClientState> _states =
      StreamController<RelayClientState>.broadcast();
  final StreamController<void> _authFailures =
      StreamController<void>.broadcast();

  RelayClientState _state = RelayClientState.idle;
  RelaySocket? _socket;
  StreamSubscription<String>? _subscription;
  Timer? _retryTimer;
  Timer? _heartbeatTimer;
  Timer? _watchdogTimer;
  DateTime _lastInboundAt = DateTime.now();
  bool _manualClose = true;
  bool _reconnectLoopRunning = false;
  int _attempt = 0;
  String? _lastError;
  String? _serverUrl;
  String? _token;

  /// 服务端 → App 的事件流（协议信封解析后的）。
  Stream<RelayEvent> get events => _events.stream;

  /// 连接状态流。
  Stream<RelayClientState> get states => _states.stream;

  /// 认证失效流：WSS 握手被以 4401（token 无效/过期）关闭时触发一次，
  /// 供上层用配对码自动重新配对（M2 §2.4）。
  Stream<void> get authFailures => _authFailures.stream;

  RelayClientState get state => _state;

  bool get isConnected => _state == RelayClientState.connected;

  String? get lastError => _lastError;

  String? get serverUrl => _serverUrl;

  /// 建连（单次尝试，不自动重连）。失败抛 [RelayClientException]。
  Future<void> connect(String serverUrl, {required String token}) async {
    _manualClose = false;
    _serverUrl = serverUrl;
    _token = token;
    _attempt = 0;
    _lastError = null;
    try {
      await _open();
    } on RelayClientException {
      _setState(RelayClientState.error);
      rethrow;
    }
  }

  /// 外部触发一次后台重连（App 回到前台、网络恢复时用）。
  ///
  /// 与 [connect] 不同：不抛异常、不改地址，失败后继续按退避重试。
  void reconnectInBackground() {
    if (_manualClose) return;
    if (_state == RelayClientState.connected) return;
    if (_reconnectLoopRunning) return;
    unawaited(_scheduleReconnect());
  }

  /// 主动断开：关闭连接并回到 idle，不再重连。
  Future<void> disconnect() async {
    _manualClose = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    _reconnectLoopRunning = false;
    await _teardownSocket();
    if (_state != RelayClientState.idle) {
      _setState(RelayClientState.idle);
    }
  }

  /// 发送一条 App → 后端消息；未连接时返回 false（不抛异常）。
  bool send(String type, [Map<String, dynamic> payload = const {}]) {
    final socket = _socket;
    if (socket == null || _state != RelayClientState.connected) return false;
    try {
      socket.send(encodeRelayMessage(type: type, payload: payload));
      return true;
    } catch (e) {
      _lastError = '发送失败：$e';
      _handleDrop();
      return false;
    }
  }

  Future<void> dispose() async {
    _manualClose = true;
    _retryTimer?.cancel();
    await _teardownSocket();
    await _events.close();
    await _states.close();
    await _authFailures.close();
  }

  // -------------------------------------------------------------------------
  // 建连 / 重连
  // -------------------------------------------------------------------------

  Future<void> _open() async {
    final url = _serverUrl;
    final token = _token;
    if (url == null || token == null) {
      throw const RelayClientException('尚未配置服务器地址');
    }
    _setState(_attempt == 0 ? RelayClientState.connecting : RelayClientState.reconnecting);
    final uri = webSocketUri(url, token: token, role: role);
    RelaySocket socket;
    try {
      socket = await _connector(uri).timeout(connectTimeout);
    } on RelayClientException {
      rethrow;
    } on TimeoutException {
      throw RelayClientException(
          '连接超时（${connectTimeout.inSeconds} 秒）：电脑端没有响应，请检查地址与网络');
    } on HandshakeException {
      throw const RelayClientException(
          'WSS 握手失败：请确认地址是 https/wss 且证书有效');
    } on SocketException catch (e) {
      throw RelayClientException(
          '无法连接到服务器：${e.message.isEmpty ? e.osError?.message ?? e.toString() : e.message}');
    } on WebSocketException catch (e) {
      throw RelayClientException('WebSocket 连接失败：${e.message}');
    } catch (e) {
      throw RelayClientException('连接失败：$e');
    }

    _socket = socket;
    _attempt = 0;
    _lastError = null;
    _setState(RelayClientState.connected);
    _startHeartbeat();
    _subscription = socket.messages.listen(
      _onRawMessage,
      onError: (Object error) {
        _lastError = '连接出错：$error';
        _handleDrop();
      },
      onDone: () {
        final code = socket.closeCode;
        final reason = socket.closeReason;
        _handleDrop(closeCode: code, closeReason: reason);
      },
      cancelOnError: false,
    );
  }

  void _handleDrop({int? closeCode, String? closeReason}) {
    final wasManual = _manualClose;
    if (!wasManual && _socket == null && _state != RelayClientState.connected) {
      // 已经处理过一次掉线（onError 后 onDone 还会再来一次），忽略重复回调。
      return;
    }
    _teardownSocket();
    if (wasManual) {
      _setState(RelayClientState.idle);
      return;
    }
    if (closeCode == 4401) {
      _lastError = '认证失败：token 无效或已过期，请重新配对';
      if (!_authFailures.isClosed) _authFailures.add(null);
      _setState(RelayClientState.error);
      return;
    }
    if (closeCode == 1008) {
      _lastError = '服务器拒绝了连接（策略限制）：$closeReason';
      _setState(RelayClientState.error);
      return;
    }
    if (closeCode != null && closeCode != 1000 && closeCode != 1001) {
      _lastError =
          '连接已断开（code $closeCode${closeReason == null || closeReason.isEmpty ? '' : '：$closeReason'}）';
    } else if (_lastError == null) {
      _lastError = '连接已断开，正在尝试重连…';
    }
    unawaited(_scheduleReconnect());
  }

  Future<void> _scheduleReconnect() async {
    if (_reconnectLoopRunning || _manualClose) return;
    _reconnectLoopRunning = true;
    try {
      while (!_manualClose && (maxRetries <= 0 || _attempt < maxRetries)) {
        _attempt += 1;
        final delay = _delayForAttempt(_attempt);
        _setState(RelayClientState.reconnecting);
        await Future<void>.delayed(delay);
        if (_manualClose) break;
        try {
          await _open();
          _reconnectLoopRunning = false;
          return;
        } on RelayClientException catch (e) {
          _lastError = e.message;
          if (e.fatal) {
            _setState(RelayClientState.error);
            break;
          }
        }
      }
      if (!_manualClose && maxRetries > 0 && _attempt >= maxRetries) {
        _lastError = '多次重连失败（$maxRetries 次），请检查电脑端与网络';
        _setState(RelayClientState.error);
      }
    } finally {
      _reconnectLoopRunning = false;
    }
  }

  Duration _delayForAttempt(int attempt) {
    final factor = 1 << (attempt - 1).clamp(0, 10);
    final base = initialRetryDelay.inMilliseconds * factor;
    final capped = base > maxRetryDelay.inMilliseconds ? maxRetryDelay.inMilliseconds : base;
    // ±20% 抖动：网络切换时避免所有连接同一秒重试。
    final jitter = (capped * (0.8 + Random().nextDouble() * 0.4)).round();
    return Duration(milliseconds: jitter);
  }

  Future<void> _teardownSocket() async {
    final subscription = _subscription;
    _subscription = null;
    final socket = _socket;
    _socket = null;
    if (subscription != null) {
      try {
        await subscription.cancel();
      } catch (_) {
        // 忽略：连接已失效。
      }
    }
    if (socket != null) {
      try {
        await socket.close(1000, 'client close');
      } catch (_) {
        // 忽略：连接可能已断开。
      }
    }
  }

  void _onRawMessage(String raw) {
    _lastInboundAt = DateTime.now();
    try {
      final event = RelayEvent.parse(raw);
      if (!_events.isClosed) _events.add(event);
    } on RelayProtocolException catch (e) {
      _lastError = '收到无法识别的消息：${e.message}';
    } catch (e) {
      _lastError = '消息处理失败：$e';
    }
  }

  void _startHeartbeat() {
    _stopHeartbeat();
    _lastInboundAt = DateTime.now();
    _heartbeatTimer = Timer.periodic(heartbeatInterval, (_) {
      if (_state != RelayClientState.connected) return;
      final socket = _socket;
      if (socket == null) return;
      try {
        socket.send(encodeRelayMessage(type: 'ping'));
      } catch (_) {
        // 发送失败交给 watchdog / onError 处理。
      }
    });
    // 检查频率跟着超时走：真实环境 55s 超时 → 5s 一查；
    // 测试里把超时调到 100ms 时，也能在几百毫秒内发现。
    final tick = heartbeatTimeout < const Duration(seconds: 5)
        ? Duration(
            milliseconds: (heartbeatTimeout.inMilliseconds ~/ 4).clamp(20, 5000))
        : const Duration(seconds: 5);
    _watchdogTimer = Timer.periodic(tick, (_) {
      if (_state != RelayClientState.connected) return;
      final silentFor = DateTime.now().difference(_lastInboundAt);
      if (silentFor >= heartbeatTimeout) {
        _lastError = '连接心跳超时（${silentFor.inSeconds} 秒无响应），正在重连…';
        _handleDrop();
      }
    });
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
  }

  void _setState(RelayClientState next) {
    if (_state == next) return;
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }

  // -------------------------------------------------------------------------
  // 地址换算（纯函数，可单测）
  // -------------------------------------------------------------------------

  /// 服务器基地址 → WebSocket URI：https→wss、http→ws，路径补 `/ws`，
  /// query 带 `role` 与 `token`（契约 §2.3）。
  static Uri webSocketUri(String serverUrl, {required String token, String role = 'app'}) {
    final base = PairingApi.normalizeBaseUrl(serverUrl);
    var path = Uri.parse(base).path;
    path = path.replaceAll(RegExp(r'/+$'), '');
    if (!path.endsWith('/ws')) {
      path = '$path/ws';
    }
    return Uri.parse(base).replace(
      scheme: Uri.parse(base).scheme == 'https' ? 'wss' : 'ws',
      path: path,
      queryParameters: <String, String>{'role': role, 'token': token},
    );
  }

  /// 供测试直接注入的默认建连器。
  static Future<RelaySocket> _dartIoConnector(Uri uri) async {
    final socket = await WebSocket.connect(uri.toString());
    return _IoRelaySocket(socket);
  }
}

/// `dart:io WebSocket` 的 [RelaySocket] 适配器。
class _IoRelaySocket implements RelaySocket {
  _IoRelaySocket(this._socket) {
    _messages = _socket.map<String>((dynamic event) {
      if (event is String) return event;
      if (event is List<int>) return utf8.decode(event, allowMalformed: true);
      return event.toString();
    });
  }

  final WebSocket _socket;
  late final Stream<String> _messages;

  @override
  Stream<String> get messages => _messages;

  @override
  int? get closeCode => _socket.closeCode;

  @override
  String? get closeReason => _socket.closeReason;

  @override
  void send(String data) => _socket.add(data);

  @override
  Future<void> close([int? code, String? reason]) => _socket.close(code, reason);
}
