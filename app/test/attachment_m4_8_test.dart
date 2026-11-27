import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:deepseek_remote_app/services/cloud_chat.dart';
import 'package:deepseek_remote_app/widgets/attachment_bar.dart';

/// M4.8：「和正常的 AI 一样」——附件不进电脑、界面不喊上传，认不出的格式
/// 由本机直读兜底。这里只测纯函数与接口形状，不建 widget。
class _TextCaretaker implements CaretakerReader {
  _TextCaretaker(this.reply);

  final String? reply;
  final List<String> seen = [];

  @override
  Future<String?> read(PendingAttachment attachment) async {
    seen.add(attachment.name);
    return reply;
  }
}

void main() {
  group('非图片附件交给本机直读（M4.8）', () {
    test('PDF 由电脑读成文字后内联进 prompt', () async {
      final caretaker = _TextCaretaker('第三章 结论：全部通过。');
      final content = await CloudMessage.user(
        '这份报告讲了什么',
        attachments: [
          PendingAttachment(name: 'report.pdf', bytes: const [37, 80, 68, 70]),
        ],
      ).buildContent(caretaker: caretaker);

      expect(caretaker.seen, ['report.pdf']);
      final parts = content as List<Map<String, dynamic>>;
      final text = parts.single['text'] as String;
      expect(text, contains('这份报告讲了什么'));
      expect(text, contains('【附件 report.pdf】'));
      expect(text, contains('第三章 结论：全部通过。'));
      expect(text, isNot(contains('格式不支持')));
    });

    test('没有电脑或读不出时，只提示文件名而不是报错', () async {
      final parts = await CloudMessage.user(
        '看看',
        attachments: [
          PendingAttachment(name: 'archive.zip', bytes: const [80, 75, 3, 4]),
        ],
      ).buildContent(caretaker: _TextCaretaker(null)) as List<Map<String, dynamic>>;

      final text = parts.single['text'] as String;
      expect(text, contains('已附带文件：archive.zip'));
      expect(text, contains('格式不支持在手机上预览'));
    });

    test('读的时候抛异常也不影响发送', () async {
      final parts = await CloudMessage.user(
        '看看',
        attachments: [
          PendingAttachment(name: 'x.docx', bytes: const [1]),
        ],
      ).buildContent(caretaker: _ThrowingCaretaker()) as List<Map<String, dynamic>>;

      expect((parts.single['text'] as String), contains('已附带文件：x.docx'));
    });

    test('图片始终直发模型，不交给电脑', () async {
      final caretaker = _TextCaretaker('不该被调用');
      final parts = await CloudMessage.user(
        '这张图呢',
        attachments: [
          PendingAttachment(name: 'a.png', bytes: const [137, 80, 78, 71]),
        ],
      ).buildContent(caretaker: caretaker) as List<Map<String, dynamic>>;

      expect(caretaker.seen, isEmpty);
      expect(parts.last['type'], 'image_url');
    });

    test('文本文件仍然在手机上内联，不麻烦电脑', () async {
      final caretaker = _TextCaretaker('不该被调用');
      final parts = await CloudMessage.user(
        '总结一下',
        attachments: [
          PendingAttachment(name: 'a.md', bytes: utf8.encode('# 标题')),
        ],
      ).buildContent(caretaker: caretaker) as List<Map<String, dynamic>>;

      expect(caretaker.seen, isEmpty);
      expect(parts.single['text'] as String, contains('# 标题'));
    });
  });

  group('多段 content 的 JSON 形状（M4.8）', () {
    test('文本段 + 图片段可以 jsonEncode，服务端能直接吃', () async {
      final parts = await CloudMessage.user(
        '对比这两张',
        attachments: [
          PendingAttachment(name: 'a.png', bytes: const [1, 2, 3]),
          PendingAttachment(name: 'b.jpg', bytes: const [4, 5, 6]),
        ],
      ).buildContent() as List<Map<String, dynamic>>;

      final encoded = jsonEncode(parts);
      final decoded = jsonDecode(encoded) as List<dynamic>;
      expect(decoded, hasLength(3));
      expect((decoded[1] as Map)['image_url'], isA<Map>());
    });
  });
}

class _ThrowingCaretaker implements CaretakerReader {
  @override
  Future<String?> read(PendingAttachment attachment) async {
    throw StateError('电脑离线');
  }
}
