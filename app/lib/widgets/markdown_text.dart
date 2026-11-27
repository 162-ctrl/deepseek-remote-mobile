import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';

/// M4.12：对话正文的 Markdown 排版（对齐 DeepSeek 官方 App 的观感）。
///
/// 以前正文只认 `**加粗**` 与 `` `代码` ``，`##`、`- `、代码块和表格都原样
/// 露在屏幕上。这里做一个**零依赖**的块级解析器：按行切块，再交给对应的
/// widget 渲染，链接 / 加粗 / 行内代码这些行内样式用 `TextSpan` 拼。
///
/// 解析是纯函数（[MarkdownParser.blockKinds] 供单测断言），渲染在
/// [MarkdownText] 里。故意不做的事：嵌套列表、脚注、HTML、图片语法。
class MdBlockKind {
  const MdBlockKind._();

  static const String heading = 'heading';
  static const String paragraph = 'paragraph';
  static const String bullet = 'bullet';
  static const String ordered = 'ordered';
  static const String quote = 'quote';
  static const String code = 'code';
  static const String table = 'table';
  static const String rule = 'rule';
}

/// 一个块级元素。
class MdBlock {
  const MdBlock(
    this.kind, {
    this.text = '',
    this.level = 0,
    this.lines = const <String>[],
    this.rows = const <List<String>>[],
    this.header = const <String>[],
    this.language = '',
    this.indent = 0,
  });

  final String kind;

  /// 正文 / 列表项 / 引用 / 标题的原始文字（含行内标记）。
  final String text;

  /// 标题级别（1~6）。
  final int level;

  /// 代码块、引用的原始行。
  final List<String> lines;

  /// 表格数据行。
  final List<List<String>> rows;

  /// 表格表头。
  final List<String> header;

  /// 代码块语言（``` 后面那串）。
  final String language;

  /// 列表嵌套层数（0 起）。
  final int indent;
}

/// 块级 Markdown 解析器。
class MarkdownParser {
  const MarkdownParser._();

  static final _heading = RegExp(r'^(#{1,6})\s+(.*)$');
  static final _fence = RegExp(r'^```\s*([A-Za-z0-9_+-]*)');
  static final _bullet = RegExp(r'^(\s*)[-*+]\s+(.*)$');
  static final _ordered = RegExp(r'^(\s*)(\d{1,3})[.)]\s+(.*)$');
  static final _rule = RegExp(r'^\s*([-*_])(\s*\1){2,}\s*$');
  static final _tableSep = RegExp(r'^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$');

