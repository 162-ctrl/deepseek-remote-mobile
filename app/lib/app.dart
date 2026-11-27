import 'dart:async';

import 'package:flutter/material.dart';

import 'data/live_store.dart';
import 'screens/root_shell.dart';
import 'services/boot_guard.dart';
import 'services/notification_gateway.dart';
import 'services/notification_prefs.dart';
import 'services/session_store.dart';
import 'services/settings_gateway.dart';
import 'services/share_gateway.dart';
import 'theme/app_theme.dart';
import 'theme/theme_controller.dart';
import 'widgets/common.dart';

/// DeepSeek Remote 手机端。
///
/// M2.4：App 只保留真实链路（LiveStore）——未连接时五页展示空态，
/// 不再内置任何假数据。连接成功后走
/// 手机 → 云端中继 → 电脑 Agent → Harness 的真实链路。
///
/// M2：App 生命周期用于「前台弹审批 / 后台发通知」的判断；连接成功后
/// 启动前台服务保活，认证失效时自动重配对。
class DeepSeekRemoteApp extends StatefulWidget {
  const DeepSeekRemoteApp({super.key});

  @override
  State<DeepSeekRemoteApp> createState() => _DeepSeekRemoteAppState();
}

class _DeepSeekRemoteAppState extends State<DeepSeekRemoteApp>
    with WidgetsBindingObserver {
  late final LiveStore _liveStore;
  late final ThemeController _themeController;
  late final ShareGateway _shareGateway;
  final GlobalKey<ScaffoldMessengerState> _messengerKey =
      GlobalKey<ScaffoldMessengerState>();

  @override
  void initState() {
    super.initState();
    final settings = MethodChannelSettingsGateway();
    _liveStore = LiveStore(
      notificationGateway: MethodChannelNotificationGateway(),
      sessionStore: SessionStore(),
    );
    _themeController = ThemeController(gateway: settings);
    _shareGateway = MethodChannelShareGateway();
    // 通知/前台服务的原生通道只注册一次：冷启动点击路径由
    // getInitialApprovalId 补回。
    WidgetsBinding.instance.addObserver(this);
    _liveStore.initNotifications();
    // M4.4：「我的 → 通知」里的两个开关（任务做完提醒 / 等待授权提醒）。
    unawaited(_liveStore.attachNotificationPrefs(
      NotificationPrefs(gateway: settings),
    ));
    // 读取上次选中的外观模式。
    _themeController.load();
    // M4.63：先过一次启动自愈（连续闪退就清掉本地存档），再续连。
    unawaited(_bootstrap(settings));
  }

  /// M4.63：启动自愈 + 续连。
  ///
  /// 用户遇到「打开就闪退、清数据才能开」，说明本地存档里有东西把启动卡死。
  /// 这里在续连之前先看 [BootGuard]：如果短时间内连续几次都没走到第一帧，
  /// 就把会话存档清掉，让 App 至少能进到扫码页。
  Future<void> _bootstrap(SettingsGateway settings) async {
    final guard = BootGuard(gateway: settings);
    var reset = false;
    try {
      if (await guard.shouldReset()) {
        await _liveStore.disconnect();
        reset = true;
      }
      await guard.markAttempt();
    } catch (_) {
      // 自愈本身失败也不能挡住启动。
    }
    if (reset && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _messengerKey.currentState?.showSnackBar(
          const SnackBar(
            content: Text('上次启动没有完成，已清掉本地连接存档，重新扫码即可'),
          ),
        );
      });
    }
    await _liveStore.restoreSession();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(guard.markFirstFrame().catchError((Object _) {}));
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    _liveStore.setAppForeground(state == AppLifecycleState.resumed);
    // M3.1：切回前台时如果连接已经掉了（后台被系统冻结/网络切换），
    // 立刻用保存的地址与 token 补一次重连。
    if (state == AppLifecycleState.resumed) {
      unawaited(_liveStore.ensureReconnected());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _themeController.dispose();
    _shareGateway.dispose();
    _liveStore.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ThemeScope(
      controller: _themeController,
      child: ListenableBuilder(
        listenable: _themeController,
        builder: (context, _) => LiveScope(
          store: _liveStore,
          child: MaterialApp(
            title: 'DeepSeek Remote',
            scaffoldMessengerKey: _messengerKey,
            debugShowCheckedModeBanner: false,
            theme: buildAppTheme(Brightness.light),
            darkTheme: buildAppTheme(Brightness.dark),
            themeMode: _themeController.themeMode,
            home: RootShell(
              liveStore: _liveStore,
              shareGateway: _shareGateway,
            ),
          ),
        ),
      ),
    );
  }
}
