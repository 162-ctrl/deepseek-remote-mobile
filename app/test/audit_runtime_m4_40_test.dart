// M4.40 测试审计 · 角度四：跑起来之后——大负载、连点、离开页面
//
// 前三组都是「静态」的（接口坏掉怎么说话、存档坏掉怎么读、小屏怎么排）。
// 这一组压的是运行期行为：
//   1. 一条 500 条消息的会话，只渲染视口附近，不是 500 个卡片全建；
//   2. 发送按钮连点三下，只发一次；
//   3. 页面关掉之后，轮询必须停（不能后台一直打电脑）。
import 'dart:collection';

import 'package:deepseek_remote_app/data/live_store.dart';
import 'package:deepseek_remote_app/models.dart';
import 'package:deepseek_remote_app/screens/desktop_session_screen.dart';
import 'package:deepseek_remote_app/services/history_api.dart';
import 'package:deepseek_remote_app/theme/app_theme.dart';
import 'package:deepseek_remote_app/widgets/chat_items.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) => MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: child,
    );

void main() {
  group('M4.40 运行期行为', () {
    testWidgets('500 条消息：只建视口附近的卡片，不是 500 个', (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 780));
      final store = _BigStore(count: 500);
      await tester.pumpWidget(_wrap(DesktopSessionScreen(
        liveStore: store,
        sessionId: 'session-big',
        title: '很多消息',
      )));
      await tester.pump(const Duration(milliseconds: 200));

      expect(tester.takeException(), isNull);
      final built = find.byType(ChatItemView).evaluate().length;
      // 懒加载的意义就在这里：一屏 780 高，建出来的卡片应该远小于 500。
      expect(built, lessThan(60), reason: '实际建了 $built 个卡片');
      expect(built, greaterThan(0));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('连点三下发送：只发一条', (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 780));
      final store = _BigStore(count: 3);
      await tester.pumpWidget(_wrap(DesktopSessionScreen(
        liveStore: store,
        sessionId: 'session-big',
        title: '连点',
      )));
      await tester.pump(const Duration(milliseconds: 200));

      await tester.enterText(find.byType(TextField), '在吗');
      await tester.pump();

      final send = find.byTooltip('发送');
      await tester.tap(send);
      await tester.tap(send, warnIfMissed: false);
      await tester.tap(send, warnIfMissed: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(store.prompts, <String>['在吗']);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('页面关掉之后，轮询要停（不能后台一直打电脑）', (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 780));
      final store = _BigStore(count: 5);
      await tester.pumpWidget(_wrap(DesktopSessionScreen(
        liveStore: store,
        sessionId: 'session-big',
        title: '关掉',
      )));
      await tester.pump(const Duration(milliseconds: 200));

      // 让它正常轮两轮。
      await tester.pump(const Duration(seconds: 3));
      final beforeClose = store.fetches;
      expect(beforeClose, greaterThan(1), reason: '没在轮询的话这条用例没意义');

      // 关掉页面（真实场景：返回上一页）。
      await tester.pumpWidget(_wrap(const SizedBox.shrink()));
      await tester.pump(const Duration(seconds: 10));

      expect(store.fetches, beforeClose,
          reason: '关掉后还在请求：before=$beforeClose after=${store.fetches}');

      await tester.binding.setSurfaceSize(null);
    });
  });
}

/// 一条有很多消息的会话。`fetchDesktopSession` 计次，`sendDesktopPrompt` 记账。
class _BigStore extends LiveStore {
  _BigStore({required this.count});

  final int count;
  int fetches = 0;
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
  Future<DesktopQueue> fetchDesktopQueue(String sessionId) async =>
      const DesktopQueue();

  @override
  Future<DesktopSessionFeed> fetchDesktopSession(
    String sessionId, {
    int? afterSeq,
    int limit = 80,
  }) async {
    fetches += 1;
    return DesktopSessionFeed.fromJson(<String, dynamic>{
      'sessionId': sessionId,
      'title': '很多消息',
      'cwd': r'D:\Projects\big',
      'running': false,
      'lastSeq': count,
      'events': <Map<String, dynamic>>[
        for (var i = 0; i < count; i++)
          <String, dynamic>{
            'seq': i + 1,
            'kind': i.isEven ? 'user' : 'assistant',
            'text': '第 ${i + 1} 条消息，用来把列表撑长',
            'time': 1763200000000 + i * 1000,
          },
      ],
    });
  }

  @override
  Future<DesktopPromptResult> sendDesktopPrompt(
    String sessionId,
    String text,
  ) async {
    prompts.add(text);
    return const DesktopPromptResult(sessionId: 'session-big', resumed: true);
  }
}
