import 'settings_gateway.dart';

/// M4.63：启动自愈。
///
/// 有用户遇到「打开 App 就闪退」，清掉应用数据后恢复正常——说明是本地存档
/// 里的某条状态把启动卡死了。应用层没法替用户去清数据，所以这里做一层保险：
///
/// * 每次启动前记一次「启动尝试」；
/// * 如果短时间内连续启动多次都没走到第一帧，就认为存档坏了，把会话存档清掉再启动；
/// * 一旦第一帧画出来，就把计数复位。
///
/// 这样即使某个存档写坏了，用户最多遇到两三次闪退，之后会自愈。
class BootGuard {
  BootGuard({required SettingsGateway gateway, DateTime Function()? now})
      : _gateway = gateway,
        _now = now ?? DateTime.now;

  static const String attemptsKey = 'boot_attempts';
  static const String lastAttemptKey = 'boot_last_attempt_at';

  /// 连续几次没走到第一帧就判定为启动失败。
  static const int maxAttempts = 3;

  /// 两次启动间隔超过这个时长就不算连续（用户可能只是很久没开）。
  static const Duration window = Duration(minutes: 3);

  final SettingsGateway _gateway;
  final DateTime Function() _now;

  Future<int> attempts() async {
    final raw = await _gateway.getString(attemptsKey);
    return int.tryParse(raw ?? '') ?? 0;
  }

  Future<DateTime?> lastAttemptAt() async {
    final raw = await _gateway.getString(lastAttemptKey);
    final millis = int.tryParse(raw ?? '');
    if (millis == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(millis);
  }

  /// 上一次启动是否没走完（且间隔在窗口内）。
  Future<bool> shouldReset() async {
    final count = await attempts();
    if (count < maxAttempts) return false;
    final last = await lastAttemptAt();
    if (last == null) return true;
    return _now().difference(last) < window;
  }

  /// 记一次启动尝试。
  Future<void> markAttempt() async {
    final count = await attempts();
    await _gateway.setString(attemptsKey, '${count + 1}');
    await _gateway.setString(
      lastAttemptKey,
      '${_now().millisecondsSinceEpoch}',
    );
  }

  /// 已经画出第一帧：复位计数。
  Future<void> markFirstFrame() async {
    if (await attempts() == 0) return;
    await _gateway.setString(attemptsKey, '0');
  }
}
