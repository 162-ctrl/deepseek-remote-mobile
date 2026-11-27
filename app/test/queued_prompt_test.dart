import 'dart:async';
import 'dart:convert';

import 'package:deepseek_remote_app/data/live_store.dart';
import 'package:deepseek_remote_app/models.dart';
import 'package:deepseek_remote_app/services/pairing_api.dart';
import 'package:deepseek_remote_app/services/relay_client.dart';
import 'package:deepseek_remote_app/services/relay_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

/// M2.1 审批等待排队降级（A4，契约 §4.2）测试。
///
/// 纯内存 fake WebSocket，不依赖真实后端。

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
    await _controller.close();
  }

  void serverSend(Map<String, dynamic> message) =>
      _controller.add(jsonEncode(message));
}

Map<String, dynamic> _frame(String type, Map<String, dynamic> payload) =>
    <String, dynamic>{'v': 1, 'type': type, 'payload': payload};

Future<PairResult> _fakePairer(String baseUrl, String pairingCode) async =>
    PairResult.fromJson(<String, dynamic>{
      'token': 'tok-1',
      'role': 'app',
      'deviceId': 'device-1',
    });

class _QueuedHarness {
  _QueuedHarness() {
    store = LiveStore(
      relayClient: RelayClient(
        connector: (Uri uri) async {
          final socket = _FakeSocket();
          sockets.add(socket);
          return socket;
        },
      ),
      pairer: _fakePairer,
    );
  }

  final List<_FakeSocket> sockets = <_FakeSocket>[];
  late final LiveStore store;

  _FakeSocket get socket => sockets.last;

  List<Map<String, dynamic>> get sentFrames => socket.sent
      .map((raw) => jsonDecode(raw) as Map<String, dynamic>)
      .toList();

  List<Map<String, dynamic>> framesOfType(String type) =>
      sentFrames.where((frame) => frame['type'] == type).toList();

  Map<String, dynamic>? lastFrameOfType(String type) {
    final frames = framesOfType(type);
    return frames.isEmpty ? null : frames.last;
  }

  Future<void> connect() async {
    await store.connect('https://relay.example.com', code: '824613');
    await pumpEventQueue();
  }

  Future<void> openConversation() async {
    socket.serverSend(_frame(
      RelayMessageTypes.conversationCreated,
      <String, dynamic>{'conversationId': 'conv-1', 'sessionId': 'session-1'},
    ));
    await pumpEventQueue();
  }

  Future<void> sendTaskState(String state) async {
    socket.serverSend(_frame(
      RelayMessageTypes.taskState,
      <String, dynamic>{'conversationId': 'conv-1', 'state': state},
    ));
    await pumpEventQueue();
  }

  Future<void> sendApprovalRequest() async {
    socket.serverSend(_frame(
      RelayMessageTypes.approvalRequest,
      <String, dynamic>{
        'conversationId': 'conv-1',
        'approvalId': 'ap-1',
        'tool': 'pwsh',
        'input': <String, dynamic>{'command': 'Get-ChildItem -Path C:\\'},
        'workspace': r'D:\work\sales-analysis',
      },
    ));
    await pumpEventQueue();
  }

  Future<void> sendApprovalResolved() async {
    socket.serverSend(_frame(
      RelayMessageTypes.approvalResolved,
      <String, dynamic>{
        'conversationId': 'conv-1',
        'approvalId': 'ap-1',
        'decision': 'approved',
        'decidedBy': 'phone',
      },
    ));
    await pumpEventQueue();
  }

  void dispose() => store.dispose();
}

