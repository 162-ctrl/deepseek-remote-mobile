import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseek_remote_app/app.dart';
import 'package:deepseek_remote_app/screens/assistant_screen.dart';

/// M2.9：页面切换改由左侧抽屉完成。
Future<void> _openPage(WidgetTester tester, String label) async {
  tester.state<ScaffoldState>(find.byType(Scaffold).first).openDrawer();
  await tester.pumpAndSettle();
  await tester.tap(
    find.descendant(of: find.byType(Drawer), matching: find.text(label)),
  );
  await tester.pumpAndSettle();
}

/// M2.4：App 只保留真实数据；未连接时五页统一为连接空态。
void main() {
  testWidgets('启动后落在 AI 助手空态，四个 Tab 均存在且无演示标记', (tester) async {
    await tester.pumpWidget(const DeepSeekRemoteApp());
    await tester.pump(const Duration(milliseconds: 300));

    // M4.6/M4.48：默认落在 AI 助手页的「本机对话」档（云端直连），顶栏是云端接口入口
    expect(find.textContaining('云端直连'), findsOneWidget);
    // 切到「远程电脑」档才是未连接空态
    (tester.state(find.byType(AssistantScreen)) as dynamic)
        .switchModeForTest('desktop');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('还没有连接电脑'), findsOneWidget);
    expect(find.text('连接你的电脑'), findsOneWidget);

    // 旧演示数据标记/假设备必须已清空
    expect(find.text('演示数据'), findsNothing);
    expect(find.textContaining('DESKTOP-XXXXXXX'), findsNothing);

    // M4.41：「电脑」页删掉后剩下三个入口
    tester.state<ScaffoldState>(find.byType(Scaffold).first).openDrawer();
    await tester.pumpAndSettle();
    for (final label in ['AI 助手', '工作区', '我的']) {
      expect(find.text(label), findsWidgets);
    }
    // 「电脑」这一项必须消失（AI 助手页的「远程电脑」胶囊不在抽屉里，见 M4.6/M4.48）
    expect(
      find.descendant(
        of: find.byType(Drawer),
        matching: find.text('电脑'),
      ),
      findsNothing,
    );
  });

  testWidgets('工作区页未连接时展示连接空态', (tester) async {
    await tester.pumpWidget(const DeepSeekRemoteApp());
    await tester.pump(const Duration(milliseconds: 300));

    await _openPage(tester, '工作区');

    expect(find.text('工作区'), findsWidgets);
    expect(find.text('连接后在这里看工作区'), findsOneWidget);
  });

  // M4.41：「电脑」页已删除（紧急停止搬到「我的」），这条用例随之删除。

  testWidgets('我的页未连接时提供连接入口，且保留外观与版本', (tester) async {
    await tester.pumpWidget(const DeepSeekRemoteApp());
    await tester.pump(const Duration(milliseconds: 300));

    await _openPage(tester, '我的');

    expect(find.text('未连接'), findsOneWidget);
    expect(find.text('连接电脑'), findsWidgets);
    // M4.25：「我的」页顶部多了「账户余额」一栏，往下都得滚动才看得到。
    await tester.scrollUntilVisible(find.text('账户余额').first, 200);
    expect(find.text('账户余额'), findsWidgets);
    // M4.4：「通知」分区新增两个开关，外观模式被挤到下面，需要滚动。
    await tester.scrollUntilVisible(find.text('等待授权提醒'), 200);
    expect(find.text('等待授权提醒'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('外观模式'), 200);
    expect(find.text('外观模式'), findsOneWidget);
    await tester.scrollUntilVisible(
        find.textContaining('手机端 v0.4.67-m4.67'), 200);
    expect(find.textContaining('手机端 v0.4.67-m4.67'), findsWidgets);
  });
}
