import 'dart:convert';
import 'dart:io' show ZLibEncoder;
import 'dart:typed_data';

import 'package:deepseek_remote_app/data/live_store.dart';
import 'package:deepseek_remote_app/screens/file_viewer_screen.dart';
import 'package:deepseek_remote_app/services/file_opener.dart';
import 'package:deepseek_remote_app/services/office_text.dart';
import 'package:deepseek_remote_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeStore extends LiveStore {
  @override
  bool get isConnected => true;

  @override
  String get deviceName => 'DeepSeek Harness';

  @override
  bool get tasksLoading => false;

  @override
  bool get conversationsLoading => false;

  @override
  bool get canWriteWorkspaceFiles => false;
}

Future<void> _pump(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(420, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(theme: buildAppTheme(Brightness.light), home: child),
  );
  await tester.pumpAndSettle();
}

List<int> _u16(int value) => <int>[value & 0xff, (value >> 8) & 0xff];

List<int> _u32(int value) => <int>[
      value & 0xff,
      (value >> 8) & 0xff,
      (value >> 16) & 0xff,
      (value >> 24) & 0xff,
    ];

/// 造一个多条目 zip（条目内容按字节给，方便塞图片）。
Uint8List _zip(Map<String, Uint8List> entries, {bool compress = false}) {
  final local = <int>[];
  final central = <int>[];
  var offset = 0;
  entries.forEach((name, content) {
    final nameBytes = utf8.encode(name);
    final payload =
        compress ? ZLibEncoder(raw: true).convert(content) : content;
    final method = compress ? 8 : 0;
    final localStart = offset;
    local.addAll(<int>[
      ..._u32(0x04034b50),
      ..._u16(20),
      ..._u16(0),
      ..._u16(method),
      ..._u16(0),
      ..._u16(0),
      ..._u32(0),
      ..._u32(payload.length),
      ..._u32(content.length),
      ..._u16(nameBytes.length),
      ..._u16(0),
      ...nameBytes,
      ...payload,
    ]);
    offset = localStart + 30 + nameBytes.length + payload.length;
    central.addAll(<int>[
      ..._u32(0x02014b50),
      ..._u16(20),
      ..._u16(20),
      ..._u16(0),
      ..._u16(method),
      ..._u16(0),
      ..._u16(0),
      ..._u32(0),
      ..._u32(payload.length),
      ..._u32(content.length),
      ..._u16(nameBytes.length),
      ..._u16(0),
      ..._u16(0),
      ..._u16(0),
      ..._u16(0),
      ..._u32(0),
      ..._u32(localStart),
      ...nameBytes,
    ]);
  });
  return Uint8List.fromList(<int>[
    ...local,
    ...central,
    ..._u32(0x06054b50),
    ..._u16(0),
    ..._u16(0),
    ..._u16(entries.length),
    ..._u16(entries.length),
    ..._u32(central.length),
    ..._u32(offset),
    ..._u16(0),
  ]);
}

Uint8List _document(String text) => Uint8List.fromList(utf8.encode(
      '<w:document><w:body><w:p><w:r><w:t>$text</w:t></w:r></w:p></w:body></w:document>',
    ));

/// 1×1 的 PNG，够 `Image.memory` 解码。
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

void main() {
  group('M4.69 扫描件 docx 按页看图', () {
    test('有文字的 docx 不当成图片文档', () {
      final bytes = _zip(<String, Uint8List>{'word/document.xml': _document('正文')});
      expect(docxTextFromBytes(bytes), '正文');
      expect(docxImagePages(bytes), isEmpty);
    });

    test('没有文字的 docx 取出 word/media 里的图片', () {
      final bytes = _zip(<String, Uint8List>{
        'word/media/image2.png': _png,
        'word/media/image10.png': _png,
        'word/media/notes.txt': Uint8List.fromList(utf8.encode('不是图片')),
      });

      expect(docxTextFromBytes(bytes), isNull);
      final pages = docxImagePages(bytes);
      expect(pages.length, 2);
      expect(pages.first, _png);
    });

    test('图片顺序按数字排（image2 在 image10 前面）', () {
      final small = Uint8List.fromList(<int>[1, 2, 3]);
      final large = Uint8List.fromList(<int>[9, 9, 9]);
      final bytes = _zip(<String, Uint8List>{
        'word/media/image10.png': large,
        'word/media/image2.png': small,
      });

      final pages = docxImagePages(bytes);
      expect(pages, <Uint8List>[small, large]);
    });

    test('张数上限生效', () {
      final bytes = _zip(<String, Uint8List>{
        'word/media/image1.png': _png,
        'word/media/image2.png': _png,
        'word/media/image3.png': _png,
      });

      expect(docxImagePages(bytes, maxPages: 2).length, 2);
    });

    testWidgets('文件页把扫描件按图片显示出来', (tester) async {
      final bytes = _zip(<String, Uint8List>{
        'word/media/image1.png': _png,
        'word/media/image2.png': _png,
      });
      await _pump(
        tester,
        FileViewerScreen(
          liveStore: _FakeStore(),
          fileName: '示例作业.docx',
          fetchBytes: () async => bytes,
          fileOpener: FakeFileOpener(),
        ),
      );

      expect(
        find.textContaining('图片预览（共 2 张'),
        findsOneWidget,
      );
      expect(find.byType(Image), findsWidgets);
      expect(
        find.text('这份文档没有可选文字（多半是扫描件），上面是文档里的图片'),
        findsOneWidget,
      );
      expect(find.textContaining('没读出文字'), findsNothing);
    });
  });
}
