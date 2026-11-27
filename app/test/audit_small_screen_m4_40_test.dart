// M4.40 测试审计 · 角度三：又窄又大的字——320x480 + 字号 2.0
//
// 真机里最难看的那种组合：小屏（320x480）+ 系统字号拉满（textScale 2.0）+
// 内容是最长的形态（长提问卡、超长消息、6 列表格、超长代码行）。
// Flutter 的溢出在测试里会以 FlutterError 抛出，所以这里断言「一个异常都没有」。
import 'dart:collection';

import 'package:deepseek_remote_app/data/live_store.dart';
import 'package:deepseek_remote_app/models.dart';
import 'package:deepseek_remote_app/screens/cloud_chat_screen.dart';
import 'package:deepseek_remote_app/screens/desktop_session_screen.dart';
import 'package:deepseek_remote_app/services/cloud_chat.dart';
import 'package:deepseek_remote_app/services/cloud_conversations.dart';
import 'package:deepseek_remote_app/services/history_api.dart';
import 'package:deepseek_remote_app/theme/app_theme.dart';
import 'package:deepseek_remote_app/widgets/markdown_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 320x480 的小屏 + 系统字号 2.0。
Future<void> _tinyScreen(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(320, 480));
  tester.platformDispatcher.textScaleFactorTestValue = 2.0;
  addTearDown(() {
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });
}

Widget _wrap(Widget child) => MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: Scaffold(body: child),
    );

