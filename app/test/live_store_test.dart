import 'dart:async';
import 'dart:convert';

import 'package:deepseek_remote_app/data/live_store.dart';
import 'package:deepseek_remote_app/models.dart';
import 'package:deepseek_remote_app/services/history_api.dart';
import 'package:deepseek_remote_app/services/pairing_api.dart';
import 'package:deepseek_remote_app/services/relay_client.dart';
import 'package:deepseek_remote_app/services/relay_protocol.dart';
import 'package:deepseek_remote_app/services/session_store.dart';
import 'package:flutter_test/flutter_test.dart';

const String _token =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

RelayEvent _eventOf(String type, Map<String, dynamic> payload) {
  return RelayEvent.parse(
    encodeRelayMessage(type: type, payload: payload),
  );
}

/// 不联网的假 WebSocket：记录发出帧，并可注入服务端帧。
class _FakeSocket implements RelaySocket {
  final StreamController<String> _controller =
      StreamController<String>.broadcast();
  final List<String> sent = <String>[];
  int? _closeCode;
  String? _closeReason;

  @override
  Stream<String> get messages => _controller.stream;

  @override
  int? get closeCode => _closeCode;

  @override
  String? get closeReason => _closeReason;

  @override
  void send(String data) => sent.add(data);

  @override
  Future<void> close([int? code, String? reason]) async {
    _closeCode = code;
    _closeReason = reason;
    if (!_controller.isClosed) {
      await _controller.close();
    }
  }

  void serverSend(String raw) {
    if (!_controller.isClosed) _controller.add(raw);
  }
}

class _Harness {
  _Harness({
    PairFunction? pairer,
    HistoryApi? historyApi,
    SessionStore? sessionStore,
    bool connectorFails = false,
  }) {
    _relay = RelayClient(
      connector: (Uri uri) async {
        if (connectorFails) {
          throw const RelayClientException('连接被拒绝');
        }
        connectedUri = uri;
        return socket;
      },
    );
    _store = LiveStore(
      relayClient: _relay,
      historyApi: historyApi,
      sessionStore: sessionStore,
      pairer: pairer ??
          (String baseUrl, String code) async {
            pairedBaseUrl = baseUrl;
            pairedCode = code;
            return PairResult.fromJson(<String, dynamic>{
              'token': _token,
              'role': 'app',
              'deviceId': 'device-1',
              'expiresAt': '2026-11-30T00:00:00.000Z',
            });
          },
    );
  }

  final _FakeSocket socket = _FakeSocket();
  late final RelayClient _relay;
  late final LiveStore _store;

  Uri? connectedUri;
  String? pairedBaseUrl;
  String? pairedCode;

  LiveStore get store => _store;