  /// 解析成块列表。空行只做分段处理，不产生块。
  static List<MdBlock> parse(String source) {
    final blocks = <MdBlock>[];
    final lines = source.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
    var i = 0;
    while (i < lines.length) {
      final line = lines[i];
      if (line.trim().isEmpty) {
        i++;
        continue;
      }
      // 围栏代码块：一直吃到收尾围栏或文末。
      final fence = _fence.firstMatch(line.trimLeft());
      if (fence != null) {
        final language = fence.group(1) ?? '';
        final body = <String>[];
        i++;
        while (i < lines.length && !lines[i].trimLeft().startsWith('```')) {
          body.add(lines[i]);
          i++;
        }
        if (i < lines.length) i++;
        blocks.add(MdBlock(
          MdBlockKind.code,
          text: body.join('\n'),
          lines: body,
          language: language,
        ));
        continue;
      }
      // 表格：表头行 + 分隔行才算。
      if (line.contains('|') &&
          i + 1 < lines.length &&
          _tableSep.hasMatch(lines[i + 1]) &&
          lines[i + 1].contains('-')) {
        final header = _splitRow(line);
        final rows = <List<String>>[];
        i += 2;
        while (i < lines.length && lines[i].trim().isNotEmpty && lines[i].contains('|')) {
          rows.add(_splitRow(lines[i]));
          i++;
        }
        blocks.add(MdBlock(MdBlockKind.table, header: header, rows: rows));
        continue;
      }
      final heading = _heading.firstMatch(line);
      if (heading != null) {
        blocks.add(MdBlock(
          MdBlockKind.heading,
          text: heading.group(2)!.trim(),
          level: heading.group(1)!.length,
        ));
        i++;
        continue;
      }
      if (_rule.hasMatch(line)) {
        blocks.add(const MdBlock(MdBlockKind.rule));
        i++;
        continue;
      }
      if (line.trimLeft().startsWith('>')) {
        final quoted = <String>[];
        while (i < lines.length && lines[i].trimLeft().startsWith('>')) {
          quoted.add(lines[i].trimLeft().replaceFirst(RegExp(r'^>\s?'), ''));
          i++;
        }
        blocks.add(MdBlock(
          MdBlockKind.quote,
          text: quoted.join('\n'),
          lines: quoted,
        ));
        continue;
      }
      final bullet = _bullet.firstMatch(line);
      if (bullet != null) {
        blocks.add(MdBlock(
          MdBlockKind.bullet,
          text: bullet.group(2)!.trim(),
          indent: _indentOf(bullet.group(1)!),
        ));
        i++;
        continue;
      }
      final ordered = _ordered.firstMatch(line);
      if (ordered != null) {
        blocks.add(MdBlock(
          MdBlockKind.ordered,
          text: ordered.group(3)!.trim(),
          level: int.parse(ordered.group(2)!),
          indent: _indentOf(ordered.group(1)!),
        ));
        i++;
        continue;
      }
      // 普通段落：连续非空、非块起始的行并成一段。
      final buffer = <String>[line];
      i++;
      while (i < lines.length && _continuesParagraph(lines[i])) {
        buffer.add(lines[i]);
        i++;
      }
      blocks.add(MdBlock(MdBlockKind.paragraph, text: buffer.join('\n').trim()));
    }
    return blocks;
  }

  /// 块类型序列——单测用它断言解析结果。
  static List<String> blockKinds(String source) =>
      parse(source).map((block) => block.kind).toList(growable: false);

  static bool _continuesParagraph(String line) {
    if (line.trim().isEmpty) return false;
    if (_heading.hasMatch(line)) return false;
    if (line.trimLeft().startsWith('```')) return false;
    if (_bullet.hasMatch(line)) return false;
    if (_ordered.hasMatch(line)) return false;
    if (line.trimLeft().startsWith('>')) return false;
    if (_rule.hasMatch(line)) return false;
    return true;
  }

  static int _indentOf(String spaces) {
    final width = spaces.replaceAll('\t', '  ').length;
    return (width ~/ 2).clamp(0, 3);
  }

  /// 切表格一行：去首尾竖线，按竖线切，保留空单元格。
  static List<String> _splitRow(String line) {
    var trimmed = line.trim();
    if (trimmed.startsWith('|')) trimmed = trimmed.substring(1);
    if (trimmed.endsWith('|')) trimmed = trimmed.substring(0, trimmed.length - 1);
    return trimmed.split('|').map((cell) => cell.trim()).toList(growable: false);
  }
}

/// 正文里一段可点击的链接（便于测试和以后接外链）。
class MdLink {
  const MdLink({required this.start, required this.end, required this.url, required this.label});

  /// 在原始文本里的位置。
  final int start;
  final int end;
  final String url;
  final String label;
}

/// 正文里链接文字的颜色（与主色一致，带下划线以示可点）。
const Color mdLinkColor = Color(0xFF4C5CFF);

/// 行内标记的匹配规则：`` `代码` ``、`**加粗**`、`__加粗__`、
/// `~~删除~~`、`[文字](链接)`、单独的 `*斜体*`。
final RegExp _inlinePattern = RegExp(
  r'`[^`]+`|\*\*[^*]+\*\*|__[^_]+__|~~[^~]+~~|\[[^\]]+\]\([^)]+\)|(?<![*\w])\*[^*\s][^*]*\*(?!\*)',
);

