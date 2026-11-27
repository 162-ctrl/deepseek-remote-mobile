import 'dart:collection';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseek_remote_app/data/live_store.dart';
import 'package:deepseek_remote_app/models.dart';
import 'package:deepseek_remote_app/screens/desktop_session_screen.dart';
import 'package:deepseek_remote_app/screens/tasks_screen.dart';
import 'package:deepseek_remote_app/services/history_api.dart';
import 'package:deepseek_remote_app/services/pairing_api.dart';
import 'package:deepseek_remote_app/theme/app_theme.dart';

/// M4.10：电脑端存档（会话列表消失后手机端仍能看到）的接口层与页面。
class _Call {
  _Call(this.method, this.uri, this.body);
  final String method;
  final Uri uri;
  final Object? body;
}

class _Recorder {
  _Recorder(this.respond);
  final Map<String, dynamic> Function(_Call call) respond;
  final List<_Call> calls = <_Call>[];

  Future<JsonHttpResponse> sender(
    String method,
    Uri uri,
    Map<String, String> headers,
    Map<String, dynamic>? body,
  ) async {
    final call = _Call(method, uri, body);
    calls.add(call);
    return JsonHttpResponse(200, jsonEncode(respond(call)));
  }
}

Map<String, dynamic> _archiveSessionJson({
  String id = 'session-499ef7ec',
  String title = '古典诗词鉴赏',
  String workspace = r'D:\work\poetry',
  String source = 'disk',
  int lastTime = 1763200000000,
}) {
  return <String, dynamic>{
    'id': id,
    'title': title,
    'workspace': workspace,
    'source': source,
    'createdAt': 1763100000000,
    'lastTime': lastTime,
    'messageCount': 42,
    'eventCount': 96,
  };
}

class _FakeArchiveStore extends LiveStore {
  _FakeArchiveStore({this.hidden = const <ArchivedSession>[]});

  final List<ArchivedSession> hidden;
  final List<String> fetched = <String>[];
  final List<TaskItem> _items = <TaskItem>[];

  /// 电脑列表里还在的任务（用来验证存档去重）。
  void setTasks(List<TaskItem> items) {
    _items
      ..clear()
      ..addAll(items);
  }

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
  Future<DesktopSessionFeed> fetchArchivedSession(String sessionId) async {
    fetched.add(sessionId);
    return DesktopSessionFeed.fromJson(<String, dynamic>{
      'sessionId': sessionId,
      'title': '古典诗词鉴赏',
      'cwd': r'D:\work\poetry',
      'running': false,
      'lastSeq': 2,
      'events': <Map<String, dynamic>>[
        <String, dynamic>{
          'seq': 1,
          'kind': 'user',
          'text': '帮我看看《静夜思》',
          'time': 1763200000000,
        },
        <String, dynamic>{
          'seq': 2,
          'kind': 'assistant',
          'text': '这首诗写的是月夜思乡。',
          'time': 1763200060000,
        },
      ],
    });
  }
}

Widget _wrap(Widget child) => MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: child,
    );

