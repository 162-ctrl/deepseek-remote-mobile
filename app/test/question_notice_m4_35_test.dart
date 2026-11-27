// M4.35：电脑在等你回答时，手机上要发系统通知。
//
// 用户原话：「这个页面划不动，而且没有消息通知」。划不动是排版问题（见
// desktop_question_scroll_m4_35_test.dart），这里只钉通知这一半：
//   1. 新提问 → 发一条「电脑在等你回答」通知（走「等待授权提醒」的开关）；
//   2. 同一个提问不重复发（5 秒轮询会反复读到）；
//   3. 提问答完（列表里没了）→ 把通知收回；
//   4. 开关关掉 → 一条都不发。
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseek_remote_app/data/live_store.dart';
import 'package:deepseek_remote_app/services/history_api.dart';
import 'package:deepseek_remote_app/services/notification_gateway.dart';
import 'package:deepseek_remote_app/services/notification_prefs.dart';
import 'package:deepseek_remote_app/services/settings_gateway.dart';

DesktopPendingQuestion _question({
  String questionId = 'call_00_pzW16',
  String sessionId = 'session-video',
}) =>
    DesktopPendingQuestion(
      sessionId: sessionId,
      questionId: questionId,
      count: 1,
      createdAt: 1763200100000,
      header: '歌词样式',
      question: '歌词字幕想要什么形式？',
      title: '示例项目E',
    );

void main() {
  group('电脑在等你回答的通知（M4.35）', () {
    late FakeNotificationGateway gateway;
    late LiveStore store;

    setUp(() async {
      gateway = FakeNotificationGateway();
      store = LiveStore(notificationGateway: gateway);
      await store.attachNotificationPrefs(NotificationPrefs(gateway: FakeSettingsGateway()));
    });

    tearDown(() {
      store.dispose();
    });

    test('新提问发一条通知，标题点明「在等你回答」', () async {
      await store.notePendingQuestions(<DesktopPendingQuestion>[_question()]);

      expect(gateway.taskUpdates, hasLength(1));
      final notice = gateway.taskUpdates.single;
      expect(notice['key'], 'question-call_00_pzW16');
      expect(notice['title'], contains('电脑在等你回答'));
      expect(notice['title'], contains('歌词样式'));
      expect(notice['body'], contains('歌词字幕想要什么形式'));
      expect(store.pendingNotificationRoute, 'tasks');
    });

    test('同一个提问不重复发', () async {
      await store.notePendingQuestions(<DesktopPendingQuestion>[_question()]);
      await store.notePendingQuestions(<DesktopPendingQuestion>[_question()]);

      expect(gateway.taskUpdates, hasLength(1));
    });

    test('提问答完后把通知收回', () async {
      await store.notePendingQuestions(<DesktopPendingQuestion>[_question()]);
      await store.notePendingQuestions(const <DesktopPendingQuestion>[]);

      expect(gateway.canceledTaskUpdates, <String>['question-call_00_pzW16']);
    });

    test('关掉「等待授权提醒」就一条都不发', () async {
      await store.setApprovalNotifications(false);
      await store.notePendingQuestions(<DesktopPendingQuestion>[_question()]);

      expect(gateway.taskUpdates, isEmpty);
    });

    test('两个不同会话的提问各发一条', () async {
      await store.notePendingQuestions(<DesktopPendingQuestion>[
        _question(questionId: 'q-a', sessionId: 'session-a'),
        _question(questionId: 'q-b', sessionId: 'session-b'),
      ]);

      expect(
        gateway.taskUpdates.map((notice) => notice['key']).toList(),
        <String>['question-q-a', 'question-q-b'],
      );
    });
  });
}
