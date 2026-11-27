import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseek_remote_app/data/live_store.dart';
import 'package:deepseek_remote_app/models.dart';
import 'package:deepseek_remote_app/screens/tasks_screen.dart';
import 'package:deepseek_remote_app/services/history_api.dart';
import 'package:deepseek_remote_app/theme/app_theme.dart';

/// M4.51：一个项目里二十几条会话全铺出来，既看不清有几个项目，也找不到正在跑的
/// 那条。所以「工作区」页的项目卡默认折叠，点项目头才摊开。
class _FakeFoldStore extends LiveStore {
  _FakeFoldStore({
    this.roots = const <String>[],
    List<TaskItem> tasks = const <TaskItem>[],
  }) {
    _items.addAll(tasks);
  }

  final List<String> roots;
  final List<TaskItem> _items = <TaskItem>[];

  @override
  bool get isConnected => true;

  @override
  String get deviceName => 'DeepSeek Harness';

  @override
  bool get tasksLoading => false;

  @override
  bool get conversationsLoading => false;

  @override
  String? get tasksError => null;

  @override
  bool get usesDesktopTaskMirror => true;

  @override
  bool get canListWorkspace => true;

  @override
  List<String> get workspaceRoots => roots;

  @override
  UnmodifiableListView<TaskItem> get tasks =>
      UnmodifiableListView<TaskItem>(_items);

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

TaskItem _task({
  required String id,
  required String title,
  required String workspace,
  TaskStatus status = TaskStatus.completed,
  DateTime? updatedAt,
}) {
  return TaskItem(
    id: id,
    title: title,
    status: status,
    workspace: workspace,
    updatedAt: updatedAt ?? DateTime(2026, 11, 15, 12),
  );
}

Widget _wrap(Widget child) => MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: child,
    );

void main() {
  group('M4.51 工作区项目卡默认折叠', () {
    testWidgets('会话默认收在项目卡里，只露项目名与摘要', (tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 1200));
      final store = _FakeFoldStore(
        roots: const <String>[r'D:\work\demo', r'D:\work\other'],
        tasks: <TaskItem>[
          _task(id: 'a', title: '会话 A', workspace: r'D:\work\demo'),
          _task(id: 'b', title: '会话 B', workspace: r'D:\work\demo'),
          _task(id: 'c', title: '会话 C', workspace: r'D:\work\other'),
        ],
      );
      await tester.pumpWidget(_wrap(TasksScreen(liveStore: store)));
      await tester.pump(const Duration(milliseconds: 200));

      // 三条会话一条都不露，但项目卡的摘要告诉用户里面有几条。
      expect(find.text('会话 A'), findsNothing);
      expect(find.text('会话 B'), findsNothing);
      expect(find.text('会话 C'), findsNothing);
      expect(find.textContaining('2 个会话'), findsOneWidget);
      expect(find.textContaining('1 个会话'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      store.dispose();
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('点项目头展开，再点收起；同页其他项目互不影响', (tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 1200));
      final store = _FakeFoldStore(
        roots: const <String>[r'D:\work\demo', r'D:\work\other'],
        tasks: <TaskItem>[
          _task(id: 'a', title: '会话 A', workspace: r'D:\work\demo'),
          _task(id: 'b', title: '会话 B', workspace: r'D:\work\demo'),
          _task(id: 'c', title: '会话 C', workspace: r'D:\work\other'),
        ],
      );
      await tester.pumpWidget(_wrap(TasksScreen(liveStore: store)));
      await tester.pump(const Duration(milliseconds: 200));

      // 胶囊里也有项目名，项目卡排在胶囊后面，所以取 last。
      await tester.tap(find.text('demo').last);
      await tester.pumpAndSettle();
      expect(find.text('会话 A'), findsOneWidget);
      expect(find.text('会话 B'), findsOneWidget);
      expect(find.text('会话 C'), findsNothing);

      // 另一个项目单独展开。
      await tester.tap(find.text('other').last);
      await tester.pumpAndSettle();
      expect(find.text('会话 C'), findsOneWidget);
      expect(find.text('会话 A'), findsOneWidget);

      // 收起 demo，不会连带收起 other。
      await tester.tap(find.text('demo').last);
      await tester.pumpAndSettle();
      expect(find.text('会话 A'), findsNothing);
      expect(find.text('会话 C'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      store.dispose();
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('空项目没有可展开的内容，不画展开箭头', (tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 1200));
      final store = _FakeFoldStore(
        roots: const <String>[r'D:\work\empty'],
      );
      await tester.pumpWidget(_wrap(TasksScreen(liveStore: store)));
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('空项目'), findsOneWidget);
      expect(find.byIcon(Icons.expand_more_rounded), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      store.dispose();
      await tester.binding.setSurfaceSize(null);
    });
  });
}
