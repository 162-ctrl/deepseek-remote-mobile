import 'dart:collection';
import 'dart:convert';

import 'package:deepseek_remote_app/data/live_store.dart';
import 'package:deepseek_remote_app/models.dart';
import 'package:deepseek_remote_app/screens/tasks_screen.dart';
import 'package:deepseek_remote_app/screens/workspace_screen.dart';
import 'package:deepseek_remote_app/services/history_api.dart';
import 'package:deepseek_remote_app/services/pairing_api.dart';
import 'package:deepseek_remote_app/services/remote_chat_intent.dart';
import 'package:deepseek_remote_app/theme/app_theme.dart';
import 'package:deepseek_remote_app/widgets/common.dart' show TaskStatusBadge;
import 'package:deepseek_remote_app/widgets/workspace_create_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 记录 HistoryApi 收到的请求，便于断言方法 / 路径 / body。
class _Recorder {
  final List<String> methods = <String>[];
  final List<Uri> uris = <Uri>[];
  final List<Map<String, dynamic>?> bodies = <Map<String, dynamic>?>[];

  AuthorizedHttpSender handler(
    JsonHttpResponse Function(String method, Uri uri, Map<String, dynamic>? body)
        respond,
  ) {
    return (
      String method,
      Uri uri,
      Map<String, String> headers,
      Map<String, dynamic>? body,
    ) async {
      methods.add(method);
      uris.add(uri);
      bodies.add(body);
      return respond(method, uri, body);
    };
  }
}

/// 只覆写新建工作区接口的 LiveStore；不调真实 connect()（假时钟下会挂起）。
class _FakeWorkspaceStore extends LiveStore {
  _FakeWorkspaceStore({this.roots = const <String>[]});

  final List<String> roots;
  PairingApiException? error;
  final List<String> created = <String>[];

  /// M4.13：对话框会带 parentDir，这里记下来断言。
  final List<String?> parents = <String?>[];

  @override
  bool get isConnected => true;

  @override
  List<String> get workspaceRoots => List<String>.unmodifiable(roots);

  @override
  Future<DesktopWorkspaceCreated> createDesktopWorkspace(
    String name, {
    String? parentDir,
  }) async {
    created.add(name);
    parents.add(parentDir);
    final failure = error;
    if (failure != null) throw failure;
    return DesktopWorkspaceCreated(
      name: name,
      path: '${parentDir ?? 'D:\\work'}\\$name',
      parent: parentDir ?? '',
    );
  }
}

/// 只用来看工作区页列表的 LiveStore：任务固定、不轮询真实接口。
class _FakeTaskStore extends LiveStore {
  _FakeTaskStore(this._items, {this.roots = const <String>[]});

  final List<TaskItem> _items;
  final List<String> roots;

  @override
  bool get isConnected => true;

  @override
  bool get usesDesktopTaskMirror => true;

  @override
  List<String> get workspaceRoots => List<String>.unmodifiable(roots);

  @override
  UnmodifiableListView<TaskItem> get tasks => UnmodifiableListView<TaskItem>(_items);

  @override
  bool get tasksLoading => false;

  @override
  String? get tasksError => null;

  @override
  bool get canListWorkspace => true;

  @override
  Future<void> loadTasks({int limit = 50, List<String>? statuses}) async {}

  @override
  void createConversation({String? workspacePath, String? title}) {
    createdConversations.add(<String, String?>{
      'workspacePath': workspacePath,
      'title': title,
    });
  }

  @override
  void setPendingWorkspace(String? path) => pendingWorkspaceCalls.add(path);

  @override
  Future<DesktopPromptResult> sendDesktopPrompt(
    String sessionId,
    String text,
  ) async {
    sentPrompts.add('$sessionId::$text');
    return DesktopPromptResult(sessionId: sessionId);
  }

  final List<Map<String, String?>> createdConversations =
      <Map<String, String?>>[];
  final List<String?> pendingWorkspaceCalls = <String?>[];
  final List<String> sentPrompts = <String>[];
}

