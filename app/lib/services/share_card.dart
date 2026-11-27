import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models.dart';
import '../theme/app_theme.dart';
import 'share_gateway.dart';

/// 分享卡内容（M2.2 A4）。
///
/// 只包含「最近一轮」的对话正文与摘要：不含工具原始命令、路径、token。
@immutable
class ShareCardData {
  const ShareCardData({
    required this.deviceName,
    required this.time,
    this.conversationTitle,
    this.userMessage,
    this.assistantMessage,
    this.summary = '',
  });

  final String deviceName;
  final DateTime time;
  final String? conversationTitle;
  final String? userMessage;
  final String? assistantMessage;

  /// 完成摘要行（例如 `已完成 3 步 · 用时 8s`），没有则为空串。
  final String summary;

  bool get hasContent =>
      (userMessage != null && userMessage!.isNotEmpty) ||
      (assistantMessage != null && assistantMessage!.isNotEmpty);

  String get title =>
      (conversationTitle == null || conversationTitle!.trim().isEmpty)
          ? 'AI 会话'
          : conversationTitle!.trim();
}

/// 从聊天记录构造分享卡内容：取最近一条用户文本、其后最后一条助手文本，
/// 加上调用方传入的摘要行。
ShareCardData? buildShareCardData({
  required List<ChatItem> messages,
  required String deviceName,
  String? conversationTitle,
  String summary = '',
  DateTime? now,
}) {
  String? userText;
  int? userIndex;
  for (var i = messages.length - 1; i >= 0; i--) {
    final item = messages[i];
    if (item.role == ChatRole.user &&
        item.kind == ChatItemKind.text &&
        !item.queued &&
        item.text.trim().isNotEmpty) {
      userText = item.text.trim();
      userIndex = i;
      break;
    }
  }
  String? assistantText;
  for (var i = messages.length - 1; i >= 0; i--) {
    if (userIndex != null && i <= userIndex) break;
    final item = messages[i];
    if (item.role == ChatRole.assistant &&
        item.kind == ChatItemKind.text &&
        item.text.trim().isNotEmpty) {
      assistantText = item.text.trim();
      break;
    }
  }
  if (userText == null && assistantText == null) return null;
  return ShareCardData(
    deviceName: deviceName,
    time: now ?? DateTime.now(),
    conversationTitle: conversationTitle,
    userMessage: userText == null ? null : sanitizeShareText(userText),
    assistantMessage:
        assistantText == null ? null : sanitizeShareText(assistantText),
    summary: summary,
  );
}

/// 分享前脱敏：去掉 Windows/Unix 路径与长 token（保留正文可读性）。
String sanitizeShareText(String text) {
  var result = text;
  // Windows 路径（D:\work\xxx 或 D:/work/xxx）。
  result = result.replaceAll(
    RegExp(r'[A-Za-z]:[\\/][^\s，。；、,;）)\]】]*'),
    '[路径已隐藏]',
  );
  // Unix 绝对路径（/home/...、/Users/...）。
  result = result.replaceAll(
    RegExp(r'(?<![\w])/(?:home|Users|root|var|tmp|mnt|opt)/[^\s，。；、,;）)\]】]*'),
    '[路径已隐藏]',
  );
  // 长十六进制/Base64 形态的 token。
  result = result.replaceAll(RegExp(r'[A-Fa-f0-9]{32,}'), '[已隐藏]');
  result = result.replaceAll(RegExp(r'[A-Za-z0-9_\-]{48,}={0,2}'), '[已隐藏]');
  // http(s) 地址里的查询参数（避免泄露 token）。
  result = result.replaceAllMapped(
    RegExp(r'(https?://[^\s?]+)\?[^\s]+'),
    (match) => '${match.group(1)}?[已隐藏]',
  );
  return result;
}

