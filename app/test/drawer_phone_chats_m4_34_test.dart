// M4.34：手机对话从「工作区」搬到抽屉。
//
// 用户的诉求：手机档（云端直连）的对话不该出现在工作区，而应出现在抽屉的
// 「历史会话」这一块里。这里验证两件事：抽屉里能列出来、点一条会发意图给
// AI 助手页（由 AssistantScreen 消费）。
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseek_remote_app/data/live_store.dart';
import 'package:deepseek_remote_app/models.dart';
import 'package:deepseek_remote_app/screens/root_shell.dart';
import 'package:deepseek_remote_app/services/cloud_chat_intent.dart';
import 'package:deepseek_remote_app/services/cloud_conversations.dart';
import 'package:deepseek_remote_app/services/history_api.dart' show ArchivedSession;
import 'package:deepseek_remote_app/theme/app_theme.dart';

class _OfflineStore extends LiveStore {
  @override
  bool get isConnected => false;

  @override
  String get deviceName => 'DeepSeek Harness';

  @override
  String get agentVersion => '0.1.0-m1';

  @override
  String get harnessVersion => '0.2.30';

  @override
  bool get tasksLoading => false;

  @override
  bool get conversationsLoading => false;

  @override
  String? get tasksError => null;

  @override
  bool get usesDesktopTaskMirror => false;

  @override
  List<String> get workspaceRoots => const <String>[];

  @override
  UnmodifiableListView<TaskItem> get tasks =>
      UnmodifiableListView<TaskItem>(const <TaskItem>[]);

  @override
  UnmodifiableListView<ArchivedSession> get archivedSessions =>
      UnmodifiableListView<ArchivedSession>(const <ArchivedSession>[]);

  @override
  Future<void> ensureLiveData({bool force = false}) async {}

  @override
  Future<void> loadTasks({int limit = 50, List<String>? statuses}) async {}

  @override
  Future<void> loadArchivedSessions() async {}
}

class _FakeConversationStore extends CloudConversationStore {
  _FakeConversationStore(this.items);

  final List<CloudConversation> items;

  @override
  Future<List<CloudConversation>> load() async => items;

  @override
  Future<void> save(List<CloudConversation> conversations) async {}
}

CloudConversation _conversation({
  required String id,
  required String firstUserText,
  int messages = 4,
}) {
  final base = DateTime(2026, 11, 18, 8, 0);
  return CloudConversation(
    id: id,
    createdAt: base,
    updatedAt: base,
    title: firstUserText,
    messages: <CloudChatRecord>[
      for (var i = 0; i < messages; i++)
        CloudChatRecord(
          role: i.isEven ? 'user' : 'assistant',
          text: i == 0 ? firstUserText : '第 ${i + 1} 句',
        ),
    ],
  );
}

Future<void> _pumpShell(WidgetTester tester, CloudConversationStore store) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: RootShell(liveStore: _OfflineStore(), conversations: store),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openDrawer(WidgetTester tester) async {
  await tester.dragFrom(const Offset(2, 300), const Offset(320, 0));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    // 上一条用例可能留下意图，先清空。
    CloudChatIntent.instance.take();
  });

  testWidgets('抽屉里列出手机对话，工作区不再出现「手机对话」', (tester) async {
    await _pumpShell(
      tester,
      _FakeConversationStore(<CloudConversation>[
        _conversation(id: 'c1', firstUserText: '静夜思讲一讲', messages: 4),
        _conversation(id: 'c2', firstUserText: '写个开场白', messages: 2),
      ]),
    );

    await _openDrawer(tester);

    expect(
      find.descendant(of: find.byType(Drawer), matching: find.text('本机对话')),
      findsOneWidget,
    );
    expect(find.text('静夜思讲一讲'), findsOneWidget);
    expect(find.textContaining('4 条消息'), findsOneWidget);
    expect(find.text('写个开场白'), findsOneWidget);

    // 切到工作区：手机对话不该再出现在那一页。
    await tester.tap(find.text('工作区').last);
    await tester.pumpAndSettle();
    expect(find.text('本机对话'), findsNothing);
    expect(find.text('静夜思讲一讲'), findsNothing);
  });

  testWidgets('点一条手机对话会切到 AI 助手并打开那一条', (tester) async {
    await _pumpShell(
      tester,
      _FakeConversationStore(<CloudConversation>[
        _conversation(id: 'c1', firstUserText: '静夜思讲一讲'),
      ]),
    );

    // 先停在「工作区」，这样切到助手页是可观察的。
    await _openDrawer(tester);
    await tester.tap(find.text('工作区').last);
    await tester.pumpAndSettle();
    expect(find.text('工作区'), findsWidgets);

    await _openDrawer(tester);
    await tester.tap(find.text('静夜思讲一讲'));
    await tester.pumpAndSettle();

    // 抽屉已关，且已离开工作区（助手页有「本机对话 / 远程电脑」分档）。
    expect(find.text('工作区'), findsNothing);
    expect(find.text('本机对话'), findsOneWidget);
  });

  testWidgets('没有手机对话时抽屉里不出现这一段', (tester) async {
    await _pumpShell(
      tester,
      _FakeConversationStore(const <CloudConversation>[]),
    );

    await _openDrawer(tester);

    expect(
      find.descendant(of: find.byType(Drawer), matching: find.text('本机对话')),
      findsNothing,
    );
    expect(find.text('连接电脑后显示远程会话'), findsOneWidget);
  });
}
