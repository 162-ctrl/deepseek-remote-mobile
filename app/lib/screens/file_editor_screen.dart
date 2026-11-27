import 'dart:convert';

import 'package:flutter/material.dart';

import '../data/live_store.dart';
import '../services/workspace_models.dart';
import '../theme/app_theme.dart';
import '../widgets/write_confirm_sheet.dart';

/// M2.8：手机端文本编辑器（新建 / 修改后保存到电脑）。
///
/// 保存流程：本地校验 → 确认 Bottom Sheet → `file.write`（带 baseSha256）→
/// 成功后退回上一页并返回 true。冲突时给「重新加载 / 强制覆盖 / 取消」。
class FileEditorScreen extends StatefulWidget {
  const FileEditorScreen({
    super.key,
    required this.liveStore,
    required this.workspacePath,
    required this.relativePath,
    this.initial,
  });

  final LiveStore liveStore;
  final String workspacePath;
  final String relativePath;

  /// 已打开的文件内容；为 null 表示新建文件。
  final WorkspaceFileContent? initial;

  @override
  State<FileEditorScreen> createState() => _FileEditorScreenState();
}

class _FileEditorScreenState extends State<FileEditorScreen> {
  late final TextEditingController _controller;
  String _original = '';
  String? _baseSha256;
  bool _bom = false;
  bool _crlf = false;
  bool _saving = false;

  bool get _isNew => widget.initial == null;

  /// 预览被截断时不允许保存：否则会把电脑上的大文件截成前 N 字节。
  bool get _truncated => widget.initial?.truncated == true;

  bool get _dirty => _controller.text != _original;

  bool get _canSave =>
      !_saving && !_truncated && (_isNew || _dirty);

