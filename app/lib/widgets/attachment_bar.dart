import 'dart:io' show File;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart' as fp;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../theme/app_theme.dart';

/// M4.7：待发送的本地附件（电脑档要上传，手机档要直接塞进云端请求）。
///
/// 电脑档和手机档共用同一个模型，这样两边的附件条、缩略图、大小文案
/// 和"是不是图片"的判断只写一份。
class PendingAttachment {
  PendingAttachment({required this.name, required this.bytes});

  final String name;
  final List<int> bytes;

  int get size => bytes.length;

  String get lowerName => name.toLowerCase();

  /// 图片才走 `image_url`（base64）；其它一律按文本内联。
  bool get isImage => mediaType != null;

  /// 图片的 MIME；不是图片（或后缀不认识）时为 null。
  String? get mediaType {
    final lower = lowerName;
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.bmp')) return 'image/bmp';
    if (lower.endsWith('.heic') || lower.endsWith('.heif')) return 'image/heic';
    return null;
  }

  /// 能按 UTF-8 当文本发出去的扩展名（云端模型只吃文本和图片）。
  bool get isText {
    const textExtensions = {
      '.txt',
      '.md',
      '.markdown',
      '.json',
      '.csv',
      '.log',
      '.yaml',
      '.yml',
      '.xml',
      '.ini',
      '.dart',
      '.js',
      '.ts',
      '.py',
      '.java',
      '.kt',
      '.c',
      '.h',
      '.cpp',
      '.cs',
      '.go',
      '.rs',
      '.m',
      '.sh',
      '.ps1',
      '.bat',
      '.sql',
      '.html',
      '.css',
    };
    return textExtensions.contains(_extension(lowerName));
  }

  /// 取 `.xxx` 小写后缀（不引 path 包，自己拼）。
  static String _extension(String name) {
    final dot = name.lastIndexOf('.');
    return dot <= 0 ? '' : name.substring(dot);
  }

  String get sizeLabel {
    final value = size;
    if (value < 1024) return '$value B';
    if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(1)} KB';
    return '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// M4.7：拍照 / 相册 / 文件三条入口共用的选择逻辑。
///
/// 首页电脑档（上传到电脑）和手机档（直发云端模型）都调这里，
/// 这样"选完怎么解码、失败怎么提示"不会两边各写一套。
class AttachmentPicker {
  AttachmentPicker({ImagePicker? imageProvider, fp.FilePicker? filePicker})
      : _imageProvider = imageProvider,
        _filePicker = filePicker;

  final ImagePicker? _imageProvider;
  final fp.FilePicker? _filePicker;

  // M4.7：插件只在真正点「拍照 / 相册 / 文件」时才去取（纯 widget 测试里
  // 没有注册 file_picker 的平台实现，构造时就取会抛 LateInitializationError）。
  ImagePicker get _image => _imageProvider ?? ImagePicker();
  fp.FilePicker get _files => _filePicker ?? fp.FilePicker.platform;

  /// 相机拍一张（压到 2400px 以内，免得 20 MB 上限被原图撑爆）。
  Future<PendingAttachment?> pickCamera() async {
    final picked = await _image
        .pickImage(source: ImageSource.camera, maxWidth: 2400);
    if (picked == null) return null;
    final bytes = await File(picked.path).readAsBytes();
    return PendingAttachment(name: picked.name, bytes: bytes);
  }

  /// 相册多选。
  Future<List<PendingAttachment>> pickPhotos() async {
    final picked = await _image.pickMultiImage(maxWidth: 2400);
    final result = <PendingAttachment>[];
    for (final file in picked) {
      final bytes = await File(file.path).readAsBytes();
      result.add(PendingAttachment(name: file.name, bytes: bytes));
    }
    return result;
  }

  /// 任意文件多选。
  Future<List<PendingAttachment>> pickFiles() async {
    final picked = await _files.pickFiles(allowMultiple: true, withData: true);
    if (picked == null) return const [];
    final result = <PendingAttachment>[];
    for (final file in picked.files) {
      final bytes =
          file.bytes ?? (file.path == null ? null : await File(file.path!).readAsBytes());
      if (bytes == null) continue;
      result.add(PendingAttachment(name: file.name, bytes: bytes));
    }
    return result;
  }
}

/// M4.7：附件条——拍照 / 相册 / 文件三个胶囊 + 已选附件（图片带缩略图）。
class AttachmentBar extends StatelessWidget {
  const AttachmentBar({
    super.key,
    required this.attachments,
    this.uploading = false,
    this.onRemove,
    this.onPickCamera,
    this.onPickPhoto,
    this.onPickFile,
    this.hint,
  });

  final List<PendingAttachment> attachments;
  final bool uploading;
  final ValueChanged<int>? onRemove;
  final VoidCallback? onPickCamera;
  final VoidCallback? onPickPhoto;
  final VoidCallback? onPickFile;

