import 'dart:convert';

import 'package:deepseek_remote_app/screens/cloud_chat_screen.dart';
import 'package:deepseek_remote_app/services/cloud_chat.dart';
import 'package:deepseek_remote_app/theme/app_theme.dart';
import 'package:deepseek_remote_app/widgets/attachment_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// M4.7：手机档（云端直连）也能拍照 / 选相册 / 发文件。
///
/// 覆盖三件事：
/// 1. 附件模型自己就能判断"是不是图片 / 能不能内联"；
/// 2. 请求体拼成 OpenAI 兼容的 `image_url` + 文本多段结构；
/// 3. 云端对话页真的带上附件发出去，并在气泡里显示缩略图。

final _pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

Widget _wrap(Widget child) => MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: Scaffold(body: child),
    );

void main() {
  group('PendingAttachment 分类（M4.7）', () {
    test('图片按后缀识别 MIME', () {
      final jpg = PendingAttachment(name: 'a.JPG', bytes: const [1, 2, 3]);
      final png = PendingAttachment(name: 'b.png', bytes: const [1]);
      final heic = PendingAttachment(name: 'c.heic', bytes: const [1]);
      final doc = PendingAttachment(name: 'd.docx', bytes: const [1]);

      expect(jpg.mediaType, 'image/jpeg');
      expect(jpg.isImage, isTrue);
      expect(png.mediaType, 'image/png');
      expect(heic.mediaType, 'image/heic');
      expect(doc.mediaType, isNull);
      expect(doc.isImage, isFalse);
    });

    test('文本类文件可内联，二进制文件不行', () {
      expect(PendingAttachment(name: 'a.md', bytes: const []).isText, isTrue);
      expect(PendingAttachment(name: 'b.dart', bytes: const []).isText, isTrue);
      expect(PendingAttachment(name: 'c.json', bytes: const []).isText, isTrue);
      expect(PendingAttachment(name: 'd.pdf', bytes: const []).isText, isFalse);
      expect(PendingAttachment(name: 'e.zip', bytes: const []).isText, isFalse);
      expect(PendingAttachment(name: 'f', bytes: const []).isText, isFalse);
    });

    test('大小文案', () {
      expect(PendingAttachment(name: 'a', bytes: List.filled(512, 0)).sizeLabel,
          '512 B');
      expect(
          PendingAttachment(name: 'a', bytes: List.filled(2048, 0)).sizeLabel,
          '2.0 KB');
      expect(
          PendingAttachment(name: 'a', bytes: List.filled(3 * 1024 * 1024, 0))
              .sizeLabel,
          '3.0 MB');
    });
  });

  group('CloudMessage.buildUserContent（M4.7）', () {
    test('没有附件时保持纯字符串', () async {
      final content = await CloudMessage.user('你好').buildContent();
      expect(content, '你好');
    });

    test('图片走 image_url base64，文字在前', () async {
      final content = await CloudMessage.user(
        '这张图有什么问题',
        attachments: [
          PendingAttachment(name: 'shot.png', bytes: _pngBytes),
        ],
      ).buildContent() as List<Map<String, dynamic>>;

      expect(content, hasLength(2));
      expect(content.first['type'], 'text');
      expect(content.first['text'], '这张图有什么问题');
      expect(content.last['type'], 'image_url');
      final image = content.last['image_url'] as Map<String, dynamic>;
      expect(image['url'], startsWith('data:image/png;base64,'));
      expect(image['url'], contains(base64Encode(_pngBytes)));
    });

    test('文本文件内联成【附件】段，二进制只提示名字', () async {
      final content = await CloudMessage.user(
        '看看这两个文件',
        attachments: [
          PendingAttachment(
            name: 'notes.md',
            bytes: utf8.encode('# 标题\n正文'),
          ),
          PendingAttachment(name: 'report.pdf', bytes: const [1, 2, 3]),
        ],
      ).buildContent() as List<Map<String, dynamic>>;

      // 没有图片 → 只有一个文本段。
      expect(content, hasLength(1));
      final text = content.single['text'] as String;
      expect(text, startsWith('看看这两个文件'));
      expect(text, contains('【附件 notes.md】'));
      expect(text, contains('# 标题'));
      expect(text, contains('已附带文件：report.pdf'));
    });

    test('只发图片、不写字时补一句占位', () async {
      final content = await CloudMessage.user(
        '',
        attachments: [
          PendingAttachment(name: 'shot.png', bytes: _pngBytes),
        ],
      ).buildContent() as List<Map<String, dynamic>>;

      expect(content, hasLength(2));
      expect((content.first['text'] as String).isNotEmpty, isTrue);
    });
  });

  group('云端对话页的附件入口（M4.7）', () {
    testWidgets('未配置接口时不显示附件入口', (tester) async {
      final store = _FakeStore(null);
      await tester.pumpWidget(_wrap(CloudChatScreen(store: store, client: null)));
      await tester.pumpAndSettle();

      expect(find.text('填一个 API Key 就能用'), findsOneWidget);
      expect(find.byType(AttachmentBar), findsNothing);
      expect(find.textContaining('要发图片'), findsOneWidget);
    });

    testWidgets('已配置后输入条上方常驻拍照 / 相册 / 文件', (tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 900));
      final store = _FakeStore(
        const CloudChatConfig(apiKey: 'sk-test', model: 'gpt-4o'),
      );
      await tester.pumpWidget(_wrap(CloudChatScreen(store: store, client: _FakeClient())));
      await tester.pumpAndSettle();

      expect(find.byType(AttachmentBar), findsOneWidget);
      expect(find.text('拍照'), findsOneWidget);
      expect(find.text('相册'), findsOneWidget);
      expect(find.text('文件'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('附件随消息发出去，气泡里能看到缩略图', (tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 900));
      final store = _FakeStore(
        const CloudChatConfig(apiKey: 'sk-test', model: 'gpt-4o'),
      );
      final client = _FakeClient();
      await tester.pumpWidget(_wrap(CloudChatScreen(store: store, client: client)));
      await tester.pumpAndSettle();

      final state = tester.state<State<CloudChatScreen>>(
        find.byType(CloudChatScreen),
      ) as dynamic;
      state.attachForTest(name: 'shot.png', bytes: _pngBytes);
      await tester.pump();
      expect(find.byType(AttachmentBar), findsOneWidget);

      await state.sendForTest('这个图里是什么');
      await tester.pumpAndSettle();

      // 发出去的请求体里带了 image_url。
      expect(client.sent, hasLength(1));
      final user = (client.sent.single as List<Map<String, dynamic>>)
          .firstWhere((m) => m['role'] == 'user');
      final content = user['content'] as List<Map<String, dynamic>>;
      expect(content.map((part) => part['type']),
          containsAll(<String>['text', 'image_url']));
      // 附件发完就清空，不会重复带上。
      expect((state.pendingAttachmentsForTest as List).isEmpty, isTrue);
      // 气泡里渲染了缩略图 + 文字。
      expect(find.byType(Image), findsWidgets);
      expect(find.text('这个图里是什么'), findsOneWidget);
      expect(find.text('模型看到了'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.binding.setSurfaceSize(null);
    });
  });
}

class _FakeStore extends CloudChatStore {
  _FakeStore(this._config);

  final CloudChatConfig? _config;

  @override
  Future<CloudChatConfig?> load() async => _config;

  @override
  Future<void> save(CloudChatConfig config) async {}
}

class _FakeClient extends CloudChatClient {
  final List<List<Map<String, dynamic>>> sent = [];

  @override
  Future<String> complete({
    required CloudChatConfig config,
    required List<CloudMessage> history,
    CaretakerReader? caretaker,
    String systemPrompt =
        '你是一个简洁、可靠的中文助手。回答直接给结论，需要时再展开。',
    void Function(String delta)? onDelta,
    CancellationToken? cancel,
  }) async {
    sent.add([
      for (final message in history)
        <String, dynamic>{
          'role': message.role,
          'content': message.role == 'user'
              ? await message.buildContent(caretaker: caretaker)
              : message.text,
        },
    ]);
    onDelta?.call('模型看到了');
    return '模型看到了';
  }

  @override
  void close() {}
}