/// 把一行 Markdown 拼成 [TextSpan]（沿用调用方给的基础 style）。
///
/// 链接默认样式与正文一致（官方 App 里链接不上色抢注意力），
/// 只通过 [onLinkTap] 提供点击。
List<TextSpan> buildInlineSpans(
  String text,
  TextStyle base, {
  Color? codeColor,
  Color? codeBackground,
  void Function(String url)? onLinkTap,
}) {
  final spans = <TextSpan>[];
  var last = 0;
  for (final match in _inlinePattern.allMatches(text)) {
    if (match.start > last) {
      spans.add(TextSpan(text: text.substring(last, match.start)));
    }
    final raw = match.group(0)!;
    if (raw.startsWith('`')) {
      final codePaint = codeBackground == null
          ? null
          : (Paint()..color = codeBackground);
      spans.add(TextSpan(
        text: raw.substring(1, raw.length - 1),
        style: base.copyWith(
          fontFamily: kMono.fontFamily,
          fontFamilyFallback: kMono.fontFamilyFallback,
          fontSize: (base.fontSize ?? 15) - 0.6,
          color: codeColor,
          background: codePaint,
        ),
      ));
    } else if (raw.startsWith('**') || raw.startsWith('__')) {
      // 中文加粗用 w600：系统对 CJK 的 w700 是伪装加粗，手机上会糊。
      spans.add(TextSpan(
        text: raw.substring(2, raw.length - 2),
        style: const TextStyle(fontWeight: FontWeight.w600),
      ));
    } else if (raw.startsWith('~~')) {
      spans.add(TextSpan(
        text: raw.substring(2, raw.length - 2),
        style: const TextStyle(decoration: TextDecoration.lineThrough),
      ));
    } else if (raw.startsWith('[')) {
      final close = raw.indexOf('](');
      final label = raw.substring(1, close);
      final url = raw.substring(close + 2, raw.length - 1);
      TapGestureRecognizer? recognizer;
      if (onLinkTap != null) {
        recognizer = TapGestureRecognizer()..onTap = () => onLinkTap(url);
      }
      spans.add(TextSpan(
        text: label,
        recognizer: recognizer,
        style: const TextStyle(
          color: mdLinkColor,
          decoration: TextDecoration.underline,
          decorationColor: mdLinkColor,
        ),
      ));
    } else if (raw.startsWith('*')) {
      spans.add(TextSpan(
        text: raw.substring(1, raw.length - 1),
        style: const TextStyle(fontStyle: FontStyle.italic),
      ));
    }
    last = match.end;
  }
  if (last < text.length) {
    spans.add(TextSpan(text: text.substring(last)));
  }
  return spans;
}

/// 一行 Markdown 文本（支持行内标记、换行），不参与块级排版。
///
/// 标题 / 表格单元格 / 列表项 / 引用都用它，保证行内样式处处一致。
class MdInlineText extends StatelessWidget {
  const MdInlineText(
    this.text, {
    super.key,
    required this.style,
    this.codeColor,
    this.codeBackground,
    this.onLinkTap,
  });

  final String text;
  final TextStyle style;
  final Color? codeColor;
  final Color? codeBackground;
  final void Function(String url)? onLinkTap;

  @override
  Widget build(BuildContext context) {
    return SelectableText.rich(
      TextSpan(
        style: style,
        children: buildInlineSpans(
          text,
          style,
          codeColor: codeColor,
          codeBackground: codeBackground,
          onLinkTap: onLinkTap,
        ),
      ),
    );
  }
}

/// 一段富文本正文：块级排版 + 行内样式。
class MarkdownText extends StatelessWidget {
  const MarkdownText(
    this.source, {
    super.key,
    this.onLinkTap,
  });

