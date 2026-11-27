import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/live_store.dart';
import '../models.dart';
import '../services/file_opener.dart';
import '../services/office_text.dart';
import '../services/pairing_api.dart';
import '../services/workspace_models.dart';
import '../theme/app_theme.dart';
import '../widgets/empty_state.dart';
import 'file_editor_screen.dart';
import 'project_browser_screen.dart';

/// M4.9：按扩展名判断预览方式。
enum FilePreviewKind { text, image, pdf, office, other }

/// 由文件名猜出预览方式（纯函数，便于单测）。
///
/// - 图片：直接下载字节后在 App 内放大看；
/// - PDF / Office：下载后交给系统应用（WPS / 阅读器）打开；
/// - 其它：文本按原来的等宽预览，二进制走「用其他应用打开」。
FilePreviewKind previewKindOf(String fileName) {
  final lower = fileName.toLowerCase();
  final dot = lower.lastIndexOf('.');
  final ext = dot < 0 ? '' : lower.substring(dot + 1);
  const images = <String>{
    'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'heic', 'heif',
  };
  const office = <String>{
    'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'csv', 'tsv',
  };
  if (images.contains(ext)) return FilePreviewKind.image;
  if (ext == 'pdf') return FilePreviewKind.pdf;
  if (office.contains(ext)) return FilePreviewKind.office;
  return FilePreviewKind.text;
}

/// M2.6/M2.8：文件预览（文本等宽可编辑；M4.9 起图片、PDF、Office 也能打开）。
class FileViewerScreen extends StatefulWidget {
  const FileViewerScreen({
    super.key,
    required this.liveStore,
    this.workspacePath = '',
    this.relativePath = '',
    this.fileName,
    this.fileOpener,
    this.fetchBytes,
  });

  final LiveStore liveStore;
  final String workspacePath;
  final String relativePath;

  /// 列表里展示的文件名（缺省取路径最后一段）。
  final String? fileName;

  /// M4.9：拉起系统应用用的网关（测试注入 [FakeFileOpener]）。
  final FileOpener? fileOpener;

  /// M4.57：「功能 → 接收文件」里的文件不在工作区里，改用这个取字节。
  /// 设置后不再读工作区，[workspacePath]/[relativePath] 只用于展示。
  final Future<List<int>> Function()? fetchBytes;

  @override
  State<FileViewerScreen> createState() => _FileViewerScreenState();
}

class _FileViewerScreenState extends State<FileViewerScreen> {
  WorkspaceFileContent? _content;
  String? _error;
  bool _loading = true;
  bool _showLineNumbers = true;
  late final FileOpener _opener = widget.fileOpener ?? MethodChannelFileOpener();

  /// M4.9：图片/PDF/Office 下载到的原始字节（文本预览时为 null）。
  Uint8List? _bytes;
  bool _binary = false;
  bool _opening = false;

  /// M4.52：.docx 抽出来的正文；null 表示没抽出来（退回系统应用）。
  String? _officePreview;

  /// M4.69：没有文字的 .docx（扫描件）按页取出来的图片。
  List<Uint8List> _officePages = const <Uint8List>[];

  /// M4.70：这台手机上有没有应用能「打开」这个文件；false 时不显示那个按钮。
  bool _canOpenExternal = true;

