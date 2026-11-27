import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 一次 HTTP JSON 调用的最小结果（只保留状态码与原始 body），
/// 便于把网络层做成可注入的，从而在纯单测里跑通成功/失败分支。
class JsonHttpResponse {
  const JsonHttpResponse(this.statusCode, this.body);

  final int statusCode;
  final String body;

  /// body 能解析成 JSON 对象时返回它，否则返回 null。
  Map<String, dynamic>? get jsonObject {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }
}

/// 可注入的 HTTP 发送器：`(method, uri, body)` → 响应。
typedef JsonHttpSender = Future<JsonHttpResponse> Function(
  String method,
  Uri uri,
  Map<String, dynamic>? body,
);

/// 配对/健康检查失败。UI 直接展示 [message]（已是人话）。
class PairingApiException implements Exception {
  const PairingApiException(
    this.message, {
    this.code,
    this.statusCode,
  });

  final String message;

  /// 后端错误码（如 AUTH_FAILED），网络层错误时为 null。
  final String? code;

  /// HTTP 状态码，网络层错误时为 null。
  final int? statusCode;

  @override
  String toString() => 'PairingApiException($code/$statusCode): $message';
}

/// 配对成功结果。
class PairResult {
  const PairResult({
    required this.token,
    required this.role,
    required this.deviceId,
    this.expiresAt,
  });

  factory PairResult.fromJson(Map<String, dynamic> json) {
    final token = json['token'];
    if (token is! String || token.isEmpty) {
      throw const PairingApiException('配对失败：服务器没有返回 token');
    }
    return PairResult(
      token: token,
      role: json['role'] is String ? json['role'] as String : 'app',
      deviceId: json['deviceId'] is String ? json['deviceId'] as String : '',
      expiresAt: json['expiresAt'] is String
          ? DateTime.tryParse(json['expiresAt'] as String)
          : null,
    );
  }

  final String token;
  final String role;
  final String deviceId;
  final DateTime? expiresAt;
}

/// `/api/v1/health` 结果。
class HealthResult {
  const HealthResult({
    required this.status,
    required this.version,
    required this.agentOnline,
    required this.apps,
  });

  factory HealthResult.fromJson(Map<String, dynamic> json) {
    final apps = json['apps'];
    return HealthResult(
      status: json['status'] is String ? json['status'] as String : 'unknown',
      version: json['version'] is String ? json['version'] as String : '未知',
      agentOnline: json['agentOnline'] == true,
      apps: apps is num ? apps.toInt() : 0,
    );
  }

  final String status;
  final String version;
  final bool agentOnline;
  final int apps;

  bool get healthy => status == 'ok';

  /// 供连接页展示的一行中文摘要。
  String get readableLabel {
    if (!healthy) return '后端状态异常：$status';
    final agent = agentOnline ? '电脑 Agent 在线' : '电脑 Agent 离线';
    return '后端正常 · v$version · $agent';
  }
}

/// 配对 + 健康检查客户端。零第三方依赖，只在 dart:io 上实现。
///
/// 两个方法都做完整错误映射：网络错误、超时、TLS、HTTP 错误码、非法 JSON
/// 都会抛 [PairingApiException]，其 message 可直接给用户看。
class PairingApi {
  PairingApi({
    JsonHttpSender? sender,
    this.timeout = const Duration(seconds: 10),
  }) : _sender = sender ?? _dartIoSender;

  final JsonHttpSender _sender;
  final Duration timeout;

  static const String pairPath = '/api/v1/auth/pair';
  static const String healthPath = '/api/v1/health';

  /// 配对：POST /api/v1/auth/pair（契约 §2.1）。
  Future<PairResult> pair(
    String baseUrl, {
    required String pairingCode,
    String clientName = 'DeepSeek Remote 手机',
  }) async {
    final code = pairingCode.trim();
    if (code.isEmpty) {
      throw const PairingApiException('请填写电脑端显示的配对码');
    }
    final uri = resolveEndpoint(baseUrl, pairPath);
    final response = await _run(
      () => _sender('POST', uri, <String, dynamic>{
        'pairingCode': code,
        'clientName': clientName,
        'role': 'app',
      }),
    );
    final json = _requireSuccess(response, path: pairPath);
    try {
      return PairResult.fromJson(json);
    } on PairingApiException {
      rethrow;
    } catch (e) {
      throw PairingApiException('配对失败：服务器返回格式不正确（$e）');
    }
  }

