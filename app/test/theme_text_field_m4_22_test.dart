// M4.22：输入框里打出来的字不能是透明的。
//
// 用户反馈「输入时搜索框里面不显示」：插件市场搜索框里敲了 `dsh`，`onChanged` 收到了、
// 统计行也显示 `“dsh”`，可输入框里只剩一个光标。根因是主题把 `textTheme` **整体替换**
// 成了一个只写了几条样式的部分主题，`bodyLarge` 因此是没有颜色的
// `englishLike bodyLarge 2021`——而 `TextField` 的正文样式取的就是 `bodyLarge`。
//
// 这里守住两件事：①浅色/深色主题里 `TextTheme` 的每条正文样式都必须带颜色；
// ②真实输入框（插件市场搜索框）渲染出来的 `EditableText` 样式必须有颜色。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseek_remote_app/data/live_store.dart';
import 'package:deepseek_remote_app/screens/plugins_screen.dart';
import 'package:deepseek_remote_app/theme/app_theme.dart';

void main() {
  group('M4.22 输入框文字颜色', () {
    test('浅色与深色主题的正文样式都带颜色', () {
      for (final brightness in <Brightness>[
        Brightness.light,
        Brightness.dark,
      ]) {
        final theme = buildAppTheme(brightness);
        final text = theme.textTheme;
        for (final entry in <String, TextStyle?>{
          'bodyLarge': text.bodyLarge,
          'bodyMedium': text.bodyMedium,
          'bodySmall': text.bodySmall,
          'titleLarge': text.titleLarge,
          'titleMedium': text.titleMedium,
          'labelMedium': text.labelMedium,
          'labelSmall': text.labelSmall,
        }.entries) {
          expect(
            entry.value?.color,
            isNotNull,
            reason: '${brightness.name} 的 ${entry.key} 没有颜色，输入框会变成透明字',
          );
        }
      }
    });

    testWidgets('插件市场搜索框打进去的字是可见的', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: PluginsScreen(liveStore: LiveStore()),
      ));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('插件市场'));
      await tester.pumpAndSettle();

      final editable =
          tester.widget<EditableText>(find.byType(EditableText).first);
      expect(editable.style.color, isNotNull);

      await tester.enterText(find.byType(TextField).first, 'dsh');
      await tester.pump();
      expect(find.text('dsh'), findsWidgets);
      expect(editable.controller.text, 'dsh');
    });
  });
}
