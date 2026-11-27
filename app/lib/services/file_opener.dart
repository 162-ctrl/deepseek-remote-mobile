import 'package:flutter/services.dart';

/// M4.9：用系统应用打开文件（PDF / Office / 图片以外的格式）。
///
/// 真实实现走 Kotlin `deepseek_remote/files`：把字节写进 cacheDir 下的
/// `preview/`，再用 FileProvider 生成 `content://` URI + `ACTION_VIEW`
/// 拉起系统应用（WPS / 系统阅读器 / 看图 App）。单测注入 [FakeFileOpener]。
abstract class FileOpener {
  /// 返回是否真的拉起了系统应用。
  Future<bool> openBytes(
    Uint8List bytes, {
    required String fileName,
    String? mimeType,
  });

  /// M4.64：把这批字节交给系统「分享」面板（微信 / QQ / 文件管理器…）。
  ///
  /// 手机上常常没有能「打开」某类文件的应用（例如没装 WPS 时的 .docx），
  /// 但分享面板几乎总是有——先发出去，再在别的设备上看。
  Future<bool> shareBytes(
    Uint8List bytes, {
    required String fileName,
    String? mimeType,
  });

  /// M4.70：这台手机上有没有应用能「打开」这类文件。
  ///
  /// 没装 WPS 时 .docx 必然打不开；先把按钮藏掉，比点一下再弹「没装应用」
  /// 更诚实。实现失败时按「能打开」处理，免得把本来可用的按钮藏掉。
  Future<bool> canOpenBytes(String fileName, {String? mimeType});

  /// M4.72：最近一次失败的原因（原生端的 `code: message`）。
  ///
  /// 之前原生把所有 `PlatformException` 都吞成 `false`，界面上只能显示一句
  /// 「手机上没有能打开这种文件的应用」，把「provider 路径错了」这类真实原因
  /// 一起盖住。现在把原因留下来，好在提示里说清。
  String? get lastError => null;

  Future<void> dispose();
}

/// 通过平台通道调用原生实现的 [FileOpener]。
class MethodChannelFileOpener implements FileOpener {
  MethodChannelFileOpener({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  static const String channelName = 'deepseek_remote/files';

  final MethodChannel _channel;

  String? _lastError;

  @override
  String? get lastError => _lastError;

  @override
  Future<bool> openBytes(
    Uint8List bytes, {
    required String fileName,
    String? mimeType,
  }) async {
    try {
      final result = await _channel.invokeMethod<bool>('openBytes', <String, dynamic>{
        'bytes': bytes,
        'fileName': fileName,
        if (mimeType != null && mimeType.isNotEmpty) 'mimeType': mimeType,
      });
      return result ?? false;
    } on MissingPluginException {
      _lastError = '这台手机没有安装文件通道（可能是旧版本）';
      return false;
    } on PlatformException catch (error) {
      _lastError = error.message ?? error.code;
      return false;
    }
  }

  @override
  Future<bool> shareBytes(
    Uint8List bytes, {
    required String fileName,
    String? mimeType,
  }) async {
    try {
      final result = await _channel.invokeMethod<bool>('shareBytes', <String, dynamic>{
        'bytes': bytes,
        'fileName': fileName,
        if (mimeType != null && mimeType.isNotEmpty) 'mimeType': mimeType,
      });
      return result ?? false;
    } on MissingPluginException {
      _lastError = '这台手机没有安装文件通道（可能是旧版本）';
      return false;
    } on PlatformException catch (error) {
      _lastError = error.message ?? error.code;
      return false;
    }
  }

  @override
  Future<bool> canOpenBytes(String fileName, {String? mimeType}) async {
    try {
      final result = await _channel.invokeMethod<bool>(
        'canOpenBytes',
        <String, dynamic>{
          'fileName': fileName,
          if (mimeType != null && mimeType.isNotEmpty) 'mimeType': mimeType,
        },
      );
      return result ?? true;
    } on MissingPluginException {
      return true;
    } on PlatformException {
      return true;
    }
  }

  @override
  Future<void> dispose() async {}
}

/// 记录调用、不真的拉起应用的假实现（测试用）。
class FakeFileOpener implements FileOpener {
  FakeFileOpener({this.result = true, this.shareResult = true, this.canOpen = true});

  bool result;
  bool shareResult;
  bool canOpen;
  int canOpenCalls = 0;
  final List<OpenedFile> opened = <OpenedFile>[];
  final List<OpenedFile> shared = <OpenedFile>[];
  bool disposed = false;

  /// M4.72：想模拟「原生失败并带原因」时直接设它。
  String? lastErrorValue;

  @override
  String? get lastError => lastErrorValue;

  int get openCalls => opened.length;

  int get shareCalls => shared.length;

  OpenedFile? get last => opened.isEmpty ? null : opened.last;

  OpenedFile? get lastShared => shared.isEmpty ? null : shared.last;

  @override
  Future<bool> openBytes(
    Uint8List bytes, {
    required String fileName,
    String? mimeType,
  }) async {
    opened.add(OpenedFile(bytes: bytes, fileName: fileName, mimeType: mimeType));
    return result;
  }

  @override
  Future<bool> shareBytes(
    Uint8List bytes, {
    required String fileName,
    String? mimeType,
  }) async {
    shared.add(OpenedFile(bytes: bytes, fileName: fileName, mimeType: mimeType));
    return shareResult;
  }

  @override
  Future<bool> canOpenBytes(String fileName, {String? mimeType}) async {
    canOpenCalls += 1;
    return canOpen;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

/// [FakeFileOpener] 记录的一次打开请求。
class OpenedFile {
  const OpenedFile({required this.bytes, required this.fileName, this.mimeType});

  final Uint8List bytes;
  final String fileName;
  final String? mimeType;
}
