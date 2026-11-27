import 'dart:async';
import 'dart:convert';

import 'package:deepseek_remote_app/data/live_store.dart';
import 'package:deepseek_remote_app/models.dart';
import 'package:deepseek_remote_app/services/history_api.dart';
import 'package:deepseek_remote_app/services/pairing_api.dart';
import 'package:deepseek_remote_app/services/relay_client.dart';
import 'package:deepseek_remote_app/services/relay_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

/// M2.1 事件增量补拉（断线 / 后台恢复）测试。
///
/// 全部使用内存 fake：WebSocket 用 [_FakeSocket]，REST 用注入的 sender，
/// 不依赖真实网络与后端。

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

Map<String, dynamic> _sessionOutput(int seq, String text) => _frame(
      RelayMessageTypes.sessionUpdate,
      <String, dynamic>{
        'conversationId': 'conv-1',
        'seq': seq,
        'kind': 'output',
        'text': text,
      },
    );

Map<String, dynamic> _event(String type, int seq, Map<String, dynamic> payload) =>
    <String, dynamic>{
      'seq': seq,
      'type': type,
      'kind': payload['kind'],
      'payload': payload,
      'createdAt': '2026-11-02T15:00:0${seq % 10}Z',
    };

/// REST 假实现：只处理 `/conversations/{id}/events`。
class _FakeEventsRest {
  final List<int> afterSeqs = <int>[];
  bool fail = false;

  /// M2.8：模拟插件直连——只有中继，没有历史接口（404 BAD_REQUEST）。
  bool pluginMode = false;

  Future<JsonHttpResponse> send(
    String method,
    Uri uri,
    Map<String, String> headers,
    Map<String, dynamic>? body,
  ) async {
    if (!uri.path.endsWith('/events')) {
      return const JsonHttpResponse(404, '{"error":{"code":"NOT_FOUND"}}');
    }
    if (pluginMode) {
      return const JsonHttpResponse(
        404,
        '{"code":"BAD_REQUEST","message":"not found"}',
      );
    }
    final after =
        int.tryParse(uri.queryParameters['afterSeq'] ?? '0') ?? 0;
    afterSeqs.add(after);
    if (fail) {
      return const JsonHttpResponse(
        500,
        '{"error":{"code":"INTERNAL","message":"boom"}}',
      );
    }
    final events = <Map<String, dynamic>>[
      _event(RelayMessageTypes.sessionUpdate, 3, <String, dynamic>{
        'conversationId': 'conv-1',
        'seq': 3,
        'kind': 'output',
        'text': '断线 A',
      }),
      _event(RelayMessageTypes.sessionUpdate, 4, <String, dynamic>{
        'conversationId': 'conv-1',
        'seq': 4,
        'kind': 'output',
        'text': '断线 B',
      }),
      _event(RelayMessageTypes.sessionUpdate, 5, <String, dynamic>{
        'conversationId': 'conv-1',
        'seq': 5,
        'kind': 'output',
        'text': '断线 C',
      }),
    ];
    return JsonHttpResponse(
      200,
      jsonEncode(<String, dynamic>{
        'conversationId': 'conv-1',
        'events': events,
        'nextSeq': 6,
      }),
    );
  }
}

Future<PairResult> _fakePairer(String baseUrl, String pairingCode) async =>
    PairResult.fromJson(<String, dynamic>{
      'token': 'tok-1',
      'role': 'app',
      'deviceId': 'device-1',
    });

class _CatchUpHarness {
  _CatchUpHarness() {
    store = LiveStore(
      relayClient: RelayClient(
        connector: (Uri uri) async {
          final socket = _FakeSocket();
          sockets.add(socket);
          return socket;
        },
        initialRetryDelay: const Duration(milliseconds: 10),
        maxRetryDelay: const Duration(milliseconds: 20),
        maxRetries: 3,
      ),
      pairer: _fakePairer,
      historyApi: HistoryApi(sender: rest.send),
    );
  }

