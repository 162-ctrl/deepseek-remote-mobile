import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models.dart';
import '../services/message_text.dart';
import '../theme/app_theme.dart';
import 'markdown_text.dart';

/// M2.2 A5：消息气泡长按菜单里可执行的动作。
enum ChatItemAction { copy, resend, copyOutput }

/// 一条消息支持哪些长按动作（纯函数，便于单测）。
///
/// - 用户文本：复制、重新发送（写入输入框，不自动发送）；
/// - 助手文本/思考：复制；
/// - 工具调用/工具输出卡片：复制输出；
/// - 排队气泡、系统提示、审批卡：不参与长按菜单。
List<ChatItemAction> actionsForChatItem(ChatItem item) {
  if (item.queued) return const <ChatItemAction>[];
  if (item.role == ChatRole.user && item.kind == ChatItemKind.text) {
    return const <ChatItemAction>[ChatItemAction.copy, ChatItemAction.resend];
  }
  if (item.role != ChatRole.assistant) return const <ChatItemAction>[];
  switch (item.kind) {
    case ChatItemKind.text:
    case ChatItemKind.thinking:
      return const <ChatItemAction>[ChatItemAction.copy];
    case ChatItemKind.toolCall:
    case ChatItemKind.toolResult:
      return const <ChatItemAction>[ChatItemAction.copyOutput];
    case ChatItemKind.approval:
    case ChatItemKind.artifact:
      return const <ChatItemAction>[];
  }
}

/// 工具卡片长按「复制输出」时复制的文本。
String copyableOutput(ChatItem item) {
  if (item.kind == ChatItemKind.toolResult) {
    if (item.steps.isNotEmpty && item.steps.first.output != null) {
      return item.steps.first.output!;
    }
    return item.text;
  }
  final outputs = <String>[];
  for (final step in item.steps) {
    if (step.output != null && step.output!.isNotEmpty) {
      outputs.add(step.output!);
    }
  }
  return outputs.join('\n\n');
}

/// 聊天消息渲染（M2.3 视觉规范 §3.7/§3.8）：
/// 用户气泡 / 助手正文（左侧 3px 竖线，无气泡）/ 思考折叠行 / 工具卡片 / 系统提示。
class ChatItemView extends StatelessWidget {
  const ChatItemView({
    super.key,
    required this.item,
    this.onApprovalDemo,
    this.onRemoveQueued,
    this.onSendNow,
    this.interrupting = false,
    this.onResend,
  });

  final ChatItem item;

  /// 历史审批卡上的「查看并处理」回调；真实模式的审批走弹层，可为空。
  final VoidCallback? onApprovalDemo;

  /// M2.1：排队中的用户指令可点击「移除」。
  final VoidCallback? onRemoveQueued;

  /// M2.2 A2：排队气泡的「立即发送」动作（先打断当前任务）。
  final VoidCallback? onSendNow;

  /// M2.2 A2：是否正在打断（按钮显示「正在打断…」并禁用）。
  final bool interrupting;

  /// M2.2 A5：长按「重新发送」时把用户文本交给输入框（不自动发送）。
  final ValueChanged<String>? onResend;

  @override
  Widget build(BuildContext context) {
    Widget child;
    switch (item.role) {
      case ChatRole.user:
        if (item.queued) {
          child = _QueuedBubble(
            text: item.text,
            time: item.time,
            onRemove: onRemoveQueued,
            onSendNow: onSendNow,
            interrupting: interrupting,
          );
        } else {
          child = _UserBubble(text: item.text, time: item.time);
        }
      case ChatRole.system:
        child = _SystemNotice(text: item.text);
      case ChatRole.assistant:
        child = switch (item.kind) {
          ChatItemKind.thinking => _ThinkingFold(text: item.text),
          ChatItemKind.toolCall =>
            _ToolCallCard(title: item.text, steps: item.steps),
          ChatItemKind.toolResult => _ToolResultCard(item: item),
          ChatItemKind.approval =>
            _ApprovalInlineCard(item: item, onTap: onApprovalDemo ?? () {}),
          _ => _AssistantText(text: item.text, time: item.time),
        };
    }
    return _LongPressMenu(item: item, onResend: onResend, child: child);
  }
}

