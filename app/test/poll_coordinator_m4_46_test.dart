// M4.46：统一轮询协调器（测试）。
//
// 第二阶段第 ⑦ 条：页面被 IndexedStack 保活，用户在看别的页时任务页仍每 5 秒
// 请求一次；而且定时器不看上一个请求是否在途、失败也照原节奏重试。
// 这里先测协调器本身（纯 Dart），再测任务页「可见才轮询、切走就停」。
import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseek_remote_app/data/live_store.dart';
import 'package:deepseek_remote_app/models.dart';
import 'package:deepseek_remote_app/screens/tasks_screen.dart';
import 'package:deepseek_remote_app/services/history_api.dart' show ArchivedSession, DesktopPending;
import 'package:deepseek_remote_app/services/poll_coordinator.dart';
import 'package:deepseek_remote_app/theme/app_theme.dart';

/// 只覆写任务页会读到的面，并记录 loadTasks / fetchDesktopPending 次数。
class _CountingStore extends LiveStore {
  int loadTasksCalls = 0;
  int pendingCalls = 0;

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
  UnmodifiableListView<TaskItem> get tasks => UnmodifiableListView<TaskItem>(const <TaskItem>[]);

  @override
  UnmodifiableListView<ArchivedSession> get archivedSessions =>
      UnmodifiableListView<ArchivedSession>(const <ArchivedSession>[]);

  @override
  List<RecentDesktopSession> get recentDesktopSessions => const <RecentDesktopSession>[];

  @override
  Future<void> ensureLiveData({bool force = false}) async {}

  @override
  Future<void> loadTasks({int limit = 50, List<String>? statuses}) async {
    loadTasksCalls += 1;
  }

  @override
  Future<void> loadArchivedSessions() async {}

  @override
  Future<DesktopPending> fetchDesktopPending() async {
    pendingCalls += 1;
    return const DesktopPending();
  }
}

Widget _app(TasksScreen screen) => MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: screen,
    );

void main() {
  group('M4.46 退避规则', () {
    test('成功时用基础间隔，失败按 2 的幂翻倍并封顶', () {
      const base = Duration(seconds: 5);
      expect(pollBackoffDelay(base, 0), const Duration(seconds: 5));
      expect(pollBackoffDelay(base, 1), const Duration(seconds: 10));
      expect(pollBackoffDelay(base, 2), const Duration(seconds: 20));
      // 40 秒超过 30 秒上限，直接封顶。
      expect(pollBackoffDelay(base, 3), const Duration(seconds: 30));
      expect(pollBackoffDelay(base, 9), const Duration(seconds: 30));
      // 自定义上限也生效。
      expect(
        pollBackoffDelay(base, 2, maxBackoff: const Duration(seconds: 12)),
        const Duration(seconds: 12),
      );
    });
  });

  group('M4.46 协调器', () {
    test('没激活时一次都不跑', () async {
      int runs = 0;
      final poller = PollCoordinator(
        interval: const Duration(milliseconds: 20),
        run: () async => runs += 1,
      );
      addTearDown(poller.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(runs, 0);
      expect(poller.active, isFalse);
    });

    test('激活后会按间隔持续跑，停掉就停', () async {
      int runs = 0;
      final poller = PollCoordinator(
        interval: const Duration(milliseconds: 20),
        run: () async => runs += 1,
      );
      addTearDown(poller.dispose);
      poller.active = true;
      await Future<void>.delayed(const Duration(milliseconds: 110));
      final int afterActive = runs;
      expect(afterActive, greaterThanOrEqualTo(2));
      poller.active = false;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(runs, afterActive);
    });

    test('上一个还没回来时不会再发第二个', () async {
      final completer = Completer<void>();
      int runs = 0;
      final poller = PollCoordinator(
        interval: const Duration(milliseconds: 20),
        run: () {
          runs += 1;
          return completer.future;
        },
      );
      addTearDown(poller.dispose);
      poller.active = true;
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(runs, 1);
      expect(poller.inFlight, isTrue);
      completer.complete();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(runs, greaterThan(1));
    });

    test('失败一次后下一次等更久，成功后退回正常节奏', () async {
      bool fail = true;
      int runs = 0;
      final poller = PollCoordinator(
        interval: const Duration(milliseconds: 20),
        maxBackoff: const Duration(milliseconds: 200),
        run: () async {
          runs += 1;
          if (fail) throw StateError('boom');
        },
      );
      addTearDown(poller.dispose);
      poller.active = true;
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(runs, 1);
      expect(poller.failures, 1);
      // 20ms * 2^1 = 40ms
      expect(poller.nextDelay, const Duration(milliseconds: 40));

      fail = false;
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(poller.failures, 0);
      expect(poller.nextDelay, const Duration(milliseconds: 20));
    });

    test('refreshNow 立刻跑一次并复位失败计数', () async {
      int runs = 0;
      final poller = PollCoordinator(
        interval: const Duration(seconds: 30),
        run: () async => runs += 1,
      );
      addTearDown(poller.dispose);
      poller.active = true;
      expect(await poller.refreshNow(), isTrue);
      expect(runs, 1);
    });
  });

  group('M4.46 任务页只在可见时轮询', () {
    testWidgets('看着这一页会轮询，切走后立刻停', (tester) async {
      final store = _CountingStore();
      addTearDown(store.dispose);

      // 1) 可见：应当在 5 秒节奏上真的发请求。
      await tester.pumpWidget(_app(TasksScreen(liveStore: store, active: true)));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 6));
      final int whileVisible = store.loadTasksCalls;
      expect(whileVisible, greaterThanOrEqualTo(1));

      // 2) 切到别的页（IndexedStack 仍保活，只是 active=false）：一次都不该再发。
      await tester.pumpWidget(_app(TasksScreen(liveStore: store, active: false)));
      await tester.pump(const Duration(seconds: 12));
      expect(store.loadTasksCalls, whileVisible);

      // 3) 切回来：立刻补一次（PollCoordinator 的 active=true 会立即排一轮）。
      await tester.pumpWidget(_app(TasksScreen(liveStore: store, active: true)));
      await tester.pump(const Duration(milliseconds: 100));
      expect(store.loadTasksCalls, greaterThan(whileVisible));
    });
  });
}