  final String source;
  final void Function(String url)? onLinkTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final blocks = MarkdownParser.parse(source);
    final children = <Widget>[];
    for (var i = 0; i < blocks.length; i++) {
      final block = blocks[i];
      final previous = i == 0 ? null : blocks[i - 1];
      if (i > 0) {
        children.add(SizedBox(height: _gapBefore(block, previous)));
      }
      children.add(_buildBlock(context, block, palette));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  /// 块之间的间距：标题上方多留白，列表项之间收紧。
  double _gapBefore(MdBlock block, MdBlock? previous) {
    if (previous == null) return 0;
    if (block.kind == MdBlockKind.heading) return 14;
    if (block.kind == MdBlockKind.bullet || block.kind == MdBlockKind.ordered) {
      return previous.kind == block.kind ? 6 : 12;
    }
    if (block.kind == MdBlockKind.code || block.kind == MdBlockKind.table) {
      return 14;
    }
    return 12;
  }

  Widget _buildBlock(BuildContext context, MdBlock block, AppPalette palette) {
    switch (block.kind) {
      case MdBlockKind.heading:
        return _Heading(block: block, onLinkTap: onLinkTap, palette: palette);
      case MdBlockKind.bullet:
        return _ListItem(block: block, onLinkTap: onLinkTap, palette: palette);
      case MdBlockKind.ordered:
        return _ListItem(
          block: block,
          onLinkTap: onLinkTap,
          palette: palette,
          marker: '${block.level}.',
        );
      case MdBlockKind.quote:
        return _QuoteBlock(block: block, onLinkTap: onLinkTap, palette: palette);
      case MdBlockKind.code:
        return _MarkdownCodeBlock(block: block, palette: palette);
      case MdBlockKind.table:
        return _MarkdownTable(block: block, palette: palette, onLinkTap: onLinkTap);
      case MdBlockKind.rule:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Container(height: 1, color: palette.line),
        );
      default:
        return MdInlineText(
          block.text,
          style: TextStyle(color: palette.text, fontSize: 15, height: 1.75),
          codeColor: palette.accent,
          codeBackground: palette.isDark
              ? palette.codeBg
              : palette.codeBg.withValues(alpha: 0.9),
          onLinkTap: onLinkTap,
        );
    }
  }
}

/// 标题：字号 + 主色强调（中文没有真粗体，`w700` 会被系统伪装加粗，
/// 在 CJK 上糊成一团；官方 App 的标题是「更大 + 更深」而不是更粗）。
class _Heading extends StatelessWidget {
  const _Heading({required this.block, required this.palette, this.onLinkTap});

  final MdBlock block;
  final AppPalette palette;
  final void Function(String url)? onLinkTap;

  @override
  Widget build(BuildContext context) {
    final size = switch (block.level) {
      1 => 19.5,
      2 => 17.5,
      3 => 16.5,
      _ => 15.5,
    };
    return Padding(
      padding: EdgeInsets.only(top: block.level <= 2 ? 2 : 0),
      child: MdInlineText(
        block.text,
        style: TextStyle(
          color: palette.text,
          fontSize: size,
          height: 1.45,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.1,
        ),
        codeColor: palette.accent,
        onLinkTap: onLinkTap,
      ),
    );
  }
}

/// 列表项：用圆点 / 序号做标记，换行后文字与首行对齐。
class _ListItem extends StatelessWidget {
  const _ListItem({
    required this.block,
    required this.palette,
    this.marker,
    this.onLinkTap,
  });

  final MdBlock block;
  final AppPalette palette;
  final String? marker;
  final void Function(String url)? onLinkTap;

  @override
  Widget build(BuildContext context) {
    final markerWidth = marker == null ? 16.0 : 22.0;
    return Padding(
      padding: EdgeInsets.only(left: 2.0 + block.indent * 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: markerWidth,
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: marker == null
                  ? Center(
                      child: Container(
                        width: 5,
                        height: 5,
                        decoration: BoxDecoration(
                          color: palette.text3,
                          shape: BoxShape.circle,
                        ),
                      ),
                    )
                  : Text(
                      marker!,
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        color: palette.text2,
                        fontSize: 14,
                        height: 1.75,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: MdInlineText(
              block.text,
              style: TextStyle(color: palette.text, fontSize: 15, height: 1.75),
              codeColor: palette.accent,
              codeBackground: palette.codeBg,
              onLinkTap: onLinkTap,
            ),
          ),
        ],
      ),
    );
  }
}

