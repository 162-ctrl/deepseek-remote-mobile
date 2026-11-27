import 'dart:convert';
import 'dart:typed_data';

import 'package:deepseek_remote_app/data/live_store.dart';
import 'package:deepseek_remote_app/screens/file_viewer_screen.dart';
import 'package:deepseek_remote_app/services/file_opener.dart';
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

Uint8List _zip(Map<String, Uint8List> entries) {
  final local = <int>[];
  final central = <int>[];
  var offset = 0;
  entries.forEach((name, content) {
    final nameBytes = utf8.encode(name);
    final localStart = offset;
    local.addAll(<int>[
      ..._u32(0x04034b50),
      ..._u16(20),
      ..._u16(0),
      ..._u16(0),
      ..._u16(0),
      ..._u16(0),
      ..._u32(0),
      ..._u32(content.length),
      ..._u32(content.length),
      ..._u16(nameBytes.length),
      ..._u16(0),
      ...nameBytes,
      ...content,
    ]);
    offset = localStart + 30 + nameBytes.length + content.length;
    central.addAll(<int>[
      ..._u32(0x02014b50),
      ..._u16(20),
      ..._u16(20),
      ..._u16(0),
      ..._u16(0),
      ..._u16(0),
      ..._u16(0),
      ..._u32(0),
      ..._u32(content.length),
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

final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

void main() {
  group('M4.70 没有能打开的应用就别给按钮', () {
    testWidgets('扫码件图片预览：没有应用可开时藏掉「用其他应用打开」', (tester) async {
      final opener = FakeFileOpener(canOpen: false);
      final bytes = _zip(<String, Uint8List>{'word/media/image1.png': _png});

      await _pump(
        tester,
        FileViewerScreen(
          liveStore: _FakeStore(),
          fileName: '示例作业.docx',
          fetchBytes: () async => bytes,
          fileOpener: opener,
        ),
      );

      expect(opener.canOpenCalls, 1);
      expect(find.text('用其他应用打开'), findsNothing);
      expect(find.textContaining('这台手机没有能打开它的应用'), findsOneWidget);
      expect(find.text('分享'), findsOneWidget);
    });

    testWidgets('二进制兜底：没有应用可开时改成「只能在电脑上看」', (tester) async {
      final opener = FakeFileOpener(canOpen: false);

      await _pump(
        tester,
        FileViewerScreen(
          liveStore: _FakeStore(),
          fileName: '讲义.pdf',
          fetchBytes: () async => <int>[1, 2, 3],
          fileOpener: opener,
        ),
      );

      expect(find.text('用其他应用打开'), findsNothing);
      expect(find.text('这个文件只能在电脑上看'), findsOneWidget);
      expect(find.textContaining('可以点「分享文件」'), findsOneWidget);
      expect(find.text('分享文件'), findsOneWidget);
    });

    testWidgets('有应用可开时按钮照旧出现', (tester) async {
      final opener = FakeFileOpener(canOpen: true);

      await _pump(
        tester,
        FileViewerScreen(
          liveStore: _FakeStore(),
          fileName: '讲义.pdf',
          fetchBytes: () async => <int>[1, 2, 3],
          fileOpener: opener,
        ),
      );

      expect(find.text('用其他应用打开'), findsWidgets);
      await tester.tap(find.text('用其他应用打开').last);
      await tester.pumpAndSettle();
      expect(opener.openCalls, 1);
    });
  });
}
