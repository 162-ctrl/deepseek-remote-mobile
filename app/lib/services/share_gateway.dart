
import 'package:flutter/services.dart';

/// 系统分享网关（M2.2 A4）。
///
/// 真实实现走 Kotlin `deepseek_remote/share`：把 PNG 写进 cache 后用
/// FileProvider + ACTION_SEND 弹出系统分享面板；单测注入 [FakeShareGateway]。
abstract class ShareGateway {
  /// 分享一张 PNG。返回是否真的拉起了分享面板。
  Future<bool> shareImage(
    Uint8List bytes, {
    required String fileName,
    required String chooserTitle,
  });

  Future<void> dispose();
}

/// 通过平台通道调用原生分享的实现。
class MethodChannelShareGateway implements ShareGateway {
  MethodChannelShareGateway({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  static const String channelName = 'deepseek_remote/share';

  final MethodChannel _channel;

  @override
  Future<bool> shareImage(
    Uint8List bytes, {
    required String fileName,
    required String chooserTitle,
  }) async {
    try {
      final result = await _channel.invokeMethod<bool>('shareImage', {
        'bytes': bytes,
        'fileName': fileName,
        'chooserTitle': chooserTitle,
      });
      return result ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<void> dispose() async {}
}

/// 记录分享请求的假实现（测试用）。
class FakeShareGateway implements ShareGateway {
  FakeShareGateway({this.result = true});

  bool result;
  final List<SharedImage> shared = <SharedImage>[];
  bool disposed = false;

  int get shareCalls => shared.length;

  Uint8List? get lastBytes => shared.isEmpty ? null : shared.last.bytes;

  @override
  Future<bool> shareImage(
    Uint8List bytes, {
    required String fileName,
    required String chooserTitle,
  }) async {
    shared.add(SharedImage(
      bytes: bytes,
      fileName: fileName,
      chooserTitle: chooserTitle,
    ));
    return result;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

class SharedImage {
  const SharedImage({
    required this.bytes,
    required this.fileName,
    required this.chooserTitle,
  });

  final Uint8List bytes;
  final String fileName;
  final String chooserTitle;
}