/// M2.2 A5：给气泡加长按菜单（复制 / 重新发送 / 复制工具输出）。
class _LongPressMenu extends StatelessWidget {
  const _LongPressMenu({
    required this.item,
    required this.child,
    this.onResend,
  });

  final ChatItem item;
  final Widget child;
  final ValueChanged<String>? onResend;

  @override
  Widget build(BuildContext context) {
    if (actionsForChatItem(item).isEmpty) return child;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: () => _showMenu(context),
      child: child,
    );
  }

  Future<void> _showMenu(BuildContext context) async {
    final palette = context.appPalette;
    final actions = actionsForChatItem(item);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: palette.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.sheetTop)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const _SheetHandle(),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 6, 20, 4),
                child: Row(
                  children: [
                    Icon(
                      item.role == ChatRole.user
                          ? Icons.person_outline_rounded
                          : Icons.smart_toy_outlined,
                      size: 16,
                      color: palette.accent,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '消息操作',
                      style: TextStyle(
                        color: palette.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              for (final action in actions)
                ListTile(
                  dense: true,
                  leading: Icon(_actionIcon(action),
                      size: 18, color: palette.text2),
                  title: Text(
                    _actionLabel(action),
                    style: TextStyle(color: palette.text, fontSize: 13.5),
                  ),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _perform(action);
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  IconData _actionIcon(ChatItemAction action) => switch (action) {
        ChatItemAction.copy => Icons.copy_rounded,
        ChatItemAction.resend => Icons.refresh_rounded,
        ChatItemAction.copyOutput => Icons.content_copy_rounded,
      };

  String _actionLabel(ChatItemAction action) => switch (action) {
        ChatItemAction.copy => '复制',
        ChatItemAction.resend => '重新发送',
        ChatItemAction.copyOutput => '复制工具输出',
      };

  void _perform(ChatItemAction action) {
    switch (action) {
      case ChatItemAction.copy:
        Clipboard.setData(ClipboardData(text: item.text));
        break;
      case ChatItemAction.resend:
        onResend?.call(item.text);
        break;
      case ChatItemAction.copyOutput:
        final output = copyableOutput(item);
        if (output.isNotEmpty) {
          Clipboard.setData(ClipboardData(text: output));
        }
        break;
    }
  }
}

/// 底部弹层顶部拖动条（§3.16）。
class _SheetHandle extends StatelessWidget {
  const _SheetHandle();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 36,
      height: 4,
      margin: const EdgeInsets.only(top: 10, bottom: 6),
      decoration: BoxDecoration(
        color: context.appPalette.lineSoft,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}

/// M2.1：busy 时排队中的指令气泡（等待当前 turn 结束后自动发送）。
///
/// M2.2 A2：新增「立即发送」（先打断当前任务）与「正在打断…」禁用态。
class _QueuedBubble extends StatelessWidget {
  const _QueuedBubble({
    required this.text,
    this.time,
    this.onRemove,
    this.onSendNow,
    this.interrupting = false,
  });

  final String text;
  final DateTime? time;
  final VoidCallback? onRemove;
  final VoidCallback? onSendNow;
  final bool interrupting;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 300),
        margin: const EdgeInsets.only(top: 14, left: 56),
        padding: const EdgeInsets.fromLTRB(14, 11, 14, 9),
        decoration: BoxDecoration(
          color: palette.card,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(AppRadius.bubble),
            topRight: Radius.circular(AppRadius.bubble),
            bottomLeft: Radius.circular(AppRadius.bubble),
            bottomRight: Radius.circular(AppRadius.bubbleTail),
          ),
          border: Border.all(color: palette.line),
          boxShadow: palette.cardShadow,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.schedule_rounded, size: 12, color: palette.warn),
                const SizedBox(width: 4),
                Text(
                  '已排队',
                  style: TextStyle(
                    color: palette.warn,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 5),
            Text(
              text,
              style: TextStyle(
                color: palette.text,
                fontSize: 14.2,
                height: 1.55,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (onSendNow != null) ...[
                  InkWell(
                    onTap: interrupting ? null : onSendNow,
                    borderRadius: BorderRadius.circular(9),
                    child: Container(
                      height: 30,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: interrupting
                            ? palette.lineSoft
                            : palette.accent,
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Text(
                        interrupting ? '正在打断…' : '立即发送',
                        style: TextStyle(
                          color: interrupting
                              ? palette.text3
                              : palette.onAccent,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                ],
                if (onRemove != null && !interrupting)
                  InkWell(
                    onTap: onRemove,
                    borderRadius: BorderRadius.circular(6),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 2),
                      child: Text(
                        '移除',
                        style: TextStyle(
                          color: palette.text3,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              interrupting
                  ? '正在打断当前任务，随后发送…'
                  : (onSendNow == null
                      ? '当前任务结束后自动发送'
                      : '将打断当前任务 · 不点则结束后自动发送'),
              style: TextStyle(color: palette.text3, fontSize: 9.5),
            ),
          ],
        ),
      ),
    );
  }
}

/// 用户气泡（M2.9 Kimi 风格）：右对齐、浅蓝灰填充、深色字、20/20/6/20 圆角。
class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.text, this.time});

  final String text;
  final DateTime? time;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final parsed = parseUserText(text);
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 300),
        margin: const EdgeInsets.only(top: 18, left: 56),
        padding: const EdgeInsets.fromLTRB(15, 11, 15, 9),
        decoration: BoxDecoration(
          color: palette.bubbleUser,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(AppRadius.bubble),
            topRight: Radius.circular(AppRadius.bubble),
            bottomLeft: Radius.circular(AppRadius.bubble),
            bottomRight: Radius.circular(AppRadius.bubbleTail),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (parsed.body.isNotEmpty)
              Text(
                parsed.body,
                style: TextStyle(
                  color: palette.bubbleUserText,
                  fontSize: 14.5,
                  height: 1.55,
                ),
              ),
            if (parsed.hasAttachments)
              Padding(
                padding: EdgeInsets.only(top: parsed.body.isEmpty ? 0 : 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (final path in parsed.attachments)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.attach_file_rounded,
                                size: 12,
                                color: palette.bubbleUserText
                                    .withValues(alpha: 0.6)),
                            const SizedBox(width: 4),
                            Text(
                              attachmentFileName(path),
                              style: TextStyle(
                                color: palette.bubbleUserText
                                    .withValues(alpha: 0.75),
                                fontSize: 11.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            if (time != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  formatTime(time!),
                  style: TextStyle(
                    color: palette.bubbleUserText.withValues(alpha: 0.55),
                    fontSize: 10.5,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 助手正文（M2.9）：无气泡、无竖条，直接排版，行距更松。
///
/// M4.12：正文改走 [MarkdownText]（标题 / 列表 / 表格 / 代码块都按 Markdown
/// 排），时间与「复制」并进一条底部操作行，和官方 App 一致。
class _AssistantText extends StatelessWidget {
  const _AssistantText({required this.text, this.time});

  final String text;
  final DateTime? time;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Padding(
      padding: const EdgeInsets.only(top: 18, right: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MarkdownText(text),
          _AnswerActions(text: text, time: time, palette: palette),
        ],
      ),
    );
  }
}

/// 回复底部的一行小动作：复制 / 时间（长按菜单里还有「重新发送」）。
class _AnswerActions extends StatelessWidget {
  const _AnswerActions({
    required this.text,
    required this.time,
    required this.palette,
  });

  final String text;
  final DateTime? time;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: text.trim().isEmpty
                ? null
                : () async {
                    await Clipboard.setData(ClipboardData(text: text));
                    if (!context.mounted) return;
                    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                      const SnackBar(
                        content: Text('已复制'),
                        duration: Duration(milliseconds: 1200),
                      ),
                    );
                  },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Icon(Icons.copy_rounded, size: 13, color: palette.text3),
            ),
          ),
          if (time != null) ...[
            const SizedBox(width: 8),
            Text(
              formatTime(time!),
              style: TextStyle(color: palette.text3, fontSize: 10.5),
            ),
          ],
        ],
      ),
    );
  }
}

