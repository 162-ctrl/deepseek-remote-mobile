/// M3.2：手机发出附件时，正文末尾会拼一段「附件（已保存到电脑）：- <路径>」给电脑上的模型看。
/// 这只是给模型看的元信息，手机上显示时应把这段收起来，只留用户真正打的字 + 文件名。
library;

const String kAttachmentMarker = '附件（已保存到电脑）：';

/// 只发附件、没打字时 App 自动补的占位话（不显示给用户）。
const String kAttachmentOnlyHint = '我发了一些附件，请看一下：';

class ParsedUserText {
  const ParsedUserText(this.body, this.attachments);

  /// 用户真正输入的文字；只发附件时为空。
  final String body;

  /// 附件在电脑上的绝对路径。
  final List<String> attachments;

  bool get hasAttachments => attachments.isNotEmpty;
}

/// 把「正文 + 附件清单」拆开；没有附件标记时原样返回。
ParsedUserText parseUserText(String raw) {
  final index = raw.indexOf(kAttachmentMarker);
  if (index < 0) {
    return ParsedUserText(raw.trim(), const <String>[]);
  }
  final body = raw.substring(0, index).trim();
  final attachments = raw
      .substring(index + kAttachmentMarker.length)
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.startsWith('- '))
      .map((line) => line.substring(2).trim())
      .where((path) => path.isNotEmpty)
      .toList(growable: false);
  // 只发附件时 App 会补一句占位话，显示时也收起来，只留文件 chips。
  final visibleBody = body == kAttachmentOnlyHint ? '' : body;
  return ParsedUserText(visibleBody, attachments);
}

/// 取路径里的文件名，用于手机上显示附件 chip。
String attachmentFileName(String path) {
  final normalized = path.replaceAll('\\', '/');
  final index = normalized.lastIndexOf('/');
  return index < 0 ? normalized : normalized.substring(index + 1);
}
