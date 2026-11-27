import 'dart:async';
import 'dart:convert';

import 'package:deepseek_remote_app/data/live_store.dart';
import 'package:deepseek_remote_app/services/notification_gateway.dart';
import 'package:deepseek_remote_app/services/pairing_api.dart';
import 'package:deepseek_remote_app/services/relay_client.dart';
import 'package:deepseek_remote_app/services/relay_protocol.dart';
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

Map<String, dynamic> _envelope(
  String type,
  Map<String, dynamic> payload,
) {
  return <String, dynamic>{'v': 1, 'type': type, 'payload': payload};
}

void _sendApprovalRequest(
  _FakeSocket socket, {
  String approvalId = 'ap-1',
  String tool = 'pwsh',
  String command = r'Get-ChildItem -Path C:\ -Recurse',
}) {
  socket.serverSend(_envelope(RelayMessageTypes.approvalRequest, {
    'conversationId': 'conv-1',
    'approvalId': approvalId,
    'tool': tool,
    'input': <String, dynamic>{'command': command},
    'workspace': r'D:\work\sales-analysis',
    'options': <Map<String, String>>[
      {'kind': 'allow_once', 'label': '允许一次'},
    ],
    'permissionLevel': 3,
    'riskLevel': 'high',
  }));
}

void _sendDeviceStatus(_FakeSocket socket, String deviceName) {
  socket.serverSend(_envelope(RelayMessageTypes.deviceStatus, {
    'online': true,
    'deviceName': deviceName,
    'agentVersion': '0.2.0-m2',
    'harnessVersion': '0.2.1',
    'capabilities': <String, bool>{'terminal': true},
    'workspaceRoots': <String>[r'D:\work\sales-analysis'],
  }));
}

class _NotifHarness {
  _NotifHarness({bool throwOnStartService = false}) {
    gateway = FakeNotificationGateway(throwOnStartService: throwOnStartService);
    relay = RelayClient(
      connector: (Uri uri) async {
        final socket = _FakeSocket();
        sockets.add(socket);
        return socket;
      },
      initialRetryDelay: const Duration(milliseconds: 10),
      maxRetryDelay: const Duration(milliseconds: 20),
      maxRetries: 2,
    );
    store = LiveStore(
      relayClient: relay,
      pairer: _fakePairer,
      notificationGateway: gateway,
    );
  }

  late final FakeNotificationGateway gateway;
  late final RelayClient relay;
  late final LiveStore store;
  final List<_FakeSocket> sockets = <_FakeSocket>[];

  _FakeSocket get socket => sockets.last;

  Future<void> connect() async {
    await store.connect('https://relay.example.com', code: '824613');
    await pumpEventQueue();
  }

  Future<void> dispose() async {
    store.dispose();
  }
}

