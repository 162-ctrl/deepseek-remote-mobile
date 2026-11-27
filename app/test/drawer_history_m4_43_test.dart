// M4.43：抽屉与顶栏的「历史会话」不再是死链。
//
// 以前它读 `liveStore.conversations`，那是 M1.1 老后端的 `/api/v1/conversations`，
// 插件直连下这个路由根本不存在（必然 404），所以永远显示「还没有历史会话」。
// 现在数据源换成插件真实提供的桌面会话镜像 + 存档（recentDesktopSessions）。
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseek_remote_app/data/live_store.dart';
import 'package:deepseek_remote_app/models.dart';
import 'package:deepseek_remote_app/screens/desktop_session_screen.dart';
import 'package:deepseek_remote_app/screens/root_shell.dart';
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

/// 已连接、带两条桌面会话的 store（只覆写抽屉用到的读取面）。
class _ConnectedStore extends LiveStore {
  _ConnectedStore({List<TaskItem> tasks = const <TaskItem>[], List<ArchivedSession> archived = const <ArchivedSession>[]})
      : _tasks = tasks,
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
  UnmodifiableListView<TaskItem> get tasks => UnmodifiableListView<TaskItem>(_tasks);

  @override
  UnmodifiableListView<ArchivedSession> get archivedSessions =>
      UnmodifiableListView<ArchivedSession>(_archived);

  /// [LiveStore.recentDesktopSessions] 读的是内部的私有 `_tasks`，注不进去，
  /// 所以这里直接照同样的合并规则覆写（活会话 + 只在存档里的会话，按时间倒序）。
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
          title: session.title.trim().isEmpty ? '未命名会话' : session.title.trim(),
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

class _OfflineStore extends LiveStore {
  @override
  bool get isConnected => false;

  @override
  String get deviceName => 'DeepSeek Harness';

  @override
  bool get tasksLoading => false;

  @override
  String? get tasksError => null;

  @override
  List<String> get workspaceRoots => const <String>[];

  @override
  UnmodifiableListView<TaskItem> get tasks => UnmodifiableListView<TaskItem>(const <TaskItem>[]);

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

Future<void> _pumpShell(WidgetTester tester, LiveStore store) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: RootShell(liveStore: store),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openDrawer(WidgetTester tester) async {
  await tester.dragFrom(const Offset(2, 300), const Offset(320, 0));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('抽屉「远程电脑」列出桌面会话，不再写「还没有历史会话」', (tester) async {
    final base = DateTime(2026, 11, 22, 20, 0).millisecondsSinceEpoch;
    await _pumpShell(
      tester,
      _ConnectedStore(tasks: <TaskItem>[
        _task('s1', '把历史会话修好', base),
        _task('s2', '跑一遍插件测试', base - 60000),
      ]),
    );

    await _openDrawer(tester);

    // M4.48：分档胶囊也叫「远程电脑」，所以只认抽屉里的分组标题。
    expect(
      find.descendant(of: find.byType(Drawer), matching: find.text('远程电脑')),
      findsOneWidget,
    );
    expect(find.text('把历史会话修好'), findsOneWidget);
    expect(find.text('跑一遍插件测试'), findsOneWidget);
    expect(find.text('还没有历史会话'), findsNothing);
    expect(find.text('2'), findsOneWidget, reason: '角标要跟列表条数一致');
  });

  testWidgets('点抽屉里一条会话 → 打开那场直播', (tester) async {
    final base = DateTime(2026, 11, 22, 20, 0).millisecondsSinceEpoch;
    await _pumpShell(
      tester,
      _ConnectedStore(tasks: <TaskItem>[_task('s1', '把历史会话修好', base)]),
    );

    await _openDrawer(tester);
    await tester.tap(find.text('把历史会话修好'));
    await tester.pumpAndSettle();

    expect(find.byType(DesktopSessionScreen), findsOneWidget);
    // 直播页的标题就是会话标题
    expect(find.text('把历史会话修好'), findsWidgets);
  });

  testWidgets('只在存档里的会话也会列出，并标「已存档」', (tester) async {
    final base = DateTime(2026, 11, 22, 19, 0).millisecondsSinceEpoch;
    await _pumpShell(
      tester,
      _ConnectedStore(archived: <ArchivedSession>[
        ArchivedSession(id: 'a1', title: '上次那个重构', lastTime: base),
      ]),
    );

    await _openDrawer(tester);

    expect(find.text('上次那个重构'), findsOneWidget);
    expect(find.text('已存档'), findsOneWidget);
  });

  testWidgets('未连接 → 「连接电脑后显示远程会话」', (tester) async {
    await _pumpShell(tester, _OfflineStore());

    await _openDrawer(tester);

    expect(find.text('连接电脑后显示远程会话'), findsOneWidget);
  });
}
