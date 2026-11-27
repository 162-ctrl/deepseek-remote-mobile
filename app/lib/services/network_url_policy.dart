// M4.44 / 用户三阶段计划第 1 阶段第 4 条：统一的连接地址安全策略。
//
// 以前每个入口各自判断：连接页只看能不能连上，云端接口只在字符串层面看
// `startsWith('http')`，更新地址直接拼 URL。于是公网明文 `http://` 也能通过，
// 而全局 `cleartextTrafficPermitted` 又是开着的——等于没有任何一处真正把关。
//
// 这里的规则只有三条：
//   1. 公网主机必须 `https://` / `wss://`（明文一律拒绝）；
//   2. `http://` / `ws://` 只允许回环、局域网、私有网段（含 Tailscale 的 100.64/10）；
//   3. 允许但未加密时给出明确提示，而不是静默降级。
//
// 纯函数、无 IO，便于任何入口复用与单测。
import 'dart:io' show InternetAddress;

/// 主机属于哪一类网络。
enum NetworkHostScope {
  /// 本机：`localhost`、`127.0.0.0/8`、`::1`。
  loopback,

  /// 局域网/私有网段：`10/8`、`172.16/12`、`192.168/16`、`169.254/16`、
  /// `100.64/10`（Tailscale）、IPv6 的 `fc00::/7` 与 `fe80::/10`。
  privateNetwork,

  /// 公网主机（域名或公网 IP）。
  publicHost,

  /// 解析不出来。
  invalid,
}

/// 一次地址检查的结果。
class NetworkUrlCheck {
  const NetworkUrlCheck({
    required this.scope,
    this.uri,
    this.error,
    this.secure = true,
  });

  final NetworkHostScope scope;
  final Uri? uri;

  /// 非空表示这个地址不能使用。
  final String? error;

  /// 是否走加密通道（https/wss）。
  final bool secure;

  bool get allowed => error == null && uri != null;

  /// 局域网明文连接的提示语；加密连接返回 null。
  String? get warning {
    if (!allowed || secure) return null;
    return '此连接未加密：内容在同一条网络上可被读取，只在信任的局域网里使用';
  }
}

class NetworkUrlPolicy {
  const NetworkUrlPolicy._();

  /// 允许的 scheme（`ws` 只在明确要求时才接受，避免把 WebSocket 地址当 HTTP 用）。
  static const Set<String> _httpSchemes = <String>{'http', 'https'};
  static const Set<String> _wsSchemes = <String>{'ws', 'wss'};

  /// 拆分并判断一个地址。
  ///
  /// [raw] 可以带 scheme，也可以只是 `192.168.1.5:8787`；
  /// [allowWebSocket] 为 true 时接受 `ws://` / `wss://`（中继地址用）。
  static NetworkUrlCheck inspect(String raw, {bool allowWebSocket = false}) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return const NetworkUrlCheck(
        scope: NetworkHostScope.invalid,
        error: '请先填写电脑端地址',
      );
    }

    // 有没有写协议，只能看 `xxx://` 这个前缀：Dart 的 Uri 会把 `192.168.1.5:8787`
    // 解析成 scheme = `192.168.1.5`（宽松解析），不能拿 scheme 是否为空来判断。
    final hasExplicitScheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(trimmed);
    final uri = hasExplicitScheme
        ? Uri.tryParse(trimmed)
        : Uri.tryParse('${_guessScheme(trimmed)}://$trimmed');
    if (uri == null || uri.host.isEmpty) {
      return const NetworkUrlCheck(
        scope: NetworkHostScope.invalid,
        error: '地址格式不正确，示例：https://<公网隧道>.trycloudflare.com 或 192.168.1.5:8787',
      );
    }

    final scheme = uri.scheme.toLowerCase();
    final schemes = allowWebSocket ? <String>{..._httpSchemes, ..._wsSchemes} : _httpSchemes;
    if (!schemes.contains(scheme)) {
      return NetworkUrlCheck(
        scope: NetworkHostScope.invalid,
        uri: uri,
        error: '只支持 http:// 或 https:// 开头的地址（收到 $scheme://）',
      );
    }

    final scope = classifyHost(uri.host);
    if (scope == NetworkHostScope.invalid) {
      return NetworkUrlCheck(
        scope: scope,
        uri: uri,
        error: '看不懂这个主机名：${uri.host}',
      );
    }

    final secure = scheme == 'https' || scheme == 'wss';
    if (!secure && scope == NetworkHostScope.publicHost) {
      return NetworkUrlCheck(
        scope: scope,
        uri: uri,
        error: '公网地址必须用 https://（明文 http 会被中间人读取，已拒绝）',
      );
    }

    return NetworkUrlCheck(scope: scope, uri: uri, secure: secure);
  }

  /// 把一个 host 归类。域名（含 `xxx.trycloudflare.com`）一律算公网。
  static NetworkHostScope classifyHost(String rawHost) {
    var host = rawHost.trim().toLowerCase();
    if (host.isEmpty) return NetworkHostScope.invalid;
    if (host.startsWith('[') && host.endsWith(']')) {
      host = host.substring(1, host.length - 1);
    }

    if (host == 'localhost' || host.endsWith('.localhost')) {
      return NetworkHostScope.loopback;
    }

    final address = InternetAddress.tryParse(host);
    if (address == null) {
      // 不是字面量 IP 就按域名处理：域名无法离线判断内网性，按最严的算。
      return NetworkHostScope.publicHost;
    }

    if (address.isLoopback) return NetworkHostScope.loopback;

    final bytes = address.rawAddress;
    if (bytes.length == 4) {
      final a = bytes[0];
      final b = bytes[1];
      if (a == 10) return NetworkHostScope.privateNetwork;
      if (a == 172 && b >= 16 && b <= 31) return NetworkHostScope.privateNetwork;
      if (a == 192 && b == 168) return NetworkHostScope.privateNetwork;
      if (a == 169 && b == 254) return NetworkHostScope.privateNetwork;
      if (a == 100 && b >= 64 && b <= 127) return NetworkHostScope.privateNetwork;
      return NetworkHostScope.publicHost;
    }

    // IPv6：fc00::/7（唯一本地）与 fe80::/10（链路本地）
    if (bytes.length == 16) {
      if ((bytes[0] & 0xfe) == 0xfc) return NetworkHostScope.privateNetwork;
      if (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80) return NetworkHostScope.privateNetwork;
    }
    return NetworkHostScope.publicHost;
  }

  static String _guessScheme(String raw) {
    var host = raw;
    final slash = host.indexOf('/');
    if (slash >= 0) host = host.substring(0, slash);
    final colon = host.lastIndexOf(':');
    if (colon >= 0 && !host.startsWith('[')) host = host.substring(0, colon);
    final scope = classifyHost(host);
    return scope == NetworkHostScope.publicHost ? 'https' : 'http';
  }
}
