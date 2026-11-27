/// M4.52：手机上没有 WPS 时，.docx 也能在 App 里当文字读。
///
/// 只做一件事：解开 zip 取 `word/document.xml`、去掉标签，得到正文。
/// 排版、图片、表格线不会显示；读不出文字就返回 null，由文件页退回
/// 「用其他应用打开」，不假装成功。
///
/// 不引入新依赖：zip 容器自己按规范解析（只认 stored / deflate 两种，
/// zip64 直接放弃），压缩流用 `dart:io` 的 [ZLibDecoder] 解。
library;

import 'dart:convert';
import 'dart:io' show ZLibDecoder;
import 'dart:typed_data';

const int _endOfCentralDirectorySignature = 0x06054b50;
const int _centralDirectorySignature = 0x02014b50;
const int _localFileHeaderSignature = 0x04034b50;
const int _storeMethod = 0;
const int _deflateMethod = 8;

/// 这个文件名看起来是不是 .docx。
bool isDocxFileName(String fileName) {
  final lower = fileName.toLowerCase();
  return lower.endsWith('.docx') && !lower.endsWith('.docm');
}

/// 从 zip 里取出一个条目，取不到（没有、格式不认识、解压失败）都返回 null。
Uint8List? readZipEntry(Uint8List archive, String entryName) {
  final entries = _listEntries(archive);
  if (entries == null) return null;
  for (final entry in entries) {
    if (entry.name != entryName) continue;
    return _readLocalEntry(
      archive,
      ByteData.sublistView(archive),
      entry.localOffset,
      entry.method,
      entry.compressedSize,
    );
  }
  return null;
}

/// M4.69：整份列一遍中央目录，供「没有文字但有图片」的扫描件取页。
List<_ZipEntry>? _listEntries(Uint8List archive) {
  if (archive.length < 22) return null;
  final view = ByteData.sublistView(archive);
  final endOfCentralDirectory = _findEndOfCentralDirectory(view);
  if (endOfCentralDirectory < 0) return null;

  final total = view.getUint16(endOfCentralDirectory + 10, Endian.little);
  var cursor = view.getUint32(endOfCentralDirectory + 16, Endian.little);
  if (total == 0xFFFF || cursor == 0xFFFFFFFF) {
    return null; // zip64：这种量级的文件用不上，直接放弃
  }

  final entries = <_ZipEntry>[];
  for (var i = 0; i < total; i++) {
    if (cursor + 46 > archive.length) return null;
    if (view.getUint32(cursor, Endian.little) != _centralDirectorySignature) {
      return null;
    }
    final method = view.getUint16(cursor + 10, Endian.little);
    final compressedSize = view.getUint32(cursor + 20, Endian.little);
    final nameLength = view.getUint16(cursor + 28, Endian.little);
    final extraLength = view.getUint16(cursor + 30, Endian.little);
    final commentLength = view.getUint16(cursor + 32, Endian.little);
    final localOffset = view.getUint32(cursor + 42, Endian.little);
    final nameStart = cursor + 46;
    final nameEnd = nameStart + nameLength;
    if (nameEnd > archive.length) return null;
    entries.add(
      _ZipEntry(
        name: utf8.decode(archive.sublist(nameStart, nameEnd),
            allowMalformed: true),
        method: method,
        compressedSize: compressedSize,
        localOffset: localOffset,
      ),
    );
    cursor = nameEnd + extraLength + commentLength;
  }
  return entries;
}

class _ZipEntry {
  const _ZipEntry({
    required this.name,
    required this.method,
    required this.compressedSize,
    required this.localOffset,
  });

  final String name;
  final int method;
  final int compressedSize;
  final int localOffset;
}

/// 从 .docx 的字节里取出正文；不是合法 docx 或者抽不出字就返回 null。
String? docxTextFromBytes(Uint8List bytes, {int maxChars = 200000}) {
  try {
    final xml = readZipEntry(bytes, 'word/document.xml');
    if (xml == null) return null;
    final text = docxXmlToText(utf8.decode(xml, allowMalformed: true));
    if (text.isEmpty) return null;
    if (text.length <= maxChars) return text;
    return '${text.substring(0, maxChars)}\n\n…（后面还有内容，先显示到这里）';
  } catch (_) {
    return null;
  }
}