void main() {
  group('M4.40 小屏 + 大字号', () {
    testWidgets('直播页：长提问卡 + 320x480 + 字号 2.0 不溢出，提交仍可点',
        (tester) async {
      await _tinyScreen(tester);
      await tester.pumpWidget(_wrap(DesktopSessionScreen(
        liveStore: _LongQuestionStore(),
        sessionId: 'session-video',
        title: '示例项目E',
      )));
      await tester.pump(const Duration(milliseconds: 200));

      expect(tester.takeException(), isNull);
      // M4.40：320x480 + 2.0 字号下，提问卡放不进一屏是物理事实，所以它退化成
      // 「上半屏可滚」——手指往上一推，提交按钮必须露出来并且点得到。
      final submit = find.widgetWithText(FilledButton, '提交');
      if (submit.hitTestable().evaluate().isEmpty) {
        await tester.drag(
          find.text('电脑在等你回答（2 个问题）'),
          const Offset(0, -220),
        );
        await tester.pump();
      }
      expect(submit.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('直播页：长表格 + 超长代码行的消息，320 宽不溢出', (tester) async {
      await _tinyScreen(tester);
      await tester.pumpWidget(_wrap(DesktopSessionScreen(
        liveStore: _WideContentStore(),
        sessionId: 'session-wide',
        title: '宽内容',
      )));
      await tester.pump(const Duration(milliseconds: 200));

      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('手机档：一条 1200 字的消息 + 320 宽字号 2.0 不溢出', (tester) async {
      await _tinyScreen(tester);
      final long = '这是一条用来压窄屏的消息，' * 60;
      await tester.pumpWidget(_wrap(CloudChatScreen(
        store: _MemoryChatStore(),
        conversations: _MemoryConversationStore(<CloudConversation>[
          CloudConversation(
            id: 'c1',
            createdAt: DateTime(2026, 11, 18, 9),
            updatedAt: DateTime(2026, 11, 18, 10),
            title: '窄屏',
            messages: <CloudChatRecord>[
              CloudChatRecord(role: 'user', text: long),
              CloudChatRecord(role: 'assistant', text: long),
            ],
          ),
        ]),
      )));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      // 输入框还在（没被内容挤没）。
      expect(find.byType(TextField), findsWidgets);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('Markdown：6 列表格 + 200 字符不换行的代码，320 宽不溢出',
        (tester) async {
      await _tinyScreen(tester);
      final table = StringBuffer()
        ..writeln('| 场景 | 用 | 备注 | 风险 | 代价 | 谁来做 |')
        ..writeln('| --- | --- | --- | --- | --- | --- |')
        ..writeln('| 合进 main | merge | 分支合并提交 | 历史分叉 | 大 | 你 |')
        ..writeln('| 跟最新 | rebase | 重放提交 | 哈希全变 | 中 | 你 |');
      final code = 'x' * 200;
      await tester.pumpWidget(_wrap(SingleChildScrollView(
        child: MarkdownText('$table\n```text\n$code\n```\n'),
      )));
      await tester.pump();

      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.binding.setSurfaceSize(null);
    });
  });
}

class _LongQuestionStore extends LiveStore {
  @override
  bool get isConnected => true;
  @override
  String get deviceName => 'DeepSeek Harness';
  @override
  bool get tasksLoading => false;
  @override
  bool get conversationsLoading => false;
  @override
  String? get tasksError => null;
  @override
  bool get usesDesktopTaskMirror => true;
  @override
  List<String> get workspaceRoots => const <String>[];
  @override
  UnmodifiableListView<TaskItem> get tasks =>
      UnmodifiableListView<TaskItem>(const <TaskItem>[]);
  @override
  UnmodifiableListView<ArchivedSession> get archivedSessions =>
      UnmodifiableListView<ArchivedSession>(const <ArchivedSession>[]);
  @override
  Future<void> ensureLiveData({bool force = false}) async {}
  @override
  Future<void> loadTasks({int limit = 50, List<String>? statuses}) async {}
  @override
  Future<void> loadArchivedSessions() async {}
  @override
  Future<DesktopQueue> fetchDesktopQueue(String sessionId) async =>
      const DesktopQueue();

  @override
  Future<DesktopSessionFeed> fetchDesktopSession(
    String sessionId, {
    int? afterSeq,
    int limit = 80,
  }) async {
    return DesktopSessionFeed.fromJson(<String, dynamic>{
      'sessionId': sessionId,
      'title': '示例项目E',
      'cwd': r'D:\Projects\示例项目E',
      'running': true,
      'lastSeq': 2,
      'events': <Map<String, dynamic>>[
        <String, dynamic>{
          'seq': 1,
          'kind': 'user',
          'text': '把歌词也加进去',
          'time': 1763200000000,
        },
      ],
      'questions': <Map<String, dynamic>>[
        <String, dynamic>{
          'questionId': 'call_00_tiny',
          'createdAt': 1763200100000,
          'items': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'q1',
              'header': '时长方案',
              'question': '五段旁白按温柔语速合成后总长 73.9 秒，塞不进 60 秒的版式，怎么处理？',
              'detail': '也可以自己写一句',
              'options': <Map<String, dynamic>>[
                <String, dynamic>{
                  'label': '剪文案到 60 秒（推荐）',
                  'description': '保留金句和结构，语速保持自然温柔',
                },
                <String, dynamic>{
                  'label': '画面跟旁白走，成片约 78 秒',
                  'description': '文案一字不改，节奏更从容',
                },
                <String, dynamic>{
                  'label': '卡死 60 秒，整体提速 1.32 倍',
                  'description': '会损失「舒缓」的感觉',
                },
              ],
            },
            <String, dynamic>{
              'id': 'q2',
              'header': '配乐',
              'question': '轻柔钢琴纯音乐从哪来？',
              'options': <Map<String, dynamic>>[
                <String, dynamic>{
                  'label': '我去找一首可商用的 CC0 钢琴曲',
                  'description': '从免费音乐库下载',
                },
                <String, dynamic>{
                  'label': '暂时不要 BGM，先出纯旁白版',
                  'description': '先看画面和配音对不对',
                },
              ],
            },
          ],
        },
      ],
    });
  }

  @override
  Future<void> answerDesktopQuestion(
    String sessionId,
    String questionId, {
    required List<DesktopQuestionAnswer> answers,
  }) async {}
}

/// 一屏塞满宽内容：6 列表格 + 200 个不换行字符的代码行。
class _WideContentStore extends _LongQuestionStore {
  @override
  Future<DesktopSessionFeed> fetchDesktopSession(
    String sessionId, {
    int? afterSeq,
    int limit = 80,
  }) async {
    final table = StringBuffer()
      ..writeln('| 场景 | 用 | 备注 | 风险 | 代价 | 谁来做 |')
      ..writeln('| --- | --- | --- | --- | --- | --- |')
      ..writeln('| 合进 main | merge | 分支合并提交 | 历史分叉 | 大 | 你 |');
    final code = 'y' * 200;
    return DesktopSessionFeed.fromJson(<String, dynamic>{
      'sessionId': sessionId,
      'title': '宽内容',
      'cwd': r'D:\Projects\宽内容',
      'running': false,
      'lastSeq': 2,
      'events': <Map<String, dynamic>>[
        <String, dynamic>{
          'seq': 1,
          'kind': 'user',
          'text': '给我个对照表',
          'time': 1763200000000,
        },
        <String, dynamic>{
          'seq': 2,
          'kind': 'assistant',
          'text': '$table\n```text\n$code\n```\n',
          'time': 1763200060000,
        },
      ],
    });
  }
}

class _MemoryChatStore extends CloudChatStore {
  CloudChatConfig? config = const CloudChatConfig(
    apiKey: 'sk-test',
    model: 'deepseek-chat',
  );

  @override
  Future<CloudChatConfig?> load() async => config;

  @override
  Future<void> save(CloudChatConfig value) async => config = value;

  @override
  Future<void> clear() async => config = null;
}

class _MemoryConversationStore extends CloudConversationStore {
  _MemoryConversationStore(this.items);

  List<CloudConversation> items;

  @override
  Future<List<CloudConversation>> load() async => items;

  @override
  Future<void> save(List<CloudConversation> next) async => items = next;
}
