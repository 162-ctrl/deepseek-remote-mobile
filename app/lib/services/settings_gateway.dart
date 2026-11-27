import 'package:flutter/services.dart';

/// 轻量键值设置存储网关（M2.2 A3）。
///
/// 真实实现走 Kotlin `SharedPreferences`（MethodChannel
/// `deepseek_remote/settings`），单测里注入 [FakeSettingsGateway]。
abstract class SettingsGateway {
  Future<String?> getString(String key);

  Future<void> setString(String key, String value);

  Future<void> dispose();
}

/// 通过平台通道读写 SharedPreferences 的实现。
class MethodChannelSettingsGateway implements SettingsGateway {
  MethodChannelSettingsGateway({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  static const String channelName = 'deepseek_remote/settings';

  final MethodChannel _channel;

  @override
  Future<String?> getString(String key) async {
    try {
      return await _channel.invokeMethod<String>('getString', {'key': key});
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<void> setString(String key, String value) async {
    try {
      await _channel
          .invokeMethod<void>('setString', {'key': key, 'value': value});
    } on MissingPluginException {
      // 桌面/测试环境没有原生实现：静默降级，不影响功能。
    } on PlatformException {
      // 忽略写入失败，主题只在本次运行内生效。
    }
  }

  @override
  Future<void> dispose() async {}
}

/// 内存实现，用于单测（同时记录调用次数方便断言持久化）。
class FakeSettingsGateway implements SettingsGateway {
  FakeSettingsGateway({Map<String, String>? seed})
      : values = <String, String>{...?seed};

  final Map<String, String> values;
  int getCalls = 0;
  int setCalls = 0;
  bool disposed = false;

  @override
  Future<String?> getString(String key) async {
    getCalls++;
    return values[key];
  }

  @override
  Future<void> setString(String key, String value) async {
    setCalls++;
    values[key] = value;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}
