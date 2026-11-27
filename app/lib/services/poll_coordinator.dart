// M4.46：统一轮询协调器。
//
// 第二阶段第 ⑦ 条要解决的三个毛病，都出在「各自开 Timer.periodic」这件事上：
//   1. 页面被 IndexedStack 保活，用户在看别的页时工作区/任务页照样每 5 秒打一次；
//   2. 定时器不看上一个请求是否还在途，弱网时请求会越堆越多（M4.38 已在直播页单独
//      修过一次，这里是通用版）；
//   3. 失败之后仍然按原节奏重试，等于持续给一台刚拒过我们的电脑加压。
//
// [PollCoordinator] 把「什么时候该轮询」收成一处：外部只需要告诉它当前**该不该跑**
// （页面可见 && App 在前台），它自己负责「一次只跑一个、失败翻倍退避、成功立刻复位」。
//
// 刻意不做全局单例：页面自己持有、dispose 时释放，测试可以直接用短间隔驱动。

import 'dart:async';
import 'dart:math' as math;


/// 通用退避：`base * 2^min(failures, 5)`，封顶 `maxBackoff`。
///
/// `failures <= 0` 表示上次成功，立刻回到 `base`。
Duration pollBackoffDelay(
  Duration base,
  int failures, {
  Duration maxBackoff = const Duration(seconds: 30),
}) {
  if (failures <= 0) return base;
  final int exponent = math.min(failures, 5);
  final int ms = base.inMilliseconds * (1 << exponent);
  if (ms >= maxBackoff.inMilliseconds) return maxBackoff;
  return Duration(milliseconds: ms);
}

/// 一个「可开可停」的轮询循环。
class PollCoordinator {
  PollCoordinator({
    required Future<void> Function() run,
    Future<void> Function()? onError,
    Duration interval = const Duration(seconds: 5),
    Duration maxBackoff = const Duration(seconds: 30),
    bool active = false,
  })  : _run = run,
        _onError = onError,
        _interval = interval,
        _maxBackoff = maxBackoff,
        _active = active {
    if (_active) _schedule();
  }

  final Future<void> Function() _run;
  final Future<void> Function()? _onError;
  final Duration _interval;
  final Duration _maxBackoff;

  Timer? _timer;
  bool _active;
  bool _inFlight = false;
  bool _disposed = false;
  int _failures = 0;
  int _runs = 0;
  Duration _pendingDelay = Duration.zero;

  /// 当前是否允许轮询（页面可见 + App 在前台）。
  bool get active => _active;

  set active(bool value) {
    if (_disposed || value == _active) return;
    _active = value;
    if (value) {
      // 从后台/别的页切回来：不要等满一个间隔，立刻补一次。
      _schedule(immediate: true);
    } else {
      _timer?.cancel();
      _timer = null;
      _pendingDelay = Duration.zero;
    }
  }

  /// 连续失败次数（成功后清零）。
  int get failures => _failures;

  /// 累计真正跑过的次数，测试用来断言「一次都没发」。
  int get runs => _runs;

  /// 有没有请求还挂着。
  bool get inFlight => _inFlight;

  /// 下一次真正触发还要等多久（没排上时是 [Duration.zero]）。
  Duration get nextDelay => _pendingDelay;

  /// 按当前失败次数应等的时间。
  Duration get pollDelay => pollBackoffDelay(
        _interval,
        _failures,
        maxBackoff: _maxBackoff,
      );

  void _schedule({bool immediate = false}) {
    if (_disposed || !_active) {
      _pendingDelay = Duration.zero;
      return;
    }
    _timer?.cancel();
    _pendingDelay = immediate ? Duration.zero : pollDelay;
    _timer = Timer(_pendingDelay, _tick);
  }

  Future<void> _tick() async {
    _timer = null;
    if (_disposed || !_active) return;
    if (_inFlight) {
      // 上一个还没回来：跳过这一轮，等它自己回来后再排下一次。
      return;
    }
    _inFlight = true;
    _runs += 1;
    try {
      await _run();
      _failures = 0;
    } catch (_) {
      _failures += 1;
      final Future<void> Function()? onError = _onError;
      if (onError != null) {
        try {
          await onError();
        } catch (_) {
          // 错误回调本身不许把轮询打死。
        }
      }
    } finally {
      _inFlight = false;
      _schedule();
    }
  }

  /// 立刻跑一次（下拉刷新、切回页面时想马上要数据）。
  ///
  /// 与定时轮询共用同一个「在途」闸门：真的在里面时直接返回 false。
  Future<bool> refreshNow() async {
    if (_disposed || _inFlight) return false;
    _timer?.cancel();
    _timer = null;
    _inFlight = true;
    _runs += 1;
    try {
      await _run();
      _failures = 0;
      return true;
    } catch (_) {
      _failures += 1;
      return false;
    } finally {
      _inFlight = false;
      _schedule();
    }
  }

  void dispose() {
    _disposed = true;
    _active = false;
    _timer?.cancel();
    _timer = null;
  }
}
