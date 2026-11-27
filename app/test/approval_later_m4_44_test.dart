// M4.44 审批弹层：下滑 / 返回 / 超时都只是「暂缓」，不能替用户拒绝。
//
// 以前 `showModalBottomSheet` 返回 null（下滑关闭）就直接 `decideApproval(false)`，
// 用户手滑一下电脑上的任务就被判死。现在只有点红色「拒绝本次操作」才发送拒绝。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseek_remote_app/data/live_store.dart';
import 'package:deepseek_remote_app/screens/assistant_screen.dart';
import 'package:deepseek_remote_app/services/relay_protocol.dart';
import 'package:deepseek_remote_app/theme/app_theme.dart';
import 'package:deepseek_remote_app/widgets/approval_sheet.dart';

ApprovalRequestInfo _info() => const ApprovalRequestInfo(
      conversationId: 'conv-1',
      approvalId: 'ap-1',
      tool: 'pwsh',
      input: <String, dynamic>{'command': r'Get-ChildItem -Path C:\'},
      workspace: r'<项目根>',
    );

class _ApprovalStore extends LiveStore {
  _ApprovalStore({this.hasApproval = true});

  final bool hasApproval;
  final List<bool> decisions = <bool>[];
  int clearApprovalToOpenCalls = 0;

  @override
  bool get isConnected => true;

  @override
  bool get appInForeground => true;

  @override
  String get deviceName => 'DeepSeek Harness (插件直连)';

  @override
  String? get workspacePath => r'<项目根>';

  @override
  PendingApproval? get pendingApproval =>
      hasApproval ? PendingApproval(info: _info()) : null;

  @override
  void clearApprovalToOpen() => clearApprovalToOpenCalls += 1;

  @override
  void decideApproval(bool approved) => decisions.add(approved);

  @override
  bool get tasksLoading => false;

  @override
  bool get conversationsLoading => false;

  @override
  Future<void> ensureLiveData({bool force = false}) async {}
}

Widget _wrap(LiveStore store) => MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: AssistantScreen(liveStore: store),
    );

Future<void> _showSheet(WidgetTester tester, _ApprovalStore store) async {
  // 必须用 tester.view：setSurfaceSize 只改渲染尺寸，命中测试仍按 view 的
  // 800x600 裁剪，结果是弹层下半截的文字「找到了但点不到」。
  tester.view.physicalSize = const Size(420, 1500);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_wrap(store));
  await tester.pump(const Duration(milliseconds: 300));
  // 弹层是在 postFrame 里打开的，动画 250ms——不 settle 的话它还在屏幕下方
  // 滑入途中，文字找得到但点不到。
  await tester.pumpAndSettle();
  expect(find.text('有一项操作需要你的授权'), findsOneWidget);
}

void main() {
  group('M4.44 审批弹层不会替人拒绝', () {
    testWidgets('下滑关闭只暂缓：不发送任何决定，也不会立刻再弹', (tester) async {
      final store = _ApprovalStore();
      addTearDown(store.dispose);
      await _showSheet(tester, store);

      // 下滑关闭（modal bottom sheet 的默认手势）
      await tester.fling(
        find.byType(ApprovalSheet),
        const Offset(0, 900),
        2000,
      );
      await tester.pumpAndSettle();

      expect(store.decisions, isEmpty, reason: '下滑不能产生 approved/denied');
      expect(find.text('有一项操作需要你的授权'), findsNothing);
      expect(
        find.text('先不处理。电脑仍在等你回答，可以从通知或工作区再进来'),
        findsOneWidget,
      );

      // 关键：不能因为「又有待审批」而立刻再弹一次
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('有一项操作需要你的授权'), findsNothing);
    });

    testWidgets('点「拒绝本次操作」才发送 denied', (tester) async {
      final store = _ApprovalStore();
      addTearDown(store.dispose);
      await _showSheet(tester, store);

      await tester.tap(find.text('拒绝本次操作'));
      await tester.pumpAndSettle();

      expect(store.decisions, <bool>[false]);
      expect(find.text('已拒绝本次操作，电脑端已取消'), findsOneWidget);
    });

    testWidgets('点「允许一次」发送 approved', (tester) async {
      final store = _ApprovalStore();
      addTearDown(store.dispose);
      await _showSheet(tester, store);

      await tester.tap(find.text('允许一次'));
      await tester.pumpAndSettle();

      expect(store.decisions, <bool>[true]);
      expect(find.text('已允许本次操作，电脑正在执行…'), findsOneWidget);
    });

    testWidgets('没有待审批时不弹', (tester) async {
      final store = _ApprovalStore(hasApproval: false);
      addTearDown(store.dispose);
      tester.view.physicalSize = const Size(420, 1500);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_wrap(store));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('有一项操作需要你的授权'), findsNothing);
      expect(store.decisions, isEmpty);
    });
    testWidgets('弹层自己超时也只返回 later，不当作拒绝', (tester) async {
      ApprovalDecision? got;
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  got = await showModalBottomSheet<ApprovalDecision>(
                    context: context,
                    builder: (_) => const ApprovalSheet(
                      tool: 'pwsh',
                      command: r'Get-ChildItem -Path C:\',
                      deviceName: 'DeepSeek Harness',
                      workspace: r'<项目根>',
                      timeout: Duration(seconds: 1),
                    ),
                  );
                },
                child: const Text('打开授权'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('打开授权'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('有一项操作需要你的授权'), findsOneWidget);

      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      expect(got, ApprovalDecision.later);
      expect(find.text('有一项操作需要你的授权'), findsNothing);
    });
  });
}