  /// 健康检查：GET /api/v1/health（契约 §2.2）。
  Future<HealthResult> health(String baseUrl) async {
    final uri = resolveEndpoint(baseUrl, healthPath);
    final response = await _run(() => _sender('GET', uri, null));
    final json = _requireSuccess(response, path: healthPath);
    try {
      return HealthResult.fromJson(json);
    } catch (e) {
      throw PairingApiException('健康检查失败：服务器返回格式不正确（$e）');
    }
  }

  // -------------------------------------------------------------------------
  // 纯函数工具（可单测）
  // -------------------------------------------------------------------------

  /// 把用户输入的地址规范成「基地址」：
  /// - 空 → 抛异常；
  /// - 缺协议 → 局域网/回环地址补 `http://`，其余补 `https://`；
  /// - `wss://` / `ws://` → `https://` / `http://`；
  /// - 去掉末尾的 `/` 与误粘贴的 `/ws`；
  /// - 去掉误粘贴的 `/api/v1` 后缀；
  /// - 去掉 `#c=…` 这类二维码 fragment（匹配码由 [PairingLink] 单独解析）。
  static String normalizeBaseUrl(String raw) {
    var value = raw.trim();
    if (value.isEmpty) {
      throw const PairingApiException('请先填写电脑端地址');
    }
    final hashIndex = value.indexOf('#');
    if (hashIndex >= 0) {
      value = value.substring(0, hashIndex).trim();
      if (value.isEmpty) {
        throw const PairingApiException('请先填写电脑端地址');
      }
    }
    if (value.startsWith('wss://')) {
      value = 'https://${value.substring('wss://'.length)}';
    } else if (value.startsWith('ws://')) {
      value = 'http://${value.substring('ws://'.length)}';
    } else if (!value.startsWith('http://') && !value.startsWith('https://')) {
      // 插件直连场景（dsh-plugin-m1）是局域网明文 HTTP，公网隧道才是 HTTPS。
      value = '${_isLocalHost(value) ? 'http' : 'https'}://$value';
    }
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    if (value.endsWith('/ws')) {
      value = value.substring(0, value.length - 3);
      while (value.endsWith('/')) {
        value = value.substring(0, value.length - 1);
      }
    }
    if (value.endsWith('/api/v1')) {
      value = value.substring(0, value.length - '/api/v1'.length);
      while (value.endsWith('/')) {
        value = value.substring(0, value.length - 1);
      }
    }
    final uri = Uri.tryParse(value);
    if (uri == null || uri.host.isEmpty) {
      throw const PairingApiException('服务器地址格式不正确，示例：https://<公网隧道>.trycloudflare.com');
    }
    return value;
  }

  /// 判断裸地址（可能带端口/路径）是否属于局域网或回环主机。
  ///
  /// 这些地址只有明文 HTTP，公网隧道域名才走 HTTPS。
  static bool _isLocalHost(String raw) {
    var host = raw;
    final schemeIndex = host.indexOf('://');
    if (schemeIndex >= 0) {
      host = host.substring(schemeIndex + 3);
    }
    final pathIndex = host.indexOf('/');
    if (pathIndex >= 0) {
      host = host.substring(0, pathIndex);
    }
    final queryIndex = host.indexOf('?');
    if (queryIndex >= 0) {
      host = host.substring(0, queryIndex);
    }
    if (!host.startsWith('[')) {
      final portIndex = host.lastIndexOf(':');
      if (portIndex >= 0) {
        host = host.substring(0, portIndex);
      }
    }
    host = host.toLowerCase();
    if (host.isEmpty) {
      return false;
    }
    if (host == 'localhost' ||
        host.endsWith('.localhost') ||
        host == '::1' ||
        host == '[::1]') {
      return true;
    }
    if (host.startsWith('127.') ||
        host.startsWith('192.168.') ||
        host.startsWith('10.') ||
        host.startsWith('169.254.')) {
      return true;
    }
    final parts = host.split('.');
    if (parts.length == 4 && parts[0] == '172') {
      final second = int.tryParse(parts[1]);
      if (second != null && second >= 16 && second <= 31) {
        return true;
      }
    }
    return false;
  }

