import 'dart:convert';

import 'package:deepseek_remote_app/data/live_store.dart';
import 'package:deepseek_remote_app/screens/file_viewer_screen.dart';
import 'package:deepseek_remote_app/services/file_opener.dart';
import 'package:deepseek_remote_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// M4.64：手机上没装能「打开」某类文件的应用时，至少还能分享出去。
class _FakeStore extends LiveStore {
  _FakeStore({this.bytes = const <int>[]});

  final List<int> bytes;

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

Future<void> _pump(WidgetTester tester, Widget child) async {  tester.view.physicalSize = const Size(420, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: buildAppTheme(Brightness.light), home: child));
  await tester.pumpAndSettle();
}

List<int> _u16(int value) => <int>[value & 0xff, (value >> 8) & 0xff];

List<int> _u32(int value) => <int>[
      value & 0xff,
      (value >> 8) & 0xff,
      (value >> 16) & 0xff,
      (value >> 24) & 0xff,
    ];

/// 造一个最小可读的 .docx（单条 stored `word/document.xml`）。
List<int> _docx(String text) {
  final name = utf8.encode('word/document.xml');
  final data = utf8.encode(
    '<w:document><w:body><w:p><w:r><w:t>$text</w:t></w:r></w:p></w:body></w:document>',
  );
  final local = <int>[
    ..._u32(0x04034b50),
    ..._u16(20),
    ..._u16(0),
    ..._u16(0),
    ..._u16(0),
    ..._u16(0),
    ..._u32(0),
    ..._u32(data.length),
    ..._u32(data.length),
    ..._u16(name.length),
    ..._u16(0),
    ...name,
    ...data,
  ];
  final central = <int>[
    ..._u32(0x02014b50),
    ..._u16(20),
    ..._u16(20),
    ..._u16(0),
    ..._u16(0),
    ..._u16(0),
    ..._u16(0),
    ..._u32(0),
    ..._u32(data.length),
    ..._u32(data.length),
    ..._u16(name.length),
    ..._u16(0),
    ..._u16(0),
    ..._u16(0),
    ..._u16(0),
    ..._u32(0),
    ..._u32(0),
    ...name,
  ];
  return <int>[
    ...local,
    ...central,
    ..._u32(0x06054b50),
    ..._u16(0),
    ..._u16(0),
    ..._u16(1),
    ..._u16(1),
    ..._u32(central.length),
    ..._u32(local.length),
    ..._u16(0),
  ];
}

void main() {
  group('M4.64 文件分享', () {
    testWidgets('接收的文件可以交给系统分享面板', (tester) async {
      final opener = FakeFileOpener();
      final body = utf8.encode('# 实验报告\n\n正文两行。');
      await _pump(
        tester,
        FileViewerScreen(
          liveStore: _FakeStore(),
          fileName: '074_用户_实验2.md',
          fetchBytes: () async => body,
          fileOpener: opener,
        ),
      );

      expect(find.byTooltip('分享文件'), findsOneWidget);
      await tester.tap(find.byTooltip('分享文件'));
      await tester.pumpAndSettle();

      expect(opener.shareCalls, 1);
      expect(opener.lastShared?.fileName, '074_用户_实验2.md');
      expect(opener.lastShared?.bytes.length, body.length);
      expect(opener.openCalls, 0);
    });

    testWidgets('分享面板拉不起来时给出提示', (tester) async {
      final opener = FakeFileOpener(shareResult: false);
      await _pump(
        tester,
        FileViewerScreen(
          liveStore: _FakeStore(),
          fileName: 'data.bin',
          fetchBytes: () async => <int>[1, 2, 3],
          fileOpener: opener,
        ),
      );

      await tester.tap(find.byTooltip('分享文件'));
      await tester.pumpAndSettle();

      expect(opener.shareCalls, 1);
      expect(find.text('分享失败：没能拉起系统分享面板'), findsOneWidget);
    });

    testWidgets('M4.72 原生给了原因就照原样报出来', (tester) async {
      final opener = FakeFileOpener(shareResult: false)
        ..lastErrorValue = 'Failed to resolve canonical path';
      await _pump(
        tester,
        FileViewerScreen(
          liveStore: _FakeStore(),
          fileName: 'data.bin',
          fetchBytes: () async => <int>[1, 2, 3],
          fileOpener: opener,
        ),
      );

      await tester.tap(find.byTooltip('分享文件'));
      await tester.pumpAndSettle();

      expect(find.text('分享失败：Failed to resolve canonical path'), findsOneWidget);
    });

    testWidgets('docx 文字预览页也能分享', (tester) async {
      final opener = FakeFileOpener();
      final bytes = _docx('正文内容');
      await _pump(
        tester,
        FileViewerScreen(
          liveStore: _FakeStore(),
          fileName: '074_实验2.docx',
          fetchBytes: () async => bytes,
          fileOpener: opener,
        ),
      );

      expect(find.text('分享'), findsOneWidget);
      await tester.tap(find.text('分享'));
      await tester.pumpAndSettle();

      expect(opener.shareCalls, 1);
      expect(
        opener.lastShared?.mimeType,
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      );
    });
  });
}
