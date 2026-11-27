import 'package:flutter/material.dart';

import '../models.dart';
import '../theme/app_theme.dart';

/// 聊天流里的一个渲染单元：普通消息，或折叠后的「一轮工具/思考」。
sealed class TurnFeedEntry {
  const TurnFeedEntry();
}

class TurnFeedMessage extends TurnFeedEntry {
  const TurnFeedMessage(this.item);

  final ChatItem item;
}

class TurnFeedGroup extends TurnFeedEntry {
  const TurnFeedGroup({
    required this.turnId,
    required this.stats,
    required this.items,
  });

  final int? turnId;
  final TurnStats? stats;
  final List<ChatItem> items;

  /// 组里工具卡片的数量。
  int get toolCount =>
      items.where((item) => item.kind == ChatItemKind.toolCall).length;
}

/// 只有这几种消息参与折叠（工具调用卡片 + 思考过程）。
bool isFoldableKind(ChatItemKind kind) =>
    kind == ChatItemKind.thinking ||
    kind == ChatItemKind.toolCall ||
    kind == ChatItemKind.toolResult;

/// 把消息列表转换成渲染单元（M2.2 A1 / M3.0 调整）。
///
/// 规则：
/// - 连续的「工具/思考」消息一律折叠成一行摘要，执行中也折叠，
///   手机端只关心对话正文，不需要盯着命令行输出；
/// - 助手正文、系统提示、用户消息、排队气泡始终可见；
/// - 折叠卡片默认收起，点开才显示原始工具卡片。
List<TurnFeedEntry> groupTurnMessages(
  List<ChatItem> messages,
  Map<int, TurnStats> stats,
) {
  final entries = <TurnFeedEntry>[];
  var index = 0;
  while (index < messages.length) {
    final item = messages[index];
    final foldable = isFoldableKind(item.kind) && !item.queued;
    if (!foldable) {
      entries.add(TurnFeedMessage(item));
      index++;
      continue;
    }
    final groupItems = <ChatItem>[];
    final turnId = item.turnId;
    while (index < messages.length) {
      final current = messages[index];
      if (!isFoldableKind(current.kind) ||
          current.queued ||
          current.turnId != turnId) {
        break;
      }
      groupItems.add(current);
      index++;
    }
    entries.add(TurnFeedGroup(
      turnId: turnId,
      stats: turnId == null ? null : stats[turnId],
      items: groupItems,
    ));
  }
  return entries;
}

/// 完成轮的工具/思考折叠卡（§3.9）：默认收成一行摘要，点击展开原卡片。
class TurnSummaryCard extends StatefulWidget {
  const TurnSummaryCard({
    super.key,
    required this.group,
    required this.itemBuilder,
    this.initiallyExpanded = false,
  });

  final TurnFeedGroup group;
  final Widget Function(BuildContext context, ChatItem item) itemBuilder;
  final bool initiallyExpanded;

  @override
  State<TurnSummaryCard> createState() => _TurnSummaryCardState();
}

class _TurnSummaryCardState extends State<TurnSummaryCard> {
  late bool _expanded = widget.initiallyExpanded;

  Color _statusColor(AppPalette palette, TurnStats? stats) =>
      switch (stats?.status) {
        TaskStatus.failed => palette.danger,
        TaskStatus.cancelled => palette.warn,
        TaskStatus.completed => palette.success,
        _ => palette.text3,
      };

  String _label(TurnStats? stats) {
    if (stats != null && stats.toolCount > 0) {
      return stats.summaryLabel;
    }
    final steps = widget.group.toolCount;
    if (steps == 0) return '思考过程';
    return '执行过程 · $steps 步';
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final stats = widget.group.stats;
    final color = _statusColor(palette, stats);
    return Container(
      margin: const EdgeInsets.only(top: 12, right: 24),
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: palette.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => setState(() => _expanded = !_expanded),
            child: SizedBox(
              height: 40,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(
                  children: [
                    Container(
                      width: 19,
                      height: 19,
                      decoration: BoxDecoration(
                        color: palette.accentSoft,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        stats?.icon ?? Icons.bolt_rounded,
                        size: 11,
                        color: palette.accent,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _label(stats),
                        style: TextStyle(
                          color: color,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Text(
                      _expanded ? '收起' : '展开',
                      style: TextStyle(color: palette.text3, fontSize: 11),
                    ),
                    const SizedBox(width: 2),
                    Icon(
                      _expanded
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      size: 18,
                      color: palette.text3,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 2, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final item in widget.group.items)
                    widget.itemBuilder(context, item),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
