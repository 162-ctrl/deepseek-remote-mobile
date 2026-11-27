import 'package:flutter_test/flutter_test.dart';

import 'package:deepseek_remote_app/services/message_text.dart';

void main() {
  group('附件消息拆分（M3.2）', () {
    test('把正文和附件路径拆开', () {
      final parsed = parseUserText(
        '看下这张图\n\n附件（已保存到电脑）：\n'
        '- C:\\Users\\user\\.dsh\\dsh-plugin-m1\\uploads\\2026-11-11-a.jpg\n'
        '- C:\\Users\\user\\.dsh\\dsh-plugin-m1\\uploads\\2026-11-11-b.pdf',
      );

      expect(parsed.body, '看下这张图');
      expect(parsed.attachments, hasLength(2));
      expect(attachmentFileName(parsed.attachments.first), '2026-11-11-a.jpg');
      expect(attachmentFileName(parsed.attachments.last), '2026-11-11-b.pdf');
    });

    test('只发附件时隐藏自动补的占位话', () {
      final parsed = parseUserText(
        '$kAttachmentOnlyHint\n附件（已保存到电脑）：\n'
        '- C:\\tmp\\photo.png',
      );

      expect(parsed.body, isEmpty);
      expect(parsed.attachments, ['C:\\tmp\\photo.png']);
    });

    test('没有附件标记时原样返回', () {
      final parsed = parseUserText('  普通消息  ');

      expect(parsed.body, '普通消息');
      expect(parsed.attachments, isEmpty);
      expect(parsed.hasAttachments, isFalse);
    });
  });
}
