import 'pairing_api.dart';

/// 从二维码（或粘贴的文本）里解析出来的一次配对信息。
///
/// 电脑端 `dsh-plugin-m1` 的配网页把地址和匹配码编进同一个二维码，形如：
///
/// ```
/// http://192.168.1.x:8787#c=000000        # 局域网
/// https://<公网隧道>.trycloudflare.com#c=000000  # 公网隧道
/// ```
///
/// 为了容错，下面这些写法都认：
/// - `host:8787#c=123456`（没写协议，局域网补 http）
/// - `http://host:8787/?code=123456`（query 而不是 fragment）
/// - `dshremote://host:8787#c=123456`（自定义 scheme，方便以后做深链）
/// - 只有地址没有码（`http://host:8787`）：[pairingCode] 为 null，界面让用户手输 6 位码。
class PairingLink {
  const PairingLink({
    required this.baseUrl,
    this.pairingCode,
    this.raw = '',
  });

  /// 规范化后的基地址，例如 `http://192.168.1.x:8787`。
  final String baseUrl;

  /// 二维码里带的匹配码；没带时为 null。
  final String? pairingCode;

  /// 扫描到的原始文本，用于在界面上回显"扫到了什么"。
  final String raw;

  bool get hasCode => pairingCode != null && pairingCode!.isNotEmpty;

  /// 解析失败（不是配对二维码、地址不合法、只扫到一串数字等）返回 null。
  static PairingLink? tryParse(String raw) {
    final text = raw.trim();
    if (text.isEmpty) {
      return null;
    }

    var body = text;

    // 自定义 scheme（dshremote://…）只是外壳，真正的地址仍交给 normalizeBaseUrl 判断。
    final schemeMatch = RegExp(
      r'^([a-zA-Z][a-zA-Z0-9+.\-]*)://(.*)$',
      dotAll: true,
    ).firstMatch(body);
    if (schemeMatch != null) {
      final scheme = schemeMatch.group(1)!.toLowerCase();
      const passthrough = {'http', 'https'};
      const wrappers = {'dshremote', 'dsh', 'deepseek', 'dsremote'};
      if (passthrough.contains(scheme)) {
        // 保持原样，normalizeBaseUrl 会处理。
      } else if (wrappers.contains(scheme)) {
        body = schemeMatch.group(2)!;
      } else {
        return null;
      }
    }

    String? code;
    final hashIndex = body.indexOf('#');
    if (hashIndex >= 0) {
      code = _codeFromParams(body.substring(hashIndex + 1));
      body = body.substring(0, hashIndex);
    }
    final queryIndex = body.indexOf('?');
    if (queryIndex >= 0) {
      code ??= _codeFromParams(body.substring(queryIndex + 1));
      body = body.substring(0, queryIndex);
    }

    body = body.trim();
    if (body.isEmpty) {
      return null;
    }

    // 没有协议时，要求它看起来真的像 host[:port][/path]：
    // 这样 `mailto:a@b.com`、`这是一句话` 之类的文本不会被打成地址。
    final hasScheme =
        body.startsWith('http://') || body.startsWith('https://');
    if (!hasScheme && !_hostPortPattern.hasMatch(body)) {
      return null;
    }

    final String baseUrl;
    try {
      baseUrl = PairingApi.normalizeBaseUrl(body);
    } on PairingApiException {
      return null;
    } catch (_) {
      return null;
    }

    // 拦住"只扫到一串数字/一句话"的情况：主机名至少要像一个地址。
    final host = Uri.tryParse(baseUrl)?.host ?? '';
    if (host.isEmpty) {
      return null;
    }
    final looksLikeHost =
        host.contains('.') || host.contains(':') || host == 'localhost';
    if (!looksLikeHost) {
      return null;
    }

    return PairingLink(baseUrl: baseUrl, pairingCode: code, raw: text);
  }

  /// `localhost` / IPv4 / 域名 / `[IPv6]`，可带端口与路径，不带协议。
  static final RegExp _hostPortPattern = RegExp(
    r'^(localhost|\[[0-9a-fA-F:]+\]|[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?)*)(:\d{1,5})?(\/\S*)?$',
  );

  /// 从 `c=123456&x=y` 这样的参数串里取 4–8 位数字码。
  static String? _codeFromParams(String params) {
    if (params.isEmpty) {
      return null;
    }
    for (final pair in params.split('&')) {
      final index = pair.indexOf('=');
      if (index <= 0) {
        continue;
      }
      final key = pair.substring(0, index).trim().toLowerCase();
      if (key != 'c' &&
          key != 'code' &&
          key != 'pair' &&
          key != 'pairing' &&
          key != 'pairingcode' &&
          key != 'pairing_code') {
        continue;
      }
      final value = pair.substring(index + 1).trim();
      if (RegExp(r'^\d{4,8}$').hasMatch(value)) {
        return value;
      }
    }
    return null;
  }
}
