import 'dart:async';
import 'dart:io';

import 'package:deepseek_remote_app/screens/cloud_chat_screen.dart';
import 'package:deepseek_remote_app/services/cloud_chat.dart';
import 'package:deepseek_remote_app/services/cloud_conversations.dart';
import 'package:deepseek_remote_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// M4.27：手机档的对话记录（新建 / 存盘 / 侧边历史）。
void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('cloud-conversations-test');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<Directory> dir() async => temp;

  group('对话记录的存与读', () {
    test('存进去再读出来，消息与标题都在，按更新时间倒序', () async {
      final store = CloudConversationStore(directory: dir);
      final older = CloudConversation(
        id: 'a',
        createdAt: DateTime(2026, 11, 17, 8),
        updatedAt: DateTime(2026, 11, 17, 9),
        title: '早一点的对话',
        messages: const [
          CloudChatRecord(role: 'user', text: '你好'),
          CloudChatRecord(role: 'assistant', text: '在的'),
        ],
      );
      final newer = CloudConversation(
        id: 'b',
        createdAt: DateTime(2026, 11, 17, 10),
        updatedAt: DateTime(2026, 11, 17, 11),
        messages: const [CloudChatRecord(role: 'user', text: '第二句')],
      );
      await store.save([older, newer]);

      final loaded = await CloudConversationStore(directory: dir).load();
      expect(loaded.map((item) => item.id).toList(), ['b', 'a']);
      expect(loaded[1].title, '早一点的对话');
      expect(loaded[1].messages.length, 2);
      expect(loaded[1].messages[1].role, 'assistant');
      expect(loaded[1].messages[1].text, '在的');
    });

    test('没有标题时用第一句用户消息当标题', () {
      final conversation = CloudConversation(
        id: 'c',
        createdAt: DateTime(2026, 11, 17),
        updatedAt: DateTime(2026, 11, 17),
        messages: const [
          CloudChatRecord(role: 'assistant', text: '你好呀'),
          CloudChatRecord(role: 'user', text: '帮我把这段话改成晚会致辞'),
        ],
      );
      expect(conversation.displayTitle, '帮我把这段话改成晚会致辞');
      expect(
        CloudConversation(
          id: 'd',
          createdAt: DateTime(2026, 11, 17),
          updatedAt: DateTime(2026, 11, 17),
        ).displayTitle,
        '新对话',
      );
    });

    test('标题压成单行并截断', () {
      expect(conversationTitle('  第一行\n第二行  '), '第一行 第二行');
      expect(conversationTitle('一二三四五六七八九十一二三四五六七八九十'), '一二三四五六七八九十一二三四五六七八…');
      expect(conversationTitle('   '), '');
    });

    test('只保留最近的若干条', () async {
      final store = CloudConversationStore(directory: dir, maxConversations: 2);
      final items = List<CloudConversation>.generate(
        5,
        (index) => CloudConversation(
          id: 'id$index',
          createdAt: DateTime(2026, 11, 17, index),
          updatedAt: DateTime(2026, 11, 17, index),
        ),
      );
      await store.save(items);
      final loaded = await store.load();
      expect(loaded.map((item) => item.id).toList(), ['id4', 'id3']);
    });

    test('文件坏了当空库，不抛异常', () async {
      final file = File('${temp.path}${Platform.pathSeparator}${CloudConversationStore.fileName}');
      await file.writeAsString('{ not json ');
      expect(await CloudConversationStore(directory: dir).load(), isEmpty);
    });
  });

  // testWidgets 跑在 fake-async 里，真实文件读写永远不会完成，所以 widget 测试
  // 用内存里的假存储；真实读写由上面那组纯 Dart 的 test() 覆盖。
  group('手机档的多对话', () {
    late _MemoryChatStore configStore;
    late _MemoryConversationStore conversations;

    setUp(() {
      configStore = _MemoryChatStore(
        const CloudChatConfig(apiKey: 'sk-test', model: 'deepseek-chat'),
      );
      conversations = _MemoryConversationStore([
        CloudConversation(
          id: 'old',
          createdAt: DateTime(2026, 11, 17, 8),
          updatedAt: DateTime(2026, 11, 17, 9),
          title: '旧的那条',
          messages: const [
            CloudChatRecord(role: 'user', text: '旧对话里的话'),
            CloudChatRecord(role: 'assistant', text: '旧对话里的回答'),
          ],
        ),
        CloudConversation(
          id: 'new',
          createdAt: DateTime(2026, 11, 17, 10),
          updatedAt: DateTime(2026, 11, 17, 11),
          title: '最近那条',
          messages: const [CloudChatRecord(role: 'user', text: '最近说过的话')],
        ),
      ]);
    });

    Widget app(CloudChatController controller) => MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: Scaffold(
            body: CloudChatScreen(
              embedded: true,
              controller: controller,
              store: configStore,
              conversations: conversations,
            ),
          ),
        );

    testWidgets('打开时显示最近那条对话', (tester) async {
      await tester.pumpWidget(app(CloudChatController()));
      await tester.pumpAndSettle();

      expect(find.text('最近说过的话'), findsOneWidget);
      expect(find.text('旧对话里的话'), findsNothing);
    });

    testWidgets('侧栏列出历史，点一条就切过去', (tester) async {
      final controller = CloudChatController();
      await tester.pumpWidget(app(controller));
      await tester.pumpAndSettle();

      unawaited(controller.openHistory());
      await tester.pumpAndSettle();
      expect(find.text('对话记录'), findsOneWidget);
      expect(find.text('最近那条'), findsOneWidget);
      expect(find.text('旧的那条'), findsOneWidget);

      await tester.tap(find.text('旧的那条'));
      await tester.pumpAndSettle();
      expect(find.text('旧对话里的话'), findsOneWidget);
      expect(find.text('旧对话里的回答'), findsOneWidget);
      expect(find.text('最近说过的话'), findsNothing);
    });

    testWidgets('新对话会真的另起一条，并且写回存储', (tester) async {
      final controller = CloudChatController();
      await tester.pumpWidget(app(controller));
      await tester.pumpAndSettle();

      unawaited(controller.openHistory());
      await tester.pumpAndSettle();
      await tester.tap(find.text('新对话'));
      await tester.pumpAndSettle();

      expect(find.text('最近说过的话'), findsNothing);
      expect(find.text('旧对话里的话'), findsNothing);
      expect(conversations.items.length, 3);
      expect(conversations.items.first.messages, isEmpty);
    });

    testWidgets('删掉一条不会把别的一起弄丢', (tester) async {
      final controller = CloudChatController();
      await tester.pumpWidget(app(controller));
      await tester.pumpAndSettle();

      unawaited(controller.openHistory());
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('删除这条对话').first);
      await tester.pumpAndSettle();

      expect(conversations.items.map((item) => item.id).toList(), ['old']);
      expect(find.text('旧对话里的话'), findsOneWidget);
    });

    testWidgets('重新打开时说过的话还在', (tester) async {
      await tester.pumpWidget(app(CloudChatController()));
      await tester.pumpAndSettle();
      expect(find.text('最近说过的话'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await tester.pumpWidget(app(CloudChatController()));
      await tester.pumpAndSettle();
      expect(find.text('最近说过的话'), findsOneWidget);
      expect(conversations.items.length, 2);
    });
  });
}

class _MemoryChatStore extends CloudChatStore {
  _MemoryChatStore(this.config);

  CloudChatConfig? config;

  @override
  Future<CloudChatConfig?> load() async => config;

  @override
  Future<void> save(CloudChatConfig value) async {
    config = value;
  }

  @override
  Future<void> clear() async {
    config = null;
  }
}

class _MemoryConversationStore extends CloudConversationStore {
  _MemoryConversationStore(List<CloudConversation> seed) : _seed = seed;

  final List<CloudConversation> _seed;

  List<CloudConversation> get items => _seed;

  int saves = 0;

  @override
  Future<List<CloudConversation>> load() async =>
      List<CloudConversation>.of(_seed)
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  @override
  Future<void> save(List<CloudConversation> conversations) async {
    saves += 1;
    _seed
      ..clear()
      ..addAll(conversations);
  }
}