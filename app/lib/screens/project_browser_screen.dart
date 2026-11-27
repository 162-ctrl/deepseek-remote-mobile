import 'package:flutter/material.dart';

import '../data/live_store.dart';
import '../models.dart';
import '../services/workspace_models.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import 'file_editor_screen.dart';
import 'file_viewer_screen.dart';

/// M2.6：逐级浏览工作区目录（懒加载，一次只列当前目录）。
/// M2.8：可在此新建文件。
class ProjectBrowserScreen extends StatefulWidget {
  const ProjectBrowserScreen({
    super.key,
    required this.liveStore,
    required this.workspacePath,
    this.relativePath = '',
    this.onOpenAssistant,
  });

  final LiveStore liveStore;

  /// 工作区根（必须是 device.status.workspaceRoots 之一）。
  final String workspacePath;

  /// 相对工作区根的路径，空 = 根目录。
  final String relativePath;

  /// 「在此目录发指令」后切到 AI 助手 Tab。
  final VoidCallback? onOpenAssistant;

  @override
  State<ProjectBrowserScreen> createState() => _ProjectBrowserScreenState();
}

class _ProjectBrowserScreenState extends State<ProjectBrowserScreen> {
  WorkspaceListing? _listing;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final listing = await widget.liveStore.listDirectory(
        workspacePath: widget.workspacePath,
        relativePath: widget.relativePath,
      );
      if (!mounted) return;
      setState(() {
        _listing = listing;
        _loading = false;
      });
    } on WorkspaceRequestException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.friendlyMessage;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '加载失败：$error';
        _loading = false;
      });
    }
  }

  void _openDirectory(WorkspaceEntry entry) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ProjectBrowserScreen(
          liveStore: widget.liveStore,
          workspacePath: widget.workspacePath,
          relativePath: entry.path,
          onOpenAssistant: widget.onOpenAssistant,
        ),
      ),
    );
  }

  void _openFile(WorkspaceEntry entry) {
    Navigator.of(context)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => FileViewerScreen(
              liveStore: widget.liveStore,
              workspacePath: widget.workspacePath,
              relativePath: entry.path,
              fileName: entry.name,
            ),
          ),
        )
        .then((_) {
      // 详情页里可能保存过内容，回来后刷新大小/时间。
      if (mounted) _load();
    });
  }

  Future<void> _createFile() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _NewFileDialog(),
    );
    final trimmed = name?.trim() ?? '';
    if (!mounted || trimmed.isEmpty) return;
    final relativePath =
        widget.relativePath.isEmpty ? trimmed : '${widget.relativePath}/$trimmed';
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => FileEditorScreen(
          liveStore: widget.liveStore,
          workspacePath: widget.workspacePath,
          relativePath: relativePath,
        ),
      ),
    );
    if (mounted && created == true) await _load();
  }

  void _useThisDirectory() {
    widget.liveStore.setPendingWorkspace(widget.workspacePath);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '已选择项目目录：${widget.relativePath.isEmpty ? '根目录' : widget.relativePath}',
        ),
      ),
    );
    widget.onOpenAssistant?.call();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final title = widget.relativePath.isEmpty
        ? _lastSegment(widget.workspacePath)
        : _lastSegment(widget.relativePath);
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 4,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: palette.text,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 1),
            Text(
              widget.relativePath.isEmpty ? '项目根目录' : widget.relativePath,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: palette.text3,
                fontSize: 10.5,
                fontFamily: 'monospace',
              ),
            ),
          ],
        ),
        actions: [
          if (widget.liveStore.canWriteWorkspaceFiles)
            IconButton(
              tooltip: '新建文件',
              onPressed: _loading ? null : _createFile,
              icon: const Icon(Icons.note_add_outlined, size: 20),
            ),
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded, size: 20),
          ),
        ],
      ),
      body: Column(
        children: [
          if (widget.relativePath.isNotEmpty)
            _BreadcrumbBar(
              rootName: _lastSegment(widget.workspacePath),
              relativePath: widget.relativePath,
              onUp: () => Navigator.of(context).maybePop(),
            ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _load,
              child: _buildBody(palette),
            ),
          ),
          SafeArea(
            top: false,
            child: Container(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.page,
                10,
                AppSpace.page,
                10,
              ),
              decoration: BoxDecoration(
                color: palette.bg,
                border: Border(top: BorderSide(color: palette.line)),
              ),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _useThisDirectory,
                  icon: const Icon(Icons.terminal_rounded, size: 18),
                  label: const Text('在此目录发指令'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 46),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(AppPalette palette) {
    if (_loading && _listing == null) {
      return ListView(
        children: const [
          Padding(
            padding: EdgeInsets.symmetric(vertical: 64),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2.4)),
          ),
        ],
      );
    }
    if (_error != null) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpace.page,
          24,
          AppSpace.page,
          24,
        ),
        children: [
          EmptyHint(icon: Icons.cloud_off_rounded, text: _error!),
          const SizedBox(height: 12),
          Center(
            child: OutlinedButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('重试'),
            ),
          ),
        ],
      );
    }
    final listing = _listing;
    if (listing == null || listing.entries.isEmpty) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpace.page,
          24,
          AppSpace.page,
          24,
        ),
        children: const [
          EmptyHint(icon: Icons.folder_off_outlined, text: '这个目录是空的'),
        ],
      );
    }
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(AppSpace.page, 8, AppSpace.page, 20),
      itemCount: listing.entries.length + 1,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        if (index == 0) {
          return _ListingHeader(listing: listing);
        }
        final entry = listing.entries[index - 1];
        return _EntryRow(
          entry: entry,
          onTap: () => entry.isDir ? _openDirectory(entry) : _openFile(entry),
        );
      },
    );
  }

  static String _lastSegment(String path) {
    final normalized = path.replaceAll('\\', '/');
    final segments =
        normalized.split('/').where((segment) => segment.isNotEmpty).toList();
    return segments.isEmpty ? path : segments.last;
  }
}

