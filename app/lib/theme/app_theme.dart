import 'package:flutter/material.dart';

/// 视觉模式（M2.3）：跟随系统 / 浅色 / 深色，「我的 → 外观」三选并持久化。
enum AppThemeMode {
  system('system', '跟随系统'),
  light('light', '浅色'),
  dark('dark', '深色');

  const AppThemeMode(this.storageValue, this.label);

  /// 持久化用的稳定字符串（不要随 UI 文案变化）。
  final String storageValue;

  /// 界面展示名称。
  final String label;

  /// 解析持久化的值；非法/空值回退到跟随系统。
  static AppThemeMode parse(String? raw) {
    if (raw == null) return AppThemeMode.system;
    for (final mode in AppThemeMode.values) {
      if (mode.storageValue == raw || mode.name == raw) return mode;
    }
    return AppThemeMode.system;
  }
}

/// M2.3 设计 Token（浅色 + 深色两套，见 docs/design/M2_3_UI_DELTA.md §2）。
///
/// 组件统一通过 `context.appPalette.xxx` 读取，禁止再写死颜色值。
@immutable
class AppPalette {
  const AppPalette({
    required this.isDark,
    required this.bg,
    required this.card,
    required this.line,
    required this.lineSoft,
    required this.text,
    required this.text2,
    required this.text3,
    required this.accent,
    required this.accentSoft,
    required this.onAccent,
    required this.bubbleUser,
    required this.bubbleUserText,
    required this.codeBg,
    required this.codeText,
    required this.success,
    required this.warn,
    required this.danger,
  });

  /// 是否深色（用于阴影/alpha 之类的小差别）。
  final bool isDark;

  // 页面 / 卡片 / 分割线。
  final Color bg;
  final Color card;
  final Color line;
  final Color lineSoft;

  // 文本三级。
  final Color text;
  final Color text2;
  final Color text3;

  // 主色。
  final Color accent;
  final Color accentSoft;
  final Color onAccent;

  // 对话气泡。
  final Color bubbleUser;
  final Color bubbleUserText;

  // 代码块。
  final Color codeBg;
  final Color codeText;

  // 状态色。
  final Color success;
  final Color warn;
  final Color danger;

  /// 浅色（默认）：M2.9 Kimi 风格——纯白底、蓝紫强调色、浅灰气泡。
  static const AppPalette light = AppPalette(
    isDark: false,
    bg: Color(0xFFFFFFFF),
    card: Color(0xFFFFFFFF),
    line: Color(0xFFECEDF2),
    lineSoft: Color(0xFFF4F5F8),
    text: Color(0xFF111318),
    text2: Color(0xFF5F636B),
    text3: Color(0xFF9CA1AA),
    accent: Color(0xFF4C5CFF),
    accentSoft: Color(0xFFEEF0FF),
    onAccent: Color(0xFFFFFFFF),
    bubbleUser: Color(0xFFEFF1FF),
    bubbleUserText: Color(0xFF141726),
    codeBg: Color(0xFFF6F7FA),
    codeText: Color(0xFF2C2F37),
    success: Color(0xFF12B76A),
    warn: Color(0xFFF79009),
    danger: Color(0xFFF04438),
  );

  /// 深色：M2.9 Kimi 风格——近黑而非纯黑。
  static const AppPalette dark = AppPalette(
    isDark: true,
    bg: Color(0xFF0D0E12),
    card: Color(0xFF16181E),
    line: Color(0xFF23262E),
    lineSoft: Color(0xFF1B1E25),
    text: Color(0xFFF1F3F7),
    text2: Color(0xFFA6AAB3),
    text3: Color(0xFF6D727C),
    accent: Color(0xFF8A93FF),
    accentSoft: Color(0xFF1D2034),
    onAccent: Color(0xFFFFFFFF),
    bubbleUser: Color(0xFF262B47),
    bubbleUserText: Color(0xFFEEF0FF),
    codeBg: Color(0xFF14161C),
    codeText: Color(0xFFC9CED8),
    success: Color(0xFF3DD68C),
    warn: Color(0xFFFFB020),
    danger: Color(0xFFFF5A5F),
  );

