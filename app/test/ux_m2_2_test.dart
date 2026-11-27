import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseek_remote_app/data/live_store.dart';
import 'package:deepseek_remote_app/models.dart';
import 'package:deepseek_remote_app/services/pairing_api.dart';
import 'package:deepseek_remote_app/services/relay_client.dart';
import 'package:deepseek_remote_app/services/relay_protocol.dart';
import 'package:deepseek_remote_app/services/settings_gateway.dart';
import 'package:deepseek_remote_app/services/share_card.dart';
import 'package:deepseek_remote_app/services/share_gateway.dart';
import 'package:deepseek_remote_app/theme/app_theme.dart';
import 'package:deepseek_remote_app/theme/theme_controller.dart';
import 'package:deepseek_remote_app/widgets/chat_items.dart';
import 'package:deepseek_remote_app/widgets/turn_fold.dart';

// ---------------------------------------------------------------------------
// 测试夹具：假 WebSocket / 假配对 / 假 REST 均不联网。
// ---------------------------------------------------------------------------

Map<String, dynamic> _envelope(String type, [Map<String, dynamic>? payload]) => {
      'v': 1,
      'type': type,
      'ts': DateTime.now().toUtc().toIso8601String(),
      'payload': payload ?? <String, dynamic>{},
    };

class _FakeSocket implements RelaySocket {
  final _controller = StreamController<String>.broadcast();
  final List<String> sent = [];
  int? _closedCode;

  @override
  Stream<String> get messages => _controller.stream;

  @override
  int? get closeCode => _closedCode;

  @override
  String? get closeReason => null;

  @override
  void send(String data) => sent.add(data);

  @override
  Future<void> close([int? code, String? reason]) async {
    _closedCode = code;
    await _controller.close();
  }

  void serverSend(Map<String, dynamic> frame) =>
      _controller.add(jsonEncode(frame));

  List<Map<String, dynamic>> get sentFrames => sent
      .map((raw) => jsonDecode(raw) as Map<String, dynamic>)
      .toList(growable: false);

  List<String> get sentTypes =>
      sentFrames.map((frame) => frame['type'] as String).toList();

  Map<String, dynamic>? lastPayloadOf(String type) {
    for (var i = sentFrames.length - 1; i >= 0; i--) {
      final frame = sentFrames[i];
      if (frame['type'] == type) {
        return (frame['payload'] as Map).cast<String, dynamic>();
      }
    }
    return null;
  }
}

Future<PairResult> _fakePairer(String baseUrl, String code) async =>
    PairResult.fromJson({
      'token': 'tok-1',
      'role': 'app',
      'deviceId': 'device-1',
      'expiresAt': DateTime.now().add(const Duration(hours: 1)).toIso8601String(),
    });

class _Harness {
  _Harness({Duration interruptTimeout = const Duration(seconds: 3)}) {
    _relay = RelayClient(
      connector: (uri) async {
        final socket = _FakeSocket();
        sockets.add(socket);
        return socket;
      },
      initialRetryDelay: const Duration(milliseconds: 10),
      maxRetryDelay: const Duration(milliseconds: 20),
      maxRetries: 2,
    );
    store = LiveStore(
      relayClient: _relay,
      pairer: _fakePairer,
      interruptTimeout: interruptTimeout,
    );
  }

  late final RelayClient _relay;
  late final LiveStore store;
  final List<_FakeSocket> sockets = [];

  _FakeSocket get socket => sockets.last;

  Future<void> connect() async {
    await store.connect('https://relay.example.com', code: '824613');
    await pumpEventQueue();
  }

  Future<void> sendConversationCreated() async {
    socket.serverSend(_envelope(RelayMessageTypes.conversationCreated, {
      'conversationId': 'conv-1',
      'sessionId': 'session-1',
      'workspacePath': r'D:\work\sales-analysis',
    }));
    await pumpEventQueue();
  }

  Future<void> sendTaskState(String state) async {
    socket.serverSend(_envelope(RelayMessageTypes.taskState, {
      'conversationId': 'conv-1',
      'state': state,
    }));
    await pumpEventQueue();
  }