void main() {
  group('M2.1 排队指令（队列深度 1）', () {
    test('busy 时发送进入队列，不立刻发 prompt.send', () async {
      final h = _QueuedHarness();
      addTearDown(h.dispose);
      await h.connect();
      await h.openConversation();
      await h.sendTaskState('running');
      expect(h.store.isBusy, isTrue);

      h.store.sendPrompt('第二条指令');
      await pumpEventQueue();

      expect(h.store.hasQueuedPrompt, isTrue);
      expect(h.store.queuedPromptText, '第二条指令');
      expect(h.framesOfType(RelayMessageTypes.promptSend), isEmpty);
      final queued = h.store.messages.last;
      expect(queued.role, ChatRole.user);
      expect(queued.queued, isTrue);
      expect(queued.text, '第二条指令');
    });

    test('排队深度为 1：第二条排队请求只提示，不覆盖已排队指令', () async {
      final h = _QueuedHarness();
      addTearDown(h.dispose);
      await h.connect();
      await h.openConversation();
      await h.sendTaskState('running');

      h.store.sendPrompt('第一条排队');
      await pumpEventQueue();
      h.store.sendPrompt('第二条排队');
      await pumpEventQueue();

      expect(h.store.errorText, contains('已有一条排队中的指令'));
      expect(h.store.queuedPromptText, '第一条排队');
      expect(h.store.hasQueuedPrompt, isTrue);
      expect(
        h.store.messages.where((m) => m.queued).length,
        1,
      );
      expect(h.framesOfType(RelayMessageTypes.promptSend), isEmpty);
    });

    test('removeQueuedPrompt 移除队列且不发送', () async {
      final h = _QueuedHarness();
      addTearDown(h.dispose);
      await h.connect();
      await h.openConversation();
      await h.sendTaskState('running');

      h.store.sendPrompt('稍后再发');
      await pumpEventQueue();
      expect(h.store.hasQueuedPrompt, isTrue);

      h.store.removeQueuedPrompt();
      await pumpEventQueue();
      expect(h.store.hasQueuedPrompt, isFalse);
      expect(h.store.queuedPromptText, isNull);
      expect(h.store.messages.where((m) => m.queued), isEmpty);
      expect(h.framesOfType(RelayMessageTypes.promptSend), isEmpty);
    });

    test('task.state completed 后自动发出排队指令', () async {
      final h = _QueuedHarness();
      addTearDown(h.dispose);
      await h.connect();
      await h.openConversation();
      await h.sendTaskState('running');

      h.store.sendPrompt('排队指令');
      await pumpEventQueue();
      expect(h.framesOfType(RelayMessageTypes.promptSend), isEmpty);

      await h.sendTaskState('completed');
      final sends = h.framesOfType(RelayMessageTypes.promptSend);
      expect(sends, hasLength(1));
      final payload = sends.single['payload'] as Map<String, dynamic>;
      expect(payload['conversationId'], 'conv-1');
      expect(payload['text'], '排队指令');
      expect(h.store.taskState, TaskStatus.queued);
      expect(h.store.hasQueuedPrompt, isFalse);
      final sent = h.store.messages.firstWhere((m) => m.text == '排队指令');
      expect(sent.queued, isFalse);
      expect(sent.role, ChatRole.user);
    });

    test('审批等待（waitingApproval）属于 busy，resolved 后仍等待 turn 结束', () async {
      final h = _QueuedHarness();
      addTearDown(h.dispose);
      await h.connect();
      await h.openConversation();
      await h.sendApprovalRequest();
      expect(h.store.taskState, TaskStatus.waitingApproval);
      expect(h.store.isBusy, isTrue);

      h.store.sendPrompt('审批期间排队');
      await pumpEventQueue();
      expect(h.store.hasQueuedPrompt, isTrue);
      expect(h.framesOfType(RelayMessageTypes.promptSend), isEmpty);

      await h.sendApprovalResolved();
      // 审批解决后 turn 仍在跑，排队指令还要继续等。
      expect(h.store.taskState, TaskStatus.running);
      expect(h.store.hasQueuedPrompt, isTrue);
      expect(h.framesOfType(RelayMessageTypes.promptSend), isEmpty);

      await h.sendTaskState('completed');
      expect(h.framesOfType(RelayMessageTypes.promptSend), hasLength(1));
      expect(h.store.hasQueuedPrompt, isFalse);
    });

    test('空闲时发送不排队，直接走 prompt.send', () async {
      final h = _QueuedHarness();
      addTearDown(h.dispose);
      await h.connect();
      await h.openConversation();

      h.store.sendPrompt('直接发送');
      await pumpEventQueue();

      expect(h.store.hasQueuedPrompt, isFalse);
      final sends = h.framesOfType(RelayMessageTypes.promptSend);
      expect(sends, hasLength(1));
      final payload = sends.single['payload'] as Map<String, dynamic>;
      expect(payload['conversationId'], 'conv-1');
      expect(payload['text'], '直接发送');
      final message = h.store.messages.last;
      expect(message.role, ChatRole.user);
      expect(message.queued, isFalse);
    });

    test('turn 失败/取消同样会发出排队指令', () async {
      for (final terminal in <String>['failed', 'cancelled']) {
        final h = _QueuedHarness();
        addTearDown(h.dispose);
        await h.connect();
        await h.openConversation();
        await h.sendTaskState('running');
        h.store.sendPrompt('等失败后发送');
        await pumpEventQueue();
        expect(h.framesOfType(RelayMessageTypes.promptSend), isEmpty);

        await h.sendTaskState(terminal);
        final sends = h.framesOfType(RelayMessageTypes.promptSend);
        expect(sends, hasLength(1), reason: 'terminal=$terminal');
        expect(h.store.hasQueuedPrompt, isFalse, reason: 'terminal=$terminal');
      }
    });
  });
}
