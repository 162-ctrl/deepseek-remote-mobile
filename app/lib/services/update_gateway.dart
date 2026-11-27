import 'package:flutter/services.dart';

/// M2.5 A2：系统安装器桥（MethodChannel `deepseek_remote/update`）。
///
/// 纯 Dart 侧网关：Android 原生不可用（单测/桌面）时不崩溃，UI 降级提示。
class UpdateGatewayException implements Exception {
  const UpdateGatewayException(this.message);

  final String message;

  @override
  String toString() => 'UpdateGatewayException: $message';
}

abstract class UpdateGateway {
  /// 应用缓存目录（APK 下载到 `{cacheDir}/updates/`）。
  Future<String?> cacheDirectory();

  /// 是否允许安装未知来源应用；< Android 8 恒为 true。
  Future<bool> canInstallPackages();

  /// 打开系统「安装未知应用」授权页。
  Future<void> openInstallSettings();

  /// 调起系统安装器，完成后用户还需在系统界面点一次「更新」。
  Future<void> installApk(String path);

  Future<void> dispose();
}

class MethodChannelUpdateGateway implements UpdateGateway {
  MethodChannelUpdateGateway({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  static const String channelName = 'deepseek_remote/update';

  final MethodChannel _channel;

  Future<T?> _invoke<T>(String method, [Map<String, dynamic>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String?> cacheDirectory() => _invoke<String>('getCacheDirectory');

  @override
  Future<bool> canInstallPackages() async =>
      await _invoke<bool>('canInstallPackages') ?? false;

  @override
  Future<void> openInstallSettings() async {
    await _invoke<Object>('openInstallSettings');
  }

  @override
  Future<void> installApk(String path) async {
    try {
      final result = await _channel.invokeMethod<Map<Object?, Object?>>(
        'installApk',
        <String, dynamic>{'path': path},
      );
      if (result == null) {
        throw const UpdateGatewayException('系统安装器没有响应');
      }
    } on MissingPluginException {
      throw const UpdateGatewayException('当前安装环境不支持应用内更新');
    } on PlatformException catch (error) {
      throw UpdateGatewayException(error.message ?? '无法调起系统安装器');
    }
  }

  @override
  Future<void> dispose() async {}
}

/// 单测/注入用的 Fake 实现。
class FakeUpdateGateway implements UpdateGateway {
  FakeUpdateGateway({
    String? cacheDir,
    this.canInstall = true,
    this.throwOnInstall = false,
    this.throwOnCanInstall = false,
    this.throwOnOpenSettings = false,
  }) : cacheDirPath = cacheDir;

  String? cacheDirPath;
  bool canInstall;
  bool throwOnInstall;
  bool throwOnCanInstall;
  bool throwOnOpenSettings;

  final List<String> installedPaths = <String>[];
  int settingsOpened = 0;
  int canInstallCalls = 0;
  bool disposed = false;

  @override
  Future<String?> cacheDirectory() async => cacheDirPath;

  @override
  Future<bool> canInstallPackages() async {
    canInstallCalls++;
    if (throwOnCanInstall) {
      throw const UpdateGatewayException('通道不可用');
    }
    return canInstall;
  }

  @override
  Future<void> openInstallSettings() async {
    settingsOpened++;
    if (throwOnOpenSettings) {
      throw const UpdateGatewayException('无法打开设置');
    }
  }

  @override
  Future<void> installApk(String path) async {
    if (throwOnInstall) {
      throw const UpdateGatewayException('当前安装环境不支持应用内更新');
    }
    installedPaths.add(path);
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}