/// 渲染分享卡 PNG（1080 宽竖版，M2.2 A4）。
///
/// 纯 Canvas 绘制，不依赖第三方库，也不要求卡片出现在 widget 树中。
Future<Uint8List> renderShareCardPng(
  ShareCardData data,
  AppPalette palette, {
  double width = 1080,
  double padding = 48,
}) async {
  final contentWidth = width - padding * 2;

  final headerLabel = _painter(
    'DeepSeek Remote',
    TextStyle(
      color: palette.primary,
      fontSize: 30,
      fontWeight: FontWeight.w700,
      letterSpacing: 1.2,
    ),
    maxWidth: contentWidth,
    maxLines: 1,
  );
  final titleLabel = _painter(
    data.title,
    TextStyle(
      color: palette.text,
      fontSize: 56,
      fontWeight: FontWeight.w800,
      height: 1.2,
    ),
    maxWidth: contentWidth,
    maxLines: 2,
  );
  final metaLabel = _painter(
    '${data.deviceName} · ${_formatDate(data.time)}',
    TextStyle(color: palette.textMuted, fontSize: 30, height: 1.4),
    maxWidth: contentWidth,
    maxLines: 2,
  );

  final userLabel = _painter(
    '我',
    TextStyle(
      color: palette.primary,
      fontSize: 30,
      fontWeight: FontWeight.w700,
    ),
    maxWidth: contentWidth,
    maxLines: 1,
  );
  final userBody = data.userMessage == null
      ? null
      : _painter(
          _clampText(data.userMessage!, 480),
          TextStyle(color: palette.text, fontSize: 38, height: 1.5),
          maxWidth: contentWidth,
        );
  final assistantLabel = _painter(
    'AI 助手',
    TextStyle(
      color: const Color(0xFF3DD68C),
      fontSize: 30,
      fontWeight: FontWeight.w700,
    ),
    maxWidth: contentWidth,
    maxLines: 1,
  );
  final assistantBody = data.assistantMessage == null
      ? null
      : _painter(
          _clampText(data.assistantMessage!, 900),
          TextStyle(color: palette.text, fontSize: 38, height: 1.5),
          maxWidth: contentWidth,
        );
  final summaryLabel = _painter(
    data.summary.isEmpty ? '本轮已完成' : data.summary,
    TextStyle(
      color: palette.primary,
      fontSize: 32,
      fontWeight: FontWeight.w600,
      height: 1.3,
    ),
    maxWidth: contentWidth - 72,
    maxLines: 1,
  );
  final footer = _painter(
    '来自 DeepSeek Remote 手机端 · 内容已脱敏',
    TextStyle(color: palette.textMuted, fontSize: 26, height: 1.4),
    maxWidth: contentWidth,
    maxLines: 1,
  );

  var height = padding;
  height += headerLabel.height + 18;
  height += titleLabel.height + 16;
  height += metaLabel.height + 44;
  height += 2; // 分隔线
  height += 44;
  if (userBody != null) {
    height += userLabel.height + 12;
    height += userBody.height + 40;
  }
  if (assistantBody != null) {
    height += assistantLabel.height + 12;
    height += assistantBody.height + 40;
  }
  if (data.summary.isNotEmpty) {
    height += summaryLabel.height + 32 + 28;
  }
  height += footer.height + padding;

  // 竖版卡片：内容再短也保证高度大于宽度（1080 宽 → 至少 1404 高）。
  final rawHeight = height.ceilToDouble();
  final imageHeight = rawHeight < width * 1.3 ? width * 1.3 : rawHeight;

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);

  // 背景卡片。
  final bgRect = Rect.fromLTWH(0, 0, width, imageHeight);
  canvas.drawRRect(
    RRect.fromRectAndRadius(bgRect, const Radius.circular(44)),
    Paint()..color = palette.bg,
  );
  // 顶部主色装饰条。
  canvas.drawRRect(
    RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, width, 12),
      const Radius.circular(6),
    ),
    Paint()..color = palette.primary,
  );
  // 标题区的柔和主色光晕。
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width, 260),
    Paint()
      ..shader = ui.Gradient.linear(
        Offset.zero,
        const Offset(0, 260),
        <Color>[
          palette.primary.withValues(alpha: 0.16),
          palette.primary.withValues(alpha: 0),
        ],
      ),
  );

  var y = padding;
  headerLabel.paint(canvas, Offset(padding, y));
  y += headerLabel.height + 18;
  titleLabel.paint(canvas, Offset(padding, y));
  y += titleLabel.height + 16;
  metaLabel.paint(canvas, Offset(padding, y));
  y += metaLabel.height + 44;

  final divider = Paint()
    ..color = palette.stroke
    ..strokeWidth = 2;
  canvas.drawLine(Offset(padding, y), Offset(width - padding, y), divider);
  y += 44;

  if (userBody != null) {
    userLabel.paint(canvas, Offset(padding, y));
    y += userLabel.height + 12;
    userBody.paint(canvas, Offset(padding, y));
    y += userBody.height + 40;
  }
  if (assistantBody != null) {
    assistantLabel.paint(canvas, Offset(padding, y));
    y += assistantLabel.height + 12;
    assistantBody.paint(canvas, Offset(padding, y));
    y += assistantBody.height + 40;
  }
  if (data.summary.isNotEmpty) {
    final pillRect = Rect.fromLTWH(
      padding,
      y,
      contentWidth,
      summaryLabel.height + 32,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(pillRect, const Radius.circular(20)),
      Paint()..color = palette.primarySoft,
    );
    // 左侧主色小圆点。
    canvas.drawCircle(
      Offset(padding + 28, y + (summaryLabel.height + 32) / 2),
      7,
      Paint()..color = palette.primary,
    );
    summaryLabel.paint(canvas, Offset(padding + 48, y + 16));
    y += pillRect.height + 28;
  }
  footer.paint(canvas, Offset(padding, y));

  final picture = recorder.endRecording();
  final image = await picture.toImage(width.toInt(), imageHeight.toInt());
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  if (byteData == null) {
    throw StateError('分享卡渲染失败：无法导出 PNG');
  }
  return byteData.buffer.asUint8List();
}

/// 便捷服务：渲染 + 交给系统分享（失败返回 false，不抛异常）。
class ShareCardService {
  ShareCardService({ShareGateway? gateway})
      : _gateway = gateway ?? MethodChannelShareGateway();

  final ShareGateway _gateway;

  Future<bool> share({
    required ShareCardData data,
    required AppPalette palette,
  }) async {
    if (!data.hasContent) return false;
    try {
      final bytes = await renderShareCardPng(data, palette);
      return await _gateway.shareImage(
        bytes,
        fileName: 'deepseek-remote-${data.time.millisecondsSinceEpoch}.png',
        chooserTitle: '分享对话',
      );
    } catch (_) {
      return false;
    }
  }

  Future<void> dispose() => _gateway.dispose();
}

// ---- 内部工具 ----

TextPainter _painter(
  String text,
  TextStyle style, {
  required double maxWidth,
  int? maxLines,
}) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    maxLines: maxLines,
    ellipsis: maxLines == null ? null : '…',
  )..layout(maxWidth: maxWidth);
  return painter;
}

String _clampText(String text, int maxChars) {
  final flat = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  if (flat.length <= maxChars) return flat;
  return '${flat.substring(0, maxChars)}…';
}

String _formatDate(DateTime time) {
  final local = time.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}
