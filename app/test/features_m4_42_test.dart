import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseek_remote_app/data/live_store.dart';
import 'package:deepseek_remote_app/screens/features_screen.dart';
import 'package:deepseek_remote_app/screens/plugins_screen.dart';
import 'package:deepseek_remote_app/screens/profile_screen.dart';
import 'package:deepseek_remote_app/screens/root_shell.dart';
import 'package:deepseek_remote_app/theme/app_theme.dart';

/// M4.42：抽屉新增「功能」页（排在「我的」上面），插件管理从「我的」搬进去。
class _Store extends LiveStore {
  bool _connected = true;

  @override
  bool get isConnected => _connected;

  @override
  String get deviceName => 'DeepSeek Harness';

  @override
  String get agentVersion => '0.1.0-m1';

  @override
  String get harnessVersion => '0.2.30';

  @override
  Future<void> disconnect() async => _connected = false;

  @override
  Future<void> ensureLiveData({bool force = false}) async {}

  @override
  Future<void> loadTasks({int limit = 50, List<String>? statuses}) async {}

  @override
  Future<void> loadArchivedSessions() async {}
}

void main() {
  testWidgets('抽屉里「功能」排在「我的」上面', (tester) async {
    final store = _Store();
    addTearDown(store.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: RootShell(liveStore: store),
      ),
    );
    await tester.pumpAndSettle();
    await tester.dragFrom(const Offset(2, 300), const Offset(320, 0));
    await tester.pumpAndSettle();

    expect(
      RootShellItems.map((item) => item.label).toList(),
      <String>['AI 助手', '工作区', '功能', '我的'],
    );
    final drawer = find.byType(Drawer);
    expect(
      find.descendant(of: drawer, matching: find.text('功能')),
      findsOneWidget,
    );
    // 顺序：「功能」的 y 坐标小于「我的」。
    final featuresY = tester.getCenter(
      find.descendant(of: drawer, matching: find.text('功能')),
    );
    final profileY = tester.getCenter(
      find.descendant(of: drawer, matching: find.text('我的')),
    );
    expect(featuresY.dy, lessThan(profileY.dy));
  });

  testWidgets('功能页里能进插件管理', (tester) async {
    final store = _Store();
    addTearDown(store.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: FeaturesScreen(liveStore: store),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('插件管理'), findsOneWidget);
    expect(find.text('查看与开关电脑上的插件'), findsOneWidget);

    await tester.tap(find.text('插件管理'));
    await tester.pumpAndSettle();
    expect(find.byType(PluginsScreen), findsOneWidget);
  });

  testWidgets('「我的」里不再有插件管理', (tester) async {
    final store = _Store();
    addTearDown(store.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: ProfileScreen(liveStore: store),
      ),
    );
    await tester.pumpAndSettle();

    // 往下滚一遍，确认整页都没有这一行。
    await tester.drag(find.byType(ListView).first, const Offset(0, -1200));
    await tester.pumpAndSettle();
    expect(find.text('插件管理'), findsNothing);
    expect(find.text('查看与开关电脑上的插件'), findsNothing);
  });
}
