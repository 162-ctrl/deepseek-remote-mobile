import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseek_remote_app/data/live_store.dart';
import 'package:deepseek_remote_app/models.dart';
import 'package:deepseek_remote_app/screens/tasks_screen.dart';
import 'package:deepseek_remote_app/screens/workspace_screen.dart';
import 'package:deepseek_remote_app/services/history_api.dart';
import 'package:deepseek_remote_app/services/remote_chat_intent.dart';
import 'package:deepseek_remote_app/theme/app_theme.dart';

/// M4.11：电脑端会话列表变空时，「工作区」页仍然要把每个授权目录列出来，
/// 不能让用户以为项目全丢了；存档分组也不再只限「已完成」。
class _FakeWorkspaceStore extends LiveStore {
  _FakeWorkspaceStore({
    this.roots = const <String>[],
    this.hidden = const <ArchivedSession>[],
    List<TaskItem> tasks = const <TaskItem>[],
  }) {
    _items.addAll(tasks);
  }

  final List<String> roots;
  final List<ArchivedSession> hidden;
  final List<TaskItem> _items = <TaskItem>[];
  final List<String> openedConversations = <String>[];

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
      UnmodifiableListView<ArchivedSession>(hidden);

  @override
  Future<void> ensureLiveData({bool force = false}) async {}

  @override
  Future<void> loadTasks({int limit = 50, List<String>? statuses}) async {}

  @override
  Future<void> loadArchivedSessions() async {}

  @override
  void createConversation({String? workspacePath, String? title}) {
    openedConversations.add(workspacePath ?? '');
  }

  /// M4.50：新会话不再直接 create，而是把目录绑给下一场对话。
  final List<String?> pendingWorkspaceCalls = <String?>[];

  @override
  void setPendingWorkspace(String? path) {
    pendingWorkspaceCalls.add(path);
    super.setPendingWorkspace(path);
  }
}

ArchivedSession _archived({
  String id = 'session-499ef7ec',
  String title = '古典诗词鉴赏',
  String workspace = r'D:\work\poetry',
  int lastTime = 1763200000000,
}) {
  return ArchivedSession.fromJson(<String, dynamic>{
    'id': id,
    'title': title,
    'workspace': workspace,
    'source': 'disk',
    'createdAt': 1763100000000,
    'lastTime': lastTime,
    'messageCount': 42,
    'eventCount': 96,
  });
}

Widget _wrap(Widget child) => MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: child,
    );

