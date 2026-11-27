import 'dart:async';
import 'dart:convert';

import 'package:deepseek_remote_app/data/live_store.dart';
import 'package:deepseek_remote_app/models.dart';
import 'package:deepseek_remote_app/services/history_api.dart';
import 'package:deepseek_remote_app/services/notification_gateway.dart';
import 'package:deepseek_remote_app/services/notification_prefs.dart';
import 'package:deepseek_remote_app/services/pairing_api.dart';
import 'package:deepseek_remote_app/services/relay_client.dart';
import 'package:deepseek_remote_app/services/relay_protocol.dart';
import 'package:deepseek_remote_app/services/settings_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

/// 假 WebSocket：记录 App 发出的帧，可注入服务端帧/关闭码。
class _FakeSocket implements RelaySocket {
  final StreamController<String> _controller =
      StreamController<String>.broadcast();
  final List<String> sent = <String>[];
  int? _closeCode;

  @override
  Stream<String> get messages => _controller.stream;

  @override
  int? get closeCode => _closeCode;

  @override
  String? get closeReason => null;

  @override
  void send(String data) => sent.add(data);

  @override
  Future<void> close([int? code, String? reason]) async {
    _closeCode = code;
    if (!_controller.isClosed) await _controller.close();
  }

  void serverSend(Map<String, dynamic> frame) =>
      _controller.add(jsonEncode(frame));
}

Future<PairResult> _fakePairer(String baseUrl, String pairingCode) async {
  return PairResult.fromJson(<String, dynamic>{
    'token': 'tok-1',
    'role': 'app',
    'deviceId': 'device-1',
  });
}

Map<String, dynamic> _envelope(String type, Map<String, dynamic> payload) {
  return <String, dynamic>{'v': 1, 'type': type, 'payload': payload};
}

/// 桌面任务接口返回的假数据：任务列表可持续变化（模拟轮询）。
class _FakeHistoryApi extends HistoryApi {
  _FakeHistoryApi({this.records = const <Map<String, dynamic>>[]});

  /// 每条：{'id','title','status','conversationId','workspace'}
  List<Map<String, dynamic>> records;

  @override
  Future<List<TaskRecord>> tasks(
    String baseUrl, {
    required String token,
    int limit = 50,
    List<String>? statuses,
  }) async {
    // 插件直连没有 REST 任务接口（真实环境返回 404）：让 LiveStore 切到
    // 桌面任务镜像，这样测试走的就是 App 实际使用的那条路径。
    throw PairingApiException('Not Found', statusCode: 404);
  }

  @override
  Future<List<TaskRecord>> desktopTasks(
    String baseUrl, {
    required String token,
    int limit = 50,
    String? status,
  }) async {
    return records
        .map((raw) => TaskRecord.fromJson(<String, dynamic>{
              'id': raw['id'],
              'title': raw['title'],
              'status': raw['status'],
              if (raw['conversationId'] != null)
                'conversationId': raw['conversationId'],
              if (raw['workspace'] != null) 'workspacePath': raw['workspace'],
            }))
        .toList();
  }
}

class _Harness {
  _Harness({required this.records});

  final List<Map<String, dynamic>> records;

  late final FakeNotificationGateway gateway;
  late final RelayClient relay;
  late final LiveStore store;

  void build() {
    gateway = FakeNotificationGateway();
    relay = RelayClient(
      connector: (Uri uri) async => _FakeSocket(),
      initialRetryDelay: const Duration(milliseconds: 10),
      maxRetryDelay: const Duration(milliseconds: 20),
      maxRetries: 2,
    );
    store = LiveStore(
      relayClient: relay,
      pairer: _fakePairer,
      notificationGateway: gateway,
      historyApi: _FakeHistoryApi(records: records),
    );
  }

  Future<void> dispose() async {
    store.dispose();
  }
}

