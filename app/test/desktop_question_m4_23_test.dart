// M4.23：电脑端「确认需求」提问卡，手机上也能回答。
//
// 用户原话：「这个需要审核操作的手机上还是没有」。截图里那张卡其实是
// `ask_user_question` 工具弹的（选项 + 「输入你的答案」+ 跳过/提交），走的是
// `user-questions/request`，以前手机端根本没接。这里验证三件事：
//   1. 有提问时卡片出现，选项、标题、徽标都对；
//   2. 选一个选项再提交，答案带着 selected 发回电脑，卡片消失；
//   3. 点「跳过」发的是空答案（Host 会当作用户什么都没选）。
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseek_remote_app/data/live_store.dart';
import 'package:deepseek_remote_app/models.dart';
import 'package:deepseek_remote_app/screens/desktop_session_screen.dart';
import 'package:deepseek_remote_app/services/history_api.dart';
import 'package:deepseek_remote_app/theme/app_theme.dart';

class _FakeQuestionStore extends LiveStore {
  _FakeQuestionStore({required this.shouldAsk});

  /// 第一次拉取时下发问题，回答之后就没了（和电脑端行为一致）。
  bool shouldAsk;

  final List<String> answered = <String>[];
  bool _loadedOnce = false;

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
    final first = !_loadedOnce;
    _loadedOnce = true;
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
        if (shouldAsk && first)
          <String, dynamic>{
            'questionId': 'call_00_pzW16',
            'createdAt': 1763200100000,
            'items': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'q1',
                'header': '歌词样式',
                'question': '歌词字幕想要什么形式？',
                'detail': 'MV 是剪纸水彩风',
                'multiSelect': false,
                'options': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'label': '手写体 / 衬线字',
                    'description': '与剪纸水彩风格统一',
                  },
                  <String, dynamic>{
                    'label': '干净的无衬线白字 + 细描边',
                    'description': '可读性最强',
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
  }) async {
    final parts = answers
        .map((answer) => '${answer.id}:${answer.selected.join('|')}'
            '${answer.custom.isEmpty ? '' : '+${answer.custom}'}')
        .join(',');
    answered.add('$sessionId/$questionId/$parts');
    shouldAsk = false;
  }
}

Widget _wrap(Widget child) => MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: child,
    );

void main() {
  group('手机回答电脑的提问（M4.23）', () {
    testWidgets('提问卡出现，选一项提交后答案发回电脑', (tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 900));
      final store = _FakeQuestionStore(shouldAsk: true);
      await tester.pumpWidget(_wrap(DesktopSessionScreen(
        liveStore: store,
        sessionId: 'session-video',
        title: '示例项目E',
      )));
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('电脑在等你回答'), findsOneWidget);
      expect(find.text('歌词字幕想要什么形式？'), findsOneWidget);
      expect(find.text('待回答 1'), findsOneWidget);
      expect(find.text('手写体 / 衬线字'), findsOneWidget);
      expect(find.text('干净的无衬线白字 + 细描边'), findsOneWidget);

      await tester.tap(find.text('手写体 / 衬线字'));
      await tester.pump();
      await tester.tap(find.text('提交'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        store.answered,
        <String>['session-video/call_00_pzW16/q1:手写体 / 衬线字'],
      );
      expect(find.text('电脑在等你回答'), findsNothing);
      expect(find.text('待回答 1'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('没选就提交，按钮是禁用的', (tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 900));
      final store = _FakeQuestionStore(shouldAsk: true);
      await tester.pumpWidget(_wrap(DesktopSessionScreen(
        liveStore: store,
        sessionId: 'session-video',
        title: '示例项目E',
      )));
      await tester.pump(const Duration(milliseconds: 200));

      final submit = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '提交'),
      );
      expect(submit.onPressed, isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('跳过时发的是空答案', (tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 900));
      final store = _FakeQuestionStore(shouldAsk: true);
      await tester.pumpWidget(_wrap(DesktopSessionScreen(
        liveStore: store,
        sessionId: 'session-video',
        title: '示例项目E',
      )));
      await tester.pump(const Duration(milliseconds: 200));

      await tester.tap(find.text('跳过'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(store.answered, <String>['session-video/call_00_pzW16/']);
      expect(find.text('电脑在等你回答'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.binding.setSurfaceSize(null);
    });
  });
}
