import 'package:flutter/material.dart';

import '../models.dart';
import '../theme/app_theme.dart';

/// 任务事件时间线的一行（M1.1，M2.3 视觉更新）。
///
/// 真实任务详情的 `events` 一般带 `type`，按类型选择图标与颜色；
/// 缺少 `type` 时回退到 [TaskEvent.done]。
class TaskTimelineTile extends StatelessWidget {
  const TaskTimelineTile({
    super.key,
    required this.event,
    this.isLast = false,
  });

  final TaskEvent event;
  final bool isLast;

  bool get _failed =>
      event.type == 'failed' ||
      event.type == 'error' ||
      event.type == 'cancelled' ||
      event.type == 'canceled';

  IconData get _icon {
    if (_failed) return Icons.close_rounded;
    switch (event.type) {
      case 'tool_call':
      case 'tool_call_update':
        return Icons.terminal_rounded;
      case 'approval_request':
      case 'approval_resolved':
        return Icons.lock_clock_rounded;
      case 'thinking':
        return Icons.psychology_alt_outlined;
      case 'running':
      case 'queued':
      case 'pending':
        return Icons.more_horiz_rounded;
      default:
        return event.done ? Icons.check_rounded : Icons.more_horiz_rounded;
    }
  }

  Color _color(AppPalette palette) {
    if (_failed) return palette.danger;
    switch (event.type) {
      case 'tool_call':
      case 'tool_call_update':
        return palette.accent;
      case 'approval_request':
        return palette.warn;
      case 'thinking':
        return palette.accent;
      default:
        return event.done ? palette.success : palette.text3;
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final color = _color(palette);
    final type = event.type;
    final showType = type != null && type.isNotEmpty && type != 'event';
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              Container(
                width: 18,
                height: 18,
                margin: const EdgeInsets.only(top: 2),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color.withValues(alpha: 0.14),
                ),
                child: Icon(_icon, size: 11, color: color),
              ),
              if (!isLast)
                Expanded(
                  child: Container(
                    width: 1.5,
                    margin: const EdgeInsets.symmetric(vertical: 3),
                    color: palette.line,
                  ),
                ),
            ],
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          event.title,
                          style: TextStyle(
                            color: palette.text,
                            fontSize: 12.8,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Text(
                        formatClock(event.time),
                        style: kMono.copyWith(
                          fontSize: 10,
                          color: palette.text3,
                        ),
                      ),
                    ],
                  ),
                  if (showType) ...[
                    const SizedBox(height: 2),
                    Text(
                      type,
                      style: kMono.copyWith(
                        fontSize: 9.5,
                        color: palette.text3,
                      ),
                    ),
                  ],
                  if (event.tool != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      event.tool!,
                      style: kMono.copyWith(
                        fontSize: 10.5,
                        color: palette.accent,
                      ),
                    ),
                  ],
                  if (event.detail.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      event.detail,
                      style: TextStyle(
                        color: palette.text2,
                        fontSize: 11.5,
                        height: 1.45,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
