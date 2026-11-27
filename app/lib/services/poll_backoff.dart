// M4.38：桌面直播的轮询节奏。
//
// 原来 `desktop_session_screen` 用 `Timer.periodic(1500ms)` 直接 `_load()`，
// 既不看在途请求、也不看上次是否失败。首屏一次要拉一百多 KB（忙会话为了凑够
// 十几条对话，得往回扫几百条事件），走 Cloudflare 快速隧道时一个来回就一秒多，
// 手机 5G + VPN 更慢 —— 10 秒超时一被打穿，1.5 秒后的下一次 tick 又发一个，
// 于是同时堆着六七个请求互相挤，越等越慢，看起来就是「经常连接超时」。
//
// 这里只放节奏规则本身（纯函数，方便单测）：正常 1.5 秒一次，连续失败就翻倍
// 退避，最长 30 秒，成功后立刻回到 1.5 秒。

/// 正常情况下的轮询间隔。
const Duration kDesktopPollInterval = Duration(milliseconds: 1500);

/// 连续失败时的最长退避间隔。
const Duration kDesktopPollMaxBackoff = Duration(seconds: 30);

/// 按「连续失败次数」算下一次轮询该等多久。
///
/// `failures <= 0` 表示上一次是成功的：立刻回到正常节奏。
/// 失败 1 次 3 秒、2 次 6 秒、3 次 12 秒、4 次 24 秒、再往后封顶 30 秒。
Duration desktopPollDelay(int failures) {
  if (failures <= 0) return kDesktopPollInterval;
  final int exponent = failures > 5 ? 5 : failures;
  final int ms = kDesktopPollInterval.inMilliseconds * (1 << exponent);
  if (ms >= kDesktopPollMaxBackoff.inMilliseconds) {
    return kDesktopPollMaxBackoff;
  }
  return Duration(milliseconds: ms);
}