  void dispose() => store.dispose();
}

ChatItem _text(ChatRole role, String text, {int? turnId, bool queued = false}) =>
    ChatItem(
      role: role,
      kind: ChatItemKind.text,
      text: text,
      turnId: turnId,
      queued: queued,
    );

TurnStats _completedStats({
  int turnId = 1,
  TaskStatus status = TaskStatus.completed,
  int toolCount = 2,
  int seconds = 12,
}) {
  final startedAt = DateTime(2026, 1, 1, 0, 0, 0);
  return TurnStats(turnId: turnId)
    ..startedAt = startedAt
    ..endedAt = startedAt.add(Duration(seconds: seconds))
    ..status = status
    ..toolCount = toolCount;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ------------------------------ A1 完成自动折叠 ------------------------------
  group('A1 完成自动折叠', () {
    test('终态轮的工具与思考折叠为一个 group，最终回复不折叠', () {
      final messages = <ChatItem>[
        _text(ChatRole.user, '分析一下销售数据'),
        ChatItem(
          role: ChatRole.assistant,
          kind: ChatItemKind.thinking,
          text: '先看看目录',
          turnId: 1,
        ),
        ChatItem(
          role: ChatRole.assistant,
          kind: ChatItemKind.toolCall,
          text: 'pwsh',
          turnId: 1,
        ),
        ChatItem(
          role: ChatRole.assistant,
          kind: ChatItemKind.toolResult,
          text: 'ok',
          turnId: 1,
        ),
        _text(ChatRole.assistant, '销售数据已完成分析，共 3 张图表。', turnId: 1),
      ];
      final stats = {1: _completedStats()};
      final entries = groupTurnMessages(messages, stats);
      expect(entries.length, 3);
      expect(entries[0], isA<TurnFeedMessage>());
      final folded = entries[1] as TurnFeedGroup;
      expect(folded.turnId, 1);
      expect(folded.items.length, 3);
      expect(folded.stats?.summaryLabel, '已完成 2 步 · 用时 12s');
      expect((entries[2] as TurnFeedMessage).item.text, contains('已完成分析'));
    });

    test('执行中的轮也折叠，不露出英文命令', () {
      final running = _completedStats(status: TaskStatus.running);
      final entries = groupTurnMessages(
        [
          ChatItem(
            role: ChatRole.assistant,
            kind: ChatItemKind.toolCall,
            text: 'pwsh',
            turnId: 1,
          ),
        ],
        {1: running},
      );
      expect(entries.length, 1);
      expect(entries.single, isA<TurnFeedGroup>());
      expect((entries.single as TurnFeedGroup).toolCount, 1);
    });

    test('没有工具步数时也折叠，摘要退回「思考过程」', () {
      final noTools = _completedStats(toolCount: 0);
      final entries = groupTurnMessages(
        [
          ChatItem(
            role: ChatRole.assistant,
            kind: ChatItemKind.thinking,
            text: '想一下',
            turnId: 1,
          ),
        ],
        {1: noTools},
      );
      expect(entries.single, isA<TurnFeedGroup>());
      expect((entries.single as TurnFeedGroup).toolCount, 0);

      final failed = _completedStats(status: TaskStatus.failed, toolCount: 3, seconds: 8);
      expect(failed.summaryLabel, '失败 · 3 步 · 用时 8s');
      expect(failed.color, AppColors.danger);

      final cancelled =
          _completedStats(status: TaskStatus.cancelled, toolCount: 2, seconds: 5);
      expect(cancelled.summaryLabel, '已取消 · 2 步 · 用时 5s');
      expect(cancelled.color, AppColors.warning);
    });

    testWidgets('摘要行点击展开/收起原始卡片', (tester) async {
      final group = TurnFeedGroup(
        turnId: 1,
        stats: _completedStats(),
        items: [
          ChatItem(
            role: ChatRole.assistant,
            kind: ChatItemKind.toolCall,
            text: 'pwsh',
            turnId: 1,
          ),
          ChatItem(
            role: ChatRole.assistant,
            kind: ChatItemKind.toolResult,
            text: '输出内容',
            turnId: 1,
          ),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TurnSummaryCard(
              group: group,
              itemBuilder: (context, item) => Text('item:${item.text}'),
            ),
          ),
        ),
      );
      expect(find.text('已完成 2 步 · 用时 12s'), findsOneWidget);
      expect(find.text('展开'), findsOneWidget);
      expect(find.text('item:pwsh'), findsNothing);

      await tester.tap(find.text('展开'));
      await tester.pumpAndSettle();
      expect(find.text('收起'), findsOneWidget);
      expect(find.text('item:pwsh'), findsOneWidget);
      expect(find.text('item:输出内容'), findsOneWidget);

      await tester.tap(find.text('收起'));
      await tester.pumpAndSettle();
      expect(find.text('item:pwsh'), findsNothing);
    });
  });

  // ------------------------------ A2 排队立即发送 ------------------------------
  group('A2 排队「立即发送」', () {
    test('先发 task.cancel，收到终态后再发排队指令', () async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      await harness.connect();
      await harness.sendConversationCreated();
      await harness.sendTaskState('running');

      harness.store.sendPrompt('把结果导出成 Excel');
      expect(harness.store.hasQueuedPrompt, isTrue);
      expect(harness.socket.sentTypes, isNot(contains('prompt.send')));

      harness.store.interruptAndSendQueuedPrompt();
      expect(harness.store.isInterrupting, isTrue);
      expect(harness.socket.sentTypes, contains('task.cancel'));
      final cancelIndex = harness.socket.sentTypes.indexOf('task.cancel');
      expect(
        harness.socket.sentTypes,
        isNot(contains('prompt.send')),
      );

      await harness.sendTaskState('completed');
      final sent = harness.socket.sentTypes;
      final promptIndex = sent.indexOf('prompt.send');
      expect(promptIndex, greaterThan(cancelIndex));
      expect(
        harness.socket.lastPayloadOf('prompt.send')?['text'],
        '把结果导出成 Excel',
      );
      expect(harness.store.hasQueuedPrompt, isFalse);
      expect(harness.store.isInterrupting, isFalse);
    });

    test('3 秒超时兜底：没有终态也会发出排队指令', () async {
      final harness =
          _Harness(interruptTimeout: const Duration(milliseconds: 40));
      addTearDown(harness.dispose);
      await harness.connect();
      await harness.sendConversationCreated();
      await harness.sendTaskState('running');
      harness.store.sendPrompt('超时后发送');

      harness.store.interruptAndSendQueuedPrompt();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await pumpEventQueue();

      expect(harness.socket.sentTypes, contains('prompt.send'));
      expect(
        harness.socket.lastPayloadOf('prompt.send')?['text'],
        '超时后发送',
      );
      expect(harness.store.isInterrupting, isFalse);
    });

    test('打断进行中防重复点击', () async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      await harness.connect();
      await harness.sendConversationCreated();
      await harness.sendTaskState('running');
      harness.store.sendPrompt('排队 1');

      harness.store.interruptAndSendQueuedPrompt();
      harness.store.interruptAndSendQueuedPrompt();

      final cancelCount =
          harness.socket.sentTypes.where((t) => t == 'task.cancel').length;
      expect(cancelCount, 1);
    });

    testWidgets('排队气泡显示「立即发送」/「正在打断…」', (tester) async {
      var tapped = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatItemView(
              item: _text(ChatRole.user, '排队中的指令', queued: true),
              onApprovalDemo: () {},
              onSendNow: () => tapped++,
            ),
          ),
        ),
      );
      expect(find.text('已排队'), findsOneWidget);
      expect(find.text('立即发送'), findsOneWidget);
      await tester.tap(find.text('立即发送'));
      expect(tapped, 1);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatItemView(
              item: _text(ChatRole.user, '排队中的指令', queued: true),
              onApprovalDemo: () {},
              onSendNow: () {},
              interrupting: true,
            ),
          ),
        ),
      );
      expect(find.text('正在打断…'), findsOneWidget);
      expect(find.text('立即发送'), findsNothing);
    });
  });

  // -------------------------------- A3 外观模式（M2.3 三选） --------------------------------
  group('A3 外观模式（M2.3 三选）', () {
    test('三种模式与解析/回退', () {
      expect(AppThemeMode.values.length, 3);
      expect(AppThemeMode.parse('light'), AppThemeMode.light);
      expect(AppThemeMode.parse('dark'), AppThemeMode.dark);
      expect(AppThemeMode.parse('system'), AppThemeMode.system);
      expect(AppThemeMode.parse(null), AppThemeMode.system);
      expect(AppThemeMode.parse('not-a-mode'), AppThemeMode.system);
    });

    test('buildAppTheme 按明暗生成不同背景与主色', () {
      final light = buildAppTheme(Brightness.light);
      final dark = buildAppTheme(Brightness.dark);
      expect(light.scaffoldBackgroundColor, AppPalette.light.bg);
      expect(dark.scaffoldBackgroundColor, AppPalette.dark.bg);
      expect(light.colorScheme.primary, AppPalette.light.accent);
      expect(dark.colorScheme.primary, AppPalette.dark.accent);
      expect(light.extension<AppPaletteExt>()?.palette.isDark, isFalse);
      expect(dark.extension<AppPaletteExt>()?.palette.isDark, isTrue);
    });

    test('ThemeController 读取持久化并在选择后写回', () async {
      final gateway = FakeSettingsGateway(
        seed: {ThemeController.storageKey: 'dark'},
      );
      final controller = ThemeController(gateway: gateway);
      await controller.load();
      expect(controller.mode, AppThemeMode.dark);
      expect(controller.themeMode, ThemeMode.dark);
      expect(controller.loaded, isTrue);

      await controller.select(AppThemeMode.light);
      expect(controller.mode, AppThemeMode.light);
      expect(controller.themeMode, ThemeMode.light);
      expect(gateway.values[ThemeController.storageKey], 'light');
      expect(gateway.setCalls, greaterThanOrEqualTo(1));
      controller.dispose();
    });

    testWidgets('切换外观模式后 MaterialApp 立即换色', (tester) async {
      final controller = ThemeController(gateway: FakeSettingsGateway());
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        ThemeScope(
          controller: controller,
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, _) => MaterialApp(
              theme: buildAppTheme(
                controller.mode == AppThemeMode.dark
                    ? Brightness.dark
                    : Brightness.light,
              ),
              home: Builder(
                builder: (context) => Scaffold(
                  body: Text(
                    'bg:${Theme.of(context).scaffoldBackgroundColor.toARGB32()}',
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(
        find.text('bg:${AppPalette.light.bg.toARGB32()}'),
        findsOneWidget,
      );

      await controller.select(AppThemeMode.dark);
      await tester.pumpAndSettle();
      expect(find.text('bg:${AppPalette.dark.bg.toARGB32()}'), findsOneWidget);
    });
  });

  // -------------------------------- A4 分享卡 --------------------------------
  group('A4 分享卡', () {
    test('只取最近一轮用户/助手文本并脱敏路径', () {
      final data = buildShareCardData(
        messages: [
          _text(ChatRole.user, '上一轮的问题'),
          _text(ChatRole.assistant, '上一轮的回答'),
          _text(ChatRole.user, '销售数据在哪'),
          ChatItem(
            role: ChatRole.assistant,
            kind: ChatItemKind.toolCall,
            text: 'pwsh',
            steps: [
              ToolStep(
                title: 'pwsh',
                command: r'Get-ChildItem D:\work\sales',
                status: 'done',
              ),
            ],
          ),
          _text(ChatRole.assistant, r'结果在 D:\work\sales-analysis 目录'),
        ],
        deviceName: 'DESKTOP-XXXXXXX',
        conversationTitle: '销售分析',
        summary: '已完成 2 步 · 用时 12s',
        now: DateTime(2026, 1, 1, 9, 30),
      );
      expect(data, isNotNull);
      expect(data!.deviceName, 'DESKTOP-XXXXXXX');
      expect(data.title, '销售分析');
      expect(data.userMessage, '销售数据在哪');
      expect(data.assistantMessage, isNot(contains(r'D:\work\sales-analysis')));
      expect(data.assistantMessage, contains('路径已隐藏'));
      expect(data.summary, '已完成 2 步 · 用时 12s');
      expect(data.hasContent, isTrue);
    });

    test('无文本内容返回 null；排队消息不算内容', () {
      expect(
        buildShareCardData(messages: const [], deviceName: 'PC'),
        isNull,
      );
      expect(
        buildShareCardData(
          messages: [_text(ChatRole.user, '排队中', queued: true)],
          deviceName: 'PC',
        ),
        isNull,
      );
      expect(sanitizeShareText('token=abcdef0123456789abcdef0123456789'), isNot(contains('abcdef0123456789')));
    });

    test('渲染 1080 宽 PNG', () async {
      final data = ShareCardData(
        deviceName: 'DESKTOP-XXXXXXX',
        time: DateTime(2026, 1, 1, 9, 30),
        conversationTitle: '销售分析',
        userMessage: '分析一下销售数据',
        assistantMessage: '已完成 3 张图表。',
        summary: '已完成 2 步 · 用时 12s',
      );
      final bytes = await renderShareCardPng(data, AppPalette.light);
      const pngSignature = [137, 80, 78, 71, 13, 10, 26, 10];
      expect(bytes.length, greaterThan(pngSignature.length));
      expect(bytes.sublist(0, 8), pngSignature);

      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      expect(frame.image.width, 1080);
      expect(frame.image.height, greaterThan(1080));
      frame.image.dispose();
      codec.dispose();
    });

    test('ShareCardService 把 PNG 交给系统分享通道', () async {
      final gateway = FakeShareGateway();
      final service = ShareCardService(gateway: gateway);
      final data = ShareCardData(
        deviceName: 'PC',
        time: DateTime(2026, 1, 1),
        userMessage: '你好',
        assistantMessage: '你好，有什么可以帮你？',
      );
      final ok = await service.share(data: data, palette: AppPalette.dark);
      expect(ok, isTrue);
      expect(gateway.shared.length, 1);
      expect(gateway.shared.single.fileName, endsWith('.png'));
      expect(gateway.shared.single.chooserTitle, '分享对话');
      expect(gateway.lastBytes, isNotNull);
      expect(gateway.lastBytes, isNotEmpty);
      service.dispose();
    });
  });

  // -------------------------------- A5 长按菜单 --------------------------------
  group('A5 长按菜单', () {
    test('按消息类型给出动作', () {
      expect(
        actionsForChatItem(_text(ChatRole.user, '你好')),
        [ChatItemAction.copy, ChatItemAction.resend],
      );
      expect(
        actionsForChatItem(_text(ChatRole.assistant, '好的')),
        [ChatItemAction.copy],
      );
      expect(
        actionsForChatItem(ChatItem(
          role: ChatRole.assistant,
          kind: ChatItemKind.toolResult,
          text: '结果',
        )),
        [ChatItemAction.copyOutput],
      );
      expect(actionsForChatItem(_text(ChatRole.user, '排队', queued: true)), isEmpty);
    });

    test('工具输出取法与命令无关', () {
      final item = ChatItem(
        role: ChatRole.assistant,
        kind: ChatItemKind.toolResult,
        text: '整段输出',
        steps: [
          ToolStep(
            title: 'pwsh',
            command: 'Get-ChildItem',
            status: 'done',
            output: '文件 A\n文件 B',
          ),
        ],
      );
      expect(copyableOutput(item), '文件 A\n文件 B');
    });

    testWidgets('长按文本气泡可选择「重新发送」', (tester) async {
      String? resent;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatItemView(
              item: _text(ChatRole.user, '重新发送这条'),
              onApprovalDemo: () {},
              onResend: (text) => resent = text,
            ),
          ),
        ),
      );
      await tester.longPress(find.text('重新发送这条'));
      await tester.pumpAndSettle();
      expect(find.text('消息操作'), findsOneWidget);
      expect(find.text('复制'), findsOneWidget);
      await tester.tap(find.text('重新发送'));
      await tester.pumpAndSettle();
      expect(resent, '重新发送这条');
    });
  });
}