  @override
  void initState() {
    super.initState();
    final snapshot = _normalize(widget.initial?.content ?? '');
    _original = snapshot.text;
    _bom = snapshot.bom;
    _crlf = snapshot.crlf;
    _baseSha256 = widget.initial?.sha256;
    _controller = TextEditingController(text: snapshot.text);
    _controller.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String get _fileName {
    final normalized = widget.relativePath.replaceAll('\\', '/');
    final segments = normalized
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .toList();
    return segments.isEmpty ? widget.relativePath : segments.last;
  }

  int get _lineCount => '\n'.allMatches(_controller.text).length + 1;

  String _denormalize(String text) {
    var out = _crlf ? text.replaceAll('\n', '\r\n') : text;
    if (_bom && !out.startsWith('\uFEFF')) out = '\uFEFF$out';
    return out;
  }

  Future<void> _save({bool force = false}) async {
    if (_saving || _truncated) return;
    final text = _controller.text;
    final body = _denormalize(text);
    final bytes = utf8.encode(body);
    if (bytes.length > kMaxWorkspaceWriteBytes) {
      _showSnack('内容 ${formatWriteSize(bytes.length)} 超过单次写入上限 512 KiB，请拆分文件');
      return;
    }

    if (!force) {
      final diff = _diffLineStats(_original, text);
      final confirmed = await showWriteConfirmSheet(
        context,
        relativePath: widget.relativePath,
        isNew: _isNew,
        byteCount: bytes.length,
        lineCount: _lineCount,
        addedLines: diff.added,
        removedLines: diff.removed,
      );
      if (!confirmed || !mounted) return;
    }

    setState(() => _saving = true);
    try {
      final result = await widget.liveStore.writeWorkspaceFile(
        workspacePath: widget.workspacePath,
        relativePath: widget.relativePath,
        content: body,
        baseSha256: _isNew ? null : _baseSha256,
        force: force,
      );
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            result.created
                ? '已新建 ${result.relativePath}（${formatWriteSize(result.size)}）'
                : '已保存 ${result.relativePath}（${formatWriteSize(result.size)}）',
          ),
        ),
      );
      Navigator.of(context).pop(true);
    } on WorkspaceRequestException catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      if (error.code == 'CONFLICT' || error.code == 'FILE_EXISTS') {
        await _handleWriteBlocked(error);
      } else {
        _showSnack(error.friendlyMessage);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      _showSnack('保存失败：$error');
    }
  }

  /// 乐观锁冲突 / 目标已存在：让用户决定放弃、重载还是强制覆盖。
  Future<void> _handleWriteBlocked(WorkspaceRequestException error) async {
    final isExists = error.code == 'FILE_EXISTS';
    WorkspaceFileContent? latest;
    if (!isExists) {
      try {
        latest = await widget.liveStore.readWorkspaceFile(
          workspacePath: widget.workspacePath,
          relativePath: widget.relativePath,
        );
      } on WorkspaceRequestException {
        latest = null;
      }
    }
    if (!mounted) return;

    final action = await showDialog<_ConflictAction>(
      context: context,
      builder: (dialogContext) {
        final palette = dialogContext.appPalette;
        return AlertDialog(
          backgroundColor: palette.card,
          title: Text(
            isExists ? '电脑上已有同名文件' : '文件已在电脑上被改动',
            style: TextStyle(color: palette.text, fontSize: 16),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isExists
                    ? '目标路径已存在一个文件。你可以强制覆盖它，或者取消后换个名字。'
                    : '你打开这个文件之后，电脑上的内容又变了。为避免覆盖别人的修改，这次保存被拦下了。',
                style: TextStyle(
                  color: palette.text2,
                  fontSize: 12.5,
                  height: 1.6,
                ),
              ),
              if (latest != null) ...[
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: palette.codeBg,
                    borderRadius: BorderRadius.circular(AppRadius.code),
                  ),
                  child: Text(
                    '电脑上的版本：${formatWriteSize(latest.size)} · '
                    'sha256 ${latest.sha256Short.isEmpty ? '—' : latest.sha256Short}',
                    style: kMono.copyWith(
                      fontSize: 10.5,
                      color: palette.text3,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Text(
                '你的修改还留在编辑器里，不会因为这次提示丢失。',
                style: TextStyle(color: palette.text3, fontSize: 11.5),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(_ConflictAction.cancel),
              child: const Text('取消'),
            ),
            if (!isExists)
              TextButton(
                onPressed: () =>
                    Navigator.of(dialogContext).pop(_ConflictAction.reload),
                child: const Text('重新加载'),
              ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(_ConflictAction.force),
              style: FilledButton.styleFrom(backgroundColor: palette.danger),
              child: const Text('强制覆盖'),
            ),
          ],
        );
      },
    );

    if (!mounted || action == null || action == _ConflictAction.cancel) return;
    if (action == _ConflictAction.force) {
      await _save(force: true);
      return;
    }
    // 重新加载：用电脑上的最新内容替换编辑器，放弃本地修改。
    if (latest == null) {
      try {
        latest = await widget.liveStore.readWorkspaceFile(
          workspacePath: widget.workspacePath,
          relativePath: widget.relativePath,
        );
      } on WorkspaceRequestException catch (error) {
        if (mounted) _showSnack(error.friendlyMessage);
        return;
      }
    }
    if (!mounted) return;
    final snapshot = _normalize(latest.content);
    setState(() {
      _original = snapshot.text;
      _bom = snapshot.bom;
      _crlf = snapshot.crlf;
      _baseSha256 = latest!.sha256;
      _controller.text = snapshot.text;
    });
    _showSnack('已重新加载电脑上的最新内容');
  }

  Future<void> _confirmLeave() async {
    final leave = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final palette = dialogContext.appPalette;
        return AlertDialog(
          backgroundColor: palette.card,
          title: Text('放弃未保存的修改？',
              style: TextStyle(color: palette.text, fontSize: 16)),
          content: Text(
            '你在这个文件里的改动还没有写到电脑上，离开后会丢失。',
            style: TextStyle(color: palette.text2, fontSize: 12.5, height: 1.6),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('继续编辑'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              style: FilledButton.styleFrom(backgroundColor: palette.danger),
              child: const Text('放弃'),
            ),
          ],
        );
      },
    );
    if (leave == true && mounted) {
      Navigator.of(context).pop(false);
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final dirty = _dirty;
    return PopScope(
      canPop: !dirty && !_saving,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop || _saving) return;
        _confirmLeave();
      },
      child: Scaffold(
        appBar: AppBar(
          titleSpacing: 4,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _fileName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: palette.text,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                widget.relativePath,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: kMono.copyWith(fontSize: 10, color: palette.text3),
              ),
            ],
          ),
          actions: [
            if (_saving)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 18),
                child: Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else
              TextButton(
                onPressed: _canSave ? () => _save() : null,
                child: Text(
                  '保存',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: _canSave ? palette.accent : palette.text3,
                  ),
                ),
              ),
          ],
        ),
        body: Column(
          children: [
            _buildStatusBar(palette, dirty),
            if (_truncated) _buildTruncatedBanner(palette),
            Expanded(child: _buildEditor(palette)),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusBar(AppPalette palette, bool dirty) {
    final (icon, color, label) = switch ((_isNew, dirty)) {
      (true, _) => (Icons.note_add_outlined, palette.accent, '新建文件 · 尚未保存'),
      (false, true) => (Icons.edit_outlined, palette.warn, '已修改 · 未保存'),
      (false, false) => (Icons.check_circle_outline, palette.success, '与电脑上的内容一致'),
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      decoration: BoxDecoration(
        color: palette.bg,
        border: Border(bottom: BorderSide(color: palette.line)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(color: color, fontSize: 11)),
          const Spacer(),
          Text(
            '$_lineCount 行 · ${_controller.text.length} 字符',
            style: kMono.copyWith(fontSize: 10, color: palette.text3),
          ),
        ],
      ),
    );
  }

  Widget _buildTruncatedBanner(AppPalette palette) {
    return Container(
      width: double.infinity,
      color: palette.warnSoft,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Text(
        '这个文件太大，只加载了前 ${formatWriteSize(widget.initial?.content.length ?? 0)}，'
        '为避免把电脑上的文件截断，这里不能保存。',
        style: TextStyle(color: palette.warn, fontSize: 11.5, height: 1.5),
      ),
    );
  }

  Widget _buildEditor(AppPalette palette) {
    return Container(
      color: palette.codeBg,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
        child: TextField(
          controller: _controller,
          enabled: !_truncated && !_saving,
          expands: true,
          maxLines: null,
          minLines: null,
          textAlignVertical: TextAlignVertical.top,
          keyboardType: TextInputType.multiline,
          textCapitalization: TextCapitalization.none,
          autocorrect: false,
          enableSuggestions: false,
          smartDashesType: SmartDashesType.disabled,
          smartQuotesType: SmartQuotesType.disabled,
          style: kMono.copyWith(
            color: palette.codeText,
            fontSize: 12.5,
            height: 1.55,
          ),
          decoration: InputDecoration(
            border: InputBorder.none,
            isDense: true,
            hintText: _isNew ? '在这里写下文件内容…' : null,
            hintStyle: TextStyle(color: palette.text3, fontSize: 12.5),
            contentPadding: const EdgeInsets.only(bottom: 24),
          ),
        ),
      ),
    );
  }
}

