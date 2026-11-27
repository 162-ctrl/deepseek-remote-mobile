// M4.35：长提问卡把对话挤没了，整页看起来「划不动」。
//
// 用户原话：「这个页面划不动，而且没有消息通知」。根因：提问卡和授权卡钉在
// 对话列表上方且自己不滚，两个问题三四个选项就把 Expanded 的列表挤成 0 高。
// 这里钉两件事：
//   1. 卡片再长，下面的对话列表仍然有可用高度；
//   2. 卡片自己在里面滚——最后那个选项一开始点不到，拖一下就能点到。
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseek_remote_app/data/live_store.dart';
import 'package:deepseek_remote_app/models.dart';
import 'package:deepseek_remote_app/screens/desktop_session_screen.dart';
import 'package:deepseek_remote_app/services/history_api.dart';
import 'package:deepseek_remote_app/theme/app_theme.dart';

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
        <String, dynamic>{
          'seq': 2,
          'kind': 'assistant',
          'text': '好，我先确认一下样式。',
          'time': 1763200060000,
        },
      ],
      'questions': <Map<String, dynamic>>[
        <String, dynamic>{
          'questionId': 'call_00_long',
          'createdAt': 1763200100000,
          'items': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'q1',
              'header': '时长方案',
              'question': '五段旁白按温柔语速合成后总长 73.9 秒，塞不进 60 秒的版式。怎么处理？',
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
                  'label': '我提供音频文件',
                  'description': '你把 mp3/wav 路径给我',
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

Widget _wrap(Widget child) => MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: child,
    );

void main() {
  group('长提问卡的滚动（M4.35）', () {
    testWidgets('卡片再长也不把对话列表挤成 0 高', (tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 760));
      await tester.pumpWidget(_wrap(DesktopSessionScreen(
        liveStore: _LongQuestionStore(),
        sessionId: 'session-video',
        title: '示例项目E',
      )));
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('电脑在等你回答（2 个问题）'), findsOneWidget);
      // 对话列表还在，而且有能用的高度（以前是 0）。
      final listHeight = tester.getSize(find.byType(ListView).first).height;
      expect(listHeight, greaterThan(120));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('卡片自己可以滚，滚完能看到最后那个选项', (tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 760));
      await tester.pumpWidget(_wrap(DesktopSessionScreen(
        liveStore: _LongQuestionStore(),
        sessionId: 'session-video',
        title: '示例项目E',
      )));
      await tester.pump(const Duration(milliseconds: 200));

      // M4.35.1：用户真正卡住的是「提交不了」——按钮必须一直可点。
      final submit = find.widgetWithText(FilledButton, '提交');
      expect(submit, findsOneWidget);
      expect(submit.hitTestable(), findsOneWidget);

      final lastOption = find.text('暂时不要 BGM，先出纯旁白版');
      expect(lastOption.hitTestable(), findsNothing);

      await tester.drag(find.text('剪文案到 60 秒（推荐）'), const Offset(0, -420));
      await tester.pump();

      expect(lastOption.hitTestable(), findsOneWidget);
      // 滚完之后按钮还在原位可点（选项区滚动不带走它）。
      expect(submit.hitTestable(), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.binding.setSurfaceSize(null);
    });
  });
}