/// 引用块：左侧细竖线 + 次要色文字。
class _QuoteBlock extends StatelessWidget {
  const _QuoteBlock({
    required this.block,
    required this.palette,
    this.onLinkTap,
  });

  final MdBlock block;
  final AppPalette palette;
  final void Function(String url)? onLinkTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.only(left: 11),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: palette.line, width: 2.4),
        ),
      ),
      child: MdInlineText(
        block.lines.join('\n'),
        style: TextStyle(color: palette.text2, fontSize: 14.5, height: 1.7),
        codeColor: palette.accent,
        codeBackground: palette.codeBg,
        onLinkTap: onLinkTap,
      ),
    );
  }
}

/// 代码块：顶栏（语言 + 折叠 + 复制）+ 内容，12 圆角。
class _MarkdownCodeBlock extends StatelessWidget {
  const _MarkdownCodeBlock({required this.block, required this.palette});

  final MdBlock block;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    final language = block.language.trim();
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.code),
      child: Container(
        color: palette.codeBg,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 34,
              child: Padding(
                padding: const EdgeInsets.only(left: 12, right: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        language.isEmpty ? 'text' : language,
                        style: TextStyle(
                          color: palette.text3,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w500,
                          fontFamily: kMono.fontFamily,
                        ),
                      ),
                    ),
                    InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: () async {
                        await Clipboard.setData(ClipboardData(text: block.text));
                        if (!context.mounted) return;
                        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                          const SnackBar(
                            content: Text('已复制代码'),
                            duration: Duration(milliseconds: 1200),
                          ),
                        );
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                        child: Row(
                          children: [
                            Icon(Icons.copy_rounded, size: 12.5, color: palette.text3),
                            const SizedBox(width: 4),
                            Text(
                              '复制',
                              style: TextStyle(color: palette.text3, fontSize: 11.5),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: SelectableText(
                block.text,
                style: kMono.copyWith(color: palette.codeText),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 表格：表头浅底 + 逐行分隔线；列宽按内容自适应。
class _MarkdownTable extends StatelessWidget {
  const _MarkdownTable({
    required this.block,
    required this.palette,
    this.onLinkTap,
  });

  final MdBlock block;
  final AppPalette palette;
  final void Function(String url)? onLinkTap;

  @override
  Widget build(BuildContext context) {
    final columns = <int>{
      block.header.length,
      for (final row in block.rows) row.length,
    }.reduce((a, b) => a > b ? a : b);
    final rows = <List<String>>[
      block.header,
      for (final row in block.rows)
        List<String>.generate(columns, (i) => i < row.length ? row[i] : ''),
    ];
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: palette.line),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Table(
          defaultColumnWidth: const FlexColumnWidth(),
          border: TableBorder(
            horizontalInside: BorderSide(color: palette.line, width: 0.8),
            verticalInside: BorderSide(color: palette.line, width: 0.8),
          ),
          children: [
            for (var r = 0; r < rows.length; r++)
              TableRow(
                decoration: BoxDecoration(
                  color: r == 0 ? palette.lineSoft : null,
                ),
                children: [
                  for (var c = 0; c < columns; c++)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                      child: MdInlineText(
                        c < rows[r].length ? rows[r][c] : '',
                        style: TextStyle(
                          color: r == 0 ? palette.text : palette.text2,
                          fontSize: 13,
                          height: 1.5,
                          fontWeight: r == 0 ? FontWeight.w600 : FontWeight.w400,
                        ),
                        codeColor: palette.accent,
                        onLinkTap: onLinkTap,
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