void main() {
  group('任务页列出没有会话的工作区（M4.11）', () {
    testWidgets('电脑列表为空时，每个授权目录仍占一张卡', (tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 1200));
      final store = _FakeWorkspaceStore(
        roots: const <String>[
          r'<项目根>',
          r'D:\Projects\示例项目B',
        ],
      );
      await tester.pumpWidget(_wrap(TasksScreen(liveStore: store)));
      await tester.pump(const Duration(milliseconds: 200));

      // 之前这里只有一句「这个筛选下还没有任务」，用户会以为项目丢了。
      expect(find.text('这个筛选下还没有任务'), findsNothing);
      expect(find.text('deepseek手机端'), findsWidgets);
      expect(find.text('示例项目B'), findsWidgets);
      // M4.13：空目录改成「项目卡」，没有会话时标「空项目」。
      expect(find.text('空项目'), findsNWidgets(2));
      expect(
        find.textContaining('点进去可以在电脑的这个目录里新建会话'),
        findsNothing,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      store.dispose();
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('点空工作区的卡片进入工作区页，并能在该目录开新对话', (tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 1200));
      final store = _FakeWorkspaceStore(
        roots: const <String>[r'D:\Projects\示例项目B'],
      );
      var openedAssistant = 0;
      await tester.pumpWidget(
        _wrap(
          TasksScreen(
            liveStore: store,
            onOpenAssistant: () => openedAssistant += 1,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));

      await tester.tap(find.text('示例项目B').first);
      await tester.pumpAndSettle();
      expect(find.byType(WorkspaceScreen), findsOneWidget);

      // M4.50：工作区页的空态按钮改成「去对话框发第一条消息」——绑好目录、
      // 切回 AI 助手的远程对话框，不再发一个谁都不显示的空会话。
      await tester.tap(find.text('去对话框发第一条消息'));
      await tester.pumpAndSettle();
      expect(store.pendingWorkspaceCalls, contains(r'D:\Projects\示例项目B'));
      expect(RemoteChatIntent.instance.pending?.workspacePath, r'D:\Projects\示例项目B');
      expect(openedAssistant, 1);
      expect(find.byType(WorkspaceScreen), findsNothing);
      RemoteChatIntent.instance.take();

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      store.dispose();
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('有会话的工作区不会重复铺一张「暂无会话」卡', (tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 1200));
      final store = _FakeWorkspaceStore(
        roots: const <String>[r'D:\work\poetry'],
        tasks: <TaskItem>[
          TaskItem(
            id: 'session-499ef7ec',
            title: '静夜思分析',
            status: TaskStatus.completed,
            workspace: r'D:\work\poetry',
            updatedAt: DateTime(2026, 11, 15, 12),
          ),
        ],
      );
      await tester.pumpWidget(_wrap(TasksScreen(liveStore: store)));
      await tester.pump(const Duration(milliseconds: 200));

      // M4.51：项目卡默认折叠，先点开「poetry」。
      await tester.tap(find.text('poetry').last);
      await tester.pumpAndSettle();
      expect(find.text('静夜思分析'), findsOneWidget);
      expect(find.text('空项目'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      store.dispose();
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('只有存档的工作区也算「有内容」，不再铺空卡', (tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 1200));
      final store = _FakeWorkspaceStore(
        roots: const <String>[r'D:\work\poetry'],
        hidden: <ArchivedSession>[_archived()],
      );
      await tester.pumpWidget(_wrap(TasksScreen(liveStore: store)));
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('空项目'), findsNothing);
      // M4.51：项目卡默认折叠，先点开「poetry」。
      await tester.tap(find.text('poetry').last);
      await tester.pumpAndSettle();
      expect(find.text('古典诗词鉴赏'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      store.dispose();
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('筛「进行中」时不列空目录（那是会话状态筛选）', (tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 1200));
      final store = _FakeWorkspaceStore(
        roots: const <String>[r'D:\Projects\示例项目B'],
      );
      await tester.pumpWidget(_wrap(TasksScreen(liveStore: store)));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('空项目'), findsOneWidget);

      await tester.tap(find.textContaining('进行中'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('空项目'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      store.dispose();
      await tester.binding.setSurfaceSize(null);
    });
  });

  group('存档分组不再只限「已完成」（M4.11）', () {
    testWidgets('筛「运行中」时，电脑上已消失的存档仍然列出来', (tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 1200));
      final store = _FakeWorkspaceStore(
        hidden: <ArchivedSession>[_archived()],
      );
      await tester.pumpWidget(_wrap(TasksScreen(liveStore: store)));
      await tester.pump(const Duration(milliseconds: 200));

      await tester.tap(find.textContaining('进行中'));
      await tester.pump(const Duration(milliseconds: 300));

      // 会话已经不在电脑列表里了：标「进行中」是一句假话，所以之前把整组挡掉了；
      // 但用户真正想找的恰恰是这些「看不到了」的会话，所以现在照样列出来
      // （M4.13 起挂在所属项目卡里，不再是单独的存档组；M4.51 起项目卡默认折叠）。
      await tester.tap(find.text('poetry').last);
      await tester.pumpAndSettle();
      expect(find.text('古典诗词鉴赏'), findsWidgets);
      expect(find.text('已存档'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      store.dispose();
      await tester.binding.setSurfaceSize(null);
    });
  });
}
