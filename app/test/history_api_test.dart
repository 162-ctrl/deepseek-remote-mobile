import 'dart:convert';
import 'dart:io';

import 'package:deepseek_remote_app/models.dart';
import 'package:deepseek_remote_app/services/history_api.dart';
import 'package:deepseek_remote_app/services/pairing_api.dart';
import 'package:flutter_test/flutter_test.dart';

/// 记录一次注入的 HTTP 调用，便于断言路径 / query / Bearer 头。
class _Recorder {
  final List<Uri> uris = <Uri>[];
  final List<Map<String, String>> headers = <Map<String, String>>[];

  AuthorizedHttpSender handler(
    JsonHttpResponse Function(String method, Uri uri) respond,
  ) {
    return (String method, Uri uri, Map<String, String> h,
        Map<String, dynamic>? body) async {
      uris.add(uri);
      headers.add(h);
      return respond(method, uri);
    };
  }

  Uri get lastUri => uris.last;
}

void main() {
  const String base = 'https://relay.example.com';

  group('HistoryApi 会话列表（契约 §3.1）', () {
    test('解析会话摘要、排序字段与工作区目录名', () async {
      final rec = _Recorder();
      final api = HistoryApi(
        sender: rec.handler(
          (_, __) => JsonHttpResponse(
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
                  'createdAt': '2026-11-01T08:00:00.000Z',
                },
                <String, dynamic>{
                  'conversationId': 'conv-2',
                  'title': '',
                  'messageCount': 'x',
                },
              ],
            }),
          ),
        ),
      );
      final list = await api.conversations(base, token: 'tok-123', limit: 20);

      expect(list, hasLength(2));
      expect(list.first.conversationId, 'conv-1');
      expect(list.first.title, '分析销售数据');
      expect(list.first.workspaceName, 'sales-analysis');
      expect(list.first.messageCount, 4);
      expect(list.first.activityAt.isAtSameMomentAs(
          DateTime.utc(2026, 11, 1, 9)), isTrue);
      // 缺省值兜底，不抛异常。
      expect(list[1].title, '未命名会话');
      expect(list[1].messageCount, 0);
      expect(list[1].workspaceName, '未指定工作区');

      expect(rec.lastUri.path, '/api/v1/conversations');
      expect(rec.lastUri.queryParameters['limit'], '20');
      expect(rec.headers.last[HttpHeaders.authorizationHeader], 'Bearer tok-123');
    });

    test('缺少 conversationId 抛可读异常', () async {
      final api = HistoryApi(
        sender: (_, __, ___, ____) async =>
            JsonHttpResponse(200, jsonEncode(<String, dynamic>{
              'conversations': <Map<String, dynamic>>[
                <String, dynamic>{'title': '没有 id'},
              ],
            })),
      );
      await expectLater(
        api.conversations(base, token: 'tok'),
        throwsA(isA<PairingApiException>()),
      );
    });

    test('没有 conversations 列表时抛可读异常', () async {
      final api = HistoryApi(
        sender: (_, __, ___, ____) async => JsonHttpResponse(200, '{}'),
      );
      await expectLater(
        api.conversations(base, token: 'tok'),
        throwsA(
          isA<PairingApiException>().having(
            (e) => e.message,
            'message',
            contains('conversations 列表'),
          ),
        ),
      );
    });
  });

  group('HistoryApi 历史消息（契约 §3.2）', () {
    test('按 seq 升序返回并带 afterSeq / limit 查询参数', () async {
      final rec = _Recorder();
      final api = HistoryApi(
        sender: rec.handler(
          (_, __) => JsonHttpResponse(
            200,
            jsonEncode(<String, dynamic>{
              'conversationId': 'conv 1',
              'messages': <Map<String, dynamic>>[
                <String, dynamic>{
                  'seq': 5,
                  'role': 'assistant',
                  'kind': 'text',
                  'text': '第二条',
                  'createdAt': '2026-11-01T09:05:00.000Z',
                },
                <String, dynamic>{
                  'seq': 2,
                  'role': 'user',
                  'kind': 'text',
                  'text': '第一条',
                },
              ],
            }),
          ),
        ),
      );
      final page = await api.messages(
        base,
        token: 'tok',
        conversationId: 'conv 1',
        afterSeq: 1,
      );

      expect(page.conversationId, 'conv 1');
      expect(page.messages.map((m) => m.seq), <int>[2, 5]);
      expect(page.maxSeq, 5);
      expect(rec.lastUri.path, '/api/v1/conversations/conv%201/messages');
      expect(rec.lastUri.queryParameters['afterSeq'], '1');
      expect(rec.lastUri.queryParameters['limit'], '200');
    });

    test('历史消息映射为聊天视图：user / thinking / tool_call / tool_result / system',
        () {
      final page = ConversationMessagesPage.fromJson(<String, dynamic>{
        'messages': <Map<String, dynamic>>[
          <String, dynamic>{
            'seq': 1,
            'role': 'user',
            'kind': 'text',
            'text': '查一下 TODO',
          },
          <String, dynamic>{
            'seq': 2,
            'role': 'assistant',
            'kind': 'thinking',
            'text': '先搜索 TODO',
          },
          <String, dynamic>{
            'seq': 3,
            'role': 'assistant',
            'kind': 'tool_call',
            'text': '{"tool":"pwsh","input":{"command":"rg -n TODO"}}',
            'metadata': <String, dynamic>{
              'status': 'completed',
              'durationMs': 1200,
              'exitCode': 0,
            },
          },
          <String, dynamic>{
            'seq': 4,
            'role': 'assistant',
            'kind': 'tool_result',
            'text': 'found 2 matches',
            'toolName': 'pwsh',
            'metadata': <String, dynamic>{'status': 'failed'},
          },
          <String, dynamic>{
            'seq': 5,
            'role': 'system',
            'kind': 'system',
            'text': '任务已完成。',
          },
        ],
      }, fallbackConversationId: 'conv-1');

      final items = page.toChatItems();
      expect(items[0].role, ChatRole.user);
      expect(items[1].kind, ChatItemKind.thinking);
      expect(items[1].text, '先搜索 TODO');

      final call = items[2];
      expect(call.kind, ChatItemKind.toolCall);
      expect(call.text, 'pwsh');
      expect(call.steps.first.command, 'rg -n TODO');
      expect(call.steps.first.status, 'done');
      expect(call.steps.first.durationMs, 1200);
      expect(call.steps.first.exitCode, 0);

      final result = items[3];
      expect(result.kind, ChatItemKind.toolResult);
      expect(result.steps.first.output, 'found 2 matches');
      expect(result.steps.first.status, 'failed');

      expect(items[4].role, ChatRole.system);
      expect(items[4].text, '任务已完成。');
    });

    test('空会话 id 直接抛错', () async {
      final api = HistoryApi(sender: (_, __, ___, ____) async {
        fail('不应该发出请求');
      });
      await expectLater(
        api.messages(base, token: 'tok', conversationId: '  '),
        throwsA(isA<PairingApiException>()),
      );
    });
  });

  group('tool_call 文本解析', () {
    test('JSON 文本提取工具与命令', () {
      final call = parseToolCallText(
        '{"tool":"pwsh","input":{"command":"rg -n TODO"}}',
      );
      expect(call.tool, 'pwsh');
      expect(call.command, 'rg -n TODO');
    });

    test('input 为字符串时原样作为命令', () {
      final call = parseToolCallText('{"tool":"pwsh","input":"ls -la"}');
      expect(call.tool, 'pwsh');
      expect(call.command, 'ls -la');
    });

    test('纯文本命令与 fallback 工具名', () {
      final call = parseToolCallText('rg -n TODO', fallbackTool: 'pwsh');
      expect(call.tool, 'pwsh');
      expect(call.command, 'rg -n TODO');
    });

    test('畸形 JSON 不抛异常，按纯文本处理', () {
      final call = parseToolCallText('{"tool": ', fallbackTool: 'pwsh');
      expect(call.command, '{"tool":');
    });
  });

  group('HistoryApi 任务（契约 §3.3）', () {
    test('任务列表带状态过滤并映射为任务卡模型', () async {
      final rec = _Recorder();
      final api = HistoryApi(
        sender: rec.handler(
          (_, __) => JsonHttpResponse(
            200,
            jsonEncode(<String, dynamic>{
              'tasks': <Map<String, dynamic>>[
                <String, dynamic>{
                  'taskId': 'task-1',
                  'conversationId': 'conv-1',
                  'taskName': '分析销售数据',
                  'status': 'completed',
                  'progress': 100,
                  'workspacePath': r'D:\work\sales-analysis',
                  'result': <String, dynamic>{'summary': '完成 3 个图表'},
                  'createdAt': '2026-11-01T08:00:00.000Z',
                  'finishedAt': '2026-11-01T08:10:00.000Z',
                },
                <String, dynamic>{
                  'taskId': 'task-2',
                  'taskName': '等待授权',
                  'status': 'waiting_approval',
                  'progress': 40,
                  'errorMessage': '需要确认',
                },
              ],
            }),
          ),
        ),
      );
      final records = await api.tasks(
        base,
        token: 'tok',
        limit: 10,
        statuses: const <String>['running', 'waiting_approval'],
      );

      expect(records, hasLength(2));
      final done = records.first.toTaskItem();
      expect(done.id, 'task-1');
      expect(done.title, '分析销售数据');
      expect(done.status, TaskStatus.completed);
      expect(done.progress, 1.0);
      expect(done.workspace, r'D:\work\sales-analysis');
      expect(done.result, '完成 3 个图表');
      expect(done.conversationId, 'conv-1');

      final waiting = records[1].toTaskItem();
      expect(waiting.status, TaskStatus.waitingApproval);
      expect(waiting.progress, 0.4);
      expect(waiting.workspace, '—');
      expect(waiting.errorCode, '需要确认');

      expect(rec.lastUri.path, '/api/v1/tasks');
      expect(rec.lastUri.queryParameters['limit'], '10');
      expect(rec.lastUri.queryParameters['status'], 'running,waiting_approval');
    });

    test('任务详情解析 events 时间线', () async {
      final rec = _Recorder();
      final api = HistoryApi(
        sender: rec.handler(
          (_, __) => JsonHttpResponse(
            200,
            jsonEncode(<String, dynamic>{
              'taskId': 'task-9',
              'taskName': '清理日志',
              'status': 'failed',
              'progress': 30,
              'errorCode': 'INTERNAL',
              'events': <Map<String, dynamic>>[
                <String, dynamic>{
                  'seq': 1,
                  'at': '2026-11-01T08:00:00.000Z',
                  'type': 'tool_call',
                  'title': '执行 pwsh',
                  'tool': 'pwsh',
                  'detail': 'rm -rf logs/*',
                },
                <String, dynamic>{
                  'seq': 2,
                  'at': '2026-11-01T08:00:05.000Z',
                  'type': 'failed',
                  'title': '任务失败',
                  'detail': 'exit 1',
                },
              ],
            }),
          ),
        ),
      );
      final record = await api.taskDetail(base, token: 'tok', taskId: 'task-9');

      expect(record.taskId, 'task-9');
      expect(record.taskStatus, TaskStatus.failed);
      expect(record.events, hasLength(2));
      expect(record.events.first.isToolCall, isTrue);
      expect(record.events.first.done, isTrue);
      expect(record.events.first.toTaskEvent().type, 'tool_call');
      expect(record.events[1].isFailure, isTrue);
      expect(record.events[1].toTaskEvent().type, 'failed');
      expect(record.events[1].toTaskEvent().done, isFalse);
      expect(rec.lastUri.path, '/api/v1/tasks/task-9');
    });

    test('任务数据缺少 taskId 抛可读异常', () {
      expect(
        () => TaskRecord.fromJson(const <String, dynamic>{}),
        throwsA(isA<PairingApiException>()),
      );
    });

    test('空任务 id 不发请求', () async {
      final api = HistoryApi(sender: (_, __, ___, ____) async {
        fail('不应该发出请求');
      });
      await expectLater(
        api.taskDetail(base, token: 'tok', taskId: ''),
        throwsA(isA<PairingApiException>()),
      );
    });
  });

  group('HistoryApi 错误映射', () {
    test('401 提示重新配对并带 code', () async {
      final api = HistoryApi(
        sender: (_, __, ___, ____) async => JsonHttpResponse(
          401,
          jsonEncode(<String, dynamic>{
            'error': <String, dynamic>{
              'code': 'AUTH_FAILED',
              'message': 'token 已过期',
            },
          }),
        ),
      );
      await expectLater(
        api.conversations(base, token: 'bad'),
        throwsA(
          isA<PairingApiException>()
              .having((e) => e.code, 'code', 'AUTH_FAILED')
              .having((e) => e.message, 'message', contains('认证失败')),
        ),
      );
    });

    test('404 用契约错误体映射为人话', () async {
      final api = HistoryApi(
        sender: (_, __, ___, ____) async => JsonHttpResponse(
          404,
          jsonEncode(<String, dynamic>{
            'error': <String, dynamic>{
              'code': 'CONVERSATION_NOT_FOUND',
              'message': '找不到会话',
            },
          }),
        ),
      );
      await expectLater(
        api.messages(base, token: 'tok', conversationId: 'gone'),
        throwsA(
          isA<PairingApiException>()
              .having((e) => e.statusCode, 'statusCode', 404)
              .having((e) => e.message, 'message', contains('拉取历史消息失败')),
        ),
      );
    });

    test('2xx 但非 JSON 内容报可读异常', () async {
      final api = HistoryApi(
        sender: (_, __, ___, ____) async => JsonHttpResponse(200, '<html>oops</html>'),
      );
      await expectLater(
        api.tasks(base, token: 'tok'),
        throwsA(
          isA<PairingApiException>().having(
            (e) => e.message,
            'message',
            contains('不是合法 JSON'),
          ),
        ),
      );
    });

    test('authHeaders 生成 Bearer 与 Accept', () {
      final headers = HistoryApi.authHeaders('  tok-abc  ');
      expect(headers[HttpHeaders.authorizationHeader], 'Bearer tok-abc');
      expect(headers[HttpHeaders.acceptHeader], 'application/json');
    });
  });
}
