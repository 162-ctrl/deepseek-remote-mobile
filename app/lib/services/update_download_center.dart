import 'dart:io';

import 'package:flutter/foundation.dart';

import 'update_gateway.dart';
import 'update_service.dart';

/// M4.29：APK 下载的「后台」状态。
///
/// 以前下载是由 `UpdateCheckTile` 的 State 直接 `await` 的，两件事都做不成：
/// - 弹窗一关（或用户切到别的页面），`_progressOpen` 变 false，进度再没人看；
/// - 页面被销毁后连「下载完了」这件事都无处呈现，几十兆缓存白下一次。
///
/// 现在下载挂在 [UpdateDownloadCenter] 上（默认全局单例）：弹窗只是它的一个
/// 观察者，关掉弹窗、离开「我的」页、把 App 切到后台，下载都继续走；回来时
/// 重新打开进度弹窗就能接上看进度，下完直接落成 [file] 等安装。
///
/// 注意这是「进程内的后台」：DSH 手机的保活服务让 Dart 侧不会被系统马上回收，
/// 但如果 App 被**杀掉**，下载会中断（没有走 Android 前台服务下载）。
class UpdateDownloadCenter extends ChangeNotifier {
  UpdateDownloadCenter({UpdateService? service})
      : _service = service ?? UpdateService();

  /// 全局实例：`UpdateCheckTile` 默认用它，页面重建也接着上一次的进度。
  static final UpdateDownloadCenter instance = UpdateDownloadCenter();

  final UpdateService _service;

  AppUpdateInfo? _info;
  String _baseUrl = '';
  String? _token;
  int _received = 0;
  int _total = 0;
  bool _running = false;
  bool _cancelled = false;
  String? _error;
  File? _file;
  UpdateCancelToken? _cancelToken;

  /// 正在下载（可以反复读，UI 据此显示「下载中 N%」）。
  bool get running => _running;

  /// 用户点了取消。
  bool get cancelled => _cancelled;

  /// 上次失败的原因（取消时为空）。
  String? get error => _error;

  /// 已经下好、等着安装的 APK。
  File? get file => _file;

  AppUpdateInfo? get info => _info;

  int get received => _received;

  int get total => _total;

  double? get ratio {
    if (_total <= 0) return null;
    return (_received / _total).clamp(0.0, 1.0);
  }

  /// 开始（或接上）一次下载。
  ///
  /// 同一个版本号重复点「立即更新」不会开两条流——直接返回正在进行的那次。
  Future<File?> start({
    required AppUpdateInfo info,
    required String baseUrl,
    String? token,
    required Future<String?> Function() cacheDirectory,
  }) {
    if (_running && _info?.versionCode == info.versionCode) {
      return Future<File?>.value(_file);
    }
    _info = info;
    _baseUrl = baseUrl;
    _token = token;
    _received = 0;
    _total = info.size;
    _cancelled = false;
    _error = null;
    _file = null;
    final token2 = UpdateCancelToken();
    _cancelToken = token2;
    _running = true;
    notifyListeners();
    return _run(info, baseUrl, token, cacheDirectory, token2);
  }

  Future<File?> _run(
    AppUpdateInfo info,
    String baseUrl,
    String? token,
    Future<String?> Function() cacheDirectory,
    UpdateCancelToken cancelToken,
  ) async {
    try {
      final cachePath = await cacheDirectory();
      if (cachePath == null || cachePath.trim().isEmpty) {
        throw const UpdateGatewayException('无法获取应用缓存目录');
      }
      final downloaded = await _service.download(
        info,
        baseUrl: baseUrl,
        targetDir: Directory(cachePath),
        token: token,
        cancel: cancelToken,
        onProgress: (received, total) {
          _received = received;
          if (total > 0) _total = total;
          notifyListeners();
        },
      );
      _file = downloaded;
      return downloaded;
    } on UpdateCancelled {
      _cancelled = true;
      return null;
    } on UpdateException catch (error) {
      _error = error.message;
      return null;
    } on UpdateGatewayException catch (error) {
      _error = error.message;
      return null;
    } catch (error) {
      _error = '更新失败：$error';
      return null;
    } finally {
      _running = false;
      _cancelToken = null;
      notifyListeners();
    }
  }

  /// 取消下载：标记一置，下载循环下一帧就会停下并删掉半截文件。
  void cancel() {
    if (!_running) return;
    _cancelled = true;
    _cancelToken?.cancel();
    notifyListeners();
  }

  /// 忘掉上一次的结果（例如已安装完）。
  void reset() {
    if (_running) return;
    _info = null;
    _baseUrl = '';
    _token = null;
    _received = 0;
    _total = 0;
    _cancelled = false;
    _error = null;
    _file = null;
    notifyListeners();
  }

  /// 安装时还要知道当初的地址与 token（重下时用得到）。
  String get baseUrl => _baseUrl;

  String? get token => _token;
}
