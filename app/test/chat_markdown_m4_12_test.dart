import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseek_remote_app/models.dart';
import 'package:deepseek_remote_app/theme/app_theme.dart';
import 'package:deepseek_remote_app/widgets/chat_items.dart';
import 'package:deepseek_remote_app/widgets/markdown_text.dart';

/// M4.12：对话正文按 Markdown 排版。
///
/// 目标是对齐 DeepSeek 官方 App 的观感：`### 标题`、`- 列表`、``` 代码块、
/// `|` 表格都要被**排版**，而不是把记号原样露在屏幕上。

const _sample = '''
一句话

### 同一个例子，两种结果

假设情况：`main` 上已有 A。

用 merge：

```text
* 0843ffb 合并 feature 分支
```

- **加粗**：历史形状
- `代码`：提交身份

| 场景 | 用 |
| --- | --- |
| 合进 main | merge |
| 跟上最新 main | rebase |

> 一条铁律：不要 rebase 已经推送的分支。
''';

void main() {
  group('MarkdownParser（块级解析）', () {
    test('标题 / 段落 / 代码块 / 列表 / 表格 / 引用 各自成块', () {
      final kinds = MarkdownParser.blockKinds(_sample);
      expect(kinds, <String>[
        MdBlockKind.paragraph,
        MdBlockKind.heading,
        MdBlockKind.paragraph,
        MdBlockKind.paragraph,
        MdBlockKind.code,
        MdBlockKind.bullet,
        MdBlockKind.bullet,
        MdBlockKind.table,
        MdBlockKind.quote,
      ]);
    });

    test('标题级别与文本', () {
      final heading = MarkdownParser.parse('### 同一个例子，两种结果').single;
      expect(heading.kind, MdBlockKind.heading);
      expect(heading.level, 3);
      expect(heading.text, '同一个例子，两种结果');
    });

    test('代码块保留语言与原始内容，记号不残留', () {
      final block = MarkdownParser.parse('```dart\nvoid main() {}\n\n  print(1);\n```').single;
      expect(block.kind, MdBlockKind.code);
      expect(block.language, 'dart');
      expect(block.text, 'void main() {}\n\n  print(1);');
      expect(block.text.contains('```'), isFalse);
    });

    test('未闭合的代码块吃到文末，不丢内容', () {
      final block = MarkdownParser.parse('```\nline1\nline2').single;
      expect(block.kind, MdBlockKind.code);
      expect(block.lines, <String>['line1', 'line2']);
    });

    test('表格：表头 + 多行，空单元格保留', () {
      final block = MarkdownParser.parse('| 场景 | 用 |\n| --- | --- |\n| 合进 main | merge |\n| 空 |  |').single;
      expect(block.kind, MdBlockKind.table);
      expect(block.header, <String>['场景', '用']);
      expect(block.rows.length, 2);
      expect(block.rows[1], <String>['空', '']);
    });

    test('不是表格的两行竖线文本仍按段落处理', () {
      final kinds = MarkdownParser.blockKinds('a | b\nc | d');
      expect(kinds, <String>[MdBlockKind.paragraph]);
    });

    test('有序列表、分隔线、缩进列表', () {
      final blocks = MarkdownParser.parse('1. 第一\n2. 第二\n\n---\n\n  - 缩进项');
      expect(blocks.map((b) => b.kind).toList(), <String>[
        MdBlockKind.ordered,
        MdBlockKind.ordered,
        MdBlockKind.rule,
        MdBlockKind.bullet,
      ]);
      expect(blocks[0].level, 1);
      expect(blocks[3].indent, 1);
    });

    test('多行段落合并，空行分段', () {
      final blocks = MarkdownParser.parse('第一行\n第二行\n\n第二段');
      expect(blocks.length, 2);
      expect(blocks[0].text, '第一行\n第二行');
    });

    test('空串与纯空行不产生块', () {
      expect(MarkdownParser.parse(''), isEmpty);
      expect(MarkdownParser.parse('\n\n  \n'), isEmpty);
    });
  });

  group('MarkdownText（渲染）', () {
    Future<void> pump(WidgetTester tester, String text) async {
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: Scaffold(
          body: SingleChildScrollView(
            child: MarkdownText(text),
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('标题不再显示 ### 记号', (tester) async {
      await pump(tester, _sample);
      final texts = find.byType(SelectableText);
      final contents = tester.widgetList<SelectableText>(texts).map(_plain).toList();
      expect(contents.any((t) => t.contains('###')), isFalse);
      expect(contents.any((t) => t.contains('| --- |')), isFalse);
      expect(contents.any((t) => t.contains('```')), isFalse);
    });

    testWidgets('代码块带语言标签与复制按钮', (tester) async {
      await pump(tester, '```text\n* 0843ffb 合并\n```');
      expect(find.text('text'), findsOneWidget);
      expect(find.text('复制'), findsOneWidget);
    });

    testWidgets('表格渲染成 Table，单元格文字齐全', (tester) async {
      await pump(tester, '| 场景 | 用 |\n| --- | --- |\n| 合进 main | merge |');
      expect(find.byType(Table), findsOneWidget);
      expect(_allText(tester, '场景'), findsWidgets);
      expect(_allText(tester, 'merge'), findsWidgets);
    });

    testWidgets('列表用圆点标记，正文不含「- 」（加粗与行内代码已转样式）', (tester) async {
      await pump(tester, '- **加粗**：历史形状\n- `代码`：提交身份');
      expect(find.byType(Row), findsWidgets);
      final contents =
          tester.widgetList<SelectableText>(find.byType(SelectableText)).map(_plain).toList();
      expect(contents, contains('加粗：历史形状'));
      expect(contents, contains('代码：提交身份'));
    });
  });

  group('电脑档对话正文换用 Markdown', () {
    testWidgets('助手消息里的标题与列表被排版', (tester) async {
      final item = ChatItem(
        role: ChatRole.assistant,
        kind: ChatItemKind.text,
        text: '### 一句话\n\n- 第一条\n- 第二条',
        time: DateTime(2026, 11, 16, 14, 30),
      );
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: Scaffold(
          body: SingleChildScrollView(child: ChatItemView(item: item)),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.byType(MarkdownText), findsOneWidget);
      final contents =
          tester.widgetList<SelectableText>(find.byType(SelectableText)).map(_plain).toList();
      expect(contents.any((t) => t.contains('###')), isFalse);
      expect(contents, contains('一句话'));
      expect(contents, contains('第一条'));
    });
  });

  group('buildInlineSpans（行内样式）', () {
    test('加粗 / 行内代码 / 链接 各自成 span', () {
      const base = TextStyle(fontSize: 15);
      final spans = buildInlineSpans(
        '前 **粗** 中 `code` 后 [链接](https://example.com)',
        base,
        onLinkTap: (_) {},
      );
      expect(spans.where((s) => s.style?.fontWeight == FontWeight.w600).length, 1);
      expect(spans.any((s) => s.text == 'code'), isTrue);
      expect(spans.any((s) => s.text == '链接' && s.recognizer != null), isTrue);
      expect(spans.any((s) => s.text == '链接' && s.style?.decoration == TextDecoration.underline), isTrue);
      expect(spans.map((s) => s.text).join(), '前 粗 中 code 后 链接');
    });

    test('没有可点的链接时不注册识别器', () {
      final spans = buildInlineSpans('[链接](https://example.com)', const TextStyle());
      expect(spans.single.recognizer, isNull);
      expect(spans.single.style?.color, mdLinkColor);
      expect(spans.single.text, '链接');
    });

    test('中文里单独的 * 不当斜体吃掉', () {
      final spans = buildInlineSpans('a * b * c', const TextStyle());
      expect(spans.single.text, 'a * b * c');
      expect(spans.single.style?.fontStyle, isNull);
    });
  });
}

String _plain(SelectableText widget) =>
    widget.textSpan?.toPlainText() ?? widget.data ?? '';

Finder _allText(WidgetTester tester, String text) => find.text(text, findRichText: true);