/// 轻量富文本：保留给「用户气泡 / 思考 / 工具卡」这类单行文本，
/// 正文改用 [MarkdownText]。支持 **加粗** 与 `代码`。
class _RichText extends StatelessWidget {
  const _RichText({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final spans = <TextSpan>[];
    final pattern = RegExp(r'(\*\*[^*]+\*\*|`[^`]+`)');
    var last = 0;
    for (final match in pattern.allMatches(text)) {
      if (match.start > last) {
        spans.add(TextSpan(text: text.substring(last, match.start)));
      }
      final raw = match.group(0)!;
      if (raw.startsWith('**')) {
        spans.add(TextSpan(
          text: raw.substring(2, raw.length - 2),
          style: const TextStyle(fontWeight: FontWeight.w700),
        ));
      } else {
        spans.add(TextSpan(
          text: raw.substring(1, raw.length - 1),
          style: kMono.copyWith(fontSize: 12.6, color: palette.accent),
        ));
      }
      last = match.end;
    }
    if (last < text.length) {
      spans.add(TextSpan(text: text.substring(last)));
    }
    return Text.rich(
      TextSpan(
        style: TextStyle(
          color: palette.text,
          fontSize: 15,
          height: 1.75,
        ),
        children: spans,
      ),
    );
  }
}

/// 思考过程：折叠行（card + line + 14 圆角 + 19 圆圈 ✦）。
class _ThinkingFold extends StatefulWidget {
  const _ThinkingFold({required this.text});

