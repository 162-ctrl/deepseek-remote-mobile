// M4.31：手机上要能看到电脑那头「等你选一项」。
//
// 以前提问只在「手机正停在那条会话的直播页」时才被插件接管，所以用户在电脑上看到
// 「确认需求」卡片时，手机端一无所知。现在手机 App 连着就接管，工作区顶部这条
// 提示负责先说一声，点进去就是那张带选项的卡片。
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseek_remote_app/data/live_store.dart';
import 'package:deepseek_remote_app/models.dart';
import 'package:deepseek_remote_app/screens/tasks_screen.dart';
import 'package:deepseek_remote_app/services/cloud_conversations.dart';
import 'package:deepseek_remote_app/services/history_api.dart';
import 'package:deepseek_remote_app/services/pairing_api.dart';
import 'package:deepseek_remote_app/theme/app_theme.dart';

class _MemoryConversationStore extends CloudConversationStore {
  _MemoryConversationStore(this.items);

  final List<CloudConversation> items;

  @override
  Future<List<CloudConversation>> load() async => items;

  @override
  Future<void> save(List<CloudConversation> conversations) async {}
}

class _PendingStore extends LiveStore {
  _PendingStore(this.pending);

  final DesktopPending pending;
  final List<String> openedSessions = <String>[];
  int pendingCalls = 0;

  @override
  bool get isConnected => true;

  @override
  String get deviceName => '测试电脑';

  @override
  String get agentVersion => '0.1.0-m1';

  @override
  String get harnessVersion => '0.2.2-rc.1';

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

  @override
  Future<DesktopPending> fetchDesktopPending() async {
    pendingCalls += 1;
    return pending;
  }

  @override
  Future<DesktopSessionFeed> fetchDesktopSession(
    String sessionId, {
    int? afterSeq,
    int limit = 80,
  }) async {
    openedSessions.add(sessionId);
    return DesktopSessionFeed(
      sessionId: sessionId,
      title: '示例项目E',
      cwd: r'D:\Projects\示例项目E',
      running: true,
      lastSeq: 0,
      events: const <DesktopSessionEvent>[],
    );
  }

  @override
  Future<DesktopQueue> fetchDesktopQueue(String sessionId) async =>
      const DesktopQueue();
}

const _pending = DesktopPending(
  questions: <DesktopPendingQuestion>[
    DesktopPendingQuestion(
      sessionId: 'session-video',
      questionId: 'call_1',
      count: 2,
      header: '确认范围',
      question: '要把整首 6:23 的歌和歌词都放进去吗？',
      title: '示例项目E',
    ),
    DesktopPendingQuestion(
      sessionId: 'session-music',
      questionId: 'call_2',
      count: 1,
      header: '选风格',
      question: '要民谣还是摇滚？',
      title: '做首歌',
    ),
  ],
);

Widget _app(LiveStore store) {
  return MaterialApp(
    theme: buildAppTheme(Brightness.light),
    home: TasksScreen(
      liveStore: store,
    ),
  );
}

void main() {
  testWidgets('M4.31 电脑在等你选一项时，工作区顶部会提示', (tester) async {
    final store = _PendingStore(_pending);
    await tester.pumpWidget(_app(store));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('确认范围'), findsOneWidget);
    expect(find.textContaining('6:23'), findsOneWidget);
    expect(find.text('还有 1 个'), findsOneWidget);
    expect(store.pendingCalls, greaterThanOrEqualTo(1));
  });

  testWidgets('M4.31 点提示条会进那条会话', (tester) async {
    final store = _PendingStore(_pending);
    await tester.pumpWidget(_app(store));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.text('确认范围'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(store.openedSessions, contains('session-video'));
  });

  group('M4.31 待回答摘要接口', () {
    test('旧插件回 404 时当「看不到」处理，不炸界面', () async {
      final api = HistoryApi(
        sender: (
          String method,
          Uri uri,
          Map<String, String> headers,
          Map<String, dynamic>? body,
        ) async =>
            JsonHttpResponse(404, jsonEncode(<String, dynamic>{'code': 'BAD_REQUEST', 'message': 'not found'})),
      );
      final pending = await api.fetchDesktopPending('http://127.0.0.1:8787', token: 'tok');
      expect(pending.answerable, isFalse);
      expect(pending.isEmpty, isTrue);
      expect(pending.error, contains('0.2.30'));
    });

    test('有提问时解析出会话 id 与标题', () async {
      final api = HistoryApi(
        sender: (
          String method,
          Uri uri,
          Map<String, String> headers,
          Map<String, dynamic>? body,
        ) async =>
            JsonHttpResponse(
          200,
          jsonEncode(<String, dynamic>{
            'questions': [
              {
                'sessionId': 'session-a',
                'questionId': 'call_1',
                'count': 2,
                'header': '确认范围',
                'question': '整首歌都放进去吗？',
                'title': '示例项目E',
                'createdAt': 1700000000000,
              },
            ],
          }),
        ),
      );
      final pending = await api.fetchDesktopPending('http://127.0.0.1:8787', token: 'tok');
      expect(pending.answerable, isTrue);
      expect(pending.questions.single.sessionId, 'session-a');
      expect(pending.questions.single.count, 2);
      expect(pending.questions.single.title, '示例项目E');
    });
  });

  testWidgets('M4.31 没有提问时不显示提示条', (tester) async {
    final store = _PendingStore(const DesktopPending());
    await tester.pumpWidget(_app(store));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('确认范围'), findsNothing);
    expect(find.byIcon(Icons.help_outline_rounded), findsNothing);
  });
}
