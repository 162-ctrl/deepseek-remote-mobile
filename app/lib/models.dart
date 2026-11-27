import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// 任务 7 状态（与策划案 / PROTOCOL.md 的 7 状态枚举一致）。
enum TaskStatus {
  queued('等待执行', AppColors.textMuted, Icons.schedule_rounded),
  running('正在执行', AppColors.primary, Icons.play_circle_fill_rounded),
  waitingApproval('等待授权', AppColors.warning, Icons.lock_clock_rounded),
  paused('暂停中', AppColors.purple, Icons.pause_circle_filled_rounded),
  completed('已完成', AppColors.success, Icons.check_circle_rounded),
  failed('失败', AppColors.danger, Icons.error_rounded),
  cancelled('已取消', AppColors.textFaint, Icons.do_not_disturb_on_rounded);

  const TaskStatus(this.label, this.color, this.icon);
  final String label;
  final Color color;
  final IconData icon;
}

enum ChatRole { user, assistant, system }

enum ChatItemKind { text, thinking, toolCall, toolResult, approval, artifact }

class ToolStep {
  ToolStep({
    required this.title,
    required this.command,
    required this.status,
    this.durationMs,
    this.exitCode,
    this.output,
  });

  final String title;
  final String command;
  final String status; // pending / running / done / failed
  final int? durationMs;
  final int? exitCode;
  final String? output;
}

class ChatItem {
  ChatItem({
    required this.role,
    required this.kind,
    this.text = '',
    this.time,
    this.steps = const [],
    this.collapsed = true,
    this.approvalTitle,
    this.approvalDetail,
    this.seq,
    this.queued = false,
    this.turnId,
  });

  final ChatRole role;
  final ChatItemKind kind;
  final String text;
  final DateTime? time;
  final List<ToolStep> steps;
  final bool collapsed;
  final String? approvalTitle;
  final String? approvalDetail;

  /// M2.1：该消息对应的会话事件 seq（历史回填/实时事件/补拉事件共用），
  /// 用于按 seq 去重与排序；本地消息（用户输入、系统提示）为空。
  final int? seq;

  /// M2.1：当前会话 busy 时用户排队的指令气泡，等待 turn 结束后自动发送。
  final bool queued;

  /// M2.2：该消息所属的「轮」（用户发一条指令到任务终态为同一轮）。
  /// 历史消息或本地消息为空，真实模式新消息由 LiveStore 编号。
  final int? turnId;
}

/// 一轮任务（turn）的统计信息（M2.2 A1：完成自动折叠）。
///
/// 由 LiveStore 维护：用户每次发出新指令时开一轮；工具/思考消息带上 turnId；
/// 任务进入 completed/failed/cancelled 时记录结束时间与终态。
class TurnStats {
  TurnStats({required this.turnId});

  final int turnId;

  /// 该轮首条工具/思考消息的时间。
  DateTime? startedAt;

  /// 该轮进入终态的时间。
  DateTime? endedAt;

  /// 终态（completed/failed/cancelled）；执行中为 null。
  TaskStatus? status;

  /// 该轮 toolCall 卡片数（= 折叠摘要里的“步数”）。
  int toolCount = 0;

  bool get isTerminal =>
      status == TaskStatus.completed ||
      status == TaskStatus.failed ||
      status == TaskStatus.cancelled;

  /// 该轮耗时（首条工具事件 → 终态），无数据时为 null。
  Duration? get elapsed {
    final start = startedAt;
    final end = endedAt;
    if (start == null || end == null) return null;
    final diff = end.difference(start);
    return diff.isNegative ? null : diff;
  }

  /// 折叠摘要文案，例如 `已完成 3 步 · 用时 8s`、`失败 · 3 步 · 用时 8s`。
  String get summaryLabel {
    final prefix = switch (status) {
      TaskStatus.failed => '失败 · ',
      TaskStatus.cancelled => '已取消 · ',
      TaskStatus.completed => '已完成 ',
      _ => '执行中 ',
    };
    final buffer = StringBuffer('$prefix$toolCount 步');
    final duration = elapsed;
    if (duration != null) {
      buffer.write(' · 用时 ${_formatDuration(duration)}');
    }
    return buffer.toString();
  }

  Color get color => switch (status) {
        TaskStatus.failed => AppColors.danger,
        TaskStatus.cancelled => AppColors.warning,
        TaskStatus.completed => AppColors.success,
        _ => AppColors.textMuted,
      };

  IconData get icon => switch (status) {
        TaskStatus.failed => Icons.error_rounded,
        TaskStatus.cancelled => Icons.do_not_disturb_on_rounded,
        TaskStatus.completed => Icons.check_circle_rounded,
        _ => Icons.more_horiz_rounded,
      };
}

String _formatDuration(Duration duration) {
  final ms = duration.inMilliseconds;
  if (ms < 1000) return '${ms}ms';
  final seconds = duration.inSeconds;
  if (seconds < 60) return '${seconds}s';
  final minutes = duration.inMinutes;
  final rest = seconds % 60;
  return '${minutes}m${rest}s';
}

class TaskEvent {
  TaskEvent({
    required this.time,
    required this.title,
    this.detail = '',
    this.done = true,
    this.tool,
    this.type,
    this.seq,
  });

  final DateTime time;
  final String title;
  final String detail;
  final bool done;
  final String? tool;

  /// M1.1 任务详情事件类型（`tool_call` / `completed` / `failed` / …），
  /// 历史事件没有该字段时，时间线会回退到 [done] 决定样式。
  final String? type;

  /// M2.1：事件对应的会话 seq（用于按 seq 去重/排序）。
  final int? seq;
}

class TaskItem {
  TaskItem({
    required this.id,
    required this.title,
    required this.status,
    required this.workspace,
    required this.updatedAt,
    this.progress = 0,
    this.conversationId,
    this.result,
    this.errorCode,
    this.events = const [],
    this.messageCount = 0,
    this.lastTime,
  });

  final String id;
  final String title;
  TaskStatus status;
  final String workspace;
  DateTime updatedAt;
  double progress;
  final String? conversationId;
  String? result;
  String? errorCode;
  List<TaskEvent> events;

  /// M3.6：桌面会话的消息条数（旧接口为 0）。
  final int messageCount;

  /// M3.6：桌面任务行的最后活动时刻（毫秒时间戳）。
  final int? lastTime;
}

String two(int v) => v.toString().padLeft(2, '0');

String formatTime(DateTime t) => '${two(t.hour)}:${two(t.minute)}';

String formatClock(DateTime t) =>
    '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';

/// M3.6：桌面任务行的 `lastTime`（毫秒时间戳）→ 「HH:mm」，跨天时带日期前缀。
String formatLastTime(int? ms) {
  if (ms == null || ms <= 0) return '';
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  final now = DateTime.now();
  final sameDay =
      t.year == now.year && t.month == now.month && t.day == now.day;
  return sameDay
      ? formatTime(t)
      : '${two(t.month)}-${two(t.day)} ${formatTime(t)}';
}

String relativeTime(DateTime t) {
  final diff = DateTime.now().difference(t);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  if (diff.inHours < 24) return '${diff.inHours} 小时前';
  return '${diff.inDays} 天前';
}

/// M4.4：通知里用的一行摘要（压掉换行与多余空白，超长截断加省略号）。
String notificationExcerpt(String text, {int max = 60}) {
  final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (flat.length <= max) return flat;
  return '${flat.substring(0, max)}…';
}
