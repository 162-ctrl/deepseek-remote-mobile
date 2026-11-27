import 'dart:async';
import 'dart:convert';

import 'package:deepseek_remote_app/data/live_store.dart';
import 'package:deepseek_remote_app/models.dart';
import 'package:deepseek_remote_app/services/history_api.dart';
import 'package:deepseek_remote_app/services/pairing_api.dart';
import 'package:deepseek_remote_app/services/relay_client.dart';
import 'package:deepseek_remote_app/services/relay_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

/// 假的 WebSocket：注入服务端帧、记录 App 发出的帧。
class _FakeSocket implements RelaySocket {
  _FakeSocket();

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

  void serverSend(Map<String, dynamic> frame) => _controller.add(jsonEncode(frame));
}

/// 记录被调用的 REST 请求，并按契约返回固定数据。
class _FakeRest {
  final List<Uri> uris = <Uri>[];
  final List<int> messageAfterSeqs = <int>[];
  int conversationsCalls = 0;
  int tasksCalls = 0;
  int taskDetailCalls = 0;
  bool failMessages = false;
  bool failTasks = false;

  Future<JsonHttpResponse> send(
    String method,
    Uri uri,
    Map<String, String> headers,
    Map<String, dynamic>? body,
  ) async {
    uris.add(uri);
    final path = uri.path;
    if (path == HistoryApi.conversationsPath) {
      conversationsCalls++;
      return JsonHttpResponse(
        200,
        jsonEncode(<String, dynamic>{
          'conversations': <Map<String, dynamic>>[
            <String, dynamic>{
              'conversationId': 'conv-1',
              'title': '分析销售数据',
              'workspacePath': r'D:\work\sales-analysis',
              'sessionId': 'session-1',
              'lastMessageAt': '2026-11-01T09:00:00.000Z',
              'messageCount': 4,
            },
          ],
        }),
      );
    }
    if (path.startsWith('/api/v1/conversations/') &&
        path.endsWith('/messages')) {
      final after = int.tryParse(uri.queryParameters['afterSeq'] ?? '0') ?? 0;
      messageAfterSeqs.add(after);
      if (failMessages) {
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
      final messages = after <= 0
          ? <Map<String, dynamic>>[
              <String, dynamic>{
                'seq': 1,
                'role': 'user',
                'kind': 'text',
                'text': '查一下 TODO',
              },
              <String, dynamic>{
                'seq': 2,
                'role': 'assistant',
                'kind': 'text',
                'text': '好的，我先搜索。',
              },
            ]
          : <Map<String, dynamic>>[
              <String, dynamic>{
                'seq': 3,
                'role': 'assistant',
                'kind': 'text',
                'text': '历史输出补一段。',
              },
              <String, dynamic>{
                'seq': 4,
                'role': 'user',
                'kind': 'text',
                'text': '继续',
              },
            ];
      return JsonHttpResponse(
        200,
        jsonEncode(<String, dynamic>{
          'conversationId': 'conv-1',
          'messages': messages,
        }),
      );
    }
    if (path == HistoryApi.tasksPath) {
      tasksCalls++;
      if (failTasks) {
        return JsonHttpResponse(
          500,
          jsonEncode(<String, dynamic>{
            'error': <String, dynamic>{
              'code': 'INTERNAL',
              'message': '数据库未就绪',
            },
          }),
        );
      }
      return JsonHttpResponse(
        200,
        jsonEncode(<String, dynamic>{
          'tasks': <Map<String, dynamic>>[
            <String, dynamic>{
              'taskId': 'task-1',
              'taskName': '分析销售数据',
              'status': 'running',
              'progress': 45,
              'workspacePath': r'D:\work\sales-analysis',
              'startedAt': '2026-11-01T09:00:00.000Z',
            },
            <String, dynamic>{
              'taskId': 'task-2',
              'taskName': '等待授权',
              'status': 'waiting_approval',
              'progress': 80,
            },
          ],
        }),
      );
    }
    if (path.startsWith('/api/v1/tasks/')) {
      taskDetailCalls++;
      final id = path.split('/').last;
      return JsonHttpResponse(
        200,
        jsonEncode(<String, dynamic>{
          'taskId': id,
          'taskName': '分析销售数据',
          'status': 'completed',
          'progress': 100,
          'result': <String, dynamic>{'summary': '完成 3 个图表'},
          'events': <Map<String, dynamic>>[
            <String, dynamic>{
              'seq': 1,
              'at': '2026-11-01T09:00:00.000Z',
              'type': 'tool_call',
              'title': '执行 pwsh',
              'tool': 'pwsh',
              'detail': 'rg -n TODO',
            },
          ],
        }),
      );
    }
    return JsonHttpResponse(
      404,
      jsonEncode(<String, dynamic>{
        'error': <String, dynamic>{'code': 'NOT_FOUND', 'message': '未知接口'},
      }),
    );
  }

  /// 兼容 LiveStore 构造参数里的 PairingApi 注入（本文件只用 HistoryApi）。
  PairingApi get pairingApi => PairingApi(
        sender: (method, uri, body) async =>
            JsonHttpResponse(200, '{"status":"ok"}'),
      );
}

Future<PairResult> _fakePairer(String baseUrl, String pairingCode) async {
  return PairResult.fromJson(<String, dynamic>{
    'token': 'tok-1',
    'role': 'app',
    'deviceId': 'device-1',
    'expiresAt': '2026-12-01T00:00:00.000Z',
  });
}

class _LiveHarness {
  _LiveHarness({
    List<RelaySocket>? sockets,
    bool reconnect = false,
    PairFunction? pairer,
  })  : rest = _FakeRest(),
        sockets = sockets ?? <RelaySocket>[] {
    final connector = (Uri uri) async {
      final socket = _FakeSocket();
      this.sockets.add(socket);
      return socket;
    };
    relay = RelayClient(
      connector: connector,
      initialRetryDelay: reconnect
          ? const Duration(milliseconds: 10)
          : const Duration(seconds: 1),
      maxRetryDelay: const Duration(milliseconds: 20),
      maxRetries: 2,
    );
    store = LiveStore(
      relayClient: relay,
      pairer: pairer ?? _fakePairer,
      historyApi: HistoryApi(sender: rest.send),
    );
  }