  /// 基地址 + 路径 → 完整 URI。
  static Uri resolveEndpoint(String baseUrl, String path) {
    final base = normalizeBaseUrl(baseUrl);
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$base$normalizedPath');
  }

  /// HTTP 错误 → 人话。优先用后端返回的错误码，其次状态码。
  static String messageForHttpError(
    int statusCode, {
    String? code,
    String? serverMessage,
  }) {
    final detail = (serverMessage ?? '').trim();
    final known = switch (code) {
      'AUTH_FAILED' => '配对失败：配对码错误或已过期，请核对电脑端显示的配对码',
      'BAD_REQUEST' => '请求格式不正确：请确认地址指向 M1 后端',
      'DEVICE_OFFLINE' => '电脑 Agent 不在线：请确认电脑端已启动并已连接后端',
      'PATH_NOT_ALLOWED' => '工作区路径不在允许范围内',
      'INTERNAL' => '服务器内部错误，请稍后再试',
      null => null,
      _ => null,
    };
    if (known != null) {
      return detail.isEmpty ? known : '$known（$detail）';
    }
    if (statusCode == 401 || statusCode == 403) {
      return detail.isEmpty
          ? '配对失败：配对码错误或已过期（HTTP $statusCode）'
          : '配对失败：配对码错误或已过期（$detail）';
    }
    if (statusCode == 404) {
      return '接口不存在（HTTP 404）：请确认地址是 M1 后端的根地址';
    }
    if (statusCode == 429) {
      return '请求太频繁（HTTP 429）：请稍后再试';
    }
    if (statusCode >= 500) {
      return detail.isEmpty
          ? '服务器出错（HTTP $statusCode），请稍后再试'
          : '服务器出错（HTTP $statusCode）：$detail';
    }
    return detail.isEmpty ? '请求失败（HTTP $statusCode）' : '请求失败（HTTP $statusCode）：$detail';
  }

  /// 网络层异常 → 人话。
  static String describeException(Object error) {
    if (error is PairingApiException) return error.message;
    if (error is TimeoutException) {
      return '连接超时（10 秒）：服务器没有响应，请检查地址与网络';
    }
    if (error is HandshakeException) {
      return 'HTTPS 证书校验失败：隧道证书可能无效，请改用 http 地址或更新证书';
    }
    if (error is SocketException) {
      final detail = error.message;
      return detail.isEmpty
          ? '无法连接服务器：请检查地址、网络与电脑端是否在线'
          : '无法连接服务器：$detail';
    }
    if (error is FormatException) {
      return '服务器返回的内容不是合法 JSON：请确认地址指向 M1 后端';
    }
    return '连接失败：$error';
  }

  // -------------------------------------------------------------------------
  // 内部
  // -------------------------------------------------------------------------

  Map<String, dynamic> _requireSuccess(JsonHttpResponse response, {required String path}) {
    final json = response.jsonObject;
    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (json == null) {
        throw PairingApiException(
          '服务器返回的内容不是合法 JSON：请确认地址指向 M1 后端（$path）',
          statusCode: response.statusCode,
        );
      }
      return json;
    }
    final code = json?['code'];
    final message = json?['message'];
    throw PairingApiException(
      messageForHttpError(
        response.statusCode,
        code: code is String ? code : null,
        serverMessage: message is String ? message : null,
      ),
      code: code is String ? code : null,
      statusCode: response.statusCode,
    );
  }

  Future<JsonHttpResponse> _run(Future<JsonHttpResponse> Function() action) async {
    try {
      return await action().timeout(timeout);
    } on PairingApiException {
      rethrow;
    } catch (e) {
      throw PairingApiException(describeException(e));
    }
  }

  static Future<JsonHttpResponse> _dartIoSender(
    String method,
    Uri uri,
    Map<String, dynamic>? body,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..idleTimeout = const Duration(seconds: 5)
      ..userAgent = 'deepseek-remote-app/0.1';
    try {
      final request = await client.openUrl(method, uri);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (body != null) {
        final encoded = utf8.encode(jsonEncode(body));
        request.headers.contentType = ContentType.json;
        request.headers.contentLength = encoded.length;
        request.add(encoded);
      }
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      return JsonHttpResponse(response.statusCode, text);
    } finally {
      client.close(force: true);
    }
  }
}
