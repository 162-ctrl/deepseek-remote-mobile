import 'dart:convert';

import 'package:deepseek_remote_app/data/live_store.dart';
import 'package:deepseek_remote_app/screens/file_viewer_screen.dart';
import 'package:deepseek_remote_app/screens/received_files_screen.dart';
import 'package:deepseek_remote_app/services/history_api.dart' show ReceivedFile;
import 'package:deepseek_remote_app/services/pairing_api.dart';
import 'package:deepseek_remote_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// M4.57：「功能 → 接收文件」——电脑端放进插件 received 目录的文件，手机上能看。
class _FakeReceivedStore extends LiveStore {
  List<ReceivedFile> files = const <ReceivedFile>[];
  Object? failure;
  final List<String> downloads = <String>[];

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

  @override
  Future<List<ReceivedFile>> loadReceivedFiles() async {
    final error = failure;
    if (error != null) throw error;
    return files;
  }

  @override
  Future<List<int>> downloadReceivedFile(String name) async {
    downloads.add(name);
    return utf8.encode('# 报告\n正文第一行\n正文第二行\n');
  }
}

Widget _wrap(Widget child) => MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: child,
    );

Future<void> _pump(WidgetTester tester, LiveStore store) async {
  await tester.binding.setSurfaceSize(const Size(420, 900));
  await tester.pumpWidget(_wrap(ReceivedFilesScreen(liveStore: store)));
  await tester.pumpAndSettle();
}

Future<void> _teardown(WidgetTester tester, LiveStore store) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  store.dispose();
  await tester.binding.setSurfaceSize(null);
}

void main() {
  testWidgets('列出电脑发来的文件，点开后按文本预览', (tester) async {
    final store = _FakeReceivedStore()
      ..files = <ReceivedFile>[
        ReceivedFile(
          name: '示例文档.docx',
          size: 39527,
          updatedAt: DateTime.now().subtract(const Duration(minutes: 3)),
        ),
        ReceivedFile(
          name: 'M4_57_REPORT.md',
          size: 2048,
          updatedAt: DateTime.now(),
        ),
      ];
    await _pump(tester, store);

    expect(find.text('接收文件'), findsOneWidget);
    expect(find.text('示例文档.docx'), findsOneWidget);
    expect(find.text('M4_57_REPORT.md'), findsOneWidget);

    await tester.tap(find.text('M4_57_REPORT.md'));
    await tester.pumpAndSettle();

    expect(find.byType(FileViewerScreen), findsOneWidget);
    expect(store.downloads, <String>['M4_57_REPORT.md']);
    expect(find.textContaining('正文第一行'), findsOneWidget);
    expect(find.textContaining('正文第二行'), findsOneWidget);

    await _teardown(tester, store);
  });

  testWidgets('没有文件时给一句空态', (tester) async {
    final store = _FakeReceivedStore();
    await _pump(tester, store);

    expect(find.text('还没有收到文件'), findsOneWidget);
    expect(find.textContaining('做好的文件会放进这里'), findsOneWidget);

    await _teardown(tester, store);
  });

  testWidgets('读不到时显示原因，点重试会再拉一次', (tester) async {
    final store = _FakeReceivedStore()
      ..failure = const PairingApiException('还未连接电脑，无法读取接收文件');
    await _pump(tester, store);

    expect(find.text('读不到接收文件'), findsOneWidget);
    expect(find.text('还未连接电脑，无法读取接收文件'), findsOneWidget);

    store.failure = null;
    store.files = <ReceivedFile>[
      ReceivedFile(name: 'a.md', size: 12, updatedAt: DateTime.now()),
    ];
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(find.text('a.md'), findsOneWidget);

    await _teardown(tester, store);
  });
}
