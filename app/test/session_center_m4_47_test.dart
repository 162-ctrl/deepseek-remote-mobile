// M4.47：第二阶段第 ⑧ 条——统一「会话」中心。
//
// 以前会话散在三个地方：顶栏历史按钮（桌面会话弹层）、抽屉「手机对话」、
// 抽屉「历史会话」。现在只留一页 `SessionCenterScreen`：上半「远程电脑」、
// 下半「本机对话」，抽屉里只剩一段「会话」+ 一个「全部会话」入口。
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseek_remote_app/data/live_store.dart';
import 'package:deepseek_remote_app/models.dart';
import 'package:deepseek_remote_app/screens/desktop_session_screen.dart';
import 'package:deepseek_remote_app/screens/root_shell.dart';
import 'package:deepseek_remote_app/screens/session_center_screen.dart';
import 'package:deepseek_remote_app/services/cloud_conversations.dart';
import 'package:deepseek_remote_app/services/history_api.dart' show ArchivedSession;
import 'package:deepseek_remote_app/theme/app_theme.dart';

TaskItem _task(String id, String title, int lastTime) {
  return TaskItem(
    id: id,
    title: title,
    status: TaskStatus.running,
    workspace: r'<项目根>',
    updatedAt: DateTime.fromMillisecondsSinceEpoch(lastTime),
    lastTime: lastTime,
  );
}

CloudConversation _conversation(
  String id,
  String firstText,
  int count, {
  Duration ago = const Duration(minutes: 5),
}) {
  final now = DateTime.now().subtract(ago);
  return CloudConversation(
    id: id,
    createdAt: now,
    updatedAt: now,
    messages: <CloudChatRecord>[
      CloudChatRecord(role: 'user', text: firstText),
      for (var i = 1; i < count; i += 1)
        const CloudChatRecord(role: 'assistant', text: '回复'),
    ],
  );
}

class _ConnectedStore extends LiveStore {
  _ConnectedStore({
    List<TaskItem> tasks = const <TaskItem>[],
    List<ArchivedSession> archived = const <ArchivedSession>[],
  })  : _tasks = tasks,
        _archived = archived;

  final List<TaskItem> _tasks;
  final List<ArchivedSession> _archived;
  int loadTasksCalls = 0;

  @override
  bool get isConnected => true;

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
      UnmodifiableListView<TaskItem>(_tasks);

  @override
  UnmodifiableListView<ArchivedSession> get archivedSessions =>
      UnmodifiableListView<ArchivedSession>(_archived);

  @override
  List<RecentDesktopSession> get recentDesktopSessions {
    final rows = <RecentDesktopSession>[
      for (final task in _tasks)
        RecentDesktopSession(
          id: task.id,
          title: task.title.trim().isEmpty ? '未命名会话' : task.title.trim(),
          lastTime: task.lastTime ?? 0,
        ),
      for (final session in _archived)
        RecentDesktopSession(
          id: session.id,
          title:
              session.title.trim().isEmpty ? '未命名会话' : session.title.trim(),
          lastTime: session.lastTime,
          archived: true,
        ),
    ];
    rows.sort((left, right) => right.lastTime.compareTo(left.lastTime));
    return rows.length > 12 ? rows.sublist(0, 12) : rows;
  }

  @override
  Future<void> ensureLiveData({bool force = false}) async {}

  @override
  Future<void> loadTasks({int limit = 50, List<String>? statuses}) async {
    loadTasksCalls += 1;
  }

  @override
  Future<void> loadArchivedSessions() async {}
}

class _FakeConversationStore extends CloudConversationStore {
  _FakeConversationStore(this.items);

  final List<CloudConversation> items;
  int loads = 0;

  @override
  Future<List<CloudConversation>> load() async {
    loads += 1;
    return items;
  }

  @override
  Future<void> save(List<CloudConversation> conversations) async {}
}