/// M4.69：抽不出文字的 .docx 多半是扫描件——把 `word/media/` 里的图片按页取出来。
///
/// 只看图片扩展名，按文件名里的数字排（`image2` 排到 `image10` 前面），
/// 超出张数或总量的尾部直接丢掉，避免把整份扫描件塞进内存。
List<Uint8List> docxImagePages(
  Uint8List bytes, {
  int maxPages = 24,
  int maxBytes = 40 * 1024 * 1024,
}) {
  try {
    final entries = _listEntries(bytes);
    if (entries == null) return const <Uint8List>[];
    final view = ByteData.sublistView(bytes);
    final images = entries
        .where((entry) =>
            entry.name.startsWith('word/media/') &&
            _isImageName(entry.name) &&
            entry.compressedSize > 0)
        .toList()
      ..sort((a, b) => _numericCompare(a.name, b.name));

    final pages = <Uint8List>[];
    var total = 0;
    for (final entry in images) {
      if (pages.length >= maxPages) break;
      final data = _readLocalEntry(
        bytes,
        view,
        entry.localOffset,
        entry.method,
        entry.compressedSize,
      );
      if (data == null || data.isEmpty) continue;
      if (total + data.length > maxBytes) break;
      total += data.length;
      pages.add(data);
    }
    return pages;
  } catch (_) {
    return const <Uint8List>[];
  }
}

const Set<String> _imageExtensions = {
  '.png',
  '.jpg',
  '.jpeg',
  '.gif',
  '.webp',
  '.bmp',
};

bool _isImageName(String name) {
  final lower = name.toLowerCase();
  return _imageExtensions.any(lower.endsWith);
}

/// 让 `image2` 排在 `image10` 前面：先比去掉数字后的前缀，再比数字。
int _numericCompare(String a, String b) {
  final left = _splitTrailingNumber(a);
  final right = _splitTrailingNumber(b);
  final byPrefix = left.$1.compareTo(right.$1);
  if (byPrefix != 0) return byPrefix;
  return left.$2.compareTo(right.$2);
}

(String, int) _splitTrailingNumber(String name) {
  final dot = name.lastIndexOf('.');
  final base = dot > 0 ? name.substring(0, dot) : name;
  final match = RegExp(r'^(.*?)(\d+)$').firstMatch(base);
  if (match == null) return (base, 0);
  return (match.group(1) ?? '', int.tryParse(match.group(2) ?? '') ?? 0);
}

/// 把 `word/document.xml` 压成纯文字：段落换行、单元格制表、去掉所有标签。
String docxXmlToText(String xml) {
  var text = xml;
  text = text.replaceAll(RegExp(r'<w:tab[^>]*/>'), '\t');
  text = text.replaceAll(RegExp(r'<w:br[^>]*/>'), '\n');
  text = text.replaceAll(RegExp(r'<w:cr[^>]*/>'), '\n');
  text = text.replaceAll('</w:p>', '\n');
  text = text.replaceAll('</w:tr>', '\n');
  text = text.replaceAll('</w:tc>', '\t');
  text = text.replaceAll(RegExp(r'<[^>]*>'), '');
  text = _decodeXmlEntities(text);
  text = text.replaceAll('\r\n', '\n');
  text = text.replaceAll(RegExp(r'[ \t]+\n'), '\n');
  text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return text.trim();
}

int _findEndOfCentralDirectory(ByteData view) {
  final length = view.lengthInBytes;
  final earliest = length - 22 - 65535;
  final start = earliest < 0 ? 0 : earliest;
  for (var offset = length - 22; offset >= start; offset--) {
    if (view.getUint32(offset, Endian.little) ==
        _endOfCentralDirectorySignature) {
      return offset;
    }
  }
  return -1;
}

Uint8List? _readLocalEntry(
  Uint8List archive,
  ByteData view,
  int offset,
  int method,
  int compressedSize,
) {
  if (offset + 30 > archive.length) return null;
  if (view.getUint32(offset, Endian.little) != _localFileHeaderSignature) {
    return null;
  }
  final nameLength = view.getUint16(offset + 26, Endian.little);
  final extraLength = view.getUint16(offset + 28, Endian.little);
  final start = offset + 30 + nameLength + extraLength;
  final end = start + compressedSize;
  if (end > archive.length) return null;
  final raw = Uint8List.sublistView(archive, start, end);
  switch (method) {
    case _storeMethod:
      return Uint8List.fromList(raw);
    case _deflateMethod:
      return Uint8List.fromList(ZLibDecoder(raw: true).convert(raw));
    default:
      return null;
  }
}

String _decodeXmlEntities(String text) {
  var out = text;
  out = out.replaceAllMapped(
    RegExp(r'&#x([0-9a-fA-F]+);'),
    (match) => String.fromCharCode(int.parse(match.group(1)!, radix: 16)),
  );
  out = out.replaceAllMapped(
    RegExp(r'&#(\d+);'),
    (match) => String.fromCharCode(int.parse(match.group(1)!)),
  );
  out = out.replaceAll('&lt;', '<');
  out = out.replaceAll('&gt;', '>');
  out = out.replaceAll('&quot;', '"');
  out = out.replaceAll('&apos;', "'");
  out = out.replaceAll('&amp;', '&');
  return out;
}