TaskItem _task({
  required String id,
  required String title,
  required String workspace,
  TaskStatus status = TaskStatus.completed,
  int lastTime = 0,
  int messageCount = 0,
}) {
  return TaskItem(
    id: id,
    title: title,
    status: status,
    workspace: workspace,
    updatedAt: DateTime.fromMillisecondsSinceEpoch(lastTime == 0 ? 1000 : lastTime),
    messageCount: messageCount,
    lastTime: lastTime == 0 ? null : lastTime,
  );
}

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: buildAppTheme(Brightness.light),
    home: child,
  );
}

void main() {
  const String base = 'https://relay.example.com';

  group('HistoryApi 新建工作区（M4.0 契约）', () {
    test('POST /api/v1/desktop/workspaces，body 带 name，解析 path/name', () async {
      final rec = _Recorder();
      final api = HistoryApi(
        sender: rec.handler(
          (method, uri, body) => JsonHttpResponse(
            200,
            jsonEncode(<String, dynamic>{
              'ok': true,
              'name': '新项目',
              'path': 'D:\\work\\新项目',
            }),
          ),
        ),
      );

      final created = await api.createDesktopWorkspace(
        base,
        token: 'tk',
        name: '  新项目  ',
      );

      expect(rec.methods, <String>['POST']);
      expect(rec.uris.single.path, '/api/v1/desktop/workspaces');
      expect(rec.bodies.single, <String, dynamic>{'name': '新项目'});
      expect(created.name, '新项目');
      expect(created.path, 'D:\\work\\新项目');
    });

    test('电脑端只回 path 时，名字取路径末段', () async {
      final api = HistoryApi(
        sender: (method, uri, headers, body) async => JsonHttpResponse(
          200,
          jsonEncode(<String, dynamic>{'ok': true, 'path': 'D:/work/demo'}),
        ),
      );
      final created = await api.createDesktopWorkspace(
        base,
        token: 'tk',
        name: 'demo',
      );
      expect(created.name, 'demo');
      expect(created.path, 'D:/work/demo');
    });

    test('空名字不发请求', () async {
      final rec = _Recorder();
      final api = HistoryApi(sender: rec.handler((_, __, ___) => _ok()));
      await expectLater(
        () => api.createDesktopWorkspace(base, token: 'tk', name: '   '),
        throwsA(
          isA<PairingApiException>().having(
            (e) => e.message,
            'message',
            contains('请先填写工作区名称'),
          ),
        ),
      );
      expect(rec.uris, isEmpty);
    });

    test('旧版电脑端 404 时给出可读前缀与状态码', () async {
      final api = HistoryApi(
        sender: (method, uri, headers, body) async => JsonHttpResponse(
          404,
          jsonEncode(<String, dynamic>{
            'error': <String, dynamic>{'code': 'NOT_FOUND', 'message': 'no route'},
          }),
        ),
      );
      await expectLater(
        () => api.createDesktopWorkspace(base, token: 'tk', name: 'demo'),
        throwsA(
          isA<PairingApiException>()
              .having((e) => e.statusCode, 'statusCode', 404)
              .having(
                (e) => e.message,
                'message',
                contains('新建工作区失败'),
              ),
        ),
      );
    });

    test('没有返回 path 时报错而不是静默成功', () async {
      final api = HistoryApi(
        sender: (method, uri, headers, body) async =>
            JsonHttpResponse(200, jsonEncode(<String, dynamic>{'ok': true})),
      );
      await expectLater(
        () => api.createDesktopWorkspace(base, token: 'tk', name: 'demo'),
        throwsA(
          isA<PairingApiException>().having(
            (e) => e.message,
            'message',
            contains('没有返回目录路径'),
          ),
        ),
      );
    });
  });

  group('previewWorkspaceFolderName', () {
    test('非法字符换成 - 并去掉首尾空白', () {
      expect(previewWorkspaceFolderName('  新 项目/2026  '), '新 项目-2026');
      expect(previewWorkspaceFolderName(r'a:b*c?d"e<f>g|h\i'), 'a-b-c-d-e-f-g-h-i');
      expect(previewWorkspaceFolderName(''), '');
    });
  });

  group('新建工作区对话框', () {
    testWidgets('成功创建后关闭并返回结果', (tester) async {
      final store = _FakeWorkspaceStore(roots: <String>[r'D:\work']);
      DesktopWorkspaceCreated? result;

      await tester.pumpWidget(
        _wrap(
          Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () async {
                    result = await showWorkspaceCreateDialog(
                      context,
                      liveStore: store,
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('新建项目'), findsOneWidget);
      // M4.15：不管电脑端授权了哪些根，项目一律指向固定项目根。
      expect(find.textContaining(kDefaultProjectParent), findsOneWidget);

      await tester.enterText(find.byType(TextField), '新项目');
      await tester.pump();
      expect(find.textContaining('将建在'), findsOneWidget);

      await tester.tap(find.text('创建'));
      await tester.pumpAndSettle();

      expect(store.created, <String>['新项目']);
      expect(store.parents, <String?>[kDefaultProjectParent]);
      expect(result?.path, '$kDefaultProjectParent\\新项目');
      expect(find.text('新建项目'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      store.dispose();
    });

    testWidgets('404 时提示升级电脑端插件，并留在对话框', (tester) async {
      final store = _FakeWorkspaceStore(roots: <String>[r'D:\work'])
        ..error = const PairingApiException('新建工作区失败：出错了', statusCode: 404);

      await tester.pumpWidget(
        _wrap(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () =>
                    showWorkspaceCreateDialog(context, liveStore: store),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'demo');
      await tester.pump();
      await tester.tap(find.text('创建'));
      await tester.pumpAndSettle();

      expect(find.textContaining('电脑端插件版本过低'), findsOneWidget);
      expect(find.text('新建项目'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      store.dispose();
    });

    testWidgets('名字为空时创建按钮不可点', (tester) async {
      final store = _FakeWorkspaceStore(roots: <String>[r'D:\work']);
      await tester.pumpWidget(
        _wrap(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () =>
                    showWorkspaceCreateDialog(context, liveStore: store),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final button = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(button.onPressed, isNull);

      await tester.enterText(find.byType(TextField), 'x');
      await tester.pump();
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      store.dispose();
    });
  });

  group('工作区页（M4.0）', () {
    testWidgets('会话按最后活动时间倒序，显示状态徽标与消息数', (tester) async {
      final store = _FakeTaskStore(<TaskItem>[
        _task(
          id: 'old',
          title: '旧会话',
          workspace: r'D:\work\demo',
          lastTime: 1000,
          messageCount: 3,
        ),
        _task(
          id: 'new',
          title: '最新任务',
          workspace: r'D:\work\demo',
          status: TaskStatus.waitingApproval,
          lastTime: 9000,
          messageCount: 8,
        ),
        _task(id: 'other', title: '别的工作区', workspace: r'D:\work\other'),
      ]);

      await tester.pumpWidget(
        _wrap(
          WorkspaceScreen(
            liveStore: store,
            workspacePath: r'D:\work\demo',
            workspaceName: 'demo',
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(TaskStatusBadge), findsNWidgets(2));
      expect(find.text('最新任务'), findsOneWidget);
      expect(find.text('旧会话'), findsOneWidget);
      expect(find.text('等待授权'), findsOneWidget);
      expect(find.text('已完成'), findsOneWidget);
      expect(find.textContaining('8 条消息'), findsOneWidget);
      expect(find.text('别的工作区'), findsNothing);
      final newY = tester.getTopLeft(find.text('最新任务')).dy;
      final oldY = tester.getTopLeft(find.text('旧会话')).dy;
      expect(newY, lessThan(oldY));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      store.dispose();
    });

    testWidgets('没有会话时引导去对话框，输入条只读', (tester) async {
      final store = _FakeTaskStore(const <TaskItem>[]);
      var openedAssistant = 0;

      await tester.pumpWidget(
        _wrap(
          WorkspaceScreen(
            liveStore: store,
            workspacePath: r'D:\work\demo',
            onOpenAssistant: () => openedAssistant += 1,
          ),
        ),
      );
      await tester.pump();

      expect(find.text('这个工作区还没有会话'), findsOneWidget);
      expect(find.text('去对话框发第一条消息'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      final field = tester.widget<TextField>(find.byType(TextField));
      // M4.50：没有会话时这一格不再假装能发，改成点一下就跳去有对话框的那一页。
      expect(field.readOnly, isTrue);

      await tester.tap(find.text('去对话框发第一条消息'));
      await tester.pump();
      expect(openedAssistant, 1);
      expect(store.pendingWorkspaceCalls, contains(r'D:\work\demo'));
      expect(RemoteChatIntent.instance.pending?.workspacePath, r'D:\work\demo');
      RemoteChatIntent.instance.take();

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      store.dispose();
    });
  });

  group('工作区页入口（任务页）', () {
    testWidgets('工作区胶囊里始终有「新建项目」', (tester) async {
      final store = _FakeTaskStore(<TaskItem>[
        _task(id: 'a', title: '会话 A', workspace: r'D:\work\demo'),
      ]);

      await tester.pumpWidget(
        _wrap(TasksScreen(liveStore: store)),
      );
      await tester.pump();

      expect(find.text('新建项目'), findsOneWidget);
      // M4.13：项目名在「胶囊」和「项目卡」里各出现一次。
      expect(find.text('demo'), findsNWidgets(2));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      store.dispose();
    });
  });

  group('M4.13 按项目分组', () {
    testWidgets('同项目的会话挂在项目卡里，项目默认折叠、可点开', (tester) async {
      final store = _FakeTaskStore(<TaskItem>[
        _task(id: 'a', title: '会话 A', workspace: r'D:\work\demo'),
        _task(id: 'b', title: '会话 B', workspace: r'D:\work\demo'),
        _task(id: 'c', title: '会话 C', workspace: r'D:\work\other'),
      ], roots: const [r'D:\work\demo', r'D:\work\other', r'D:\work\空项目']);

      await tester.pumpWidget(_wrap(TasksScreen(liveStore: store)));
      await tester.pump();

      // 三个项目各一张卡；M4.51 起默认全部折叠，先只看到项目名和数量。
      expect(find.text('会话 A'), findsNothing);
      expect(find.text('会话 B'), findsNothing);
      expect(find.text('会话 C'), findsNothing);
      expect(find.text('空项目'), findsWidgets);

      // 点开「demo」项目，它下面的会话出现，其他项目不受影响。
      // 项目头排在胶囊后面，按顺序取（先找到项目卡里的那个）。
      final demoHeaders = find.text('demo');
      expect(demoHeaders, findsNWidgets(2));
      await tester.tap(demoHeaders.last);
      await tester.pumpAndSettle();
      expect(find.text('会话 A'), findsOneWidget);
      expect(find.text('会话 B'), findsOneWidget);
      expect(find.text('会话 C'), findsNothing);

      // 再点一次收起。
      await tester.tap(demoHeaders.last);
      await tester.pumpAndSettle();
      expect(find.text('会话 A'), findsNothing);
      expect(find.text('会话 B'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      store.dispose();
    });

    testWidgets('新建对话框把 parentDir 固定成项目根', (tester) async {
      final store = _FakeWorkspaceStore(
        roots: <String>[kDefaultProjectParent, r'D:\work\demo'],
      );
      await tester.pumpWidget(
        _wrap(
          Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showWorkspaceCreateDialog(context, liveStore: store),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.textContaining(kDefaultProjectParent), findsOneWidget);
      await tester.enterText(find.byType(TextField), '新项目');
      await tester.pump();
      await tester.tap(find.text('创建'));
      await tester.pumpAndSettle();

      expect(store.parents, <String?>[kDefaultProjectParent]);
      expect(store.created, <String>['新项目']);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      store.dispose();
    });
  });
}

JsonHttpResponse _ok() =>
    JsonHttpResponse(200, jsonEncode(<String, dynamic>{'ok': true}));