class _BreadcrumbBar extends StatelessWidget {
  const _BreadcrumbBar({
    required this.rootName,
    required this.relativePath,
    required this.onUp,
  });

  final String rootName;
  final String relativePath;
  final VoidCallback onUp;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(8, 2, AppSpace.page, 2),
      decoration: BoxDecoration(
        color: palette.bg,
        border: Border(bottom: BorderSide(color: palette.lineSoft)),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: '返回上级',
            onPressed: onUp,
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.arrow_upward_rounded, size: 18, color: palette.text2),
          ),
          Expanded(
            child: Text(
              '$rootName / $relativePath',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: palette.text3,
                fontSize: 11,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ListingHeader extends StatelessWidget {
  const _ListingHeader({required this.listing});

  final WorkspaceListing listing;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final parts = <String>['${listing.entries.length} 项'];
    if (listing.truncated) parts.add('已截断');
    if (listing.ignoredCount > 0) {
      parts.add('已隐藏 ${listing.ignoredCount} 个忽略目录');
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              parts.join(' · '),
              style: TextStyle(color: palette.text3, fontSize: 11),
            ),
          ),
          if (listing.truncated)
            Text(
              '仅显示前 500 项',
              style: TextStyle(color: palette.warn, fontSize: 11),
            ),
        ],
      ),
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({required this.entry, required this.onTap});

  final WorkspaceEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Container(
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: palette.line),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: entry.isDir ? palette.accentSoft : palette.lineSoft,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  entry.isDir
                      ? Icons.folder_rounded
                      : Icons.description_outlined,
                  size: 18,
                  color: entry.isDir ? palette.accent : palette.text2,
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.text,
                        fontSize: 13.2,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      entry.isDir
                          ? '文件夹'
                          : '${formatFileSize(entry.size)}'
                              '${entry.modifiedAt != null ? ' · ${relativeTime(entry.modifiedAt!)}' : ''}',
                      style: TextStyle(color: palette.text3, fontSize: 10.5),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: palette.text3,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 文件大小格式化（B/KB/MB）。
String formatFileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
}

/// 新建文件的文件名输入框（只收文件名，目录由当前浏览位置决定）。
class _NewFileDialog extends StatefulWidget {
  const _NewFileDialog();

  @override
  State<_NewFileDialog> createState() => _NewFileDialogState();
}

class _NewFileDialogState extends State<_NewFileDialog> {
  final TextEditingController _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _controller.text.trim();
    final error = _validateName(value);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.of(context).pop(value);
  }

  static String? _validateName(String value) {
    if (value.isEmpty) return '请输入文件名';
    if (value.length > 120) return '文件名太长了';
    if (value.contains('\\')) return '请用 / 分隔子目录，不要用反斜杠';
    if (value.startsWith('/')) return '请填写相对路径';
    final segments = value.split('/');
    if (segments.any((segment) => segment.isEmpty)) return '路径里有空的层级';
    if (segments.any((segment) => segment == '.' || segment == '..')) {
      return '路径里不能有 . 或 ..';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return AlertDialog(
      backgroundColor: palette.card,
      title: Text(
        '新建文件',
        style: TextStyle(color: palette.text, fontSize: 16),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            style: TextStyle(color: palette.text, fontSize: 13.5),
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              hintText: '例如 notes/today.md',
              hintStyle: TextStyle(color: palette.text3, fontSize: 13),
              errorText: _error,
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '文件会建在当前目录下；目录必须已存在。',
            style: TextStyle(color: palette.text3, fontSize: 11),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('下一步'),
        ),
      ],
    );
  }
}
