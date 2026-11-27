import 'package:flutter/material.dart';

import '../data/live_store.dart';
import '../services/history_api.dart' show ReceivedFile;
import '../services/pairing_api.dart';
import '../theme/app_theme.dart';
import '../widgets/empty_state.dart';
import 'file_viewer_screen.dart';
import 'project_browser_screen.dart' show formatFileSize;

/// M4.57：「功能 → 接收文件」。
///
/// 电脑端（或 AI）把做好的文件放进插件状态目录的 `received/`，这里按修改时间
/// 倒序列出；点开复用文件预览——图片能放大、.docx 能按文字读（M4.52）、
/// 其它交给「用其他应用打开」。
class ReceivedFilesScreen extends StatefulWidget {
  const ReceivedFilesScreen({super.key, required this.liveStore});

  final LiveStore liveStore;

  @override
  State<ReceivedFilesScreen> createState() => _ReceivedFilesScreenState();
}

class _ReceivedFilesScreenState extends State<ReceivedFilesScreen> {
  List<ReceivedFile> _files = const <ReceivedFile>[];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final files = await widget.liveStore.loadReceivedFiles();
      if (!mounted) return;
      setState(() {
        _files = files;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error is PairingApiException ? error.message : '$error';
        _loading = false;
      });
    }
  }

  void _open(ReceivedFile file) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => FileViewerScreen(
          liveStore: widget.liveStore,
          fileName: file.name,
          fetchBytes: () => widget.liveStore.downloadReceivedFile(file.name),
        ),
      ),
    );
  }

  /// 按扩展名挑图标：图片 / PDF / Word / 表格 / 压缩包 / 其它。
  static IconData _iconFor(String name) {
    final lower = name.toLowerCase();
    final dot = lower.lastIndexOf('.');
    final ext = dot < 0 ? '' : lower.substring(dot + 1);
    const images = <String>{'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'heic', 'heif'};
    const words = <String>{'doc', 'docx'};
    const sheets = <String>{'xls', 'xlsx', 'csv', 'tsv'};
    const archives = <String>{'zip', 'rar', '7z', 'gz', 'tar'};
    if (images.contains(ext)) return Icons.image_outlined;
    if (ext == 'pdf') return Icons.picture_as_pdf_outlined;
    if (words.contains(ext)) return Icons.description_outlined;
    if (sheets.contains(ext)) return Icons.table_chart_outlined;
    if (archives.contains(ext)) return Icons.folder_zip_outlined;
    return Icons.insert_drive_file_outlined;
  }

  static String _formatWhen(DateTime? when) {
    if (when == null) return '';
    final diff = DateTime.now().difference(when);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
    if (diff.inHours < 24) return '${diff.inHours} 小时前';
    if (diff.inDays < 30) return '${diff.inDays} 天前';
    return '${when.year}-${when.month.toString().padLeft(2, '0')}-${when.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: palette.bg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        toolbarHeight: 64,
        titleSpacing: 4,
        title: Text(
          '接收文件',
          style: TextStyle(
            color: palette.text,
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded, size: 20),
          ),
        ],
      ),
      body: _buildBody(palette),
    );
  }

  Widget _buildBody(AppPalette palette) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.4));
    }
    if (_error != null) {
      return EmptyState(
        icon: Icons.inbox_outlined,
        title: '读不到接收文件',
        description: _error!,
        actionLabel: '重试',
        onAction: _load,
      );
    }
    if (_files.isEmpty) {
      return EmptyState(
        icon: Icons.inbox_outlined,
        title: '还没有收到文件',
        description: '在电脑上让我发文件时，做好的文件会放进这里，点开就能看。',
        actionLabel: '刷新',
        onAction: _load,
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(AppSpace.page, 4, AppSpace.page, 28),
        itemCount: _files.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final file = _files[index];
          return _ReceivedFileTile(
            file: file,
            palette: palette,
            onTap: () => _open(file),
          );
        },
      ),
    );
  }
}

class _ReceivedFileTile extends StatelessWidget {
  const _ReceivedFileTile({
    required this.file,
    required this.palette,
    required this.onTap,
  });

  final ReceivedFile file;
  final AppPalette palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final when = _ReceivedFilesScreenState._formatWhen(file.updatedAt);
    final meta = <String>[
      formatFileSize(file.size),
      if (when.isNotEmpty) when,
    ].join(' · ');
    return Material(
      color: palette.card,
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.card),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: palette.accentSoft,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  _ReceivedFilesScreenState._iconFor(file.name),
                  size: 18,
                  color: palette.accent,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      file.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.text,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      meta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: palette.text3, fontSize: 11.5),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
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
