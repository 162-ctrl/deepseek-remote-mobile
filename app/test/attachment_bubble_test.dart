import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseek_remote_app/models.dart';
import 'package:deepseek_remote_app/theme/app_theme.dart';
import 'package:deepseek_remote_app/widgets/chat_items.dart';

void main() {
  testWidgets('用户气泡把附件路径收成文件名（M3.3）', (tester) async {
    final item = ChatItem(
      role: ChatRole.user,
      kind: ChatItemKind.text,
      text: '看下这张图\n\n附件（已保存到电脑）：\n'
          '- C:\\Users\\user\\.dsh\\dsh-plugin-m1\\uploads\\2026-11-11-a.jpg',
      time: DateTime(2026, 11, 11, 12, 30),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          extensions: <ThemeExtension<dynamic>>[
            AppPaletteExt(AppPalette.light),
          ],
        ),
        home: Scaffold(body: ChatItemView(item: item)),
      ),
    );

    expect(find.text('看下这张图'), findsOneWidget);
    expect(find.text('2026-11-11-a.jpg'), findsOneWidget);
    expect(find.textContaining('附件（已保存到电脑）'), findsNothing);
    expect(find.textContaining('C:\\Users'), findsNothing);
  });

  testWidgets('只发附件时气泡只显示文件名（M3.3）', (tester) async {
    final item = ChatItem(
      role: ChatRole.user,
      kind: ChatItemKind.text,
      text: '我发了一些附件，请看一下：\n附件（已保存到电脑）：\n'
          '- C:\\tmp\\photo.png',
      time: DateTime(2026, 11, 11, 12, 31),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          extensions: <ThemeExtension<dynamic>>[
            AppPaletteExt(AppPalette.light),
          ],
        ),
        home: Scaffold(body: ChatItemView(item: item)),
      ),
    );

    expect(find.text('我发了一些附件，请看一下：'), findsNothing);
    expect(find.text('photo.png'), findsOneWidget);
  });
}