  Future<void> settle() async {
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> connect({String code = LiveStore.defaultPairingCode}) async {
    await _store.connect('https://relay.example.com', code: code);
    await settle();
  }

  RelayEvent? sentOfType(String type) {
    for (final raw in socket.sent.reversed) {
      final event = RelayEvent.parse(raw);
      if (event.type == type) return event;
    }
    return null;
  }

  Future<void> teardown() async {
    if (_store.connectionState != LiveConnectionState.idle) {
      await _store.disconnect();
      await settle();
    }
    _store.dispose();
  }
}

void main() {
  group('连接流程', () {
    test('连接：规范化地址 → 配对 → 建 wss → 自动创建会话', () async {
      final h = _Harness();
      addTearDown(h.teardown);

      await h.store.connect('relay.example.com', code: '');
      await h.settle();

      expect(h.pairedBaseUrl, 'https://relay.example.com');
      expect(h.pairedCode, LiveStore.defaultPairingCode);
      expect(h.store.connectionState, LiveConnectionState.connected);
      expect(h.store.isConnected, isTrue);
      expect(h.store.isLiveMode, isTrue);
      expect(h.store.token, _token);
      expect(h.store.deviceId, 'device-1');
      expect(h.store.serverUrl, 'https://relay.example.com');

      final uri = h.connectedUri;
      expect(uri, isNotNull);
      expect(uri!.scheme, 'wss');
      expect(uri.path, '/ws');
      expect(uri.queryParameters['role'], 'app');
      expect(uri.queryParameters['token'], _token);

      final create = h.sentOfType(RelayMessageTypes.conversationCreate);
      expect(create, isNotNull);
      expect(create!.payload['title'], isA<String>());
      expect(create.payload.containsKey('workspacePath'), isFalse);
    });

    test('连接失败进入 error 并展示人话错误', () async {
      final h = _Harness(
        pairer: (String baseUrl, String code) async {
          throw const PairingApiException('配对失败：配对码错误或已过期');
        },
      );
      addTearDown(h.teardown);

      await h.store.connect('https://relay.example.com', code: '000000');

      expect(h.store.connectionState, LiveConnectionState.error);
      expect(h.store.errorText, contains('配对失败'));
      expect(h.store.isConnected, isFalse);
    });

    test('地址非法时不发配对请求并直接报错', () async {
      var paired = false;
      final h = _Harness(
        pairer: (String baseUrl, String code) async {
          paired = true;
          return PairResult.fromJson(<String, dynamic>{'token': _token});
        },
      );
      addTearDown(h.teardown);

      await h.store.connect('   ', code: '824613');

      expect(paired, isFalse);
      expect(h.store.connectionState, LiveConnectionState.error);
      expect(h.store.errorText, contains('请先填写电脑端地址'));
    });

    test('断开会清空 token、设备与会话状态', () async {
      final h = _Harness();
      addTearDown(h.teardown);
      await h.connect();
      expect(h.store.isConnected, isTrue);

      await h.store.disconnect();
      await h.settle();

      expect(h.store.connectionState, LiveConnectionState.idle);
      expect(h.store.isConnected, isFalse);
      expect(h.store.token, isNull);
      expect(h.store.deviceId, isNull);
      expect(h.store.deviceStatus, isNull);
      expect(h.store.conversationId, isNull);
      expect(h.store.taskState, isNull);
    });

    test('未连接时发送提示只给出错误提示', () async {
      final h = _Harness();
      addTearDown(h.teardown);

      h.store.sendPrompt('帮我整理桌面');

      expect(h.store.messages, isEmpty);
      expect(h.store.errorText, contains('还未连接真实电脑'));
      expect(h.socket.sent, isEmpty);
    });
  });

  group('session.update 映射', () {
    test('output 增量合并成一条助手消息并进入运行态', () async {
      final h = _Harness();
      addTearDown(h.teardown);
      await h.connect();

      h.socket.serverSend(encodeRelayMessage(
        type: RelayMessageTypes.sessionUpdate,
        payload: <String, dynamic>{
          'conversationId': 'conv-1',
          'kind': 'output',
          'text': '你好',
        },
      ));
      await h.settle();
      h.socket.serverSend(encodeRelayMessage(
        type: RelayMessageTypes.sessionUpdate,
        payload: <String, dynamic>{
          'conversationId': 'conv-1',
          'kind': 'output',
          'text': '，世界',
        },
      ));
      await h.settle();

      final texts = h.store.messages
          .where((ChatItem item) =>
              item.role == ChatRole.assistant &&
              item.kind == ChatItemKind.text)
          .toList();
      expect(texts, hasLength(1));
      expect(texts.single.text, '你好，世界');
      expect(h.store.taskState, TaskStatus.running);
      expect(h.store.isBusy, isTrue);
    });

    test('thinking 卡片独立于正文并可合并', () async {
      final h = _Harness();
      addTearDown(h.teardown);
      await h.connect();

      for (final chunk in <String>['先读取', '文件…']) {
        h.socket.serverSend(encodeRelayMessage(
          type: RelayMessageTypes.sessionUpdate,
          payload: <String, dynamic>{
            'conversationId': 'conv-1',
            'kind': 'thinking',
            'text': chunk,
          },
        ));
      }
      await h.settle();

      final thinking = h.store.messages
          .where((ChatItem item) => item.kind == ChatItemKind.thinking)
          .toList();
      expect(thinking, hasLength(1));
      expect(thinking.single.text, '先读取文件…');
    });

    test('tool_call 与 tool_call_update 更新步骤状态', () async {
      final h = _Harness();
      addTearDown(h.teardown);
      await h.connect();

      h.socket.serverSend(encodeRelayMessage(
        type: RelayMessageTypes.sessionUpdate,
        payload: <String, dynamic>{
          'conversationId': 'conv-1',
          'kind': 'tool_call',
          'callId': 'call-1',
          'tool': 'pwsh',
          'input': <String, dynamic>{'command': 'Get-ChildItem'},
        },
      ));
      await h.settle();

      ChatItem tool = h.store.messages
          .lastWhere((ChatItem item) => item.kind == ChatItemKind.toolCall);
      expect(tool.text, 'pwsh');
      expect(tool.steps, hasLength(1));
      expect(tool.steps.first.status, 'running');
      expect(tool.steps.first.command, 'Get-ChildItem');

      h.socket.serverSend(encodeRelayMessage(
        type: RelayMessageTypes.sessionUpdate,
        payload: <String, dynamic>{
          'conversationId': 'conv-1',
          'kind': 'tool_call_update',
          'callId': 'call-1',
          'status': 'completed',
          'resultExcerpt': '共 3 个文件',
        },
      ));
      await h.settle();

      tool = h.store.messages
          .lastWhere((ChatItem item) => item.kind == ChatItemKind.toolCall);
      expect(tool.steps.first.status, 'done');
      expect(tool.steps.first.output, '共 3 个文件');
    });

    test('usage 更新上下文用量', () async {
      final h = _Harness();
      addTearDown(h.teardown);
      await h.connect();

      h.socket.serverSend(encodeRelayMessage(
        type: RelayMessageTypes.sessionUpdate,
        payload: <String, dynamic>{
          'conversationId': 'conv-1',
          'kind': 'usage',
          'contextUsed': 12000,
          'contextSize': 200000,
        },
      ));
      await h.settle();

      expect(h.store.contextUsed, 12000);
      expect(h.store.contextSize, 200000);
    });
  });

  group('task.state 映射', () {
    test('completed 结束运行态并写入系统提示', () async {
      final h = _Harness();
      addTearDown(h.teardown);
      await h.connect();

      h.socket.serverSend(encodeRelayMessage(
        type: RelayMessageTypes.taskState,
        payload: <String, dynamic>{
          'conversationId': 'conv-1',
          'state': 'completed',
        },
      ));
      await h.settle();

      expect(h.store.taskState, TaskStatus.completed);
      expect(h.store.isBusy, isFalse);
      expect(h.store.messages.last.role, ChatRole.system);
      expect(h.store.messages.last.text, contains('任务已完成'));
    });

    test('failed 带 DEVICE_OFFLINE 映射中文原因', () async {
      final h = _Harness();
      addTearDown(h.teardown);
      await h.connect();

      h.socket.serverSend(encodeRelayMessage(
        type: RelayMessageTypes.taskState,
        payload: <String, dynamic>{
          'conversationId': 'conv-1',
          'state': 'failed',
          'detail': <String, dynamic>{
            'code': 'DEVICE_OFFLINE',
            'message': '电脑离线',
          },
        },
      ));
      await h.settle();

      expect(h.store.taskState, TaskStatus.failed);
      expect(h.store.messages.last.text, contains('电脑 Agent 不在线'));
      expect(h.store.messages.last.text, contains('电脑离线'));
    });
  });

  group('approval 流程', () {
    Future<void> sendApprovalRequest(_Harness h) async {
      h.socket.serverSend(encodeRelayMessage(
        type: RelayMessageTypes.approvalRequest,
        payload: <String, dynamic>{
          'conversationId': 'conv-1',
          'approvalId': 'ap-1',
          'tool': 'pwsh',
          'input': <String, dynamic>{
            'command': r'Remove-Item -Recurse D:\work\build',
          },
          'workspace': r'D:\work',
          'options': [
            <String, dynamic>{'kind': 'allow', 'label': '允许'},
            <String, dynamic>{'kind': 'deny', 'label': '拒绝'},
          ],
          'permissionLevel': 3,
          'riskLevel': 'high',
          'expiresAt': '2026-10-31T05:10:00.000Z',
        },
      ));
      await h.settle();
    }

    test('approval.request 进入等待授权并回传允许', () async {
      final h = _Harness();
      addTearDown(h.teardown);
      await h.connect();
      await sendApprovalRequest(h);

      final pending = h.store.pendingApproval;
      expect(pending, isNotNull);
      expect(pending!.approvalId, 'ap-1');
      expect(pending.tool, 'pwsh');
      expect(pending.command, contains('Remove-Item'));
      expect(pending.workspace, r'D:\work');
      expect(h.store.taskState, TaskStatus.waitingApproval);
      expect(h.store.isBusy, isTrue);
      expect(h.store.messages.last.text, contains('授权请求'));

      h.store.decideApproval(true);
      await h.settle();

      expect(h.store.pendingApproval, isNull);
      expect(h.store.messages.last.text, contains('已允许'));
      final decide = h.sentOfType(RelayMessageTypes.approvalDecide);
      expect(decide, isNotNull);
      expect(decide!.payload['decision'], 'approved');
      expect(decide.payload['approvalId'], 'ap-1');
      expect(decide.payload['conversationId'], 'conv-1');
    });

    test('拒绝授权回传 denied', () async {
      final h = _Harness();
      addTearDown(h.teardown);
      await h.connect();
      await sendApprovalRequest(h);

      h.store.decideApproval(false);
      await h.settle();

      final decide = h.sentOfType(RelayMessageTypes.approvalDecide);
      expect(decide, isNotNull);
      expect(decide!.payload['decision'], 'denied');
      expect(h.store.pendingApproval, isNull);
    });

    test('approval.resolved 清空待授权并写系统提示', () async {
      final h = _Harness();
      addTearDown(h.teardown);
      await h.connect();
      await sendApprovalRequest(h);

      h.socket.serverSend(encodeRelayMessage(
        type: RelayMessageTypes.approvalResolved,
        payload: <String, dynamic>{
          'conversationId': 'conv-1',
          'approvalId': 'ap-1',
          'decision': 'approved',
          'decidedBy': 'phone',
        },
      ));
      await h.settle();

      expect(h.store.pendingApproval, isNull);
      expect(h.store.taskState, TaskStatus.running);
      expect(h.store.messages.last.text, contains('已通过'));
    });
  });

  group('设备与会话事件', () {
    test('device.status 更新设备信息与工作区', () async {
      final h = _Harness();
      addTearDown(h.teardown);
      await h.connect();

      h.store.applyEvent(_eventOf(RelayMessageTypes.deviceStatus,
          <String, dynamic>{
            'online': true,
            'deviceName': 'DESKTOP-REAL',
            'agentVersion': '0.1.0',
            'harnessVersion': '0.2.1',
            'workspaceRoots': [r'D:\work'],
            'lastSeen': '2026-10-31T05:00:00.000Z',
          }));
      await h.settle();

      expect(h.store.deviceName, 'DESKTOP-REAL');
      expect(h.store.deviceOnline, isTrue);
      expect(h.store.agentVersion, '0.1.0');
      expect(h.store.harnessVersion, '0.2.1');
      expect(h.store.workspaceRoots, [r'D:\work']);
    });

    test('conversation.created 记录会话并发送排队提示', () async {
      final h = _Harness();
      addTearDown(h.teardown);
      await h.connect();
      h.store.sendPrompt('整理桌面文件');
      await h.settle();
      expect(h.store.conversationId, isNull);
      expect(h.store.messages.any((ChatItem item) =>
          item.role == ChatRole.user && item.text == '整理桌面文件'), isTrue);

      h.socket.serverSend(encodeRelayMessage(
        type: RelayMessageTypes.conversationCreated,
        payload: <String, dynamic>{
          'conversationId': 'conv-9',
          'sessionId': 'sess-9',
          'workspacePath': r'D:\work',
        },
      ));
      await h.settle();

      expect(h.store.conversationId, 'conv-9');
      expect(h.store.sessionId, 'sess-9');
      expect(h.store.workspacePath, r'D:\work');
      final prompt = h.sentOfType(RelayMessageTypes.promptSend);
      expect(prompt, isNotNull);
      expect(prompt!.payload['conversationId'], 'conv-9');
      expect(prompt.payload['text'], '整理桌面文件');
      expect(h.store.taskState, TaskStatus.queued);
    });

    test('agent.online / error 事件写系统提示', () async {
      final h = _Harness();
      addTearDown(h.teardown);

      h.store.applyEvent(_eventOf(RelayMessageTypes.agentOnline, <String, dynamic>{}));
      await h.settle();
      expect(h.store.messages.last.text, contains('已上线'));

      h.store.applyEvent(_eventOf(RelayMessageTypes.error, <String, dynamic>{
        'code': 'DEVICE_OFFLINE',
        'message': 'agent 离线',
      }));
      await h.settle();
      expect(h.store.errorText, contains('电脑 Agent 不在线'));
      expect(h.store.messages.last.text, contains('出错'));
      expect(h.store.taskState, TaskStatus.queued);
    });

    test('未知类型事件被安全忽略', () async {
      final h = _Harness();
      addTearDown(h.teardown);

      h.store.applyEvent(_eventOf('workflow.unknown', <String, dynamic>{'x': 1}));
      await h.settle();

      expect(h.store.messages, isEmpty);
      expect(h.store.errorText, isNull);
      expect(h.store.connectionState, LiveConnectionState.idle);
    });
  });

  group('RelayClient 协议与 WebSocket 地址', () {
    test('webSocketUri 处理 https / http 与路径', () {
      final secure =
          RelayClient.webSocketUri('https://<公网隧道>.trycloudflare.com', token: 't1');
      expect(secure.scheme, 'wss');
      expect(secure.host, 'abc.trycloudflare.com');
      expect(secure.path, '/ws');
      expect(secure.queryParameters, <String, String>{'role': 'app', 'token': 't1'});

      final local =
          RelayClient.webSocketUri('http://192.168.1.20:8080/', token: 't2');
      expect(local.scheme, 'ws');
      expect(local.host, '192.168.1.20');
      expect(local.port, 8080);
      expect(local.path, '/ws');

      final pasted =
          RelayClient.webSocketUri('wss://relay.example.com/ws', token: 't3');
      expect(pasted.scheme, 'wss');
      expect(pasted.host, 'relay.example.com');
      expect(pasted.path, '/ws');
    });

    test('RelayClient 收发帧并解析事件', () async {
      final socket = _FakeSocket();
      final client = RelayClient(connector: (Uri uri) async => socket);
      addTearDown(client.dispose);
      final events = <RelayEvent>[];
      final subscription = client.events.listen(events.add);
      addTearDown(subscription.cancel);

      await client.connect('https://relay.example.com', token: 'token-1');
      expect(client.isConnected, isTrue);

      expect(
        client.send(RelayMessageTypes.taskCancel,
            <String, dynamic>{'conversationId': 'conv-1'}),
        isTrue,
      );
      final sent = RelayEvent.parse(socket.sent.single);
      expect(sent.type, RelayMessageTypes.taskCancel);
      expect(sent.payload['conversationId'], 'conv-1');

      socket.serverSend(encodeRelayMessage(type: RelayMessageTypes.agentOnline));
      await pumpEventQueue();
      expect(events, hasLength(1));
      expect(events.single.type, RelayMessageTypes.agentOnline);

      await client.disconnect();
      expect(client.state, RelayClientState.idle);
      expect(client.isConnected, isFalse);
      expect(client.send(RelayMessageTypes.conversationCreate), isFalse);
    });
  });

  group('插件直连降级（M2.9.1）', () {
    test('任务接口 404 时静默，任务改由 WSS 推送', () async {
      final h = _Harness(
        historyApi: HistoryApi(
          sender: (method, uri, headers, body) async =>
              const JsonHttpResponse(
            404,
            '{"code":"BAD_REQUEST","message":"not found"}',
          ),
        ),
      );
      addTearDown(h.teardown);
      await h.connect();

      await h.store.loadTasks();
      await h.settle();
      expect(h.store.tasksError, isNull);
      expect(h.store.tasks, isEmpty);

      await h.store.loadTaskDetail('task-1');
      await h.settle();
      expect(h.store.taskDetailError, isNull);
    });

    test('任务 REST 404 后改走桌面镜像并映射状态', () async {
      final h = _Harness(
        historyApi: HistoryApi(
          sender: (method, uri, headers, body) async {
            if (uri.path == HistoryApi.desktopTasksPath) {
              expect(headers['authorization'], startsWith('Bearer '));
              return const JsonHttpResponse(
                200,
                '{"tasks":['
                '{"id":"session-1","title":"示例项目B","workspace":"D:\\\\work","status":"running","progress":0.5,"updatedAt":"2026-11-10T03:41:27.224Z"},'
                '{"id":"session-2","title":"人生记录","workspace":"D:\\\\notes","status":"completed","progress":1,"updatedAt":"2026-11-10T03:40:00.000Z"}'
                ']}',
              );
            }
            return const JsonHttpResponse(
              404,
              '{"code":"BAD_REQUEST","message":"not found"}',
            );
          },
        ),
      );
      addTearDown(h.teardown);
      await h.connect();

      await h.store.loadTasks();
      await h.settle();
      expect(h.store.usesDesktopTaskMirror, isTrue);
      expect(h.store.tasks, hasLength(2));
      expect(h.store.tasks.first.title, '示例项目B');
      expect(h.store.tasks.first.status, TaskStatus.running);
      expect(h.store.tasks.first.progress, 0.5);
      expect(h.store.tasks.last.status, TaskStatus.completed);
    });

    test('桌面会话直播按 seq 增量拉取并映射事件', () async {
      final requests = <Uri>[];
      final h = _Harness(
        historyApi: HistoryApi(
          sender: (method, uri, headers, body) async {
            requests.add(uri);
            expect(headers['authorization'], startsWith('Bearer '));
            return const JsonHttpResponse(
              200,
              '{"sessionId":"session-1","title":"示例项目B","cwd":"D:\\\\work","running":true,"lastSeq":42,'
              '"events":['
              '{"seq":40,"kind":"user","text":"你好"},'
              '{"seq":41,"kind":"tool-call","name":"pwsh","args":"{\\"command\\":\\"ls\\"}","callId":"c1"},'
              '{"seq":42,"kind":"assistant","text":"正在处理"}'
              ']}',
            );
          },
        ),
      );
      addTearDown(h.teardown);
      await h.connect();

      final feed = await h.store.fetchDesktopSession('session-1', afterSeq: 39);
      expect(
        requests.single.path,
        '/api/v1/desktop/sessions/session-1/events',
      );
      expect(requests.single.queryParameters['afterSeq'], '39');
      expect(feed.title, '示例项目B');
      expect(feed.running, isTrue);
      expect(feed.lastSeq, 42);
      expect(feed.events, hasLength(3));
      expect(feed.events[0].kind, 'user');
      expect(feed.events[1].name, 'pwsh');
      expect(feed.events[2].text, '正在处理');
    });

    test('桌面会话里的授权会随直播流返回', () async {
      final h = _Harness(
        historyApi: HistoryApi(
          sender: (method, uri, headers, body) async {
            return const JsonHttpResponse(
              200,
              '{"sessionId":"session-1","title":"示例项目B","cwd":"D:\\\\work","running":true,"lastSeq":7,'
              '"events":[],"approvals":[{"approvalId":"a1","toolName":"pwsh","reason":"删除临时目录","createdAt":1}]}',
            );
          },
        ),
      );
      addTearDown(h.teardown);
      await h.connect();

      final feed = await h.store.fetchDesktopSession('session-1');
      expect(feed.approvals, hasLength(1));
      expect(feed.approvals.single.toolName, 'pwsh');
      expect(feed.approvals.single.reason, '删除临时目录');
    });

    test('手机发桌面指令与应答授权走 POST', () async {
      final posts = <String>[];
      final bodies = <String>[];
      final h = _Harness(
        historyApi: HistoryApi(
          sender: (method, uri, headers, body) async {
            posts.add('$method ${uri.path}');
            if (body != null) bodies.add(jsonEncode(body));
            return const JsonHttpResponse(200, '{"ok":true}');
          },
        ),
      );
      addTearDown(h.teardown);
      await h.connect();

      await h.store.sendDesktopPrompt('session-1', '  看一下构建日志  ');
      await h.store.decideDesktopApproval('session-1', 'a1', approve: true);
      await h.store.decideDesktopApproval('session-1', 'a2', approve: false);

      expect(posts, <String>[
        'POST /api/v1/desktop/sessions/session-1/prompt',
        'POST /api/v1/desktop/sessions/session-1/approvals/a1',
        'POST /api/v1/desktop/sessions/session-1/approvals/a2',
      ]);
      expect(bodies[0], '{"text":"看一下构建日志"}');
      expect(bodies[1], '{"decision":"approve"}');
      expect(bodies[2], '{"decision":"reject"}');
    });

    test('冷启动用保存的 token 直接续连，不再重新配对', () async {
      final saved = _FakeSessionStore(
        saved: const SavedSession(
          serverUrl: 'https://saved.example.com',
          token: 'saved-token',
          deviceId: 'device-9',
        ),
      );
      final h = _Harness(sessionStore: saved);
      addTearDown(h.teardown);

      final ok = await h.store.restoreSession();
      await h.settle();

      expect(ok, isTrue);
      expect(h.store.connectionState, LiveConnectionState.connected);
      expect(h.store.isConnected, isTrue);
      expect(h.store.token, 'saved-token');
      expect(h.store.deviceId, 'device-9');
      expect(h.pairedBaseUrl, isNull);
      expect(saved.loaded, 1);
    });

    test('配对成功会把地址与 token 存下来', () async {
      final saved = _FakeSessionStore();
      final h = _Harness(sessionStore: saved);
      addTearDown(h.teardown);

      await h.store.connect('relay.example.com', code: '123456');
      await h.settle();

      expect(saved.saved, isNotNull);
      expect(saved.saved!.serverUrl, 'https://relay.example.com');
      expect(saved.saved!.token, _token);
      expect(saved.saved!.deviceId, 'device-1');
    });

    test('续连失败清掉存档并回到未连接', () async {
      final saved = _FakeSessionStore(
        saved: const SavedSession(
          serverUrl: 'https://saved.example.com',
          token: 'stale-token',
        ),
      );
      final h = _Harness(sessionStore: saved, connectorFails: true);
      addTearDown(h.teardown);

      final ok = await h.store.restoreSession();
      await h.settle();

      expect(ok, isFalse);
      expect(h.store.connectionState, isNot(LiveConnectionState.connected));
      expect(saved.cleared, 1);
    });

    test('主动断开也会清掉存档', () async {
      final saved = _FakeSessionStore();
      final h = _Harness(sessionStore: saved);
      addTearDown(h.teardown);

      await h.store.connect('relay.example.com', code: '123456');
      await h.settle();
      await h.store.disconnect();

      expect(saved.cleared, 1);
    });
    test('心跳超时判定连接已死并自动重试（不限次数）', () async {
      var attempts = 0;
      final client = RelayClient(
        connector: (Uri uri) async {
          attempts += 1;
          return _FakeSocket();
        },
        initialRetryDelay: const Duration(milliseconds: 20),
        maxRetryDelay: const Duration(milliseconds: 20),
        heartbeatInterval: const Duration(milliseconds: 40),
        heartbeatTimeout: const Duration(milliseconds: 100),
      );
      addTearDown(client.dispose);

      expect(client.maxRetries, 0, reason: '默认无限重试');
      await client.connect('https://relay.example.com', token: 'token-1');
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(attempts, greaterThan(1), reason: '静默连接应被 watchdog 断开并重连');
      await client.disconnect();
    });

    test('回到前台时 ensureReconnected 会用存档 token 连回', () async {
      final saved = _FakeSessionStore(
        saved: const SavedSession(
          serverUrl: 'https://saved.example.com',
          token: 'saved-token',
          deviceId: 'device-9',
        ),
      );
      final h = _Harness(sessionStore: saved);
      addTearDown(h.teardown);

      await h.store.ensureReconnected();
      await h.settle();

      expect(h.store.connectionState, LiveConnectionState.connected);
      expect(h.store.token, 'saved-token');
      expect(h.pairedBaseUrl, isNull, reason: '续连不应重新配对');
      expect(saved.loaded, 1);
    });
  });
}

class _FakeSessionStore extends SessionStore {
  _FakeSessionStore({this.saved});

  SavedSession? saved;
  int loaded = 0;
  int cleared = 0;

  @override
  Future<SavedSession?> load() async {
    loaded += 1;
    return saved;
  }

  @override
  Future<void> save(SavedSession session) async {
    saved = session;
  }

  @override
  Future<void> clear() async {
    cleared += 1;
  }
}
