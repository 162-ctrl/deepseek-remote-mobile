// M4.44 紧急停止：三种结果都必须如实区分。
//
// 以前这个按钮只做 disconnect()，用户看到「已断开」会以为电脑上的任务停了。
// 现在：发 task.cancel → 等终态或超时 → 断开，并按结果给人话。
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:deepseek_remote_app/data/live_store.dart';
import 'package:deepseek_remote_app/services/pairing_api.dart';
import 'package:deepseek_remote_app/services/relay_client.dart';
import 'package:deepseek_remote_app/services/relay_protocol.dart';

class _FakeSocket implements RelaySocket {
  final StreamController<String> _controller =
      StreamController<String>.broadcast();
  final List<String> sent = <String>[];

  @override
  Stream<String> get messages => _controller.stream;

  @override
  int? get closeCode => 0;

  @override
  String? get closeReason => null;

  @override
  void send(String data) => sent.add(data);

  @override
  Future<void> close([int? code, String? reason]) async {
    if (!_controller.isClosed) await _controller.close();
  }

  void serverSend(Map<String, dynamic> message) {
    if (!_controller.isClosed) _controller.add(jsonEncode(message));
  }
}

Map<String, dynamic> _frame(String type, Map<String, dynamic> payload) =>
    <String, dynamic>{'v': 1, 'type': type, 'payload': payload};

Future<PairResult> _fakePairer(String baseUrl, String pairingCode) async =>
    PairResult.fromJson(<String, dynamic>{
      'token': 'tok-1',
      'role': 'app',
      'deviceId': 'device-1',
    });

class _Harness {
  _Harness() {
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

  int cancelCount() =>
      sentFrames.where((frame) => frame['type'] == 'task.cancel').length;

  Future<void> connect() async {
    await store.connect('https://relay.example.com', code: '824613');
    await pumpEventQueue();
    socket.serverSend(_frame(
      RelayMessageTypes.conversationCreated,
      <String, dynamic>{'conversationId': 'conv-1', 'sessionId': 'session-1'},
    ));
    await pumpEventQueue();
  }

  Future<void> taskRunning() async {
    socket.serverSend(_frame(
      RelayMessageTypes.taskState,
      <String, dynamic>{'conversationId': 'conv-1', 'state': 'running'},
    ));
    await pumpEventQueue();
  }

  void dispose() => store.dispose();
}

void main() {
  group('M4.44 紧急停止', () {
    test('电脑确认任务停下 → taskCancelled，且先 cancel 后断开', () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.connect();
      await h.taskRunning();

      final future = h.store.emergencyStop();
      await pumpEventQueue();
      expect(h.cancelCount(), 1, reason: '应当先发 task.cancel');

      h.socket.serverSend(_frame(
        RelayMessageTypes.taskState,
        <String, dynamic>{'conversationId': 'conv-1', 'state': 'cancelled'},
      ));
      await pumpEventQueue();
      final result = await future;

      expect(result.outcome, EmergencyStopOutcome.taskCancelled);
      expect(result.taskStopped, isTrue);
      expect(result.detail, contains('已停下'));
      expect(h.store.isConnected, isFalse);
    });

    test('超时没确认 → cancelUnconfirmed，仍然断开且文案说清「可能还在跑」', () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.connect();
      await h.taskRunning();

      final result =
          await h.store.emergencyStop(timeout: const Duration(milliseconds: 60));

      expect(result.outcome, EmergencyStopOutcome.cancelUnconfirmed);
      expect(result.taskStopped, isFalse);
      expect(result.detail, contains('可能还在跑'));
      expect(h.store.isConnected, isFalse);
    });

    test('没有在跑的任务 → disconnectedOnly，不发 task.cancel', () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.connect();

      final result = await h.store.emergencyStop();

      expect(result.outcome, EmergencyStopOutcome.disconnectedOnly);
      expect(h.cancelCount(), 0);
      expect(h.store.isConnected, isFalse);
    });

    test('本来就没连接 → disconnectedOnly 且不抛异常', () async {
      final h = _Harness();
      addTearDown(h.dispose);

      final result = await h.store.emergencyStop();

      expect(result.outcome, EmergencyStopOutcome.disconnectedOnly);
      expect(result.detail, contains('本来就没有连接'));
    });
  });
}
