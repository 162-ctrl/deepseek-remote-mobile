import 'package:deepseek_remote_app/data/live_store.dart';
import 'package:deepseek_remote_app/screens/assistant_screen.dart';
import 'package:deepseek_remote_app/services/mode_intro.dart';
import 'package:deepseek_remote_app/services/settings_gateway.dart';
import 'package:deepseek_remote_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// M4.48：AI 助手页两档改名为「本机对话 / 远程电脑」，第一次切换时说明差别、
/// 说过一次就不再挂。
class _FakeModeStore extends LiveStore {
  @override
  bool get isConnected => true;

  @override
  String get deviceName => 'DeepSeek Harness';

  @override
  bool get tasksLoading => false;

  @override
  bool get conversationsLoading => false;
}

Widget _wrap(Widget child) => MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: child,
    );

Future<void> _pumpScreen(
  WidgetTester tester,
  LiveStore store,
  FakeSettingsGateway settings,
) async {
  await tester.binding.setSurfaceSize(const Size(420, 900));
  await tester.pumpWidget(
    _wrap(
      AssistantScreen(
        liveStore: store,
        modeIntro: ModeIntroPrefs(gateway: settings),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _teardown(WidgetTester tester, LiveStore store) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  store.dispose();
  await tester.binding.setSurfaceSize(null);
}

void main() {
  group('档位改名与一次性说明（M4.48）', () {
    testWidgets('两档叫「本机对话 / 远程电脑」，旧名字不再出现', (tester) async {
      final store = _FakeModeStore();
      final settings = FakeSettingsGateway();
      await _pumpScreen(tester, store, settings);

      expect(find.text('本机对话'), findsOneWidget);
      expect(find.text('远程电脑'), findsOneWidget);
      expect(find.text('手机'), findsNothing);
      expect(find.text('电脑'), findsNothing);
      // 还没切过档：说明不该提前冒出来。
      expect(find.text(ModeIntroCopy.title), findsNothing);

      await _teardown(tester, store);
      await settings.dispose();
    });

    testWidgets('第一次切到远程电脑：说明两档差别，点「知道了」后记住', (tester) async {
      final store = _FakeModeStore();
      final settings = FakeSettingsGateway();
      await _pumpScreen(tester, store, settings);

      await tester.tap(find.text('远程电脑'));
      await tester.pump();

      expect(find.text(ModeIntroCopy.title), findsOneWidget);
      expect(find.text(ModeIntroCopy.local), findsOneWidget);
      expect(find.text(ModeIntroCopy.remote), findsOneWidget);

      await tester.tap(find.text(ModeIntroCopy.dismiss));
      await tester.pump();

      expect(find.text(ModeIntroCopy.title), findsNothing);
      expect(settings.values[ModeIntroPrefs.key], '1');

      // 同一次运行里再切回来：不再挂说明。
      await tester.tap(find.text('本机对话'));
      await tester.pump();
      expect(find.text(ModeIntroCopy.title), findsNothing);

      await _teardown(tester, store);
      await settings.dispose();
    });

    testWidgets('点右上角 × 也能收起并记住', (tester) async {
      final store = _FakeModeStore();
      final settings = FakeSettingsGateway();
      await _pumpScreen(tester, store, settings);

      await tester.tap(find.text('远程电脑'));
      await tester.pump();
      expect(find.text(ModeIntroCopy.title), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('modeIntroClose')));
      await tester.pump();

      expect(find.text(ModeIntroCopy.title), findsNothing);
      expect(settings.values[ModeIntroPrefs.key], '1');

      await _teardown(tester, store);
      await settings.dispose();
    });

    testWidgets('已经说过一次：重进页面切档不再打扰', (tester) async {
      final store = _FakeModeStore();
      final settings = FakeSettingsGateway(
        seed: <String, String>{ModeIntroPrefs.key: '1'},
      );
      await _pumpScreen(tester, store, settings);

      await tester.tap(find.text('远程电脑'));
      await tester.pump();

      expect(find.text(ModeIntroCopy.title), findsNothing);
      // 没再写一遍。
      expect(settings.setCalls, 0);

      await _teardown(tester, store);
      await settings.dispose();
    });
  });
}
