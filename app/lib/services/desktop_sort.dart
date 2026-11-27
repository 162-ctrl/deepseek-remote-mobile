import '../models.dart';
import 'history_api.dart';

/// M3.6：桌面会话镜像列表的排序规则（纯函数，便于单测直接调用）。
///
/// 规则：
/// 1. 有 `lastTime` 的排在没有的前面；
/// 2. 都有 `lastTime` 时按时间戳倒序（最新活动在前）；
/// 3. 都没有 `lastTime` 时按 `updatedAt` 倒序；
/// 4. 相等时保持原顺序（稳定排序，用原始下标兜底）。
List<TaskRecord> sortDesktopTasks(List<TaskRecord> tasks) {
  final indexed = <MapEntry<int, TaskRecord>>[
    for (var i = 0; i < tasks.length; i++) MapEntry<int, TaskRecord>(i, tasks[i]),
  ];
  indexed.sort((a, b) {
    final byTime = compareLastTime(a.value.lastTime, b.value.lastTime);
    if (byTime != 0) return byTime;
    final byUpdated = b.value.updatedAt.compareTo(a.value.updatedAt);
    if (byUpdated != 0) return byUpdated;
    return a.key.compareTo(b.key);
  });
  return <TaskRecord>[for (final entry in indexed) entry.value];
}

/// 与 [sortDesktopTasks] 同一套规则，作用于 UI 使用的 [TaskItem]。
List<TaskItem> sortDesktopTaskItems(List<TaskItem> tasks) {
  final indexed = <MapEntry<int, TaskItem>>[
    for (var i = 0; i < tasks.length; i++) MapEntry<int, TaskItem>(i, tasks[i]),
  ];
  indexed.sort((a, b) {
    final byTime = compareLastTime(a.value.lastTime, b.value.lastTime);
    if (byTime != 0) return byTime;
    final byUpdated = b.value.updatedAt.compareTo(a.value.updatedAt);
    if (byUpdated != 0) return byUpdated;
    return a.key.compareTo(b.key);
  });
  return <TaskItem>[for (final entry in indexed) entry.value];
}

/// M4.3：手机端「已运行 D:HH:MM:SS」的起点。
///
/// 之前的做法是「手机打开这个页面时才开始计时」，于是同一次运行在手机上总是从
/// 0:00 起算、和电脑端完全不一致（电脑端从这一轮开始算）。这里改用会话日志里
/// 最新一条 `turn-start` 的时间：只要事件带时间，就是电脑上真正的开始时刻；
/// 旧插件不带时间时，退回任务行的最后活动时间（`lastTime`），再退回会话
/// `updatedAt`，最后才是「现在」（否则显示 0:00）。
DateTime resolveRunStart({
  required Iterable<DesktopSessionEvent> events,
  int? lastTime,
  DateTime? updatedAt,
  DateTime? now,
}) {
  DesktopSessionEvent? latest;
  for (final event in events) {
    if (event.kind != 'turn-start') continue;
    if (event.time <= 0) continue;
    if (latest == null || event.time >= latest.time) latest = event;
  }
  if (latest != null) {
    return DateTime.fromMillisecondsSinceEpoch(latest.time);
  }
  if (lastTime != null && lastTime > 0) {
    return DateTime.fromMillisecondsSinceEpoch(lastTime);
  }
  return updatedAt ?? now ?? DateTime.now();
}

/// 运行时长文案：不足 1 小时是 `M:SS`，超过 1 小时是 `H:MM:SS`。
String formatElapsed(Duration elapsed) {
  final safe = elapsed.isNegative ? Duration.zero : elapsed;
  final minutes = safe.inMinutes;
  final seconds = (safe.inSeconds % 60).toString().padLeft(2, '0');
  if (safe.inHours > 0) {
    final m = (minutes % 60).toString().padLeft(2, '0');
    return '${safe.inHours}:$m:$seconds';
  }
  return '$minutes:$seconds';
}

/// 返回负数表示 `a` 应排在 `b` 前面。
int compareLastTime(int? a, int? b) {
  final hasA = a != null && a > 0;
  final hasB = b != null && b > 0;
  if (hasA && !hasB) return -1;
  if (!hasA && hasB) return 1;
  if (!hasA && !hasB) return 0;
  return b!.compareTo(a!);
}
