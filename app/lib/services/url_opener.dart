import 'package:flutter/services.dart';

/// M4.33：用系统浏览器打开一个网页（目前只服务「去充值」）。
///
/// 为什么不做 App 内支付：电脑端的 `deepseekAccount` 只开放「读余额 / 登录登出」，
/// 没有任何下单、付款、写余额的方法（`getBalance` / `getProfile` / `startSignIn` /
/// `getPlatformSession` … 全是读或身份）。想在自己的 App 里给 DeepSeek 账户加钱，
/// 得自己接支付宝/微信商户、签约对账，而最后「给它家账户加余额」这一步依然没有
/// 开放接口 —— 所以只能把用户送到官方充值页，由他自己付款。
abstract class UrlOpener {
  /// 返回是否真的拉起了浏览器。
  Future<bool> open(String url);
}

/// 走 `MethodChannel('deepseek_remote/update')` 的 `openUrl`（复用更新桥的通道）。
class MethodChannelUrlOpener implements UrlOpener {
  MethodChannelUrlOpener({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  static const String channelName = 'deepseek_remote/update';

  final MethodChannel _channel;

  @override
  Future<bool> open(String url) async {
    if (url.trim().isEmpty) return false;
    try {
      final result = await _channel.invokeMethod<bool>('openUrl', <String, dynamic>{
        'url': url,
      });
      return result ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}

/// 记录调用、不真的拉起浏览器的假实现（测试用）。
class FakeUrlOpener implements UrlOpener {
  FakeUrlOpener({this.result = true});

  bool result;
  final List<String> opened = <String>[];

  @override
  Future<bool> open(String url) async {
    opened.add(url);
    return result;
  }
}
