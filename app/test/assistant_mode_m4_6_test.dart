import 'package:deepseek_remote_app/data/live_store.dart';
import 'package:deepseek_remote_app/screens/assistant_screen.dart';
import 'package:deepseek_remote_app/screens/cloud_chat_screen.dart';
import 'package:deepseek_remote_app/services/cloud_chat.dart';
import 'package:deepseek_remote_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// M4.6：AI 助手页恢复「手机 / 电脑」两档，默认停在手机档。
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

/// 不给接口设置：云端页应该停在「去设置」提示，而不是一直转圈。
class _UnconfiguredStore extends CloudChatStore {
  @override
  Future<CloudChatConfig?> load() async => null;

  @override
  Future<void> save(CloudChatConfig config) async {}
}

Widget _wrap(Widget child) => MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: child,
    );

void main() {
  group('AI 助手两档（M4.6）', () {
    testWidgets('默认停在手机档：顶栏是云端接口，切换胶囊两档都在', (tester) async {
      final store = _FakeModeStore();
      await tester.binding.setSurfaceSize(const Size(420, 900));
      await tester.pumpWidget(
        _wrap(AssistantScreen(liveStore: store)),
      );
      await tester.pump(const Duration(milliseconds: 300));

      // 两档胶囊（M4.48 起叫「本机对话 / 远程电脑」）
      expect(find.text('本机对话'), findsOneWidget);
      expect(find.text('远程电脑'), findsOneWidget);
      // 手机档顶栏：云端直连（没有接口时提示未设置），不显示电脑设备名
      expect(find.textContaining('云端直连'), findsOneWidget);
      expect(find.text('云端直连 · 未设置接口'), findsOneWidget);
      // 手机档是云端对话，电脑档的输入条不在可见层
      expect(find.byType(CloudChatScreen), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      store.dispose();
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('点「远程电脑」切到电脑档：顶栏换成设备名，切回「本机对话」还能看到云端页', (tester) async {
      final store = _FakeModeStore();
      await tester.binding.setSurfaceSize(const Size(420, 900));
      await tester.pumpWidget(_wrap(AssistantScreen(liveStore: store)));
      await tester.pump(const Duration(milliseconds: 300));

      (tester.state(find.byType(AssistantScreen)) as dynamic)
          .switchModeForTest('desktop');
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.textContaining('云端直连'), findsNothing);
      expect(find.text('DeepSeek Harness'), findsOneWidget);

      (tester.state(find.byType(AssistantScreen)) as dynamic)
          .switchModeForTest('phone');
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('云端直连'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      store.dispose();
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('云端页没配置接口时停在「去设置」，不会一直转圈', (tester) async {
      final store = CloudChatScreen(
        store: _UnconfiguredStore(),
        embedded: true,
      );
      await tester.binding.setSurfaceSize(const Size(420, 900));
      await tester.pumpWidget(_wrap(store));
      await tester.pumpAndSettle();

      // 没有配置：页面可停帧（pumpAndSettle 能返回），且给出设置入口。
      expect(find.byType(CircularProgressIndicator), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.binding.setSurfaceSize(null);
    });
  });
}