void main() {
  group('HistoryApi 会话存档（M4.10）', () {
    test('archivedSessions 解析标题、工作区与来源', () async {
      final recorder = _Recorder((call) {
        expect(call.method, 'GET');
        expect(call.uri.path, '/api/v1/desktop/archive/sessions');
        return <String, dynamic>{
          'sessions': <Map<String, dynamic>>[_archiveSessionJson()],
        };
      });
      final api = HistoryApi(sender: recorder.sender);
      final sessions = await api.archivedSessions(
        'http://pc:8787',
        token: 'tk',
      );
      expect(sessions, hasLength(1));
      expect(sessions.single.title, '古典诗词鉴赏');
      expect(sessions.single.fromDisk, isTrue);
      expect(recorder.calls.single.uri.queryParameters, isEmpty);

      // M4.10：真正的 HTTP 发送器也走一遍，确认事件字段按接口契约序列化。
      final sent = <_Call>[];
      final httpApi = HistoryApi(sender: (method, uri, headers, body) async {
        sent.add(_Call(method, uri, body));
        return JsonHttpResponse(200, jsonEncode(<String, dynamic>{
          'ok': true,
          'saved': true,
        }));
      });
      await httpApi.postArchivedSession(
        'http://pc:8787',
        token: 'tk',
        session: ArchivedSession.fromJson(_archiveSessionJson(id: 'session-1')),
        events: <DesktopSessionEvent>[
          DesktopSessionEvent(seq: 1, kind: 'user', text: '你好', time: 1763200000000),
          DesktopSessionEvent(seq: 2, kind: 'turn-end', reason: 'completed'),
        ],
      );
      expect(sent, hasLength(1));
      expect(sent.single.method, 'POST');
      expect(sent.single.uri.path, '/api/v1/desktop/archive/sessions');
      final posted = sent.single.body! as Map<String, dynamic>;
      expect(posted['id'], 'session-1');
      expect(posted['source'], 'disk');
      final postedEvents = posted['events']! as List<dynamic>;
      expect(postedEvents, hasLength(2));
      expect((postedEvents.first as Map<String, dynamic>)['kind'], 'user');
      expect(
        (postedEvents.first as Map<String, dynamic>)['time'],
        1763200000000,
      );
    });

    test('archivedSession 读完整事件', () async {
      final recorder = _Recorder((call) {
        expect(call.uri.path, '/api/v1/desktop/archive/sessions/session-1');
        return <String, dynamic>{
          'sessionId': 'session-1',
          'running': false,
          'lastSeq': 1,
          'events': <Map<String, dynamic>>[
            <String, dynamic>{'seq': 1, 'kind': 'user', 'text': '你好'},
          ],
        };
      });
      final api = HistoryApi(sender: recorder.sender);
      final feed = await api.archivedSession(
        'http://pc:8787',
        token: 'tk',
        sessionId: 'session-1',
      );
      expect(feed.events, hasLength(1));
      expect(feed.events.single.text, '你好');
    });

    test('postArchivedSession 把事件按 kind/time/text 送回电脑', () async {
      final sent = <_Call>[];
      final httpApi = HistoryApi(sender: (method, uri, headers, body) async {
        sent.add(_Call(method, uri, body));
        return JsonHttpResponse(200, jsonEncode(<String, dynamic>{
          'ok': true,
          'saved': true,
        }));
      });
      await httpApi.postArchivedSession(
        'http://pc:8787',
        token: 'tk',
        session: ArchivedSession.fromJson(_archiveSessionJson(id: 'session-1')),
        events: <DesktopSessionEvent>[
          DesktopSessionEvent(seq: 1, kind: 'user', text: '你好', time: 1763200000000),
          DesktopSessionEvent(seq: 2, kind: 'turn-end', reason: 'completed'),
        ],
      );
      expect(sent, hasLength(1));
      expect(sent.single.method, 'POST');
      expect(sent.single.uri.path, '/api/v1/desktop/archive/sessions');
      final posted = sent.single.body! as Map<String, dynamic>;
      expect(posted['id'], 'session-1');
      expect(posted['source'], 'disk');
      final postedEvents = posted['events']! as List<dynamic>;
      expect(postedEvents, hasLength(2));
      expect((postedEvents.first as Map<String, dynamic>)['kind'], 'user');
      expect(
        (postedEvents.first as Map<String, dynamic>)['time'],
        1763200000000,
      );
    });
  });

  group('存档会话在手机上', () {
    testWidgets('工作区页列出「电脑上看不到了」的存档并进只读直播', (tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 900));
      final store = _FakeArchiveStore(
        hidden: <ArchivedSession>[
          ArchivedSession.fromJson(_archiveSessionJson()),
        ],
      );
      // M4.10：存档条目是「电脑列表里没有的」——假 store 的 tasks 为空，
      // hiddenArchivedSessions 原样返回全部存档。
      expect(
        store.hiddenArchivedSessions.map((s) => s.id).toList(),
        <String>['session-499ef7ec'],
      );
      await tester.pumpWidget(_wrap(TasksScreen(liveStore: store)));
      await tester.pump(const Duration(milliseconds: 200));

      // M4.13：存档不再单独成组，而是挂进它所属项目的卡里。
      // M4.51：项目卡默认折叠，先点开「poetry」才看得到里面的存档会话。
      await tester.tap(find.text('poetry'));
      await tester.pumpAndSettle();
      expect(find.text('古典诗词鉴赏'), findsWidgets);
      expect(find.text('已存档'), findsOneWidget);

      await tester.tap(find.text('古典诗词鉴赏'));
      await tester.pumpAndSettle();

      expect(find.byType(DesktopSessionScreen), findsOneWidget);
      expect(find.text('已存档'), findsOneWidget);
      expect(find.textContaining('电脑会把它接回原来那条对话'), findsOneWidget);
      expect(find.text('这首诗写的是月夜思乡。'), findsOneWidget);
      // M4.19：存档页也能继续对话了——输入条在，发出去会在电脑上恢复成新会话。
      expect(find.byType(TextField), findsOneWidget);
      expect(store.fetched, <String>['session-499ef7ec']);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      store.dispose();
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('电脑列表里还在的会话不会被当成存档重复显示', (tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 900));
      // 电脑列表里还有这条会话：存档不该重复出现。
      final store = _FakeArchiveStore(
        hidden: <ArchivedSession>[
          ArchivedSession.fromJson(_archiveSessionJson()),
        ],
      )
        ..setTasks(<TaskItem>[
          TaskItem(
            id: 'session-499ef7ec',
            title: '古典诗词鉴赏',
            status: TaskStatus.completed,
            workspace: r'D:\work\poetry',
            updatedAt: DateTime(2026, 11, 15, 12),
          ),
        ]);
      await tester.pumpWidget(_wrap(TasksScreen(liveStore: store)));
      await tester.pump(const Duration(milliseconds: 200));
      // 存档条目只有电脑列表里没有的才算：这里 tasks 里已经有同 id 的会话。
      expect(
        store.archivedSessions.map((s) => s.id).toList(),
        <String>['session-499ef7ec'],
      );
      // M4.13：会话已完成 → 行尾显示相对时间（有 lastTime 时优先），且只出现一次。
      // M4.51：项目卡默认折叠，先点开。
      await tester.tap(find.text('poetry').last);
      await tester.pumpAndSettle();
      expect(find.text('已存档'), findsNothing);
      expect(find.text('古典诗词鉴赏'), findsOneWidget);


      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      store.dispose();
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('存档页默认不轮询，但输入条可用（M4.19）', (tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 900));
      final store = _FakeArchiveStore();
      await tester.pumpWidget(_wrap(DesktopSessionScreen(
        liveStore: store,
        sessionId: 'session-499ef7ec',
        title: '古典诗词鉴赏',
        archived: true,
      )));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('已存档'), findsOneWidget);
      // M4.19：从「只能看」放开成「可以继续对话」。
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('这首诗写的是月夜思乡。'), findsOneWidget);
      // 等几轮轮询周期：还没发话之前，存档页不会自己开始轮询。
      final before = store.fetched.length;
      await tester.pump(const Duration(seconds: 4));
      expect(store.fetched.length, before);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      store.dispose();
      await tester.binding.setSurfaceSize(null);
    });
  });
}