  /// 附件会去哪儿（电脑档：存到某目录；手机档：直接发给模型）。
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 38,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                if (onPickCamera != null) ...[
                  _AttachAction(
                    icon: Icons.photo_camera_outlined,
                    label: '拍照',
                    onTap: uploading ? null : onPickCamera,
                  ),
                  const SizedBox(width: 8),
                ],
                if (onPickPhoto != null) ...[
                  _AttachAction(
                    icon: Icons.photo_library_outlined,
                    label: '相册',
                    onTap: uploading ? null : onPickPhoto,
                  ),
                  const SizedBox(width: 8),
                ],
                if (onPickFile != null) ...[
                  _AttachAction(
                    icon: Icons.attach_file_rounded,
                    label: '文件',
                    onTap: uploading ? null : onPickFile,
                  ),
                  const SizedBox(width: 8),
                ],
                for (var index = 0; index < attachments.length; index++) ...[
                  _PendingAttachmentChip(
                    attachment: attachments[index],
                    uploading: uploading,
                    onRemove:
                        onRemove == null ? null : () => onRemove!(index),
                  ),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
          if (uploading || (attachments.isNotEmpty && hint != null))
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 2),
              child: Row(
                children: [
                  if (uploading) ...[
                    SizedBox(
                      width: 11,
                      height: 11,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.6,
                        color: palette.accent,
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    child: Text(
                      uploading ? '正在读取…' : hint!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: palette.text3, fontSize: 10.5),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// M4.7：消息气泡里的附件缩略图（用户发出后回看是哪些图/文件）。
class AttachmentThumbnails extends StatelessWidget {
  const AttachmentThumbnails({
    super.key,
    required this.attachments,
    this.onLight = false,
    this.size = 64,
  });

  final List<PendingAttachment> attachments;

  /// 放在用户气泡（深色底）里时用浅色描边。
  final bool onLight;
  final double size;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    if (attachments.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final attachment in attachments)
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.pill / 2),
            child: SizedBox(
              width: size,
              height: size,
              child: attachment.mediaType != null
                  ? Image.memory(
                      Uint8List.fromList(attachment.bytes),
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      errorBuilder: (_, __, ___) => _fileTile(
                        palette,
                        Icons.image_outlined,
                        attachment.name,
                      ),
                    )
                  : _fileTile(
                      palette,
                      Icons.insert_drive_file_outlined,
                      attachment.name,
                    ),
            ),
          ),
      ],
    );
  }

  Widget _fileTile(AppPalette palette, IconData icon, String name) {
    return Container(
      padding: const EdgeInsets.all(4),
      color: onLight
          ? const Color(0x22FFFFFF)
          : palette.lineSoft,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 18, color: palette.text2),
          const SizedBox(height: 3),
          Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: palette.text3, fontSize: 8.5),
          ),
        ],
      ),
    );
  }
}

class _AttachAction extends StatelessWidget {
  const _AttachAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final enabled = onTap != null;
    return Material(
      color: palette.lineSoft,
      borderRadius: BorderRadius.circular(AppRadius.pill),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.pill),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Icon(
                icon,
                size: 16,
                color: enabled ? palette.accent : palette.text3,
              ),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  color: enabled ? palette.text : palette.text3,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PendingAttachmentChip extends StatelessWidget {
  const _PendingAttachmentChip({
    required this.attachment,
    required this.uploading,
    this.onRemove,
  });

  final PendingAttachment attachment;
  final bool uploading;
  final VoidCallback? onRemove;

  static IconData _iconFor(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.pdf')) return Icons.picture_as_pdf_outlined;
    if (lower.endsWith('.doc') || lower.endsWith('.docx')) {
      return Icons.description_outlined;
    }
    if (lower.endsWith('.xls') ||
        lower.endsWith('.xlsx') ||
        lower.endsWith('.csv')) {
      return Icons.table_chart_outlined;
    }
    if (lower.endsWith('.zip') ||
        lower.endsWith('.rar') ||
        lower.endsWith('.7z')) {
      return Icons.folder_zip_outlined;
    }
    if (lower.endsWith('.txt') || lower.endsWith('.md')) {
      return Icons.notes_outlined;
    }
    return Icons.insert_drive_file_outlined;
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Container(
      padding: const EdgeInsets.only(left: 4, right: 4),
      decoration: BoxDecoration(
        color: palette.lineSoft,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        children: [
          if (attachment.isImage)
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.pill),
              child: Image.memory(
                Uint8List.fromList(attachment.bytes),
                width: 28,
                height: 28,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, __, ___) => Icon(
                  Icons.image_outlined,
                  size: 15,
                  color: palette.text2,
                ),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Icon(
                _iconFor(attachment.name),
                size: 15,
                color: palette.text2,
              ),
            ),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 140),
            child: Text(
              attachment.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: palette.text, fontSize: 12),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            attachment.sizeLabel,
            style: TextStyle(color: palette.text3, fontSize: 10.5),
          ),
          InkWell(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            onTap: uploading ? null : onRemove,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(Icons.close_rounded, size: 14, color: palette.text3),
            ),
          ),
        ],
      ),
    );
  }
}
