import 'dart:convert';

import 'package:deepseek_remote_app/services/relay_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

RelayEvent _eventOf(String type, Map<String, dynamic> payload) {
  return RelayEvent.parse(
    jsonEncode(<String, dynamic>{
      'v': 1,
      'type': type,
      'ts': '2026-10-31T05:00:00.000Z',
      'payload': payload,
    }),
  );
}

void main() {
  group('信封编码与解析', () {
    test('encodeRelayMessage 生成 v/type/ts/payload', () {
      final raw = encodeRelayMessage(
        type: RelayMessageTypes.promptSend,
        payload: <String, dynamic>{'conversationId': 'conv-1', 'text': '你好'},
      );
      final json = jsonDecode(raw) as Map<String, dynamic>;
      expect(json['v'], kRelayProtocolVersion);
      expect(json['v'], 1);
      expect(json['type'], 'prompt.send');
      expect(json['ts'], isA<String>());
      expect(json['payload'], <String, dynamic>{
        'conversationId': 'conv-1',
        'text': '你好',
      });
      expect(json.containsKey('id'), isFalse);
    });

    test('保留消息 id 与协议版本，解析回 RelayEvent', () {
      final raw = encodeRelayMessage(
        type: RelayMessageTypes.approvalDecide,
        id: 'msg-1',
        payload: <String, dynamic>{'decision': 'approved'},
      );
      final event = RelayEvent.parse(raw);
      expect(event.id, 'msg-1');
      expect(event.type, RelayMessageTypes.approvalDecide);
      expect(event.ts, isNotNull);
      expect(event.payload['decision'], 'approved');
      expect(event.encode(), raw);
    });

    test('type 与 payload 原样写入信封', () {
      final raw = encodeRelayMessage(
        type: 'session.update',
        payload: <String, dynamic>{'kind': 'output'},
      );
      final event = RelayEvent.parse(raw);
      expect(event.type, 'session.update');
      expect(event.payload['kind'], 'output');
    });

    test('非法 JSON 抛协议异常', () {
      expect(
        () => RelayEvent.parse('not-json'),
        throwsA(isA<RelayProtocolException>()),
      );
    });

    test('非对象 JSON 抛协议异常', () {
      expect(
        () => RelayEvent.parse('[1,2,3]'),
        throwsA(isA<RelayProtocolException>()),
      );
    });

    test('协议版本不匹配抛协议异常', () {
      expect(
        () => RelayEvent.parse('{"v":2,"type":"task.state","payload":{}}'),
        throwsA(isA<RelayProtocolException>()),
      );
    });

    test('缺少 type 抛协议异常', () {
      expect(
        () => RelayEvent.parse('{"v":1,"payload":{}}'),
        throwsA(isA<RelayProtocolException>()),
      );
    });

    test('未知类型不影响解析，强类型 getter 返回 null', () {
      final event = _eventOf('workflow.unknown', <String, dynamic>{'x': 1});
      expect(event.type, 'workflow.unknown');
      expect(event.sessionUpdate, isNull);
      expect(event.taskState, isNull);
      expect(event.approvalRequest, isNull);
      expect(event.approvalResolved, isNull);
      expect(event.deviceStatus, isNull);
      expect(event.conversationCreated, isNull);
      expect(event.relayError, isNull);
    });

    test('newId 生成 msg_ 前缀的非空 id', () {
      final id = RelayEvent.newId();
      expect(id, isNotEmpty);
      expect(id, startsWith('msg_'));
    });
  });

  group('session.update', () {
    test('output 文本', () {
      final event = _eventOf(RelayMessageTypes.sessionUpdate, <String, dynamic>{
        'conversationId': 'conv-1',
        'seq': 2,
        'kind': 'output',
        'text': '报表已经生成。',
      });
      final update = event.sessionUpdate;
      expect(update, isNotNull);
      expect(update!.conversationId, 'conv-1');
      expect(update.seq, 2);
      expect(update.kind, SessionUpdateKind.output);
      expect(update.text, '报表已经生成。');
    });

    test('thinking 文本', () {
      final update = _eventOf(
        RelayMessageTypes.sessionUpdate,
        <String, dynamic>{'conversationId': 'conv-1', 'kind': 'thinking', 'text': '先读取文件…'},
      ).sessionUpdate;
      expect(update!.kind, SessionUpdateKind.thinking);
      expect(update.text, '先读取文件…');
    });

    test('tool_call 提取工具与命令', () {
      final update = _eventOf(
        RelayMessageTypes.sessionUpdate,
        <String, dynamic>{
          'conversationId': 'conv-1',
          'kind': 'tool_call',
          'callId': 'call-1',
          'tool': 'pwsh',
          'input': <String, dynamic>{'command': 'Get-ChildItem'},
        },
      ).sessionUpdate;
      expect(update!.kind, SessionUpdateKind.toolCall);
      expect(update.callId, 'call-1');
      expect(update.tool, 'pwsh');
      expect(toolCommandFromInput(update.input), 'Get-ChildItem');
    });

    test('tool_call_update 状态与结果摘要', () {
      final update = _eventOf(
        RelayMessageTypes.sessionUpdate,
        <String, dynamic>{
          'conversationId': 'conv-1',
          'kind': 'tool_call_update',
          'callId': 'call-1',
          'status': 'completed',
          'resultExcerpt': '共 3 个文件',
        },
      ).sessionUpdate;
      expect(update!.kind, SessionUpdateKind.toolCallUpdate);
      expect(update.status, 'completed');
      expect(update.resultExcerpt, '共 3 个文件');
      expect(toolCallStepStatus(update.status), 'done');
    });

    test('usage 上下文用量', () {
      final update = _eventOf(
        RelayMessageTypes.sessionUpdate,
        <String, dynamic>{
          'conversationId': 'conv-1',
          'kind': 'usage',
          'contextUsed': 12000,
          'contextSize': 200000,
        },
      ).sessionUpdate;
      expect(update!.kind, SessionUpdateKind.usage);
      expect(update.contextUsed, 12000);
      expect(update.contextSize, 200000);
    });

    test('未知 kind 落到 unknown', () {
      final update = _eventOf(
        RelayMessageTypes.sessionUpdate,
        <String, dynamic>{'conversationId': 'conv-1', 'kind': 'future_kind'},
      ).sessionUpdate;
      expect(update!.kind, SessionUpdateKind.unknown);
    });

    test('toolCallStepStatus 映射各状态', () {
      expect(toolCallStepStatus('completed'), 'done');
      expect(toolCallStepStatus('done'), 'done');
      expect(toolCallStepStatus('success'), 'done');
      expect(toolCallStepStatus('failed'), 'failed');
      expect(toolCallStepStatus('error'), 'failed');
      expect(toolCallStepStatus('cancelled'), 'failed');
      expect(toolCallStepStatus('running'), 'running');
      expect(toolCallStepStatus('pending'), 'running');
      expect(toolCallStepStatus(null), 'running');
    });
  });

  group('task.state', () {
    test('running 解析', () {
      final state = _eventOf(RelayMessageTypes.taskState, <String, dynamic>{
        'conversationId': 'conv-1',
        'state': 'running',
      }).taskState;
      expect(state!.state, RelayTaskState.running);
      expect(state.conversationId, 'conv-1');
    });

    test('failed 带 detail 错误码', () {
      final state = _eventOf(RelayMessageTypes.taskState, <String, dynamic>{
        'conversationId': 'conv-1',
        'state': 'failed',
        'detail': <String, dynamic>{
          'code': 'DEVICE_OFFLINE',
          'message': '电脑 Agent 已离线',
        },
      }).taskState;
      expect(state!.state, RelayTaskState.failed);
      expect(state.errorCode, 'DEVICE_OFFLINE');
      expect(state.errorMessage, '电脑 Agent 已离线');
    });

    test('未知状态落到 unknown', () {
      final state = _eventOf(RelayMessageTypes.taskState, <String, dynamic>{
        'state': 'paused',
      }).taskState;
      expect(state!.state, RelayTaskState.unknown);
    });
  });

  group('approval', () {
    test('approval.request 解析工具、命令与风险等级', () {
      final request = _eventOf(
        RelayMessageTypes.approvalRequest,
        <String, dynamic>{
          'conversationId': 'conv-1',
          'approvalId': 'ap-1',
          'tool': 'pwsh',
          'input': <String, dynamic>{
            'command': 'Remove-Item -Recurse build',
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
      ).approvalRequest;
      expect(request, isNotNull);
      expect(request!.approvalId, 'ap-1');
      expect(request.tool, 'pwsh');
      expect(request.command, 'Remove-Item -Recurse build');
      expect(request.workspace, r'D:\work');
      expect(request.permissionLevel, 3);
      expect(request.riskLevel, 'high');
      expect(request.options, hasLength(2));
      expect(request.options.first.kind, 'allow');
      expect(request.options.first.label, '允许');
      expect(request.expiresAt, isNotNull);
    });

    test('approval.request 缺省值兜底', () {
      final request = _eventOf(
        RelayMessageTypes.approvalRequest,
        <String, dynamic>{'conversationId': 'conv-1', 'approvalId': 'ap-2'},
      ).approvalRequest;
      expect(request!.tool, '未知工具');
      expect(request.command, '');
      expect(request.permissionLevel, 6);
      expect(request.riskLevel, 'high');
      expect(request.options, isEmpty);
    });

    test('approval.resolved 手机批准', () {
      final resolved = _eventOf(
        RelayMessageTypes.approvalResolved,
        <String, dynamic>{
          'conversationId': 'conv-1',
          'approvalId': 'ap-1',
          'decision': 'approved',
          'decidedBy': 'phone',
        },
      ).approvalResolved;
      expect(resolved, isNotNull);
      expect(resolved!.approved, isTrue);
      expect(resolved.decision, 'approved');
      expect(resolved.decidedBy, 'phone');
      expect(resolved.readableLabel, contains('已通过'));
      expect(resolved.readableLabel, contains('手机'));
      expect(resolved.systemNotice, contains('授权'));
    });

    test('approval.resolved 拒绝', () {
      final resolved = _eventOf(
        RelayMessageTypes.approvalResolved,
        <String, dynamic>{
          'conversationId': 'conv-1',
          'approvalId': 'ap-1',
          'decision': 'denied',
          'decidedBy': 'timeout',
        },
      ).approvalResolved;
      expect(resolved!.approved, isFalse);
      expect(resolved.systemNotice, contains('授权'));
    });
  });

  group('device / conversation / error', () {
    test('device.status 解析设备能力与工作区', () {
      final status = _eventOf(RelayMessageTypes.deviceStatus, <String, dynamic>{
        'online': true,
        'deviceName': 'DESKTOP-REAL',
        'agentVersion': '0.1.0',
        'harnessVersion': '0.2.1',
        'capabilities': <String, dynamic>{'shell': true},
        'workspaceRoots': [r'D:\work'],
        'lastSeen': '2026-10-31T05:00:00.000Z',
      }).deviceStatus;
      expect(status, isNotNull);
      expect(status!.online, isTrue);
      expect(status.deviceName, 'DESKTOP-REAL');
      expect(status.agentVersion, '0.1.0');
      expect(status.harnessVersion, '0.2.1');
      expect(status.capabilities['shell'], isTrue);
      expect(status.workspaceRoots, [r'D:\work']);
    });

    test('device.status 缺省值兜底', () {
      final status = _eventOf(
        RelayMessageTypes.deviceStatus,
        <String, dynamic>{'online': false},
      ).deviceStatus;
      expect(status!.deviceName, '未知设备');
      expect(status.agentVersion, '未知');
      expect(status.harnessVersion, '未知');
      expect(status.workspaceRoots, isEmpty);
    });

    test('conversation.created 解析会话信息', () {
      final created = _eventOf(
        RelayMessageTypes.conversationCreated,
        <String, dynamic>{
          'conversationId': 'conv-9',
          'sessionId': 'sess-9',
          'workspacePath': r'D:\work\sales',
          'title': '报表分析',
        },
      ).conversationCreated;
      expect(created!.conversationId, 'conv-9');
      expect(created.sessionId, 'sess-9');
      expect(created.workspacePath, r'D:\work\sales');
      expect(created.title, '报表分析');
    });

    test('error 映射为人话', () {
      final error = _eventOf(RelayMessageTypes.error, <String, dynamic>{
        'code': 'SESSION_BUSY',
        'message': 'busy',
        'conversationId': 'conv-1',
      }).relayError;
      expect(error!.code, 'SESSION_BUSY');
      expect(error.friendlyMessage, contains('电脑正忙'));
      expect(error.systemNotice, contains('电脑正忙'));
      expect(error.systemNotice, contains('busy'));
    });

    test('错误码中文映射与未知编码', () {
      expect(describeRelayErrorCode(null), '未知错误');
      expect(describeRelayErrorCode(''), '未知错误');
      expect(describeRelayErrorCode('AUTH_FAILED'), contains('认证失败'));
      expect(describeRelayErrorCode('DEVICE_OFFLINE'), contains('电脑 Agent 不在线'));
      expect(describeRelayErrorCode('NOT_A_REAL_CODE'), contains('NOT_A_REAL_CODE'));
      expect(relayErrorLabels.containsKey('PATH_NOT_ALLOWED'), isTrue);
    });
  });

  group('toolCommandFromInput', () {
    test('null 与字符串', () {
      expect(toolCommandFromInput(null), '');
      expect(toolCommandFromInput('pwsh -c dir'), 'pwsh -c dir');
    });

    test('从命令字段提取', () {
      expect(toolCommandFromInput(<String, dynamic>{'command': 'ls -la'}), 'ls -la');
      expect(toolCommandFromInput(<String, dynamic>{'cmd': 'dir'}), 'dir');
      expect(toolCommandFromInput(<String, dynamic>{'script': 'echo hi'}), 'echo hi');
      expect(toolCommandFromInput(<String, dynamic>{'code': 'print(1)'}), 'print(1)');
    });

    test('无法识别时序列化为文本', () {
      final rendered = toolCommandFromInput(<String, dynamic>{'path': r'D:\work'});
      expect(rendered, contains('path'));
      expect(rendered, contains('work'));
    });
  });
}
