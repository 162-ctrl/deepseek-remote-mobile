// M4.24：存档会话在**原来那条对话里**继续，不是新开一条。
//
// M4.19 那会儿直接唤醒冷会话会让那一轮 blocked（DSH 的 ArchivedSessionGate 拒掉每个
// pre-step），所以当时绕成「新开会话 + 摘要」。M4.24 用
// workspaceController.unarchiveSession() 把门抬起，再往原 sessionId 发话 —— 电脑上不
// 会多出一条会话，手机端也不用跳转，就地切成直播轮询即可。这里验证：
//   1. 存档页有输入条，发出去带原 sessionId；成功后页面仍停在这条会话（不跳转），
//      并真的从直播接口拉到回复；
//   2. 电脑上真找不到这条会话时，只提示、不假装已恢复。
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseek_remote_app/data/live_store.dart';
import 'package:deepseek_remote_app/models.dart';
import 'package:deepseek_remote_app/screens/desktop_session_screen.dart';
import 'package:deepseek_remote_app/services/history_api.dart';
import 'package:deepseek_remote_app/services/pairing_api.dart';
import 'package:deepseek_remote_app/theme/app_theme.dart';

class _FakeArchiveChatStore extends LiveStore {
  _FakeArchiveChatStore({this.promptError});

  /// 非空时 sendDesktopPrompt 直接抛这个异常（模拟电脑上会话已被清理）。
  final String? promptError;

  final List<String> archivedFetched = <String>[];
  final List<String> liveFetched = <String>[];
  final List<String> prompts = <String>[];

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
  Future<DesktopSessionFeed> fetchArchivedSession(String sessionId) async {
    archivedFetched.add(sessionId);
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

  @override
  Future<DesktopSessionFeed> fetchDesktopSession(
    String sessionId, {
    int? afterSeq,
    int limit = 80,
  }) async {
    liveFetched.add(sessionId);
    return DesktopSessionFeed.fromJson(<String, dynamic>{
      'sessionId': sessionId,
      'title': '古典诗词鉴赏',
      'cwd': r'D:\work\poetry',
      'running': true,
      'lastSeq': 4,
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
        <String, dynamic>{
          'seq': 3,
          'kind': 'user',
          'text': '再讲讲它的背景',
          'time': 1763200120000,
        },
        <String, dynamic>{
          'seq': 4,
          'kind': 'assistant',
          'text': '静夜思写于扬州旅舍。',
          'time': 1763200180000,
        },
      ],
    });
  }

  @override
  Future<DesktopPromptResult> sendDesktopPrompt(
    String sessionId,
    String text,
  ) async {
    prompts.add('$sessionId::$text');
    final error = promptError;
    if (error != null) throw PairingApiException(error);
    // M4.24：同一条会话，只多一个 resumed 标记。
    return DesktopPromptResult(sessionId: sessionId, resumed: true);
  }
}

Widget _wrap(Widget child) => MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: child,
    );

void main() {
  group('存档会话在同一条对话里继续（M4.24）', () {
    testWidgets('发一句话之后留在原会话，不新开也不跳转', (tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 900));
      final store = _FakeArchiveChatStore();
      await tester.pumpWidget(_wrap(DesktopSessionScreen(
        liveStore: store,
        sessionId: 'session-499ef7ec',
        title: '古典诗词鉴赏',
        archived: true,
      )));
      await tester.pump(const Duration(milliseconds: 200));

      // 存档态：徽标在、输入条也在、说明写着「接回原来那条对话」。
      expect(find.text('已存档'), findsOneWidget);
      expect(find.textContaining('电脑会把它接回原来那条对话'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);

      await tester.enterText(find.byType(TextField), '再讲讲它的背景');
      await tester.tap(find.byTooltip('发送'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));

      expect(store.prompts, <String>['session-499ef7ec::再讲讲它的背景']);
      // 关键：拉直播用的还是同一条 sessionId，没有新会话。
      expect(store.liveFetched, isNotEmpty);
      expect(store.liveFetched.first, 'session-499ef7ec');
      // 发过话之后就不再是「已存档」，而且真的把回复渲染出来了。
      expect(find.text('已存档'), findsNothing);
      expect(find.text('静夜思写于扬州旅舍。'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('电脑上找不到这条会话时只提示，不假装已经接回来了', (tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 900));
      final store = _FakeArchiveChatStore(
        promptError: '电脑上已经找不到这个会话了（可能被清理或换了目录）',
      );
      await tester.pumpWidget(_wrap(DesktopSessionScreen(
        liveStore: store,
        sessionId: 'session-gone',
        title: '古典诗词鉴赏',
        archived: true,
      )));
      await tester.pump(const Duration(milliseconds: 200));

      await tester.enterText(find.byType(TextField), '你好');
      await tester.tap(find.byTooltip('发送'));
      await tester.pump(const Duration(milliseconds: 300));

      expect(store.prompts, hasLength(1));
      expect(find.textContaining('电脑上已经找不到这个会话'), findsOneWidget);
      // 失败就不能假装已经接回来了。
      expect(store.liveFetched, isEmpty);
      expect(find.text('已存档'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.binding.setSurfaceSize(null);
    });
  });
}