void main() {
  group('M2 审批通知 / 前台服务', () {
    test('连接成功：请求一次通知权限并启动前台服务，设备名到了再刷新文案', () async {
      final h = _NotifHarness();
      addTearDown(h.dispose);
      await h.connect();

      expect(h.store.isConnected, isTrue);
      expect(h.gateway.permissionRequests, hasLength(1));
      expect(h.gateway.foregroundStarts, isNotEmpty);
      expect(h.gateway.foregroundStarts.first, '真实电脑');
      expect(h.gateway.clearedDisconnected, greaterThanOrEqualTo(1));

      _sendDeviceStatus(h.socket, 'DESKTOP-XXXXXXX');
      await pumpEventQueue();
      expect(h.store.deviceName, 'DESKTOP-XXXXXXX');
      expect(h.gateway.foregroundStarts.last, 'DESKTOP-XXXXXXX');

      await h.store.disconnect();
      await pumpEventQueue();
      expect(h.gateway.foregroundStops, isNotEmpty);
    });

    test('前台收到审批请求：不打扰（不发系统通知），只更新状态', () async {
      final h = _NotifHarness();
      addTearDown(h.dispose);
      await h.connect();
      expect(h.store.appInForeground, isTrue);

      _sendApprovalRequest(h.socket);
      await pumpEventQueue();

      expect(h.store.pendingApproval, isNotNull);
      expect(h.store.pendingApproval!.approvalId, 'ap-1');
      expect(h.gateway.approvalShows, isEmpty);
    });

    test('后台收到审批请求：发通知，标题固定、正文 tool + 命令首行截断', () async {
      final h = _NotifHarness();
      addTearDown(h.dispose);
      await h.connect();
      h.store.setAppForeground(false);

      _sendApprovalRequest(
        h.socket,
        command: r'Get-ChildItem -Path C:\ -Recurse | Where-Object {$_.Length -gt 1024}',
      );
      await pumpEventQueue();

      final show = h.gateway.approvalShows.single;
      expect(show['approvalId'], 'ap-1');
      expect(show['title'], '有一项操作需要授权');
      expect(show['body'], startsWith('pwsh · '));
      final commandPart = show['body']!.substring('pwsh · '.length);
      expect(commandPart.length, lessThanOrEqualTo(61));
      expect(commandPart, endsWith('…'));
    });

    test('后台审批被决定：回传 decision 并取消通知', () async {
      final h = _NotifHarness();
      addTearDown(h.dispose);
      await h.connect();
      h.store.setAppForeground(false);
      _sendApprovalRequest(h.socket);
      await pumpEventQueue();
      expect(h.gateway.approvalShows, hasLength(1));

      h.store.decideApproval(true);
      await pumpEventQueue();

      expect(h.store.pendingApproval, isNull);
      expect(h.gateway.canceledApprovals, contains('ap-1'));
      final frames = h.socket.sent
          .map((raw) => jsonDecode(raw) as Map<String, dynamic>)
          .toList();
      final decide = frames
          .lastWhere((frame) => frame['type'] == RelayMessageTypes.approvalDecide);
      final payload = decide['payload'] as Map<String, dynamic>;
      expect(payload['approvalId'], 'ap-1');
      expect(payload['decision'], 'approved');
    });

    test('审批在电脑端解决（approval.resolved）时取消通知', () async {
      final h = _NotifHarness();
      addTearDown(h.dispose);
      await h.connect();
      h.store.setAppForeground(false);
      _sendApprovalRequest(h.socket);
      await pumpEventQueue();

      h.socket.serverSend(_envelope(RelayMessageTypes.approvalResolved, {
        'conversationId': 'conv-1',
        'approvalId': 'ap-1',
        'decision': 'denied',
        'decidedBy': 'timeout',
      }));
      await pumpEventQueue();

      expect(h.store.pendingApproval, isNull);
      expect(h.gateway.canceledApprovals, contains('ap-1'));
    });

    test('点击通知（热启动）：标记 approvalToOpenId，UI 取用后清除', () async {
      final h = _NotifHarness();
      addTearDown(h.dispose);
      await h.connect();
      await h.store.initNotifications();
      expect(h.gateway.initCalled, isTrue);

      h.store.setAppForeground(false);
      _sendApprovalRequest(h.socket);
      await pumpEventQueue();

      h.gateway.emitTap('ap-1');
      await pumpEventQueue();
      expect(h.store.approvalToOpenId, 'ap-1');

      h.store.clearApprovalToOpen();
      expect(h.store.approvalToOpenId, isNull);
    });

    test('点击已失效通知：提示失效并取消该通知', () async {
      final h = _NotifHarness();
      addTearDown(h.dispose);
      await h.connect();
      await h.store.initNotifications();

      h.gateway.emitTap('ap-gone');
      await pumpEventQueue();

      expect(h.store.approvalToOpenId, isNull);
      expect(h.gateway.canceledApprovals, contains('ap-gone'));
      expect(
        h.store.messages.any(
          (message) =>
              message.role.name == 'system' &&
              message.text.contains('该审批已失效'),
        ),
        isTrue,
      );
    });

    test('冷启动：getInitialApprovalId 打开对应审批', () async {
      final h = _NotifHarness();
      addTearDown(h.dispose);

      // 审批请求先到（前台），随后 App 通过通知冷启动。
      h.store.applyEvent(RelayEvent.fromJson(
        _envelope(RelayMessageTypes.approvalRequest, {
          'conversationId': 'conv-1',
          'approvalId': 'ap-cold',
          'tool': 'pwsh',
          'input': <String, dynamic>{'command': 'dir'},
        }),
      ));
      expect(h.store.pendingApproval!.approvalId, 'ap-cold');

      h.gateway.initialApprovalId = 'ap-cold';
      await h.store.initNotifications();
      await pumpEventQueue();

      expect(h.store.approvalToOpenId, 'ap-cold');
    });

    test('App 切到后台时对已有待审批补发通知，回前台再撤销', () async {
      final h = _NotifHarness();
      addTearDown(h.dispose);
      await h.connect();
      _sendApprovalRequest(h.socket);
      await pumpEventQueue();
      expect(h.gateway.approvalShows, isEmpty);

      h.store.setAppForeground(false);
      await pumpEventQueue();
      expect(h.gateway.approvalShows, hasLength(1));

      h.store.setAppForeground(true);
      await pumpEventQueue();
      expect(h.gateway.canceledApprovals, contains('ap-1'));
    });

    test('被动断开连接：发「已断开与电脑的连接」通知；主动断开不发', () async {
      final h = _NotifHarness();
      addTearDown(h.dispose);
      await h.connect();
      expect(h.gateway.disconnectedNotices, isEmpty);

      await h.socket.close(1008, 'policy');
      await pumpEventQueue();

      expect(h.store.connectionState, LiveConnectionState.error);
      expect(h.gateway.disconnectedNotices, isNotEmpty);

      // 主动断开：不发断开通知（用户自己点的）。
      final h2 = _NotifHarness();
      addTearDown(h2.dispose);
      await h2.connect();
      await h2.store.disconnect();
      await pumpEventQueue();
      expect(h2.gateway.disconnectedNotices, isEmpty);
    });

    test('前台服务启动失败（Android 12+ 限制）不影响连接', () async {
      final h = _NotifHarness(throwOnStartService: true);
      addTearDown(h.dispose);
      await h.connect();
      await pumpEventQueue();
      expect(h.store.isConnected, isTrue);
      expect(h.store.errorText, isNull);
    });

    test('未注入 gateway 时通知相关调用为空操作，不崩溃', () async {
      final relay = RelayClient(
        connector: (Uri uri) async => _FakeSocket(),
      );
      final store = LiveStore(relayClient: relay, pairer: _fakePairer);
      addTearDown(store.dispose);

      await store.initNotifications();
      store.setAppForeground(false);
      store.handleApprovalTap('ap-1');
      expect(store.approvalToOpenId, isNull);
      expect(store.errorText, isNull);
    });
  });
}
