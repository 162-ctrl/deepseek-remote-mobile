import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseek_remote_app/models.dart';
import 'package:deepseek_remote_app/services/settings_gateway.dart';
import 'package:deepseek_remote_app/theme/app_theme.dart';
import 'package:deepseek_remote_app/theme/theme_controller.dart';
import 'package:deepseek_remote_app/widgets/chat_items.dart';
import 'package:deepseek_remote_app/widgets/common.dart';

/// 双色对比度（WCAG），用于校验深色/浅色 token 的可读性。
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  group('M2.3 主题 token', () {
    test('浅色 token 符合契约色值', () {
      const p = AppPalette.light;
      expect(p.isDark, isFalse);
      expect(p.bg, const Color(0xFFFFFFFF));
      expect(p.card, const Color(0xFFFFFFFF));
      expect(p.line, const Color(0xFFECEDF2));
      expect(p.lineSoft, const Color(0xFFF4F5F8));
      expect(p.text, const Color(0xFF111318));
      expect(p.text2, const Color(0xFF5F636B));
      expect(p.text3, const Color(0xFF9CA1AA));
      expect(p.accent, const Color(0xFF4C5CFF));
      expect(p.accentSoft, const Color(0xFFEEF0FF));
      expect(p.bubbleUser, const Color(0xFFEFF1FF));
      expect(p.bubbleUserText, const Color(0xFF141726));
      expect(p.codeBg, const Color(0xFFF6F7FA));
      expect(p.codeText, const Color(0xFF2C2F37));
      expect(p.success, const Color(0xFF12B76A));
      expect(p.warn, const Color(0xFFF79009));
      expect(p.danger, const Color(0xFFF04438));
    });

    test('深色 token 符合契约色值', () {
      const p = AppPalette.dark;
      expect(p.isDark, isTrue);
      expect(p.bg, const Color(0xFF0D0E12));
      expect(p.card, const Color(0xFF16181E));
      expect(p.line, const Color(0xFF23262E));
      expect(p.lineSoft, const Color(0xFF1B1E25));
      expect(p.text, const Color(0xFFF1F3F7));
      expect(p.text2, const Color(0xFFA6AAB3));
      expect(p.text3, const Color(0xFF6D727C));
      expect(p.accent, const Color(0xFF8A93FF));
      expect(p.accentSoft, const Color(0xFF1D2034));
      expect(p.bubbleUser, const Color(0xFF262B47));
      expect(p.codeBg, const Color(0xFF14161C));
      expect(p.codeText, const Color(0xFFC9CED8));
    });

    test('of(Brightness) 选择对应调色板', () {
      expect(AppPalette.of(Brightness.light), same(AppPalette.light));
      expect(AppPalette.of(Brightness.dark), same(AppPalette.dark));
      expect(AppPalette.light.successSoft.a, greaterThan(0));
      expect(AppPalette.light.warnSoft.a, greaterThan(0));
      expect(AppPalette.light.dangerSoft.a, greaterThan(0));
    });

    test('间距与圆角 token 符合契约', () {
      expect(AppSpace.page, 20);
      expect(AppSpace.card, 16);
      expect(AppSpace.cardGap, 12);
      expect(AppSpace.sectionTop, 22);
      expect(AppSpace.sectionBottom, 10);
      expect(AppRadius.card, 18);
      expect(AppRadius.sheetTop, 28);
      expect(AppRadius.bubble, 20);
      expect(AppRadius.bubbleTail, 6);
      expect(AppRadius.code, 14);
      expect(AppRadius.input, 24);
      expect(AppRadius.pill, 999);
    });

    test('buildAppTheme 浅色为默认且亮暗分明', () {
      final light = buildAppTheme(Brightness.light);
      final dark = buildAppTheme(Brightness.dark);
      expect(light.brightness, Brightness.light);
      expect(dark.brightness, Brightness.dark);
      expect(light.scaffoldBackgroundColor, AppPalette.light.bg);
      expect(dark.scaffoldBackgroundColor, AppPalette.dark.bg);
      expect(light.colorScheme.primary, AppPalette.light.accent);
      expect(dark.colorScheme.primary, AppPalette.dark.accent);
      expect(light.extension<AppPaletteExt>()!.palette, AppPalette.light);
      expect(dark.extension<AppPaletteExt>()!.palette, AppPalette.dark);
    });

    test('正文与底色对比度达到契约要求', () {
      expect(
        _contrast(AppPalette.light.text, AppPalette.light.bg),
        greaterThanOrEqualTo(7),
      );
      expect(
        _contrast(AppPalette.dark.text, AppPalette.dark.bg),
        greaterThanOrEqualTo(7),
      );
      expect(
        _contrast(AppPalette.light.text2, AppPalette.light.bg),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        _contrast(AppPalette.dark.text2, AppPalette.dark.bg),
        greaterThanOrEqualTo(4.5),
      );
    });

    testWidgets('context.appPalette 随明暗主题返回对应调色板', (tester) async {
      late AppPalette captured;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: Builder(
            builder: (context) {
              captured = context.appPalette;
              return const Text('probe');
            },
          ),
        ),
      );
      expect(captured.isDark, isTrue);
      expect(captured.bg, AppPalette.dark.bg);
    });
  });

  group('M2.3 三选外观模式', () {
    test('默认跟随系统，模式可解析并持久化', () async {
      final gateway = FakeSettingsGateway();
      final controller = ThemeController(gateway: gateway);
      expect(controller.mode, AppThemeMode.system);
      expect(controller.themeMode, ThemeMode.system);
      await controller.load();
      expect(controller.loaded, isTrue);

      await controller.select(AppThemeMode.dark);
      expect(controller.themeMode, ThemeMode.dark);
      expect(gateway.values[ThemeController.storageKey], 'dark');

      final restored = ThemeController(
        gateway: FakeSettingsGateway(
          seed: {ThemeController.storageKey: 'light'},
        ),
      );
      await restored.load();
      expect(restored.mode, AppThemeMode.light);
      expect(restored.themeMode, ThemeMode.light);
      controller.dispose();
      restored.dispose();
    });
  });

  group('M2.3 关键组件', () {
    testWidgets('ChatItemView 渲染用户气泡与助手正文', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: Scaffold(
            body: ListView(
              children: [
                ChatItemView(
                  item: ChatItem(
                    role: ChatRole.user,
                    kind: ChatItemKind.text,
                    text: '用户消息',
                  ),
                  onApprovalDemo: () {},
                ),
                ChatItemView(
                  item: ChatItem(
                    role: ChatRole.assistant,
                    kind: ChatItemKind.text,
                    text: '助手回复',
                  ),
                  onApprovalDemo: () {},
                ),
              ],
            ),
          ),
        ),
      );
      expect(find.text('用户消息'), findsOneWidget);
      expect(find.text('助手回复'), findsOneWidget);
    });

    testWidgets('TaskStatusBadge 状态文案保留', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: const Scaffold(
            body: Column(
              children: [
                TaskStatusBadge(status: TaskStatus.waitingApproval),
              ],
            ),
          ),
        ),
      );
      expect(find.text('等待授权'), findsOneWidget);
    });

    test('版本号与构建配置已升级到 M4.62', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(pubspec, contains('version: 0.4.67+88'));
      final local = File('android/local.properties').readAsStringSync();
      expect(local, contains('flutter.versionName=0.4.67'));
      expect(local, contains('flutter.versionCode=88'));
      final gradle = File('android/app/build.gradle.kts').readAsStringSync();
      expect(gradle, contains('versionName = "0.4.67-m4.67"'));
      final version = File('lib/app_version.dart').readAsStringSync();
      expect(version, contains('kAppVersionCode = 88'));
      expect(version, contains("kAppVersionName = '0.4.67-m4.67'"));
    });
  });
}
