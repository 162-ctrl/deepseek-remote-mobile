import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseek_remote_app/app.dart';
import 'package:deepseek_remote_app/data/live_store.dart';
import 'package:deepseek_remote_app/screens/assistant_screen.dart';
import 'package:deepseek_remote_app/theme/app_theme.dart';
import 'package:deepseek_remote_app/widgets/empty_state.dart';

/// M2.9：页面切换改由左侧抽屉完成。
Future<void> _openPage(WidgetTester tester, String label) async {
  tester.state<ScaffoldState>(find.byType(Scaffold).first).openDrawer();
  await tester.pumpAndSettle();
  await tester.tap(
    find.descendant(of: find.byType(Drawer), matching: find.text(label)),
  );
  await tester.pumpAndSettle();
}

/// M2.4：无演示数据 + 五页统一连接空态。
void main() {
  group('EmptyState 组件', () {
    testWidgets('渲染图标/标题/说明/按钮并触发回调', (tester) async {
      var tapped = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: Scaffold(
            body: EmptyState(
              icon: Icons.chat_bubble_outline_rounded,
              title: '还没有连接电脑',
              description: '连接后在这里和电脑上的 DeepSeek Harness 对话',
              actionLabel: '连接你的电脑',
              onAction: () => tapped++,
            ),
          ),
        ),
      );

      expect(find.text('还没有连接电脑'), findsOneWidget);
      expect(
        find.text('连接后在这里和电脑上的 DeepSeek Harness 对话'),
        findsOneWidget,
      );
      expect(find.text('连接你的电脑'), findsOneWidget);
      expect(find.byIcon(Icons.chat_bubble_outline_rounded), findsOneWidget);

      await tester.tap(find.text('连接你的电脑'));
      await tester.pump();
      expect(tapped, 1);
    });
  });

  group('五页未连接空态', () {
    testWidgets('AI 助手页空态与说明', (tester) async {
      await tester.pumpWidget(const DeepSeekRemoteApp());
      await tester.pump(const Duration(milliseconds: 300));

      // M4.6：默认停在「手机」档（云端直连），切到「电脑」才看电脑空态。
      (tester.state(find.byType(AssistantScreen)) as dynamic)
          .switchModeForTest('desktop');
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('还没有连接电脑'), findsOneWidget);
      expect(
        find.text('连接后在这里和电脑上的 DeepSeek Harness 对话'),
        findsOneWidget,
      );
      // 未连接时不应有输入框
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('工作区页空态文案', (tester) async {
      await tester.pumpWidget(const DeepSeekRemoteApp());
      await tester.pump(const Duration(milliseconds: 300));
      await _openPage(tester, '工作区');

      expect(find.text('连接后在这里看工作区'), findsOneWidget);
      expect(
        find.text('连接电脑后，这里按工作区列出任务与会话，也能进目录看文件'),
        findsOneWidget,
      );
    });

    // M4.41：「电脑」页已删除（紧急停止搬到「我的」），这条空态用例随之删除。


    testWidgets('我的页不空态：显示未连接与连接入口', (tester) async {
      await tester.pumpWidget(const DeepSeekRemoteApp());
      await tester.pump(const Duration(milliseconds: 300));
      await _openPage(tester, '我的');

      expect(find.text('未连接'), findsOneWidget);
      expect(find.text('连接电脑'), findsWidgets);
      // M4.25：顶部新增「账户余额」一栏，往下都要先滚一下。
      await tester.scrollUntilVisible(find.text('账户余额').first, 200);
      expect(find.text('账户余额'), findsWidgets);
      // M4.4：我的页在「通知」分区之前，新增了两个通知开关
      await tester.scrollUntilVisible(find.text('任务做完提醒'), 200);
      expect(find.text('任务做完提醒'), findsOneWidget);
      // 我的页仍有外观三选与关于
      await tester.scrollUntilVisible(find.text('外观模式'), 200);
      expect(find.text('外观模式'), findsOneWidget);
      await tester.scrollUntilVisible(
          find.textContaining('手机端 v0.4.67-m4.67'), 200);
      expect(find.textContaining('手机端 v0.4.67-m4.67'), findsWidgets);
    });
  });

  group('空态入口与清理验收', () {
    testWidgets('点空态按钮进入连接页', (tester) async {
      await tester.pumpWidget(const DeepSeekRemoteApp());
      await tester.pump(const Duration(milliseconds: 300));

      // M4.6：默认在「手机」档（云端直连），切到「电脑」档才有点连接的空态。
      (tester.state(find.byType(AssistantScreen)) as dynamic)
          .switchModeForTest('desktop');
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.text('连接你的电脑'));
      await tester.pumpAndSettle();

      // 连接页出现：标题 + 服务器地址 + 配对码输入
      expect(find.text('连接电脑'), findsWidgets);
      expect(find.text('服务器'), findsOneWidget);
      expect(find.text('配对码'), findsOneWidget);
    });

    test('demo_store.dart 已删除且 lib 中无演示文案', () {
      expect(File('lib/data/demo_store.dart').existsSync(), isFalse);
      final offenders = <String>[];
      final entity = Directory('lib');
      for (final file in entity.listSync(recursive: true)) {
        if (file is! File || !file.path.endsWith('.dart')) continue;
        final content = file.readAsStringSync();
        if (content.contains('演示') ||
            content.contains('DemoBadge') ||
            content.contains('DemoStore') ||
            content.contains('StoreScope') ||
            content.contains('ModeBadge')) {
          offenders.add(file.path);
        }
      }
      expect(offenders, isEmpty);
    });

    test('未连接时 LiveStore 状态文案为「未连接」且发送被拒', () {
      final store = LiveStore();
      expect(store.isConnected, isFalse);
      expect(store.connectionLabel, '未连接');
      expect(store.messages, isEmpty);

      store.sendPrompt('你好');
      expect(store.errorText, isNotNull);
      expect(store.errorText!, contains('还未连接真实电脑'));
      store.dispose();
    });
  });
}
