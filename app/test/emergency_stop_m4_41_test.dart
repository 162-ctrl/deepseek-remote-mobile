import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseek_remote_app/data/live_store.dart';
import 'package:deepseek_remote_app/screens/profile_screen.dart';
import 'package:deepseek_remote_app/screens/root_shell.dart';
import 'package:deepseek_remote_app/theme/app_theme.dart';
import 'package:deepseek_remote_app/widgets/common.dart';

/// M4.41：原来的「电脑」页删掉了，紧急停止搬到「我的」。
class _ConnectedStore extends LiveStore {
  int disconnects = 0;

  @override
  bool get isConnected => true;

  @override
  String get deviceName => 'DeepSeek Harness';

  @override
  String get agentVersion => '0.1.0-m1';

  @override
  String get harnessVersion => '0.2.30';

  @override
  bool get tasksLoading => false;

  @override
  bool get conversationsLoading => false;

  @override
  Future<void> disconnect() async {
    disconnects += 1;
  }
}

class _OfflineStore extends LiveStore {
  @override
  bool get isConnected => false;

  @override
  String get deviceName => 'DeepSeek Harness';
}

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: buildAppTheme(Brightness.light),
    home: child,
  );
}

void main() {
  group('M4.41 电脑页删除后的紧急停止', () {
    testWidgets('连上电脑时「我的」里有紧急停止，滑动并确认后才断开', (tester) async {
      final store = _ConnectedStore();
      addTearDown(store.dispose);
      await tester.binding.setSurfaceSize(const Size(420, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(_wrap(ProfileScreen(liveStore: store)));
      await tester.pump(const Duration(milliseconds: 300));

      final slider = find.byType(SlideToStop);
      await tester.scrollUntilVisible(slider, 200);
      expect(find.text('紧急停止'), findsWidgets);
      expect(store.disconnects, 0);

      // 拖的是滑块本身（轨道中间的文案不是拖动区），阈值是轨道 72%
      await tester.drag(
        find.byIcon(Icons.power_settings_new_rounded),
        const Offset(600, 0),
      );
      await tester.pumpAndSettle();

      expect(find.text('紧急停止远程连接？'), findsOneWidget);
      expect(store.disconnects, 0, reason: '弹确认之前不能断开');

      await tester.tap(find.text('确认停止'));
      await tester.pumpAndSettle();

      expect(store.disconnects, 1);
      // M4.44：结果改成如实汇报——这里没有在跑的任务，所以只说「只断开了连接」。
      expect(find.text('电脑上没有在跑的任务，只断开了连接'), findsOneWidget);
    });

    testWidgets('没连电脑时看不到紧急停止', (tester) async {
      final store = _OfflineStore();
      await tester.binding.setSurfaceSize(const Size(420, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(_wrap(ProfileScreen(liveStore: store)));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(SlideToStop), findsNothing);
      expect(find.text('紧急停止'), findsNothing);
    });

    // M4.42：抽屉新增「功能」，所以这里是四个入口。
    test('抽屉只有四个入口，没有「电脑」', () {
      expect(RootShellItems.length, 4);
      expect(
        RootShellItems.map((item) => item.label).toList(),
        <String>['AI 助手', '工作区', '功能', '我的'],
      );
    });
  });
}