  final String text;

  @override
  State<_ThinkingFold> createState() => _ThinkingFoldState();
}

class _ThinkingFoldState extends State<_ThinkingFold> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Padding(
      padding: const EdgeInsets.only(top: 12, right: 56),
      child: Container(
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
                          Icons.auto_awesome_rounded,
                          size: 11,
                          color: palette.accent,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '思考过程',
                          style: TextStyle(color: palette.text2, fontSize: 12.5),
                        ),
                      ),
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
                padding: const EdgeInsets.fromLTRB(10, 0, 12, 12),
                child: Text(
                  widget.text,
                  style: TextStyle(
                    color: palette.text2,
                    fontSize: 12.5,
                    height: 1.55,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 工具调用卡片（§3.8）：头部 + 步骤行 + 代码块。
class _ToolCallCard extends StatefulWidget {
  const _ToolCallCard({required this.title, required this.steps});

  final String title;
  final List<ToolStep> steps;

  @override
  State<_ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<_ToolCallCard> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final done = widget.steps.where((s) => s.status == 'done').length;
    final failed = widget.steps.where((s) => s.status == 'failed').length;
    final accent = failed > 0 ? palette.danger : palette.text2;
    return Container(
      margin: const EdgeInsets.only(top: 14, right: 24),
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: palette.line),
        boxShadow: palette.cardShadow,
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(AppRadius.card),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
              child: Row(
                children: [
                  Icon(Icons.terminal_rounded, size: 16, color: accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.text,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    '$done/${widget.steps.length} 步',
                    style: TextStyle(color: palette.text3, fontSize: 10.5),
                  ),
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
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
              child: Column(
                children: [
                  for (final step in widget.steps) _StepRow(step: step),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({required this.step});

  final ToolStep step;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final ok = step.status == 'done';
    final running = step.status == 'running';
    final color = ok
        ? palette.success
        : running
            ? palette.accent
            : palette.danger;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.14),
                  shape: BoxShape.circle,
                ),
                child: running
                    ? Padding(
                        padding: const EdgeInsets.all(3),
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          color: color,
                        ),
                      )
                    : Icon(
                        ok ? Icons.check_rounded : Icons.close_rounded,
                        size: 11,
                        color: color,
                      ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  step.title,
                  style: TextStyle(
                    color: palette.text,
                    fontSize: 12.8,
                    height: 1.35,
                  ),
                ),
              ),
              if (step.durationMs != null)
                Text(
                  '${(step.durationMs! / 1000).toStringAsFixed(1)}s',
                  style: TextStyle(color: palette.text3, fontSize: 11),
                ),
            ],
          ),
          if (step.command.isNotEmpty) ...[
            const SizedBox(height: 8),
            _CodeBlock(
              text: r'$ ' + step.command,
              color: palette.codeText,
            ),
          ],
          if (step.output != null && step.output!.isNotEmpty)
            _CollapsibleOutput(
              output: step.output!,
              color: ok ? palette.codeText : palette.danger,
            ),
        ],
      ),
    );
  }
}

/// 代码块（§3.8）：codeBg + 12 圆角 + mono 11.6/1.6，缩进 12。
class _CodeBlock extends StatelessWidget {
  const _CodeBlock({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: palette.codeBg,
        borderRadius: BorderRadius.circular(AppRadius.code),
      ),
      child: Text(
        text,
        style: kMono.copyWith(color: color),
      ),
    );
  }
}

