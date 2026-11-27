import 'package:deepseek_remote_app/data/live_store.dart';
import 'package:deepseek_remote_app/screens/assistant_screen.dart';
import 'package:deepseek_remote_app/services/mode_intro.dart';
import 'package:deepseek_remote_app/services/remote_chat_intent.dart';
import 'package:deepseek_remote_app/services/settings_gateway.dart';
import 'package:deepseek_remote_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// M4.50：「工作区 → 新会话」不再凭空建一个谁都不显示的空会话，
/// 而是把用户送到 AI 助手的「远程电脑」对话框，并把目录绑给下一场对话。
class _FakeNewChatStore extends LiveStore {
  bool busy = false;

  final List<String?> startedConversations = <String?>[];
  final List<String?> pendingWorkspaces = <String?>[];

  @override
  bool get isConnected => true;

  @override
  bool get isBusy => busy;

  @override
  String get deviceName => 'DeepSeek Harness';

  @override
  bool get tasksLoading => false;

  @override
  bool get conversationsLoading => false;

  @override
  void startNewConversation({String? workspacePath}) {
    startedConversations.add(workspacePath);
  }

  @override
  void setPendingWorkspace(String? path) {
    pendingWorkspaces.add(path);
  }
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
  group('工作区开新会话 → 远程对话框（M4.50）', () {
    testWidgets('切到远程电脑档，把目录交给新会话', (tester) async {
      final store = _FakeNewChatStore();
      final settings = FakeSettingsGateway();
      await _pumpScreen(tester, store, settings);

      expect((tester.state(find.byType(AssistantScreen)) as dynamic).modeForTest,
          'phone');

      RemoteChatIntent.instance.open(workspacePath: r'D:\Projects\示例项目C');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect((tester.state(find.byType(AssistantScreen)) as dynamic).modeForTest,
          'desktop');
      expect(store.startedConversations, <String?>[r'D:\Projects\示例项目C']);
      // 主动跳过去不该顺手挂那条「两档不一样」的说明。
      expect(find.text(ModeIntroCopy.title), findsNothing);

      await _teardown(tester, store);
      await settings.dispose();
    });

    testWidgets('电脑还在忙的时候不打断当前会话，只记下目录', (tester) async {
      final store = _FakeNewChatStore()..busy = true;
      final settings = FakeSettingsGateway();
      await _pumpScreen(tester, store, settings);

      RemoteChatIntent.instance.open(workspacePath: r'D:\work\demo');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(store.startedConversations, isEmpty);
      expect(store.pendingWorkspaces, contains(r'D:\work\demo'));
      expect(find.text('电脑还在忙这一条，等它结束再开新会话'), findsOneWidget);

      await _teardown(tester, store);
      await settings.dispose();
    });

    testWidgets('一次请求只消费一次', (tester) async {
      RemoteChatIntent.instance.open(workspacePath: r'D:\work\demo');
      expect(RemoteChatIntent.instance.pending?.workspacePath, r'D:\work\demo');

      final taken = RemoteChatIntent.instance.take();
      expect(taken?.workspacePath, r'D:\work\demo');
      expect(RemoteChatIntent.instance.pending, isNull);
      expect(RemoteChatIntent.instance.take(), isNull);
    });
  });
}
