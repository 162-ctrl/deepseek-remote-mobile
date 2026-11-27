import 'dart:async';
import 'dart:convert';

import 'package:deepseek_remote_app/data/live_store.dart';
import 'package:deepseek_remote_app/services/history_api.dart';
import 'package:deepseek_remote_app/services/pairing_api.dart';
import 'package:deepseek_remote_app/services/relay_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// 假 WebSocket：可被服务端「关闭」以触发 4401 认证失效路径。
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
}

/// 只实现会话列表：第一次返回 401，之后返回 200（验证自动重配对后重试）。
class _FakeRest {
  _FakeRest({required this.failFirstConversations});

  final bool failFirstConversations;
  int conversationsCalls = 0;

  Future<JsonHttpResponse> send(
    String method,
    Uri uri,
    Map<String, String> headers,
    Map<String, dynamic>? body,
  ) async {
    if (uri.path == HistoryApi.conversationsPath) {
      conversationsCalls++;
      if (failFirstConversations && conversationsCalls == 1) {
        return JsonHttpResponse(
          401,
          jsonEncode(<String, dynamic>{
            'error': <String, dynamic>{
              'code': 'AUTH_FAILED',
              'message': 'token 已过期',
            },
          }),
        );
      }
      return JsonHttpResponse(
        200,
        jsonEncode(<String, dynamic>{
          'conversations': <Map<String, dynamic>>[
            <String, dynamic>{
              'conversationId': 'conv-1',
              'title': '修复后的会话',
              'messageCount': 2,
              'lastMessageAt': '2026-11-02T10:00:00.000Z',
            },
          ],
        }),
      );
    }
    return JsonHttpResponse(
      404,
      jsonEncode(<String, dynamic>{
        'error': <String, dynamic>{'code': 'NOT_FOUND', 'message': 'not found'},
      }),
    );
  }
}

class _RepairHarness {
  _RepairHarness({
    this.failPairAfterFirst = false,
    bool failFirstConversations = false,
  }) {
    rest = _FakeRest(failFirstConversations: failFirstConversations);
    pairer = (String baseUrl, String code) async {
      pairCalls++;
      lastBaseUrl = baseUrl;
      lastCode = code;
      if (failPairAfterFirst && pairCalls > 1) {
        throw const PairingApiException('配对码错误或已过期');
      }
      return PairResult.fromJson(<String, dynamic>{
        'token': 'tok-$pairCalls',
        'role': 'app',
        'deviceId': 'device-$pairCalls',
      });
    };
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
      pairer: pairer,
      historyApi: HistoryApi(sender: rest.send),
    );
  }

  final bool failPairAfterFirst;
  late final _FakeRest rest;
  late final PairFunction pairer;
  late final RelayClient relay;
  late final LiveStore store;
  final List<_FakeSocket> sockets = <_FakeSocket>[];
  int pairCalls = 0;
  String? lastBaseUrl;
  String? lastCode;

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
  group('M2 自动重配对', () {
    test('WSS 4401：自动重新配对并重连，成功后静默继续', () async {
      final h = _RepairHarness();
      addTearDown(h.dispose);
      await h.connect();
      expect(h.pairCalls, 1);
      expect(h.sockets, hasLength(1));

      await h.socket.close(4401, 'auth expired');
      await pumpEventQueue();

      expect(h.pairCalls, 2);
      expect(h.lastBaseUrl, 'https://relay.example.com');
      expect(h.lastCode, '824613');
      expect(h.sockets, hasLength(2));
      expect(h.store.isConnected, isTrue);
      expect(h.store.token, 'tok-2');
      expect(h.store.errorText, isNull);
      expect(
        h.store.messages.any(
          (message) => message.text.contains('已自动重新配对并恢复连接'),
        ),
        isTrue,
      );
    });

    test('REST 401：自动重配对后重试一次请求成功', () async {
      final h = _RepairHarness(failFirstConversations: true);
      addTearDown(h.dispose);
      await h.connect();
      expect(h.pairCalls, 1);

      await h.store.loadConversations();
      await pumpEventQueue();

      // 第 1 次 401 → 自动重配对 → 第 2 次重试成功；
      // 重连后的连接恢复刷新可能再拉一次，因此只断言「至少重试过一次」。
      expect(h.rest.conversationsCalls, greaterThanOrEqualTo(2));
      expect(h.rest.conversationsCalls, greaterThan(1));
      expect(h.store.conversationsError, isNull);
      expect(h.store.conversations, hasLength(1));
      expect(h.store.conversations.first.title, '修复后的会话');
      expect(h.pairCalls, 2);
      expect(h.store.token, 'tok-2');
      expect(h.store.isConnected, isTrue);
    });

    test('重配对失败：给出可操作提示并回到连接失败态', () async {
      final h = _RepairHarness(failPairAfterFirst: true);
      addTearDown(h.dispose);
      await h.connect();
      expect(h.pairCalls, 1);

      await h.socket.close(4401);
      await pumpEventQueue();

      expect(h.pairCalls, 2);
      expect(h.store.connectionState, LiveConnectionState.error);
      expect(h.store.errorText, contains('自动重新配对失败'));
      expect(h.store.errorText, contains('请到连接页重新配对'));
    });

    test('手动断开后不会再自动重配对', () async {
      final h = _RepairHarness();
      addTearDown(h.dispose);
      await h.connect();
      await h.store.disconnect();
      await pumpEventQueue();

      // 模拟旧连接迟到的认证失效事件：不应重新配对。
      await h.socket.close(4401);
      await pumpEventQueue();
      expect(h.pairCalls, 1);
      expect(h.store.isConnected, isFalse);
    });
  });
}