enum _ConflictAction { cancel, reload, force }

/// 编辑时统一换行与 BOM，保存时再还原，避免把整份文件的行尾改掉。
class _TextSnapshot {
  const _TextSnapshot(this.text, {required this.bom, required this.crlf});

  final String text;
  final bool bom;
  final bool crlf;
}

_TextSnapshot _normalize(String raw) {
  var text = raw;
  final bom = text.startsWith('\uFEFF');
  if (bom) text = text.substring(1);
  final crlf = text.contains('\r\n');
  text = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  return _TextSnapshot(text, bom: bom, crlf: crlf);
}

/// 估算这次编辑改了多少行（只用于确认弹层的展示）。
///
/// 小文件用两行 LCS 精确算增删；超大文件退化成按行出现次数估算，
/// 避免在手机上做 O(n*m) 的比对（上限 800 行）。
({int added, int removed}) _diffLineStats(String before, String after) {
  final a = before.split('\n');
  final b = after.split('\n');
  if (a.length > 800 || b.length > 800) {
    final remaining = <String, int>{};
    for (final line in a) {
      remaining[line] = (remaining[line] ?? 0) + 1;
    }
    var added = 0;
    for (final line in b) {
      final count = remaining[line] ?? 0;
      if (count > 0) {
        remaining[line] = count - 1;
      } else {
        added++;
      }
    }
    var removed = 0;
    for (final count in remaining.values) {
      if (count > 0) removed += count;
    }
    return (added: added, removed: removed);
  }

  final n = a.length;
  final m = b.length;
  var prev = List<int>.filled(m + 1, 0);
  var cur = List<int>.filled(m + 1, 0);
  for (var i = 1; i <= n; i++) {
    for (var j = 1; j <= m; j++) {
      cur[j] = a[i - 1] == b[j - 1]
          ? prev[j - 1] + 1
          : (prev[j] >= cur[j - 1] ? prev[j] : cur[j - 1]);
    }
    final swap = prev;
    prev = cur;
    cur = swap;
    cur.fillRange(0, m + 1, 0);
  }
  final common = prev[m];
  return (added: m - common, removed: n - common);
}
