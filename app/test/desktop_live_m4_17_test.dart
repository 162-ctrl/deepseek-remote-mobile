import 'dart:io';

import 'package:deepseek_remote_app/screens/desktop_session_screen.dart';
import 'package:flutter_test/flutter_test.dart';

/// M4.17：把「桌面直播」做成官方 App 里那种对话排版。
///
/// 三处差别：
/// 一、助手回复不再套卡片，就是正文；
/// 二、「过程 · N 步（点开看）」换成官方写法「已完成 · N 次工具调用」；
/// 三、顶部是一条胶囊，副标题写「本机 · 目录名」而不是一长串绝对路径。
void main() {
  final source =
      File('lib/screens/desktop_session_screen.dart').readAsStringSync();

  group('M4.17 助手回复不套卡片', () {
    test('列表里直接返回正文行，没有 lineSoft 卡片 + 左侧 accent 竖条', () {
      expect(source, contains('return _EventRow(event: event);'));
      expect(source, isNot(contains('left: BorderSide(color: palette.accent')));
    });
  });

  group('M4.17 工具调用条对齐官方文案', () {
    test('写成「已完成/进行中 · N 次工具调用」', () {
      expect(source, contains("_running ? '进行中' : '已完成'"));
      expect(source, contains('次工具调用'));
      expect(source, isNot(contains('过程 · ')));
    });

    test('完成后用对勾、运行中用转圈', () {
      expect(source, contains('Icons.check_circle_outline_rounded'));
      expect(source, contains('Icons.autorenew_rounded'));
    });
  });

  group('M4.17 顶部胶囊', () {
    test('副标题是「本机 · 目录名」', () {
      expect(source, contains("'本机 · \$folder'"));
    });

    test('desktopFolderName 只取最后一段', () {
      expect(desktopFolderName(r'<项目根>'), 'deepseek手机端');
      expect(desktopFolderName(r'<项目根>\'), 'deepseek手机端');
      expect(desktopFolderName(''), '');
      expect(desktopFolderName('   '), '');
    });
  });
}