  static AppPalette of(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;

  // ---- 状态浅底（胶囊/行内状态用） ----
  Color get successSoft =>
      success.withValues(alpha: isDark ? 0.18 : 0.12);

  Color get warnSoft => warn.withValues(alpha: isDark ? 0.18 : 0.12);

  Color get dangerSoft => danger.withValues(alpha: isDark ? 0.18 : 0.12);

  Color get accentSurface =>
      accent.withValues(alpha: isDark ? 0.16 : 0.10);

  /// 卡片阴影：M2.9 起改用一层极淡投影（Kimi 风格几乎无阴影）。
  List<BoxShadow> get cardShadow => isDark
      ? const <BoxShadow>[]
      : const <BoxShadow>[
          BoxShadow(
            color: Color(0x08000000),
            blurRadius: 14,
            offset: Offset(0, 4),
          ),
        ];

  /// 主按钮阴影。
  List<BoxShadow> get accentShadow => isDark
      ? const <BoxShadow>[]
      : <BoxShadow>[
          BoxShadow(
            color: accent.withValues(alpha: 0.26),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
        ];

  // ---- 兼容别名（老组件/老测试迁移期使用，新代码请直接用 token 名） ----
  Color get surface => card;
  Color get surfaceHigh => card;
  Color get stroke => line;
  Color get primary => accent;
  Color get primarySoft => accentSoft;
  Color get textMuted => text2;
  Color get textFaint => text3;
  Color get warning => warn;
  Color get teal => accent;
  Color get purple => accent;

  /// 旧代码按 8 色板预览的兼容取值。
  List<Color> get swatches => <Color>[bg, card, accent];
}

/// 把当前调色板挂到 [ThemeData.extensions]，供 `context.appPalette` 读取。
@immutable
class AppPaletteExt extends ThemeExtension<AppPaletteExt> {
  const AppPaletteExt(this.palette);

  final AppPalette palette;

  @override
  AppPaletteExt copyWith({AppPalette? palette}) =>
      AppPaletteExt(palette ?? this.palette);

  @override
  AppPaletteExt lerp(ThemeExtension<AppPaletteExt>? other, double t) {
    if (other is! AppPaletteExt) return this;
    return t < 0.5 ? this : other;
  }
}

/// 组件里读当前调色板的快捷方式（未挂载时回退浅色）。
extension AppThemeContext on BuildContext {
  AppPalette get appPalette {
    final ext = Theme.of(this).extension<AppPaletteExt>();
    return ext?.palette ?? AppPalette.light;
  }

  bool get isDarkMode => Theme.of(this).brightness == Brightness.dark;
}

/// 圆角 token（M2.9：更大的气泡与输入胶囊，弱化卡片描边感）。
class AppRadius {
  const AppRadius._();

  static const double card = 18;
  static const double sheetTop = 28;
  static const double bubble = 20;
  static const double bubbleTail = 6;
  static const double code = 14;
  static const double input = 24;
  static const double button = 24;
  static const double navPill = 12;
  static const double pill = 999;
}

/// 间距 token（§2.3）。
class AppSpace {
  const AppSpace._();

  static const double page = 20;
  static const double card = 16;
  static const double cardGap = 12;
  static const double sectionTop = 22;
  static const double sectionBottom = 10;
}

/// 默认浅色 token 的常量快照（兼容层）。
///
/// 历史代码/`TaskStatus` 等 const 枚举仍引用这些常量；M2.3 起主界面组件
/// 请改用 `context.appPalette`，这里只作为迁移期的兜底值。
class AppColors {
  static const bg = Color(0xFFFFFFFF);
  static const surface = Color(0xFFFFFFFF);
  static const surfaceHigh = Color(0xFFF6F7FA);
  static const stroke = Color(0xFFECEDF2);
  static const primary = Color(0xFF4C5CFF);
  static const primarySoft = Color(0xFFEEF0FF);
  static const teal = Color(0xFF4C5CFF);
  static const purple = Color(0xFF4C5CFF);
  static const warning = Color(0xFFF79009);
  static const danger = Color(0xFFF04438);
  static const success = Color(0xFF12B76A);
  static const text = Color(0xFF111318);
  static const textMuted = Color(0xFF5F636B);
  static const textFaint = Color(0xFF9CA1AA);
}

/// 构建应用主题；[brightness] 决定浅色/深色 token（M2.3）。
ThemeData buildAppTheme(Brightness brightness) {
  final p = AppPalette.of(brightness);
  final scheme = ColorScheme(
    brightness: brightness,
    primary: p.accent,
    onPrimary: p.onAccent,
    secondary: p.accent,
    onSecondary: p.onAccent,
    error: p.danger,
    onError: Colors.white,
    surface: p.card,
    onSurface: p.text,
    surfaceContainerHighest: p.lineSoft,
    outline: p.line,
    outlineVariant: p.lineSoft,
  );

  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: p.bg,
    canvasColor: p.bg,
    fontFamilyFallback: const <String>[
      'Microsoft YaHei',
      'PingFang SC',
      'Noto Sans CJK SC',
      'Source Han Sans SC',
      'sans-serif',
    ],
  );

  return base.copyWith(
    extensions: <ThemeExtension<dynamic>>[AppPaletteExt(p)],
    appBarTheme: AppBarTheme(
      backgroundColor: p.bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleSpacing: AppSpace.page,
      toolbarHeight: 64,
      iconTheme: IconThemeData(color: p.text2, size: 20),
      actionsIconTheme: IconThemeData(color: p.text2, size: 20),
      titleTextStyle: TextStyle(
        color: p.text,
        fontSize: 20,
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
      ),
    ),
    dividerTheme: DividerThemeData(color: p.line, thickness: 1, space: 1),
    cardTheme: CardThemeData(
      color: p.card,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
        side: BorderSide(color: p.line),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: p.card,
      selectedColor: p.accent,
      disabledColor: p.lineSoft,
      side: BorderSide(color: p.line),
      labelStyle: TextStyle(
        color: p.text2,
        fontSize: 12.5,
        fontWeight: FontWeight.w500,
      ),
      secondaryLabelStyle: TextStyle(
        color: p.onAccent,
        fontSize: 12.5,
        fontWeight: FontWeight.w600,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      shape: const StadiumBorder(),
      showCheckmark: false,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.accent,
        foregroundColor: p.onAccent,
        minimumSize: const Size.fromHeight(48),
        elevation: 0,
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.button),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.text,
        backgroundColor: p.card,
        minimumSize: const Size.fromHeight(48),
        side: BorderSide(color: p.line),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.button),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.accent,
        textStyle: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
      ),
    ),
    iconTheme: IconThemeData(color: p.text2, size: 20),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.card,
      hintStyle: TextStyle(color: p.text3, fontSize: 14),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.input),
        borderSide: BorderSide(color: p.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.input),
        borderSide: BorderSide(color: p.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.input),
        borderSide: BorderSide(color: p.accent, width: 1.6),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: brightness == Brightness.dark
          ? p.card
          : const Color(0xFF0F172A),
      contentTextStyle: const TextStyle(color: Colors.white, fontSize: 13.5),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.code),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.card,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.sheetTop)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.card,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: p.accent,
      linearTrackColor: p.lineSoft,
    ),
    // M4.22：**必须** merge 到 base 的完整 Typography 上，不能直接塞一个部分 TextTheme。
    // 直接替换会让没写到的样式（`bodyLarge` 首当其冲）变成「无颜色」的
    // `englishLike bodyLarge 2021`，而 `TextField` 的正文样式正好取的就是
    // `textTheme.bodyLarge` —— 于是输入框里打出来的字是透明的（插件市场的搜索框
    // 就是这样：文字进去了、`onChanged` 也收到了，屏幕上却只剩一个光标）。
    textTheme: base.textTheme.merge(
      TextTheme(
        titleLarge: TextStyle(
          color: p.text,
          fontSize: 20,
          fontWeight: FontWeight.w600,
          letterSpacing: 0,
        ),
        titleMedium: TextStyle(
          color: p.text,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
        bodyLarge: TextStyle(color: p.text, fontSize: 15, height: 1.6),
        bodyMedium: TextStyle(color: p.text, fontSize: 14.5, height: 1.6),
        bodySmall: TextStyle(color: p.text2, fontSize: 12.5, height: 1.5),
        labelMedium: TextStyle(color: p.text2, fontSize: 12.5),
        labelSmall: TextStyle(
          color: p.text3,
          fontSize: 11,
          letterSpacing: 0.2,
        ),
      ),
    ),
  );
}


/// 等宽字体：留给代码块/命令展示；颜色由调用方按 token 指定。
const kMono = TextStyle(
  fontFamily: 'monospace',
  fontFamilyFallback: <String>['Cascadia Mono', 'Consolas', 'monospace'],
  fontSize: 11.6,
  height: 1.6,
);