  final _FakeRest rest;
  final List<RelaySocket> sockets;
  late final RelayClient relay;
  late final LiveStore store;

  _FakeSocket get socket => sockets.last as _FakeSocket;

  Future<void> connect() async {
    await store.connect('https://relay.example.com', code: '824613');
    await pumpEventQueue();
  }

  Future<void> dispose() async {
    store.dispose();
  }
}

void main() {
  group('M1.1 历史会话 / 任务 REST 接入', () {
    test('连接后不自动拉 REST；ensureLiveData 只拉任务（老后端会话不再请求）且幂等', () async {
      final h = _LiveHarness();
      addTearDown(h.dispose);
      await h.connect();

      expect(h.store.connectionState, LiveConnectionState.connected);
      expect(h.store.isConnected, isTrue);
      expect(h.rest.conversationsCalls, 0,
          reason: '连接本身不应触发 REST，避免旧测试打网络');
      expect(h.rest.tasksCalls, 0);
      expect(h.store.conversations, isEmpty);
      expect(h.store.tasks, isEmpty);

      // 连接后应自动发送 conversation.create（M1 已有行为）。
      final frame = jsonDecode(h.socket.sent.first) as Map<String, dynamic>;
      expect(frame['type'], RelayMessageTypes.conversationCreate);

      await h.store.ensureLiveData();
      // M4.43：`/api/v1/conversations` 是老后端接口，插件直连必然 404，
      // 所以 ensureLiveData 不再请求它（留 0 次就是回归断言）。
      expect(h.rest.conversationsCalls, 0);
      expect(h.rest.tasksCalls, 1);
      expect(h.store.conversations, isEmpty);
      expect(h.store.tasks, hasLength(2));
      expect(h.store.tasks.first.id, 'task-1');
      expect(h.store.tasks.first.status, TaskStatus.running);
      expect(h.store.tasks[1].status, TaskStatus.waitingApproval);
      expect(h.rest.uris.first.toString(), contains('tasks'));

      // 幂等：已拉取过就不再重复请求。
      await h.store.ensureLiveData();
      expect(h.rest.conversationsCalls, 0);
      expect(h.rest.tasksCalls, 1);
    });

    test('未连接时 REST 方法只提示、不发请求', () async {
      final h = _LiveHarness();
      addTearDown(h.dispose);

      await h.store.loadConversations();
      await h.store.loadTasks();
      await h.store.loadTaskDetail('task-1');
      await h.store.ensureLiveData();

      expect(h.rest.uris, isEmpty);
      expect(h.store.errorText, contains('还未连接真实电脑'));
      expect(h.store.conversations, isEmpty);
      expect(h.store.tasks, isEmpty);
    });

    test('打开历史会话：afterSeq=0 回填消息并记录 lastSeq', () async {
      final h = _LiveHarness();
      addTearDown(h.dispose);
      await h.connect();
      await h.store.ensureLiveData();
      // M4.43：ensureLiveData 不再拉老后端的会话列表，这里显式拉一次。
      await h.store.loadConversations();

      await h.store.openConversation(h.store.conversations.first);

      expect(h.store.conversationId, 'conv-1');
      expect(h.store.sessionId, 'session-1');
      expect(h.rest.messageAfterSeqs, <int>[0]);
      expect(h.store.messages, hasLength(2));
      expect(h.store.messages.first.text, '查一下 TODO');
      expect(h.store.lastSeq, 2);
      expect(h.store.historyLoaded, isTrue);
      expect(h.store.historyLoading, isFalse);
      expect(h.store.historyError, isNull);
      expect(h.store.isBusy, isTrue);
    });

    test('增量 syncHistory 以 lastSeq 为 afterSeq，重复消息不重复显示', () async {
      final h = _LiveHarness();
      addTearDown(h.dispose);
      await h.connect();
      await h.store.ensureLiveData();
      await h.store.loadConversations();
      await h.store.openConversation(h.store.conversations.first);

      await h.store.syncHistory();
      expect(h.rest.messageAfterSeqs, <int>[0, 2]);
      expect(h.store.messages, hasLength(4));
      expect(h.store.lastSeq, 4);

      // 实时事件按 seq 追加；seq <= lastSeq 的重复事件被忽略。
      h.store.applyEvent(RelayEvent.fromJson(<String, dynamic>{
        'v': 1,
        'type': RelayMessageTypes.sessionUpdate,
        'payload': <String, dynamic>{
          'conversationId': 'conv-1',
          'seq': 4,
          'kind': 'output',
          'text': '重复事件',
        },
      }));
      expect(h.store.messages, hasLength(4));

      h.store.applyEvent(RelayEvent.fromJson(<String, dynamic>{
        'v': 1,
        'type': RelayMessageTypes.sessionUpdate,
        'payload': <String, dynamic>{
          'conversationId': 'conv-1',
          'seq': 5,
          'kind': 'output',
          'text': '实时输出',
        },
      }));
      expect(h.store.messages, hasLength(5));
      expect(h.store.messages.last.text, contains('实时输出'));
      expect(h.store.lastSeq, 5);
    });

    test('会话消息拉取失败记录 historyError 且可清除', () async {
      // M2：401 会触发一次自动重配对；这里让重配对也失败，模拟确实无法恢复。
      var pairCalls = 0;
      final h = _LiveHarness(
        pairer: (String baseUrl, String pairingCode) async {
          pairCalls++;
          if (pairCalls > 1) {
            throw const PairingApiException('token 已过期');
          }
          return _fakePairer(baseUrl, pairingCode);
        },
      );
      addTearDown(h.dispose);
      await h.connect();
      await h.store.ensureLiveData();
      await h.store.loadConversations();
      h.rest.failMessages = true;

      await h.store.openConversation(h.store.conversations.first);

      expect(h.store.historyError, isNotNull);
      expect(h.store.historyError, contains('认证失败'));
      expect(h.store.historyLoaded, isFalse);
      // M2 自动重配对失败会写入系统提示消息，但不应有历史/实时聊天消息。
      expect(
        h.store.messages.where((message) => message.role != ChatRole.system),
        isEmpty,
      );

      h.store.clearHistoryError();
      expect(h.store.historyError, isNull);
    });

    test('任务列表拉取失败记录 tasksError 且可重试成功', () async {
      final h = _LiveHarness();
      addTearDown(h.dispose);
      await h.connect();
      h.rest.failTasks = true;

      await h.store.loadTasks();
      expect(h.store.tasksError, isNotNull);
      expect(h.store.tasks, isEmpty);
      expect(h.store.tasksLoading, isFalse);

      h.rest.failTasks = false;
      await h.store.loadTasks();
      expect(h.store.tasksError, isNull);
      expect(h.store.tasks, hasLength(2));
      expect(h.store.tasksFetchedAt, isNotNull);
    });

    test('任务详情写入 selectedTask 并回填任务列表中的对应项', () async {
      final h = _LiveHarness();
      addTearDown(h.dispose);
      await h.connect();
      await h.store.ensureLiveData();
      expect(h.store.tasks.first.status, TaskStatus.running);

      await h.store.loadTaskDetail('task-1');

      expect(h.rest.taskDetailCalls, 1);
      expect(h.store.selectedTask, isNotNull);
      expect(h.store.selectedTask!.taskId, 'task-1');
      expect(h.store.selectedTask!.events, hasLength(1));
      expect(h.store.selectedTaskItem!.status, TaskStatus.completed);
      expect(h.store.selectedTaskItem!.result, '完成 3 个图表');
      // 列表里同一任务被刷新为详情里的最新状态。
      expect(
        h.store.tasks.firstWhere((t) => t.id == 'task-1').status,
        TaskStatus.completed,
      );
      expect(h.store.taskDetailLoading, isFalse);
      expect(h.store.taskDetailError, isNull);
    });

    test('任务详情失败记录 taskDetailError', () async {
      final h = _LiveHarness();
      addTearDown(h.dispose);
      await h.connect();

      // 假 REST 只识别 task-1 前缀详情路径；未知路径返回 404。
      await h.store.loadTaskDetail('task-1');
      expect(h.store.taskDetailError, isNull);

      await h.store.loadTaskDetail('  ');
      expect(h.store.taskDetailError, '任务 id 为空');
    });

    test('重连后自动刷新任务（老后端会话不再请求）', () async {
      final h = _LiveHarness(reconnect: true);
      addTearDown(h.dispose);
      await h.connect();
      await h.store.ensureLiveData();
      // M4.43：ensureLiveData 只拉任务，老后端 conversations 一次都不打。
      expect(h.rest.conversationsCalls, 0);
      expect(h.rest.tasksCalls, 1);

      // 模拟链路掉线：关闭当前 socket，RelayClient 以 10ms 退避重连。
      await h.socket.close(1000, 'test drop');
      for (var i = 0; i < 40 && h.rest.tasksCalls < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await pumpEventQueue();
      }

      expect(h.store.isConnected, isTrue, reason: '应已自动重连成功');
      expect(h.rest.conversationsCalls, 0);
      expect(h.rest.tasksCalls, greaterThanOrEqualTo(2));
    });
  });
}
