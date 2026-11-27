import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

/// 存放敏感凭证（目前只有 token）的抽象。
///
/// M4.43：token 以前和 serverUrl 一起明文写在 `<support>/session.json`，root 过的
/// 机器、`adb backup`、厂商云备份都能整包带走，而 token 是 30 天有效的完整控制权。
/// 现在拆成两层：token 走系统钥匙串/EncryptedSharedPreferences，其余元数据继续
/// 写 json。抽成接口是为了测试能注入内存实现，不用拦 MethodChannel。
abstract class TokenVault {
  Future<String?> read();

  Future<void> write(String token);

  Future<void> clear();
}

/// 真机实现：Android 走 EncryptedSharedPreferences，iOS 走 Keychain。
class SecureTokenVault implements TokenVault {
  SecureTokenVault({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const String tokenKey = 'session_token';

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read() async {
    final value = await _storage.read(key: tokenKey);
    if (value == null || value.isEmpty) return null;
    return value;
  }

  @override
  Future<void> write(String token) => _storage.write(key: tokenKey, value: token);

  @override
  Future<void> clear() => _storage.delete(key: tokenKey);
}

/// 测试用的内存实现（也方便在没有安全存储的桌面上跑）。
class InMemoryTokenVault implements TokenVault {
  InMemoryTokenVault([this.value]);

  String? value;
  int writes = 0;
  int clears = 0;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String token) async {
    value = token;
    writes += 1;
  }

  @override
  Future<void> clear() async {
    value = null;
    clears += 1;
  }
}

/// M2.9.6：把上次成功配对的地址与 token 存到磁盘，App 冷启动时直接续连。
///
/// 只存「地址 + token + 设备信息」，不存配对码；token 由插件签发，默认 30 天有效。
class SavedSession {
  const SavedSession({
    required this.serverUrl,
    required this.token,
    this.deviceId,
    this.savedAt = 0,
  });

  factory SavedSession.fromJson(Map<String, dynamic> json) {
    final serverUrl = json['serverUrl'];
    final token = json['token'];
    if (serverUrl is! String || serverUrl.isEmpty || token is! String || token.isEmpty) {
      throw const FormatException('saved session incomplete');
    }
    return SavedSession(
      serverUrl: serverUrl,
      token: token,
      deviceId: json['deviceId'] is String ? json['deviceId'] as String : null,
      savedAt: json['savedAt'] is int ? json['savedAt'] as int : 0,
    );
  }

  final String serverUrl;
  final String token;
  final String? deviceId;
  final int savedAt;

  /// 完整形态（含 token）。**只在内存里用，不要写盘。**
  Map<String, dynamic> toJson() => {
        'serverUrl': serverUrl,
        'token': token,
        if (deviceId != null) 'deviceId': deviceId,
        'savedAt': savedAt,
      };

  /// 落盘形态：**不含 token**，token 由 [TokenVault] 单独保存。
  Map<String, dynamic> toMetadataJson() => {
        'serverUrl': serverUrl,
        if (deviceId != null) 'deviceId': deviceId,
        'savedAt': savedAt,
      };
}

class SessionStore {
  SessionStore({
    this.fileName = 'session.json',
    TokenVault? vault,
    Future<Directory> Function()? directory,
  })  : _vault = vault ?? SecureTokenVault(),
        _directory = directory;

  final String fileName;
  final TokenVault _vault;
  final Future<Directory> Function()? _directory;
  File? _cached;

  Future<File> _file() async {
    final cached = _cached;
    if (cached != null) return cached;
    final dir = _directory != null
        ? await _directory!()
        : await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return _cached = File('${dir.path}${Platform.pathSeparator}$fileName');
  }

  Future<SavedSession?> load() async {
    try {
      final stored = await _vault.read();
      final file = await _file();
      Map<String, dynamic>? meta;
      if (await file.exists()) {
        final raw = await file.readAsString();
        if (raw.trim().isNotEmpty) {
          final decoded = jsonDecode(raw);
          if (decoded is Map<String, dynamic>) meta = decoded;
        }
      }

      // 迁移：老版本把 token 明文写在 json 里。搬进 vault，再把 json 重写一遍。
      final legacy = meta?['token'];
      String? token = stored;
      if (token == null && legacy is String && legacy.isNotEmpty) {
        token = legacy;
        await _vault.write(legacy);
        final stripped = Map<String, dynamic>.from(meta!)..remove('token');
        await file.writeAsString(jsonEncode(stripped), flush: true);
        meta = stripped;
      }

      // 任何一边缺了都算没登录：只有 token 没地址不知道连哪，只有地址没 token 也连不上。
      if (meta == null || token == null) return null;
      return SavedSession.fromJson({...meta, 'token': token});
    } catch (_) {
      return null;
    }
  }

  Future<void> save(SavedSession session) async {
    try {
      await _vault.write(session.token);
      final file = await _file();
      await file.writeAsString(jsonEncode(session.toMetadataJson()), flush: true);
    } catch (_) {
      /* 存不下来只影响下次自动续连 */
    }
  }

  Future<void> clear() async {
    try {
      await _vault.clear();
    } catch (_) {
      /* ignore */
    }
    try {
      final file = await _file();
      if (await file.exists()) await file.delete();
    } catch (_) {
      /* ignore */
    }
  }
}
