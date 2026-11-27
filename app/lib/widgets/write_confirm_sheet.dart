import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 手机端写文件的最后一道确认（M2.8）。
///
/// 这一步与 AI 工具的高风险授权分开：AI 审批由 Agent 发起，这里是你主动
/// 要把手机上的编辑内容落到电脑磁盘，所以每次保存都单独确认一次。
Future<bool> showWriteConfirmSheet(
  BuildContext context, {
  required String relativePath,
  required bool isNew,
  required int byteCount,
  required int lineCount,
  int addedLines = 0,
  int removedLines = 0,
}) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.appPalette.card,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.sheetTop)),
    ),
    builder: (sheetContext) => WriteConfirmSheet(
      relativePath: relativePath,
      isNew: isNew,
      byteCount: byteCount,
      lineCount: lineCount,
      addedLines: addedLines,
      removedLines: removedLines,
    ),
  );
  return result == true;
}

class WriteConfirmSheet extends StatelessWidget {
  const WriteConfirmSheet({
    super.key,
    required this.relativePath,
    required this.isNew,
    required this.byteCount,
    required this.lineCount,
    this.addedLines = 0,
    this.removedLines = 0,
  });

  final String relativePath;
  final bool isNew;
  final int byteCount;
  final int lineCount;
  final int addedLines;
  final int removedLines;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          10,
          20,
          18 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: palette.lineSoft,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Container(
                  height: 22,
                  padding: const EdgeInsets.symmetric(horizontal: 9),
                  decoration: BoxDecoration(
                    color: palette.warnSoft,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.edit_document,
                        size: 13,
                        color: palette.warn,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        isNew ? '写入新文件' : '写入磁盘',
                        style: TextStyle(
                          color: palette.warn,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                Text(
                  '仅授权工作区内',
                  style: TextStyle(color: palette.text3, fontSize: 10.5),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              isNew ? '在电脑上新建这个文件？' : '把手机上的修改保存到电脑？',
              style: TextStyle(
                color: palette.text,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              isNew
                  ? '确认后会在电脑上创建这个文件，内容与你刚才编辑的一致。'
                  : '确认后会直接覆盖电脑上的同名文件；如果这期间电脑上又改过它，'
                      '保存会被拦下并提示你处理冲突。',
              style: TextStyle(
                color: palette.text2,
                fontSize: 12.5,
                height: 1.6,
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: palette.bg,
                borderRadius: BorderRadius.circular(AppRadius.card),
                border: Border.all(color: palette.line),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        isNew
                            ? Icons.note_add_outlined
                            : Icons.save_outlined,
                        size: 14,
                        color: palette.accent,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          relativePath,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: kMono.copyWith(
                            fontSize: 12,
                            color: palette.text,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 14,
                    runSpacing: 4,
                    children: [
                      _Metric(label: '大小', value: formatWriteSize(byteCount)),
                      _Metric(label: '行数', value: '$lineCount 行'),
                      if (!isNew && (addedLines > 0 || removedLines > 0))
                        _Metric(
                          label: '改动',
                          value: '+$addedLines / -$removedLines',
                          valueColor: palette.text2,
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: palette.text2,
                      side: BorderSide(color: palette.line),
                    ),
                    child: const Text('取消'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: FilledButton.icon(
                    onPressed: () => Navigator.of(context).pop(true),
                    icon: const Icon(Icons.check_rounded, size: 18),
                    label: Text(isNew ? '新建文件' : '覆盖保存'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.label,
    required this.value,
    this.valueColor,
  });

  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$label ',
          style: TextStyle(color: palette.text3, fontSize: 10.5),
        ),
        Text(
          value,
          style: TextStyle(
            color: valueColor ?? palette.text2,
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

/// 写入前的字节大小展示：小文件用 B，大文件用 KiB/MiB。
String formatWriteSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    final kib = bytes / 1024;
    return '${kib.toStringAsFixed(kib >= 100 ? 0 : 1)} KiB';
  }
  final mib = bytes / (1024 * 1024);
  return '${mib.toStringAsFixed(1)} MiB';
}
