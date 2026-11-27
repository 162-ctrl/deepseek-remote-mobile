import 'package:flutter/material.dart';

import '../services/settings_gateway.dart';
import 'app_theme.dart';

/// 主题模式状态（M2.3）：跟随系统 / 浅色 / 深色。
///
/// - 默认「跟随系统」；
/// - [load] 从 [SettingsGateway] 读取上次选择，重启后保留；
/// - [select] 立即通知 UI 并异步写回持久化。
class ThemeController extends ChangeNotifier {
  ThemeController({SettingsGateway? gateway})
      : _gateway = gateway ?? MethodChannelSettingsGateway();

  /// 持久化 key（M2.3 起存的是三选模式，不是旧主题 ID）。
  static const String storageKey = 'app_theme_mode';

  final SettingsGateway _gateway;

  AppThemeMode _mode = AppThemeMode.system;
  bool _loaded = false;

  AppThemeMode get mode => _mode;

  /// 传给 [MaterialApp.themeMode]。
  ThemeMode get themeMode => switch (_mode) {
        AppThemeMode.system => ThemeMode.system,
        AppThemeMode.light => ThemeMode.light,
        AppThemeMode.dark => ThemeMode.dark,
      };

  /// 是否已经尝试过读取持久化值。
  bool get loaded => _loaded;

  Future<void> load() async {
    final raw = await _gateway.getString(storageKey);
    _loaded = true;
    final parsed = AppThemeMode.parse(raw);
    if (parsed != _mode) {
      _mode = parsed;
      notifyListeners();
    }
  }

  Future<void> select(AppThemeMode mode) async {
    if (_mode == mode) return;
    _mode = mode;
    notifyListeners();
    await _gateway.setString(storageKey, mode.storageValue);
  }

  @override
  void dispose() {
    _gateway.dispose();
    super.dispose();
  }
}

/// 把 [ThemeController] 暴露给任意页面（「我的 → 外观」使用）。
class ThemeScope extends InheritedNotifier<ThemeController> {
  const ThemeScope({
    super.key,
    required ThemeController controller,
    required super.child,
  }) : super(notifier: controller);

  static ThemeController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ThemeScope>();
    assert(scope != null, 'ThemeScope 未挂载：请在 MaterialApp 外层包 ThemeScope');
    return scope!.notifier!;
  }

  static ThemeController? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<ThemeScope>()?.notifier;
  }
}
