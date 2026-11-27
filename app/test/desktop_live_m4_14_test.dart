import 'dart:io';

import 'package:deepseek_remote_app/screens/desktop_session_screen.dart';
import 'package:flutter_test/flutter_test.dart';

/// M4.14：直播页两处「用户被蒙在鼓里」的修正。
///
/// 一、空态要分清「真没内容」和「窗口只够到工具调用」；
/// 二、授权在等手机应答时，标题栏要有常驻计数（正文滚下去也看得见）。
void main() {
  group('M4.14 直播页空态文案', () {
    test('一条事件都没有：说这个会话没内容', () {
      expect(
        liveEmptyHint(hasEvents: false),
        '这个会话还没有可展示的内容',
      );
    });

    test('有事件但没抽到正文：指向工具调用那条，别再让人以为加载失败', () {
      final hint = liveEmptyHint(hasEvents: true);
      // M4.17 起那条不再叫「过程」，改成官方写法的「已完成 · N 次工具调用」。
      expect(hint, contains('工具调用'));
      expect(hint, isNot(contains('还没有可展示的内容')));
    });
  });

  group('M4.14 待应答标记', () {
    test('标题栏挂了「待应答 N」胶囊，且只在有待答时出现', () {
      final source =
          File('lib/screens/desktop_session_screen.dart').readAsStringSync();
      expect(source, contains("'待应答 \${_approvals.length}'"));
      expect(source, contains('if (_approvals.isNotEmpty || _questions.isNotEmpty)'));
    });
  });
}
