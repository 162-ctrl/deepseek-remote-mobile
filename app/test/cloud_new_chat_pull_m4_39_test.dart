
import 'package:deepseek_remote_app/screens/cloud_chat_screen.dart';
import 'package:deepseek_remote_app/services/cloud_chat.dart';
import 'package:deepseek_remote_app/services/cloud_conversations.dart';
import 'package:deepseek_remote_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// M4.39：手机档对话里**往上滑**一截，底部浮出一枚加载圈（进度跟着手走），
/// 滑够了松手就开一条新对话。
///
/// M4.37 把方向做反了（要先翻到最老的一条再往下拽），用户明确纠正：
/// 「不是下划是往上划，有个加载圈，根据上滑的力度」。
void main() {
  late _MemoryChatStore configStore;
  late _MemoryConversationStore conversations;

  setUp(() {
    configStore = _MemoryChatStore(
      const CloudChatConfig(apiKey: 'sk-test', model: 'deepseek-chat'),
    );
    conversations = _MemoryConversationStore([
      CloudConversation(
        id: 'one',
        createdAt: DateTime(2026, 11, 18, 9),
        updatedAt: DateTime(2026, 11, 18, 10),
        title: '旧的那条',
        messages: const [
          CloudChatRecord(role: 'user', text: '旧对话里的话'),
          CloudChatRecord(role: 'assistant', text: '旧对话里的回答'),
        ],
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

  Finder messageList() => find.byType(ListView).first;

  testWidgets('往上滑过阈值，松手就新建一条对话', (tester) async {
    await tester.pumpWidget(app(CloudChatController()));
    await tester.pumpAndSettle();
    expect(find.text('旧对话里的话'), findsOneWidget);

    final gesture = await tester.startGesture(tester.getCenter(messageList()));
    await gesture.moveBy(const Offset(0, -220));
    await tester.pump();

    // 滑到位了先给个提示（此时还没真的新建）。
    expect(find.text('松手开始新对话'), findsOneWidget);
    expect(conversations.items.length, 1);

    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('旧对话里的话'), findsNothing);
    expect(find.text('旧对话里的回答'), findsNothing);
    expect(find.text('松手开始新对话'), findsNothing);
    // 原来那条还在，另外多了一条空白的新对话。
    expect(conversations.items.length, 2);
    expect(conversations.items.first.messages, isEmpty);
    expect(conversations.items.any((item) => item.id == 'one'), isTrue);
  });

  testWidgets('滑一点点只出圈不新建', (tester) async {
    await tester.pumpWidget(app(CloudChatController()));
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(tester.getCenter(messageList()));
    await gesture.moveBy(const Offset(0, -60));
    await tester.pump();

    // M4.39：圈一滑就出来，但文案还没到「松手」那一步。
    expect(find.text('继续上滑新建对话'), findsOneWidget);
    expect(find.text('松手开始新对话'), findsNothing);

    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('旧对话里的话'), findsOneWidget);
    expect(conversations.items.length, 1);
  });

  testWidgets('长对话里翻历史、一甩到底都不会误触，单独再滑才出圈', (tester) async {
    conversations = _MemoryConversationStore([
      CloudConversation(
        id: 'long',
        createdAt: DateTime(2026, 11, 18, 9),
        updatedAt: DateTime(2026, 11, 18, 10),
        title: '长对话',
        messages: List<CloudChatRecord>.generate(
          40,
          (index) => CloudChatRecord(
            role: index.isEven ? 'user' : 'assistant',
            text: '第 $index 句',
          ),
        ),
      ),
    ]);
    await tester.pumpWidget(app(CloudChatController()));
    await tester.pumpAndSettle();

    // ① 手指往下 = 往上翻历史，这一段不该冒出加载圈。
    final history = await tester.startGesture(tester.getCenter(messageList()));
    await history.moveBy(const Offset(0, 260));
    await tester.pump();
    expect(find.text('继续上滑新建对话'), findsNothing);
    expect(find.text('松手开始新对话'), findsNothing);
    await history.up();
    await tester.pumpAndSettle();

    // ② 从半路一甩到底：这一手滚过列表，所以即使越界量很大也不算数。
    final fling = await tester.startGesture(tester.getCenter(messageList()));
    await fling.moveBy(const Offset(0, -4000));
    await tester.pump();
    expect(find.text('松手开始新对话'), findsNothing);
    await fling.up();
    await tester.pumpAndSettle();
    expect(find.text('第 39 句'), findsWidgets);

    // ③ 停在最新一条上，单独往上滑过阈值才出圈。
    final pull = await tester.startGesture(tester.getCenter(messageList()));
    await pull.moveBy(const Offset(0, -220));
    await tester.pump();
    expect(find.text('松手开始新对话'), findsOneWidget);

    // 松手前反向拖回去：松手不该新建。
    await pull.moveBy(const Offset(0, 260));
    await tester.pump();
    expect(find.text('松手开始新对话'), findsNothing);

    await pull.up();
    await tester.pumpAndSettle();
    // 反向拖回 260 已经翻回历史里了，所以只钉「对话没被换掉」。
    expect(find.textContaining('句'), findsWidgets);
    expect(conversations.items.length, 1);
  });
}

class _MemoryChatStore extends CloudChatStore {
  _MemoryChatStore(this.config);

  CloudChatConfig? config;

  @override
  Future<CloudChatConfig?> load() async => config;

  @override
  Future<void> save(CloudChatConfig value) async => config = value;

  @override
  Future<void> clear() async => config = null;
}

class _MemoryConversationStore extends CloudConversationStore {
  _MemoryConversationStore(this.items);

  List<CloudConversation> items;

  @override
  Future<List<CloudConversation>> load() async => items;

  @override
  Future<void> save(List<CloudConversation> next) async => items = next;
}
