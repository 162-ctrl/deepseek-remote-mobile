// M4.38：桌面直播「经常连接超时」的两个自我放大因素。
//
// 一是轮询每 1.5 秒盲打一次，不看上一个还在途 —— 首屏一次一百多 KB，
// 超时 10 秒时后面已经排了六七个请求，全挤在同一条 Cloudflare 隧道上；
// 二是失败之后仍然按 1.5 秒重试，网络没恢复就是持续拥堵。
//
// 这里钉两件事：退避节奏本身，以及「在途时不再发第二个」。
import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseek_remote_app/data/live_store.dart';
import 'package:deepseek_remote_app/models.dart';
import 'package:deepseek_remote_app/screens/desktop_session_screen.dart';
import 'package:deepseek_remote_app/services/history_api.dart';
import 'package:deepseek_remote_app/services/pairing_api.dart';
import 'package:deepseek_remote_app/services/poll_backoff.dart';
import 'package:deepseek_remote_app/theme/app_theme.dart';

/// 让第一次拉取一直挂着：用来观察「在途时会不会又发一个」。
class _SlowStore extends LiveStore {
  int calls = 0;
  bool fail = false;
  final List<Completer<DesktopSessionFeed>> pending =
      <Completer<DesktopSessionFeed>>[];

  DesktopSessionFeed feed({int lastSeq = 2}) => DesktopSessionFeed.fromJson(
        <String, dynamic>{
          'sessionId': 's1',
          'title': 'deepseek手机端',
          'cwd': r'<项目根>',
          'running': true,
          'lastSeq': lastSeq,
          'events': <Map<String, dynamic>>[
            <String, dynamic>{
              'seq': 1,
              'kind': 'user',
              'text': '先做一个 demo',
              'time': 1794900000000,
            },
            <String, dynamic>{
              'seq': 2,
              'kind': 'assistant',
              'text': '好的，我先把骨架搭起来。',
              'time': 1794900001000,
            },
          ],
        },
      );

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
  }) {
    calls += 1;
    if (fail) {
      return Future<DesktopSessionFeed>.error(
        PairingApiException('拉取桌面会话失败：连接超时（20 秒）'),
      );
    }
    final completer = Completer<DesktopSessionFeed>();
    pending.add(completer);
    return completer.future;
  }

  @override
  Future<DesktopQueue> fetchDesktopQueue(String sessionId) async =>
      const DesktopQueue();
}

Widget _screen(LiveStore store) => MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: DesktopSessionScreen(
        liveStore: store,
        sessionId: 's1',
        title: 'deepseek手机端',
      ),
    );

void main() {
  group('M4.38 轮询退避节奏', () {
    test('成功时还是 1.5 秒一次', () {
      expect(desktopPollDelay(0), kDesktopPollInterval);
      expect(desktopPollDelay(0).inMilliseconds, 1500);
    });

    test('连续失败逐次翻倍，最长 30 秒', () {
      expect(desktopPollDelay(1).inMilliseconds, 3000);
      expect(desktopPollDelay(2).inMilliseconds, 6000);
      expect(desktopPollDelay(3).inMilliseconds, 12000);
      expect(desktopPollDelay(4).inMilliseconds, 24000);
      expect(desktopPollDelay(5), kDesktopPollMaxBackoff);
      expect(desktopPollDelay(99), kDesktopPollMaxBackoff);
    });
  });

  group('M4.38 在途时不重复发请求', () {
    testWidgets('第一次还没回来，过 6 秒也只发过一次', (tester) async {
      final store = _SlowStore();
      await tester.pumpWidget(_screen(store));
      await tester.pump();
      expect(store.calls, 1, reason: '打开页面就该发第一个请求');

      // 原来的 Timer.periodic(1500ms) 在这 6 秒里会再发 4 次。
      await tester.pump(const Duration(seconds: 6));
      expect(store.calls, 1, reason: '上一个还挂着，不许再发');

      store.pending.first.complete(store.feed());
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(store.calls, 2, reason: '上一个回来之后才轮到下一个');
    });

    testWidgets('失败之后先等 3 秒再重试，不是 1.5 秒', (tester) async {
      final store = _SlowStore()..fail = true;
      await tester.pumpWidget(_screen(store));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(store.calls, 1);

      await tester.pump(const Duration(milliseconds: 2600));
      expect(store.calls, 1, reason: '第一次失败后要等 3 秒');

      await tester.pump(const Duration(milliseconds: 600));
      expect(store.calls, 2, reason: '3 秒到了才重试');
    });
  });
}