  /// 超过这个大小的 .docx 不在主线程里解，直接交给系统应用。
  static const int _maxDocxBytes = 12 * 1024 * 1024;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    if (widget.fileOpener == null) {
      _opener.dispose();
    }
    super.dispose();
  }

  FilePreviewKind get _kind => previewKindOf(_title);

  bool get _needsBytes => _kind != FilePreviewKind.text;

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
      _bytes = null;
      _binary = false;
      _officePreview = null;
      _officePages = const <Uint8List>[];
    });
    if (widget.fetchBytes != null) {
      // M4.57：接收文件不走工作区接口，直接拿字节；文本也在本地解码。
      await _loadBytes();
      return;
    }
    if (_needsBytes) {
      await _loadBytes();
      return;
    }
    try {
      final content = await widget.liveStore.readWorkspaceFile(
        workspacePath: widget.workspacePath,
        relativePath: widget.relativePath,
      );
      if (!mounted) return;
      if (content.binary) {
        // M4.9：文本接口说这是二进制（比如没扩展名的图片），改走原始字节。
        setState(() => _binary = true);
        await _loadBytes();
        return;
      }
      setState(() {
        _content = content;
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
        _error = _friendlyDownloadError(error);
        _loading = false;
      });
    }
  }

  /// M4.9：下载原始字节。插件 0.2.12 及更早没有 `/desktop/file/raw`。
  Future<void> _loadBytes() async {
    try {
      final bytes = widget.fetchBytes != null
          ? await widget.fetchBytes!()
          : await widget.liveStore.downloadWorkspaceFile(
              workspacePath: widget.workspacePath,
              relativePath: widget.relativePath,
            );
      if (!mounted) return;
      final data = Uint8List.fromList(bytes);
      // M4.57：接收文件里的 .md/.txt 没有工作区文本接口，本地按 UTF-8 解。
      if (widget.fetchBytes != null && _kind == FilePreviewKind.text) {
        setState(() {
          _bytes = data;
          _officePreview = null;
          _content = WorkspaceFileContent(
            relativePath: _title,
            content: utf8.decode(data, allowMalformed: true),
            size: data.length,
          );
          _loading = false;
        });
        return;
      }
      // M4.52：.docx 先在本地抽正文，抽得出来就不必看手机上有没有 WPS。
      // M4.69：抽不出文字的多半是扫描件，再把 word/media 里的图片按页取出来。
      final docx = isDocxFileName(_title) && data.length <= _maxDocxBytes;
      final officePreview = docx ? docxTextFromBytes(data) : null;
      final officePages = docx && officePreview == null
          ? docxImagePages(data)
          : const <Uint8List>[];
      setState(() {
        _bytes = data;
        _officePreview = officePreview;
        _officePages = officePages;
        _loading = false;
      });
      unawaited(_probeOpenable());
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = _friendlyDownloadError(error);
        _loading = false;
      });
    }
  }

  String _friendlyDownloadError(Object error) {
    final message = error is PairingApiException ? error.message : '$error';
    if (error is PairingApiException && error.statusCode == 404) {
      return '电脑端插件版本过低，还不能在手机上看这种文件；升级插件（0.2.13+）后重试。';
    }
    return message;
  }

  /// M4.70：没装能打开这类文件的应用时，把「用其他应用打开」藏起来。
  Future<void> _probeOpenable() async {
    if (_kind == FilePreviewKind.text) return;
    final openable = await _opener.canOpenBytes(_title, mimeType: _mimeOf(_title));
    if (!mounted) return;
    if (openable != _canOpenExternal) {
      setState(() => _canOpenExternal = openable);
    }
  }

  Future<void> _openWithSystem() async {
    final bytes = _bytes;
    if (bytes == null || _opening) return;
    setState(() => _opening = true);
    final opened = await _opener.openBytes(
      bytes,
      fileName: _title,
      mimeType: _mimeOf(_title),
    );
    if (!mounted) return;
    setState(() => _opening = false);
    if (!opened) {
      final reason = _opener.lastError;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            reason == null || reason.isEmpty
                ? '手机上没有能打开这种文件的应用，可以点右上角「分享」发给别的应用或设备'
                : '打不开这个文件：$reason',
          ),
        ),
      );
    }
  }

  /// M4.64：交给系统分享面板。
  Future<void> _share() async {
    final bytes = _bytes;
    if (bytes == null || _opening) return;
    setState(() => _opening = true);
    final shared = await _opener.shareBytes(
      bytes,
      fileName: _title,
      mimeType: _mimeOf(_title),
    );
    if (!mounted) return;
    setState(() => _opening = false);
    if (!shared) {
      final reason = _opener.lastError;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            reason == null || reason.isEmpty
                ? '分享失败：没能拉起系统分享面板'
                : '分享失败：$reason',
          ),
        ),
      );
    }
  }

  static String? _mimeOf(String fileName) {
    final lower = fileName.toLowerCase();
    final dot = lower.lastIndexOf('.');
    final ext = dot < 0 ? '' : lower.substring(dot + 1);
    const map = <String, String>{
      'png': 'image/png',
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'gif': 'image/gif',
      'webp': 'image/webp',
      'bmp': 'image/bmp',
      'pdf': 'application/pdf',
      'doc': 'application/msword',
      'docx':
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'xls': 'application/vnd.ms-excel',
      'xlsx':
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'ppt': 'application/vnd.ms-powerpoint',
      'pptx':
          'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      'csv': 'text/csv',
    };
    return map[ext];
  }

  void _copyAll() {
    final content = _content;
    if (content == null) return;
    Clipboard.setData(ClipboardData(text: content.content));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制文件全部内容')),
    );
  }

  Future<void> _openEditor() async {
    final content = _content;
    if (content == null) return;
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => FileEditorScreen(
          liveStore: widget.liveStore,
          workspacePath: widget.workspacePath,
          relativePath: widget.relativePath,
          initial: content,
        ),
      ),
    );
    if (saved == true && mounted) {
      await _load();
    }
  }

  /// 电脑端 Agent 支持写入且文件未被截断时才允许编辑。
  /// M4.57：接收文件是电脑端发过来的副本，改不了（没有可写回的工作区路径）。
  bool get _canEdit => widget.fetchBytes == null && widget.liveStore.canWriteWorkspaceFiles;

  String get _title {
    if (widget.fileName != null && widget.fileName!.isNotEmpty) {
      return widget.fileName!;
    }
    return _lastSegment(widget.relativePath);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final content = _content;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 4,
        title: Text(
          _title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: palette.text,
            fontSize: 17,
            fontWeight: FontWeight.w700,
          ),
        ),
        actions: [
          if (_bytes != null)
            IconButton(
              tooltip: '分享文件',
              onPressed: _opening ? null : _share,
              icon: Icon(
                Icons.ios_share_rounded,
                size: 19,
                color: _opening ? palette.text3 : palette.accent,
              ),
            ),
          if (_needsBytes || _binary) ...[
            IconButton(
              tooltip: '用其他应用打开',
              onPressed: _bytes == null || _opening ? null : _openWithSystem,
              icon: Icon(
                Icons.open_in_new_rounded,
                size: 19,
                color: _bytes == null ? palette.text3 : palette.accent,
              ),
            ),
            IconButton(
              tooltip: '刷新',
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh_rounded, size: 19),
            ),
          ] else ...[
            IconButton(
              tooltip: _showLineNumbers ? '隐藏行号' : '显示行号',
              onPressed: content == null
                  ? null
                  : () => setState(() => _showLineNumbers = !_showLineNumbers),
              icon: Icon(
                Icons.format_list_numbered_rounded,
                size: 20,
                color: _showLineNumbers ? palette.accent : palette.text3,
              ),
            ),
            IconButton(
              tooltip: '编辑并保存',
              onPressed: content == null || content.truncated || !_canEdit
                  ? null
                  : _openEditor,
              icon: Icon(
                Icons.edit_outlined,
                size: 19,
                color: content != null && !content.truncated && _canEdit
                    ? palette.accent
                    : palette.text3,
              ),
            ),
            IconButton(
              tooltip: '复制全部',
              onPressed: content == null ? null : _copyAll,
              icon: const Icon(Icons.copy_rounded, size: 19),
            ),
          ],
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
        icon: Icons.description_outlined,
        title: '无法预览这个文件',
        description: _error!,
        actionLabel: '重试',
        onAction: _load,
      );
    }
    final bytes = _bytes;
    if (_needsBytes || _binary) {
      if (bytes == null) {
        return EmptyState(
          icon: Icons.description_outlined,
          title: '没有内容',
          description: '文件下载结果为空，请重试',
          actionLabel: '重试',
          onAction: _load,
        );
      }
      return _buildBinaryBody(palette, bytes);
    }
    final content = _content;
    if (content == null) {
      return EmptyState(
        icon: Icons.description_outlined,
        title: '没有内容',
        description: '文件读取结果为空，请重试',
        actionLabel: '重试',
        onAction: _load,
      );
    }
    return Column(
      children: [
        _FileMetaBar(content: content, editable: _canEdit),
        if (content.truncated)
          Container(
            width: double.infinity,
            color: palette.warnSoft,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 7),
            child: Text(
              '文件较大，已截断，仅显示前 ${formatFileSize(content.content.length)}',
              style: TextStyle(color: palette.warn, fontSize: 11.5),
            ),
          ),
        Expanded(
          child: Container(
            color: palette.codeBg,
            child: Scrollbar(
              child: SingleChildScrollView(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 20, 24),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (_showLineNumbers)
                          _LineNumbers(text: content.content, palette: palette),
                        SelectableText(
                          content.content,
                          style: kMono.copyWith(
                            color: palette.codeText,
                            fontSize: 12,
                            height: 1.6,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// M4.9：图片在 App 内放大看；PDF / Office / 其它二进制交给系统应用。
  Widget _buildBinaryBody(AppPalette palette, Uint8List bytes) {
    if (_kind == FilePreviewKind.image) {
      return Column(
        children: [
          _BinaryMetaBar(text: '${formatFileSize(bytes.length)} · 双指可放大'),
          Expanded(
            child: Container(
              color: palette.codeBg,
              child: InteractiveViewer(
                minScale: 0.8,
                maxScale: 6,
                child: Center(
                  child: Image.memory(
                    bytes,
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stack) => _BinaryFallback(
                      palette: palette,
                      message: '这张图片没法在 App 里显示（格式可能不支持），试试用其他应用打开。',
                      onOpen: _openWithSystem,
                      onShare: _share,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }
    final docxText = _officePreview;
    if (docxText != null) {
      return Column(
        children: [
          _BinaryMetaBar(
            text: '${formatFileSize(bytes.length)} · 按文字预览（排版和图片不显示）',
          ),
          Expanded(
            child: Container(
              color: palette.bg,
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                child: SelectableText(
                  docxText,
                  style: TextStyle(
                    color: palette.text,
                    fontSize: 14,
                    height: 1.7,
                  ),
                ),
              ),
            ),
          ),
          _OfficePreviewFooter(
            palette: palette,
            onOpen: _openWithSystem,
            onShare: _share,
            opening: _opening,
            showOpen: _canOpenExternal,
          ),
        ],
      );
    }
    final isDocument = _kind != FilePreviewKind.text;
    final pages = _officePages;
    if (pages.isNotEmpty) {
      return Column(
        children: [
          _BinaryMetaBar(
            text:
                '${formatFileSize(bytes.length)} · 图片预览（共 ${pages.length} 张，按原图显示）',
          ),
          Expanded(
            child: Container(
              color: palette.bg,
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
                itemCount: pages.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, index) => ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.memory(
                    pages[index],
                    fit: BoxFit.fitWidth,
                    errorBuilder: (_, __, ___) => _BinaryMetaBar(
                      text: '第 ${index + 1} 张图片没法显示（格式可能不支持）',
                    ),
                  ),
                ),
              ),
            ),
          ),
          _OfficePreviewFooter(
            palette: palette,
            onOpen: _openWithSystem,
            onShare: _share,
            opening: _opening,
            showOpen: _canOpenExternal,
            note: '这份文档没有可选文字（多半是扫描件），上面是文档里的图片',
          ),
        ],
      );
    }
    final docxFailed = isDocument && isDocxFileName(_title);
    return Column(
      children: [
        _BinaryMetaBar(
          text: '${formatFileSize(bytes.length)} · 已下载到手机',
        ),
        Expanded(
          child: _BinaryFallback(
            palette: palette,
            title: isDocument
                ? (_canOpenExternal ? '用其他应用打开' : '这个文件只能在电脑上看')
                : '这个文件不是文本',
            message: isDocument
                ? (!_canOpenExternal
                    ? '这台手机没有能打开这种文件的应用，可以点「分享文件」发到电脑或别的设备上看。'
                    : (docxFailed
                          ? '这份 .docx 里没读出文字（可能加密或不是标准格式），交给手机上的 WPS 打开试试。'
                          : 'PDF / Office 文档不让 App 里直接看，交给手机上的 WPS 或系统阅读器打开最清楚。'))
                : 'App 里没有现成的预览器，可以交给系统里能处理它的应用。',
            onOpen: _openWithSystem,
            onShare: _share,
            opening: _opening,
            showOpen: _canOpenExternal,
          ),
        ),
      ],
    );
  }

  static String _lastSegment(String path) {
    final normalized = path.replaceAll('\\', '/');
    final segments =
        normalized.split('/').where((segment) => segment.isNotEmpty).toList();
    return segments.isEmpty ? path : segments.last;
  }
}

class _FileMetaBar extends StatelessWidget {
  const _FileMetaBar({required this.content, this.editable = false});

  final WorkspaceFileContent content;
  final bool editable;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final parts = <String>[
      formatFileSize(content.size),
      if (content.modifiedAt != null) relativeTime(content.modifiedAt!),
      'sha256 ${content.sha256Short.isEmpty ? '—' : content.sha256Short}',
    ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      decoration: BoxDecoration(
        color: palette.bg,
        border: Border(bottom: BorderSide(color: palette.line)),
      ),
      child: Row(
        children: [
          Icon(
            editable ? Icons.edit_outlined : Icons.lock_outline_rounded,
            size: 12,
            color: editable ? palette.accent : palette.text3,
          ),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              parts.join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: palette.text3,
                fontSize: 10.5,
                fontFamily: 'monospace',
              ),
            ),
          ),
          Text(
            editable ? '可编辑' : '只读',
            style: TextStyle(
              color: editable ? palette.accent : palette.text3,
              fontSize: 10.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _BinaryMetaBar extends StatelessWidget {
  const _BinaryMetaBar({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      decoration: BoxDecoration(
        color: palette.bg,
        border: Border(bottom: BorderSide(color: palette.line)),
      ),
      child: Row(
        children: [
          Icon(Icons.download_done_rounded, size: 12, color: palette.text3),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: palette.text3,
                fontSize: 10.5,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// M4.52：.docx 文字预览的底栏——排版不走，但随时能交给手机上的应用。
class _OfficePreviewFooter extends StatelessWidget {
  const _OfficePreviewFooter({
    required this.palette,
    required this.onOpen,
    this.onShare,
    this.opening = false,
    this.showOpen = true,
    this.note = '文字是从文档里抽出来的，排版、图片和表格线不显示',
  });

  final AppPalette palette;
  final VoidCallback onOpen;
  final VoidCallback? onShare;
  final bool opening;
  final bool showOpen;
  final String note;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: palette.bg,
        border: Border(top: BorderSide(color: palette.line)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              showOpen ? note : '$note。这台手机没有能打开它的应用，可以分享出去看',
              maxLines: 3,
              style: TextStyle(
                color: palette.text3,
                fontSize: 10.5,
                height: 1.4,
              ),
            ),
          ),
          if (onShare != null)
            TextButton.icon(
              onPressed: opening ? null : onShare,
              icon: const Icon(Icons.ios_share_rounded, size: 15),
              label: const Text('分享'),
            ),
          if (showOpen)
            TextButton.icon(
              onPressed: opening ? null : onOpen,
              icon: opening
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.open_in_new_rounded, size: 15),
              label: const Text('用其他应用打开'),
            ),
        ],
      ),
    );
  }
}

/// 图片显示失败 / 二进制文件时的兜底面板（带「用其他应用打开」）。
class _BinaryFallback extends StatelessWidget {
  const _BinaryFallback({
    required this.palette,
    required this.message,
    this.title,
    this.onOpen,
    this.onShare,
    this.opening = false,
    this.showOpen = true,
  });

  final AppPalette palette;
  final String message;
  final String? title;
  final Future<void> Function()? onOpen;
  final Future<void> Function()? onShare;
  final bool opening;
  final bool showOpen;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.insert_drive_file_outlined, size: 42, color: palette.text3),
            const SizedBox(height: 14),
            if (title != null) ...[
              Text(
                title!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: palette.text,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
            ],
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: palette.text3, fontSize: 12.5, height: 1.6),
            ),
            if (onOpen != null && showOpen) ...[
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: opening ? null : () => onOpen!(),
                icon: opening
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.open_in_new_rounded, size: 17),
                label: const Text('用其他应用打开'),
              ),
            ],
            if (onShare != null) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: opening ? null : () => onShare!(),
                icon: const Icon(Icons.ios_share_rounded, size: 17),
                label: const Text('分享文件'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _LineNumbers extends StatelessWidget {
  const _LineNumbers({required this.text, required this.palette});

  final String text;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    final count = text.isEmpty ? 1 : '\n'.allMatches(text).length + 1;
    final buffer = StringBuffer();
    for (var i = 1; i <= count; i++) {
      buffer.write(i);
      if (i != count) buffer.write('\n');
    }
    return Padding(
      padding: const EdgeInsets.only(right: 14),
      child: Text(
        buffer.toString(),
        textAlign: TextAlign.right,
        style: kMono.copyWith(
          color: palette.text3,
          fontSize: 12,
          height: 1.6,
        ),
      ),
    );
  }
}
