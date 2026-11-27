// M4.21：手机端也要有电脑端那排「N 条排队消息」。
//
// 电脑端对话页在一轮还在跑的时候，会把后面排着的话列成「4 条排队消息」，
// 每条能编辑 / 删除 / 插话（Cmd/Ctrl+Enter 是全部插话）。手机上以前完全没有
// 这个概念，这些行为都靠 `GET|POST /desktop/sessions/<id>/queue` 打通。
//
// 这里验证：面板出现与展开、删除、改字、单条插话、全部插话。
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseek_remote_app/data/live_store.dart';
import 'package:deepseek_remote_app/models.dart';
import 'package:deepseek_remote_app/screens/desktop_session_screen.dart';
import 'package:deepseek_remote_app/services/history_api.dart';
import 'package:deepseek_remote_app/theme/app_theme.dart';

class _FakeQueueStore extends LiveStore {
  _FakeQueueStore(this.items);

  List<DesktopQueueItem> items;
  final List<String> actions = <String>[];

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

  @override
  Future<DesktopSessionFeed> fetchDesktopSession(
    String sessionId, {
    int? afterSeq,
    int limit = 80,
  }) async {
    return DesktopSessionFeed.fromJson(<String, dynamic>{
      'sessionId': sessionId,
      'title': 'deepseek手机端',
      'cwd': r'<项目根>',
      'running': true,
      'lastSeq': 2,
      'events': <Map<String, dynamic>>[
        <String, dynamic>{
          'seq': 1,
          'kind': 'user',
          'text': '先停止一会再做',
          'time': 1763200000000,
        },
        <String, dynamic>{
          'seq': 2,
          'kind': 'assistant',
          'text': '好，先停在这里。',
          'time': 1763200060000,
        },
      ],
    });
  }

  @override
  Future<DesktopQueue> fetchDesktopQueue(String sessionId) async {
    return DesktopQueue(items: List<DesktopQueueItem>.of(items), running: true);
  }

  @override
  Future<DesktopQueue> updateDesktopQueue(
    String sessionId,
    String itemId, {
    required String action,
    String? text,
  }) async {
    actions.add(text == null ? '$action:$itemId' : '$action:$itemId:$text');
    if (action == 'remove' || action == 'steer') {
      items = items.where((item) => item.id != itemId).toList();
    } else if (action == 'edit') {
      items = <DesktopQueueItem>[
        for (final item in items)
          item.id == itemId
              ? DesktopQueueItem(
                  id: item.id,
                  placement: item.placement,
                  text: text ?? item.text,
                )
              : item,
      ];
    }
    return DesktopQueue(items: List<DesktopQueueItem>.of(items), running: true);
  }
}

const List<DesktopQueueItem> _seed = <DesktopQueueItem>[
  DesktopQueueItem(id: 'q1', placement: 'queued', text: '对话做成这样'),
  DesktopQueueItem(id: 'q2', placement: 'queued', text: '插件市场要和电脑同步'),
  DesktopQueueItem(id: 'q3', placement: 'queued', text: '存档的对话手机上也可以对话'),
  DesktopQueueItem(id: 'q4', placement: 'queued', text: '这个功能手机上也得有'),
];

Widget _wrap(Widget child) => MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: child,
    );

Future<_FakeQueueStore> _openPanel(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(420, 1000));
  final store = _FakeQueueStore(List<DesktopQueueItem>.of(_seed));
  await tester.pumpWidget(_wrap(DesktopSessionScreen(
    liveStore: store,
    sessionId: 'session-queue',
    title: 'deepseek手机端',
  )));
  await tester.pump(const Duration(milliseconds: 200));
  await tester.tap(find.text('4 条排队消息'));
  await tester.pump(const Duration(milliseconds: 120));
  return store;
}

void main() {
  group('排队消息面板（M4.21）', () {
    testWidgets('展开后列出每一条，并提示插话的含义', (tester) async {
      await _openPanel(tester);

      expect(find.text('4 条排队消息'), findsOneWidget);
      expect(find.text('对话做成这样'), findsOneWidget);
      expect(find.text('这个功能手机上也得有'), findsOneWidget);
      expect(find.textContaining('插话＝立刻送进这一轮'), findsOneWidget);
      // 四条都能改 / 删 / 插话。
      expect(find.byTooltip('改这句话'), findsNWidgets(4));
      expect(find.byTooltip('从队列里删掉'), findsNWidgets(4));
      expect(find.byTooltip('插话：立刻送进这一轮'), findsNWidgets(4));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('删除一条之后队列少一条', (tester) async {
      final store = await _openPanel(tester);

      await tester.tap(find.byTooltip('从队列里删掉').first);
      await tester.pump(const Duration(milliseconds: 200));

      expect(store.actions, <String>['remove:q1']);
      expect(find.text('3 条排队消息'), findsOneWidget);
      expect(find.text('对话做成这样'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('改字之后用新内容显示', (tester) async {
      final store = await _openPanel(tester);

      await tester.tap(find.byTooltip('改这句话').first);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.enterText(find.byType(TextField).last, '对话排版做成官方那样');
      await tester.tap(find.text('保存'));
      await tester.pump(const Duration(milliseconds: 250));

      expect(store.actions, <String>['edit:q1:对话排版做成官方那样']);
      expect(find.text('对话排版做成官方那样'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('单条插话会立刻送进这一轮', (tester) async {
      final store = await _openPanel(tester);

      await tester.tap(find.byTooltip('插话：立刻送进这一轮').at(1));
      await tester.pump(const Duration(milliseconds: 200));

      expect(store.actions, <String>['steer:q2']);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('全部插话按顺序把每条都送进去', (tester) async {
      final store = await _openPanel(tester);

      await tester.tap(find.text('全部插话'));
      await tester.pump(const Duration(milliseconds: 400));

      expect(store.actions, <String>['steer:q1', 'steer:q2', 'steer:q3', 'steer:q4']);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('队列为空时不显示面板', (tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 900));
      final store = _FakeQueueStore(<DesktopQueueItem>[]);
      await tester.pumpWidget(_wrap(DesktopSessionScreen(
        liveStore: store,
        sessionId: 'session-empty',
        title: 'deepseek手机端',
      )));
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.textContaining('条排队消息'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.binding.setSurfaceSize(null);
    });
  });
}