  final _FakeEventsRest rest = _FakeEventsRest();
  final List<_FakeSocket> sockets = <_FakeSocket>[];
  late final LiveStore store;

  _FakeSocket get socket => sockets.last;

  Future<void> connect() async {
    await store.connect('https://relay.example.com', code: '824613');
    await pumpEventQueue();
  }

  /// 让服务端确认会话创建，之后实时事件才会落到 conv-1。
  Future<void> openConversation() async {
    socket.serverSend(_frame(
      RelayMessageTypes.conversationCreated,
      <String, dynamic>{'conversationId': 'conv-1', 'sessionId': 'session-1'},
    ));
    await pumpEventQueue();
  }

  void dispose() => store.dispose();
}

void main() {
  group('M2.1 事件增量补拉', () {
    test('events 分页模型：乱序事件按 seq 排序并给出游标', () {
      final page = ConversationEventsPage.fromJson(<String, dynamic>{
        'conversationId': 'conv-1',
        'nextSeq': 9,
        'events': <Map<String, dynamic>>[
          _event(RelayMessageTypes.sessionUpdate, 6, <String, dynamic>{
            'seq': 6,
            'kind': 'output',
            'text': 'b',
          }),
          _event(RelayMessageTypes.sessionUpdate, 4, <String, dynamic>{
            'seq': 4,
            'kind': 'output',
            'text': 'a',
          }),
        ],
      });
      expect(page.conversationId, 'conv-1');
      expect(page.events.map((e) => e.seq).toList(), <int>[4, 6]);
      expect(page.maxSeq, 6);
      expect(page.cursor, 9);
      expect(page.isEmpty, isFalse);

      final relayEvent = page.events.first.toRelayEvent();
      expect(relayEvent.type, RelayMessageTypes.sessionUpdate);
      expect(relayEvent.sessionUpdate!.kind, SessionUpdateKind.output);
      expect(relayEvent.sessionUpdate!.text, 'a');
    });

    test('重连后按 afterSeq=lastSeq 补拉，缺口事件不重复且顺序正确', () async {
      final h = _CatchUpHarness();
      addTearDown(h.dispose);
      await h.connect();
      await h.openConversation();

      // 断线前实时收到 seq 1、2。
      h.socket.serverSend(_sessionOutput(1, '在线一'));
      h.socket.serverSend(_sessionOutput(2, '在线二'));
      await pumpEventQueue();
      expect(h.store.lastSeq, 2);
      expect(h.rest.afterSeqs, isEmpty);

      // 断开 → 自动重连 → 恢复后补拉 afterSeq=2。
      await h.socket.close(1000);
      for (var i = 0; i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        if (h.store.isConnected && h.rest.afterSeqs.isNotEmpty) break;
      }
      await pumpEventQueue();
      expect(h.store.isConnected, isTrue);
      expect(h.rest.afterSeqs.first, 2);
      expect(h.store.lastSeq, 5);
      expect(h.store.catchUpError, isNull);

      final text = h.store.messages
          .where((m) => m.role == ChatRole.assistant)
          .map((m) => m.text)
          .join();
      expect(text.contains('在线一'), isTrue);
      final order = <int>[
        text.indexOf('在线一'),
        text.indexOf('在线二'),
        text.indexOf('断线 A'),
        text.indexOf('断线 B'),
        text.indexOf('断线 C'),
      ];
      expect(order.every((i) => i >= 0), isTrue);
      for (var i = 1; i < order.length; i++) {
        expect(order[i] > order[i - 1], isTrue);
      }
      // 断线期间的每个事件只应用一次（按 seq 去重）。
      expect(_countOccurrences(text, '断线 A'), 1);
      expect(_countOccurrences(text, '断线 C'), 1);

      // 补拉覆盖过的 seq 再从实时流重复到达时应被忽略。
      final before = h.store.messages.length;
      h.socket.serverSend(_sessionOutput(5, '断线 C'));
      await pumpEventQueue();
      expect(h.store.messages.length, before);
    });

    test('实时事件在补拉之外的 seq 继续追加，lastSeq 前进', () async {
      final h = _CatchUpHarness();
      addTearDown(h.dispose);
      await h.connect();
      await h.openConversation();
      h.socket.serverSend(_sessionOutput(1, '第一段'));
      await pumpEventQueue();
      await h.store.catchUpEvents();
      expect(h.rest.afterSeqs, <int>[1]);
      expect(h.store.lastSeq, 5);

      h.socket.serverSend(_sessionOutput(6, '在线六'));
      await pumpEventQueue();
      expect(h.store.lastSeq, 6);
      final text = h.store.messages
          .where((m) => m.role == ChatRole.assistant)
          .map((m) => m.text)
          .join();
      expect(text.contains('在线六'), isTrue);
    });

    test('补拉失败记录 catchUpError，重试成功后清空', () async {
      final h = _CatchUpHarness();
      addTearDown(h.dispose);
      await h.connect();
      await h.openConversation();
      h.socket.serverSend(_sessionOutput(1, '在线一'));
      await pumpEventQueue();

      h.rest.fail = true;
      await h.store.catchUpEvents();
      expect(h.store.catchUpLoading, isFalse);
      expect(h.store.catchUpError, isNotNull);
      expect(h.store.catchUpError, contains('拉取增量事件失败'));
      expect(h.store.lastSeq, 1);
      // 失败不阻塞：实时事件仍可继续应用。
      h.socket.serverSend(_sessionOutput(2, '在线二'));
      await pumpEventQueue();
      expect(h.store.lastSeq, 2);

      h.rest.fail = false;
      await h.store.catchUpEvents();
      expect(h.store.catchUpError, isNull);
      expect(h.store.lastSeq, 5);
      final text = h.store.messages
          .where((m) => m.role == ChatRole.assistant)
          .map((m) => m.text)
          .join();
      expect(_countOccurrences(text, '断线 A'), 1);
      expect(text.contains('断线 C'), isTrue);

      h.store.clearCatchUpError();
      expect(h.store.catchUpError, isNull);
    });

    test('插件直连没有增量事件接口时静默跳过，不弹同步失败', () async {
      final h = _CatchUpHarness();
      addTearDown(h.dispose);
      await h.connect();
      await h.openConversation();
      h.socket.serverSend(_sessionOutput(1, '在线一'));
      await pumpEventQueue();

      h.rest.pluginMode = true;
      await h.store.catchUpEvents();
      expect(h.store.catchUpError, isNull);
      expect(h.store.catchUpLoading, isFalse);
      expect(h.store.lastSeq, 1);

      // 已知接口不存在后不再重复请求。
      final calls = h.rest.afterSeqs.length;
      await h.store.catchUpEvents();
      expect(h.rest.afterSeqs.length, calls);
      expect(h.store.catchUpError, isNull);
    });

    test('App 回到前台触发补拉', () async {
      final h = _CatchUpHarness();
      addTearDown(h.dispose);
      await h.connect();
      await h.openConversation();
      h.socket.serverSend(_sessionOutput(1, '在线一'));
      await pumpEventQueue();
      expect(h.rest.afterSeqs, isEmpty);

      h.store.setAppForeground(false);
      h.store.setAppForeground(true);
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        if (h.rest.afterSeqs.isNotEmpty) break;
      }
      await pumpEventQueue();
      expect(h.rest.afterSeqs.first, 1);
      expect(h.store.lastSeq, 5);
    });

    test('没有会话时补拉是空操作，不触碰网络', () async {
      final h = _CatchUpHarness();
      addTearDown(h.dispose);
      await h.connect();
      await h.store.catchUpEvents();
      expect(h.rest.afterSeqs, isEmpty);
      expect(h.store.catchUpError, isNull);
      expect(h.store.catchUpLoading, isFalse);
    });
  });
}

int _countOccurrences(String source, String needle) {
  if (needle.isEmpty) return 0;
  var count = 0;
  var index = source.indexOf(needle);
  while (index >= 0) {
    count += 1;
    index = source.indexOf(needle, index + needle.length);
  }
  return count;
}