void main() {
  group('NotificationPrefs（M4.4）', () {
    test('默认开启，读写落到 SettingsGateway', () async {
      final settings = FakeSettingsGateway();
      final prefs = NotificationPrefs(gateway: settings);
      await prefs.load();
      expect(prefs.loaded, isTrue);
      expect(prefs.taskDone, isTrue);
      expect(prefs.approvalAction, isTrue);

      await prefs.setTaskDone(false);
      expect(prefs.taskDone, isFalse);
      expect(settings.values['notify_task_done'], '0');

      final reloaded = NotificationPrefs(gateway: settings);
      await reloaded.load();
      expect(reloaded.taskDone, isFalse);
      expect(reloaded.approvalAction, isTrue);

      await reloaded.setApprovalAction(false);
      expect(settings.values['notify_approval_action'], '0');
    });

    test('没有网关时用默认值', () async {
      final prefs = NotificationPrefs(defaultEnabled: true);
      await prefs.load();
      expect(prefs.taskDone, isTrue);
      expect(prefs.approvalAction, isTrue);
    });
  });

  group('任务完成通知（M4.4）', () {
    test('后台：任务从执行中变完成 → 发一条通知，点开回工作区页', () async {
      final h = _Harness(records: <Map<String, dynamic>>[
        {'id': 's1', 'title': '整理目录', 'status': 'running'},
      ]);
      h.build();
      addTearDown(h.dispose);
      await h.store.connect('https://relay.example.com', code: '824613');
      await pumpEventQueue();
      await h.store.loadTasks();
      await pumpEventQueue();
      expect(h.gateway.taskUpdates, isEmpty, reason: '第一次快照只做基线');

      h.store.setAppForeground(false);
      h.records[0] = {
        'id': 's1',
        'title': '整理目录',
        'status': 'completed',
        'conversationId': 'conv-1',
        'workspace': r'D:\work\sales-analysis',
      };
      await h.store.loadTasks();
      await pumpEventQueue();

      final update = h.gateway.taskUpdates.single;
      expect(update['key'], 'task-s1');
      expect(update['status'], 'completed');
      expect(update['title'], contains('任务已完成'));
      expect(update['title'], contains('整理目录'));
      expect(update['title'], contains('sales-analysis'));
      expect(h.store.pendingNotificationRoute, 'tasks');

      h.store.clearPendingNotificationRoute();
      expect(h.store.pendingNotificationRoute, isNull);
    });

    test('前台：不发通知', () async {
      final h = _Harness(records: <Map<String, dynamic>>[
        {'id': 's1', 'title': '整理目录', 'status': 'running'},
      ]);
      h.build();
      addTearDown(h.dispose);
      await h.store.connect('https://relay.example.com', code: '824613');
      await pumpEventQueue();
      await h.store.loadTasks();
      await pumpEventQueue();

      h.records[0] = {'id': 's1', 'title': '整理目录', 'status': 'completed'};
      await h.store.loadTasks();
      await pumpEventQueue();

      expect(h.gateway.taskUpdates, isEmpty);
    });

    test('任务失败时标题是「任务失败了」且 status=failed', () async {
      final h = _Harness(records: <Map<String, dynamic>>[
        {'id': 's1', 'title': '跑构建', 'status': 'running'},
      ]);
      h.build();
      addTearDown(h.dispose);
      await h.store.connect('https://relay.example.com', code: '824613');
      await pumpEventQueue();
      await h.store.loadTasks();
      await pumpEventQueue();

      h.store.setAppForeground(false);
      h.records[0] = {'id': 's1', 'title': '跑构建', 'status': 'failed'};
      await h.store.loadTasks();
      await pumpEventQueue();

      expect(h.gateway.taskUpdates.single['status'], 'failed');
      expect(h.gateway.taskUpdates.single['title'], contains('任务失败了'));
    });

    test('关掉「任务做完提醒」后不再发', () async {
      final settings = FakeSettingsGateway();
      final prefs = NotificationPrefs(gateway: settings);
      await prefs.setTaskDone(false);

      final h = _Harness(records: <Map<String, dynamic>>[
        {'id': 's1', 'title': '整理目录', 'status': 'running'},
      ]);
      h.build();
      addTearDown(h.dispose);
      await h.store.attachNotificationPrefs(prefs);
      await h.store.connect('https://relay.example.com', code: '824613');
      await pumpEventQueue();
      await h.store.loadTasks();
      await pumpEventQueue();

      h.store.setAppForeground(false);
      h.records[0] = {'id': 's1', 'title': '整理目录', 'status': 'completed'};
      await h.store.loadTasks();
      await pumpEventQueue();

      expect(h.gateway.taskUpdates, isEmpty);
    });
  });

  group('等待授权通知（M4.4）', () {
    test('后台收到授权请求 → 发可操作通知，解决后取消', () async {
      final h = _Harness(records: const <Map<String, dynamic>>[]);
      h.build();
      addTearDown(h.dispose);
      await h.store.connect('https://relay.example.com', code: '824613');
      await pumpEventQueue();
      h.store.setAppForeground(false);

      h.store.applyEvent(RelayEvent.fromJson(_envelope(
        RelayMessageTypes.approvalRequest,
        <String, dynamic>{
          'conversationId': 'conv-1',
          'approvalId': 'ap-9',
          'tool': 'pwsh',
          'input': <String, dynamic>{'command': r'Remove-Item C:\temp -Recurse'},
        },
      )));
      await pumpEventQueue();

      final action = h.gateway.approvalActionShows.single;
      expect(action['approvalId'], 'ap-9');
      expect(action['id'], 'approval-ap-9');
      expect(action['body'], startsWith('pwsh · '));

      h.store.applyEvent(RelayEvent.fromJson(_envelope(
        RelayMessageTypes.approvalResolved,
        <String, dynamic>{
          'conversationId': 'conv-1',
          'approvalId': 'ap-9',
          'decision': 'denied',
          'decidedBy': 'user',
        },
      )));
      await pumpEventQueue();
      expect(h.gateway.canceledTaskUpdates, contains('approval-ap-9'));
    });

    test('在通知栏点「允许」→ 回传 approved 并取消通知', () async {
      final h = _Harness(records: const <Map<String, dynamic>>[]);
      h.build();
      addTearDown(h.dispose);
      await h.store.connect('https://relay.example.com', code: '824613');
      await pumpEventQueue();
      await h.store.initNotifications();
      h.store.setAppForeground(false);

      h.store.applyEvent(RelayEvent.fromJson(_envelope(
        RelayMessageTypes.approvalRequest,
        <String, dynamic>{
          'conversationId': 'conv-1',
          'approvalId': 'ap-7',
          'tool': 'pwsh',
          'input': <String, dynamic>{'command': 'dir'},
        },
      )));
      await pumpEventQueue();

      h.gateway.emitDecision('ap-7', approved: true);
      await pumpEventQueue();

      expect(h.store.pendingApproval, isNull);
      expect(h.gateway.canceledTaskUpdates, contains('approval-ap-7'));
      expect(
        h.store.messages.any(
          (message) => message.text.contains('已在通知里允许这次操作。'),
        ),
        isTrue,
      );
    });
  });

  group('通知文案截断（M4.4）', () {
    test('notificationExcerpt 压空白并截断', () {
      expect(notificationExcerpt('  a\n\n b  '), 'a b');
      final long = 'x' * 100;
      final out = notificationExcerpt(long, max: 10);
      expect(out.length, 11);
      expect(out, endsWith('…'));
    });
  });
}
