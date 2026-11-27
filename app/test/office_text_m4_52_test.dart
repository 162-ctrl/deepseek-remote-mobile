import 'dart:convert';
import 'dart:io' show ZLibEncoder;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseek_remote_app/data/live_store.dart';
import 'package:deepseek_remote_app/screens/file_viewer_screen.dart';
import 'package:deepseek_remote_app/services/file_opener.dart';
import 'package:deepseek_remote_app/services/office_text.dart';
import 'package:deepseek_remote_app/services/workspace_models.dart';
import 'package:deepseek_remote_app/theme/app_theme.dart';

/// M4.52：手机上没有 WPS 时，.docx 也能在 App 里按文字读。
void main() {
  const documentXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
      '<w:body>'
      '<w:p><w:r><w:t>第一段：答辩的自我介绍</w:t></w:r></w:p>'
      '<w:p><w:r><w:t>第二段：为什么选择这个题目</w:t></w:r></w:p>'
      '</w:body></w:document>';

  group('docx 抽文字', () {
    test('stored（不压缩）的 zip 能取出 document.xml', () {
      final bytes = _zip({'word/document.xml': documentXml});
      final text = docxTextFromBytes(bytes);
      expect(text, isNotNull);
      expect(text, contains('第一段：答辩的自我介绍'));
      expect(text, contains('第二段：为什么选择这个题目'));
      expect(text, contains('\n'));
    });

    test('deflate 压缩的 zip 也能解', () {
      final bytes = _zip({'word/document.xml': documentXml}, compress: true);
      final text = docxTextFromBytes(bytes);
      expect(text, contains('第一段：答辩的自我介绍'));
    });

    test('没有 document.xml 或不是 zip 时返回 null', () {
      expect(docxTextFromBytes(_zip({'word/styles.xml': '<x/>'})), isNull);
      expect(docxTextFromBytes(Uint8List.fromList(<int>[1, 2, 3, 4])), isNull);
      expect(readZipEntry(_zip({}), 'word/document.xml'), isNull);
    });

    test('标签去掉、制表与换行保留、实体还原', () {
      final text = docxXmlToText(
        '<w:p><w:r><w:t>a</w:t></w:r><w:r><w:tab/><w:t>b &amp; c</w:t></w:r></w:p>'
        '<w:p><w:r><w:t>d</w:t></w:r><w:r><w:br/><w:t>e</w:t></w:r></w:p>',
      );
      expect(text, 'a\tb & c\nd\ne');
    });

    test('超长正文截断并说明', () {
      final bytes = _zip({
        'word/document.xml': '<w:p><w:t>${'字' * 300}</w:t></w:p>',
      });
      final text = docxTextFromBytes(bytes, maxChars: 100)!;
      expect(text, contains('先显示到这里'));
      expect(text.length, lessThan(200));
    });

    test('isDocxFileName 只认 .docx', () {
      expect(isDocxFileName('示例文档.docx'), isTrue);
      expect(isDocxFileName(r'C:\x\A.DOCX'), isTrue);
      expect(isDocxFileName('a.doc'), isFalse);
      expect(isDocxFileName('归档.docx.zip'), isFalse);
      expect(isDocxFileName('笔记.docx.bak'), isFalse);
    });
  });

  group('文件页（M4.52）', () {
    testWidgets('.docx 在 App 内按文字显示，仍可交给系统应用', (tester) async {
      final bytes = _zip({'word/document.xml': documentXml});
      final store = _FakeStore(bytes: bytes);
      final opener = FakeFileOpener();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: FileViewerScreen(
            liveStore: store,
            workspacePath: r'D:\work',
            relativePath: '示例文档.docx',
            fileName: '示例文档.docx',
            fileOpener: opener,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(store.downloaded, 1);
      expect(find.textContaining('按文字预览'), findsOneWidget);
      expect(find.textContaining('第一段：答辩的自我介绍'), findsOneWidget);
      expect(find.text('用其他应用打开'), findsOneWidget);

      await tester.tap(find.text('用其他应用打开'));
      await tester.pumpAndSettle();
      expect(opener.openCalls, 1);
      expect(
        opener.last?.mimeType,
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      );
    });

    testWidgets('读不出文字的 .docx 说明原因，不用空白骗人', (tester) async {
      final store = _FakeStore(bytes: Uint8List.fromList(<int>[9, 9, 9]));
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: FileViewerScreen(
            liveStore: store,
            workspacePath: r'D:\work',
            relativePath: '加密.docx',
            fileName: '加密.docx',
            fileOpener: FakeFileOpener(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('没读出文字'), findsOneWidget);
      expect(find.text('用其他应用打开'), findsNWidgets(2));
    });
  });
}

class _FakeStore extends LiveStore {
  _FakeStore({required this.bytes});

  final Uint8List bytes;

  int downloaded = 0;

  @override
  bool get isConnected => true;

  @override
  bool get canWriteWorkspaceFiles => false;

  @override
  Future<List<int>> downloadWorkspaceFile({
    required String workspacePath,
    required String relativePath,
  }) async {
    downloaded += 1;
    return bytes;
  }

  @override
  Future<WorkspaceFileContent> readWorkspaceFile({
    required String workspacePath,
    required String relativePath,
    int? maxBytes,
  }) async {
    return WorkspaceFileContent(
      relativePath: relativePath,
      content: '',
      size: bytes.length,
      sha256: 'b' * 8,
      truncated: false,
      binary: true,
    );
  }
}

/// 造一个最小可读的 zip（只关心我们的解析器认不认得）。
Uint8List _zip(Map<String, String> entries, {bool compress = false}) {
  final local = BytesBuilder();
  final central = BytesBuilder();
  var offset = 0;
  entries.forEach((name, content) {
    final nameBytes = utf8.encode(name);
    final data = utf8.encode(content);
    final payload = compress ? ZLibEncoder(raw: true).convert(data) : data;
    final method = compress ? 8 : 0;
    final localStart = offset;

    _u32(local, 0x04034b50);
    _u16(local, 20);
    _u16(local, 0);
    _u16(local, method);
    _u16(local, 0);
    _u16(local, 0);
    _u32(local, 0);
    _u32(local, payload.length);
    _u32(local, data.length);
    _u16(local, nameBytes.length);
    _u16(local, 0);
    local.add(nameBytes);
    local.add(payload);
    offset = localStart + 30 + nameBytes.length + payload.length;

    _u32(central, 0x02014b50);
    _u16(central, 20);
    _u16(central, 20);
    _u16(central, 0);
    _u16(central, method);
    _u16(central, 0);
    _u16(central, 0);
    _u32(central, 0);
    _u32(central, payload.length);
    _u32(central, data.length);
    _u16(central, nameBytes.length);
    _u16(central, 0);
    _u16(central, 0);
    _u16(central, 0);
    _u16(central, 0);
    _u32(central, 0);
    _u32(central, localStart);
    central.add(nameBytes);
  });

  final centralBytes = central.takeBytes();
  final out = BytesBuilder();
  out.add(local.takeBytes());
  out.add(centralBytes);
  _u32(out, 0x06054b50);
  _u16(out, 0);
  _u16(out, 0);
  _u16(out, entries.length);
  _u16(out, entries.length);
  _u32(out, centralBytes.length);
  _u32(out, offset);
  _u16(out, 0);
  return out.takeBytes();
}

void _u16(BytesBuilder builder, int value) {
  builder.add(<int>[value & 0xff, (value >> 8) & 0xff]);
}

void _u32(BytesBuilder builder, int value) {
  builder.add(<int>[
    value & 0xff,
    (value >> 8) & 0xff,
    (value >> 16) & 0xff,
    (value >> 24) & 0xff,
  ]);
}