void main() {
  testWidgets('会话中心同时列出「远程电脑」与「本机对话」', (tester) async {
    final store = _ConnectedStore(
      tasks: <TaskItem>[_task('s1', '把历史会话修好', 3000)],
      archived: <ArchivedSession>[
        ArchivedSession(id: 'a1', title: '上次那个重构', lastTime: 2000),
      ],
    );
    final conversations = _FakeConversationStore(<CloudConversation>[
      _conversation('c1', '明早提醒我交作业', 3),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: SessionCenterScreen(
          liveStore: store,
          conversations: conversations,
          onOpenLocal: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('会话'), findsOneWidget);
    expect(find.text('远程电脑'), findsOneWidget);
    expect(find.text('把历史会话修好'), findsOneWidget);
    expect(find.text('上次那个重构'), findsOneWidget);
    expect(find.text('已存档'), findsOneWidget);
    expect(find.text('本机对话'), findsOneWidget);
    expect(find.text('明早提醒我交作业'), findsOneWidget);
    expect(find.text('3 条消息 · 5 分钟前'), findsOneWidget);
  });

  testWidgets('点远程会话 → 打开那场直播', (tester) async {
    final store = _ConnectedStore(
      tasks: <TaskItem>[_task('s1', '把历史会话修好', 3000)],
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: SessionCenterScreen(
          liveStore: store,
          conversations: _FakeConversationStore(const <CloudConversation>[]),
          onOpenLocal: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('把历史会话修好'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 320));

    expect(find.byType(DesktopSessionScreen), findsOneWidget);
  });

  testWidgets('点本机对话 → 关掉会话中心并把 id 交给调用方', (tester) async {
    final opened = <String>[];
    final conversations = _FakeConversationStore(<CloudConversation>[
      _conversation('c1', '明早提醒我交作业', 3),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => SessionCenterScreen(
                    liveStore: _ConnectedStore(),
                    conversations: conversations,
                    onOpenLocal: opened.add,
                  ),
                ),
              ),
              child: const Text('打开会话中心'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开会话中心'));
    await tester.pumpAndSettle();
    expect(find.text('会话'), findsOneWidget);
    expect(find.text('还没有本机对话；在 AI 助手页发一条就会存下来'), findsNothing);

    await tester.tap(find.text('明早提醒我交作业'));
    await tester.pumpAndSettle();

    expect(opened, <String>['c1']);
    // 中心页已经关掉，回到调用方。
    expect(find.text('打开会话中心'), findsOneWidget);
    expect(find.text('会话'), findsNothing);
  });

  testWidgets('抽屉里只剩一段「会话」，点「全部会话」进中心', (tester) async {
    final store = _ConnectedStore(
      tasks: <TaskItem>[_task('s1', '把历史会话修好', 3000)],
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: RootShell(
          liveStore: store,
          conversations: _FakeConversationStore(<CloudConversation>[
            _conversation('c1', '明早提醒我交作业', 3),
          ]),
        ),
      ),
    );
    await tester.pump();

    // 打开抽屉
    await tester.dragFrom(const Offset(2, 300), const Offset(320, 0));
    await tester.pumpAndSettle();

    expect(find.text('会话'), findsOneWidget);
    // 抽屉里的分组名；AI 助手页的分档胶囊也叫这两个名字，所以限定在抽屉里找。
    expect(
      find.descendant(of: find.byType(Drawer), matching: find.text('远程电脑')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: find.byType(Drawer), matching: find.text('本机对话')),
      findsOneWidget,
    );
    expect(find.text('全部会话'), findsOneWidget);

    await tester.tap(find.text('全部会话'));
    await tester.pumpAndSettle();

    expect(find.byType(SessionCenterScreen), findsOneWidget);
    expect(find.text('电脑上还没有会话；发第一条指令就会创建会话'), findsNothing);
    expect(find.text('明早提醒我交作业'), findsOneWidget);
  });
  testWidgets('两个来源都空时各给一句人话', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: SessionCenterScreen(
          liveStore: _ConnectedStore(),
          conversations: _FakeConversationStore(const <CloudConversation>[]),
          onOpenLocal: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('电脑上还没有会话；发第一条指令就会创建会话'), findsOneWidget);
    expect(find.text('还没有本机对话；在 AI 助手页发一条就会存下来'), findsOneWidget);
  });
}