/// 工具输出块（M1.1）：状态、耗时、退出码 + 可折叠输出，不显示原始 JSON。
class _ToolResultCard extends StatelessWidget {
  const _ToolResultCard({required this.item});

  final ChatItem item;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final step = item.steps.isEmpty ? null : item.steps.first;
    final status = step?.status ?? 'done';
    final failed = status == 'failed';
    final color = failed ? palette.danger : palette.success;
    final title = step?.title ?? '工具输出';
    final output = (step?.output ?? item.text).trim();
    return Container(
      margin: const EdgeInsets.only(top: 14, right: 24),
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: palette.line),
        boxShadow: palette.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: Row(
              children: [
                Icon(
                  failed
                      ? Icons.error_outline_rounded
                      : Icons.check_circle_outline_rounded,
                  size: 16,
                  color: color,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: palette.text,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (step?.durationMs != null)
                  Text(
                    '${(step!.durationMs! / 1000).toStringAsFixed(1)}s',
                    style: TextStyle(color: palette.text3, fontSize: 11),
                  ),
                if (step?.exitCode != null) ...[
                  const SizedBox(width: 8),
                  Text(
                    'exit ${step!.exitCode}',
                    style: kMono.copyWith(fontSize: 10, color: color),
                  ),
                ],
              ],
            ),
          ),
          if (step != null && step.command.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
              child: _CodeBlock(
                text: r'$ ' + step.command,
                color: palette.codeText,
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
            child: output.isEmpty
                ? Text(
                    '（没有输出）',
                    style: TextStyle(color: palette.text3, fontSize: 11),
                  )
                : _CollapsibleOutput(
                    output: output,
                    color: failed ? palette.danger : palette.codeText,
                    initiallyExpanded: !item.collapsed,
                  ),
          ),
        ],
      ),
    );
  }
}

/// 输出块：长输出默认折叠，点标题展开；等宽字体 + codeBg。
class _CollapsibleOutput extends StatefulWidget {
  const _CollapsibleOutput({
    required this.output,
    required this.color,
    this.initiallyExpanded,
  });

  final String output;
  final Color color;
  final bool? initiallyExpanded;

  @override
  State<_CollapsibleOutput> createState() => _CollapsibleOutputState();
}

class _CollapsibleOutputState extends State<_CollapsibleOutput> {
  late bool _expanded =
      widget.initiallyExpanded ?? widget.output.length < 600;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final lines = widget.output.split('\n').length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              children: [
                Icon(
                  _expanded
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  size: 16,
                  color: palette.text3,
                ),
                const SizedBox(width: 5),
                Text(
                  '输出 · $lines 行',
                  style: TextStyle(color: palette.text3, fontSize: 10.5),
                ),
              ],
            ),
          ),
        ),
        if (_expanded)
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 280),
            decoration: BoxDecoration(
              color: palette.codeBg,
              borderRadius: BorderRadius.circular(AppRadius.code),
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: Text(
                widget.output,
                style: kMono.copyWith(color: widget.color),
              ),
            ),
          ),
      ],
    );
  }
}

class _ApprovalInlineCard extends StatelessWidget {
  const _ApprovalInlineCard({required this.item, required this.onTap});

  final ChatItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Container(
      margin: const EdgeInsets.only(top: 14, right: 24),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: palette.warnSoft,
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.lock_clock_rounded, size: 16, color: palette.warn),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  item.approvalTitle ?? '需要你的授权',
                  style: TextStyle(
                    color: palette.warn,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            item.approvalDetail ?? '该操作需要你确认后才会执行。',
            style: TextStyle(
              color: palette.text2,
              fontSize: 12.5,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 10),
          FilledButton(
            onPressed: onTap,
            style: FilledButton.styleFrom(
              backgroundColor: palette.warn,
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(40),
              textStyle:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            child: const Text('查看并处理'),
          ),
        ],
      ),
    );
  }
}

class _SystemNotice extends StatelessWidget {
  const _SystemNotice({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 28),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.info_outline_rounded, size: 13, color: palette.text3),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(color: palette.text3, fontSize: 11.5, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}
