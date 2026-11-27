import 'dart:io';

import 'package:deepseek_remote_app/services/chat_filter.dart';
import 'package:flutter_test/flutter_test.dart';

/// M4.16：手机点开一个会话，看到的必须是「人说的话 + 模型的回复」，
/// 而且一进去就停在最新一条。
///
/// 用户原话：「每个对话里面的内容你不应该放到最新的吗，而且你这英文是什么，
/// 我要的是对话」。截图里第一条是 Host 的注入
/// （`Time sampled while preparing turn 3, step 24: …`），第二条是模型的英文
/// reasoning（`Header empty. So where does blue come from?…`），而真正的最新内容
/// 在列表更下面 —— 三件事一起坏掉了。
void main() {
  group('M4.16 注入消息过滤', () {
    test('Host 每轮注入的英文上下文都认出来', () {
      const injected = <String>[
        'Time sampled while preparing turn 3, step 24: 2026-11-10T22:49:03+08:00',
        '\n\nTime sampled while preparing turn 9, step 13: 2026-11-16T16:35:20+08:00',
        'Current runtime context. This snapshot supersedes earlier runtime-context snapshots.',
        'Browser time zone for this request: Asia/Shanghai.',
        'Elapsed since the preceding model-visible message: unavailable.',
        '<system-reminder> A skill is a reusable set of task-specific instructions.',
        '<hindsight_knowledge_refresh> Reminder — this repo has memory',
        '<acp tokens="63" type="text">m01812</acp>',
        '   ',
      ];
      for (final text in injected) {
        expect(
          looksInjectedUserText(text),
          isTrue,
          reason: '应判定为注入：${text.substring(0, text.length.clamp(0, 30))}',
        );
      }
    });

    test('人真的说的话不会被误杀', () {
      const human = <String>[
        '继续',
        '每个对话里面的内容你不应该放到最新的吗，而且你这英文是什么，我要的是对话',
        '帮我改一下 dsh-plugin-m1/lib/index.js 里的过滤逻辑',
      ];
      for (final text in human) {
        expect(looksInjectedUserText(text), isFalse, reason: '不该被判为注入：$text');
      }
      // 正文中段引用 system-reminder 不算：只看开头一段。
      final long = '这是一段很长的说明，' * 30 + '<system-reminder> 这种标签怎么处理';
      expect(looksInjectedUserText(long), isFalse);
    });
  });

  group('M4.16 一进来就在最新', () {
    final source =
        File('lib/screens/desktop_session_screen.dart').readAsStringSync();

    test('对话列表改成 reverse，最新一条天然在底部', () {
      expect(source, contains('reverse: true'));
      expect(source, contains('messages[messages.length - 1 - index]'));
      // 以前靠 jumpTo(maxScrollExtent) 猜真实高度，长列表里永远猜不准。
      expect(source, isNot(contains('jumpTo(position.maxScrollExtent)')));
    });

    test('状态条按真实位置说话，不再固定写「已同步到最新」', () {
      expect(source, contains('往上是更早的对话 · 点这里回到最新'));
      expect(source, contains('_scroll.position.pixels < 160'));
    });

    test('阅读器自己也过滤一遍注入（旧插件/旧缓存兜底）', () {
      expect(source, contains('looksInjectedUserText(event.text)'));
    });
  });
}
