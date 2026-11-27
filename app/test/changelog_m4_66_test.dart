// M4.66：功能页的「更新日志」。
//
// 两路取数：优先问电脑上的插件（`/api/v1/app/notes`），没连电脑时退回
// 随包的 `assets/update_notes.md`。测试盯住：连着时用插件那份、
// 没连时用打包那份并说明来源。
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseek_remote_app/data/live_store.dart';
import 'package:deepseek_remote_app/models.dart';
import 'package:deepseek_remote_app/screens/changelog_screen.dart';
import 'package:deepseek_remote_app/services/history_api.dart';
import 'package:deepseek_remote_app/theme/app_theme.dart';

class _ChangelogStore extends LiveStore {
  _ChangelogStore({this.notes = const <UpdateNote>[], this.connected = true});

  final List<UpdateNote> notes;
  final bool connected;

  @override
  bool get isConnected => connected;

  @override
  String get deviceName => 'DeepSeek Harness';

  @override
  bool get tasksLoading => false;

  @override
  bool get conversationsLoading => false;

  @override
  UnmodifiableListView<TaskItem> get tasks =>
      UnmodifiableListView<TaskItem>(const <TaskItem>[]);

  @override
  Future<List<UpdateNote>> loadUpdateNotes() async => notes;
}

Future<void> _pump(WidgetTester tester, LiveStore store) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: ChangelogScreen(liveStore: store),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('连着电脑时用插件那份日志', (tester) async {
    final store = _ChangelogStore(notes: const <UpdateNote>[
      UpdateNote(
        version: '0.4.61',
        title: '测试版',
        body: '这一版只改了一行。',
        date: '2026-11-28',
      ),
    ]);
    await _pump(tester, store);

    expect(find.text('0.4.61'), findsOneWidget);
    expect(find.text('测试版'), findsOneWidget);
    expect(find.text('这一版只改了一行。'), findsOneWidget);
    expect(find.textContaining('随 App 打包'), findsNothing);
  });

  testWidgets('没连电脑时退回随包日志，并说明来源', (tester) async {
    final store = _ChangelogStore(connected: false);
    await _pump(tester, store);

    expect(find.text('这是随 App 打包的版本，连上电脑后会同步最新一份。'), findsOneWidget);
    // 打包的那份至少有 0.4.59 之后的内容。
    expect(find.textContaining('0.4.'), findsWidgets);
  });
}
