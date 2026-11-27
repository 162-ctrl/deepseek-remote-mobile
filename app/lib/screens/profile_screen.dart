import 'package:flutter/material.dart';

import '../app_version.dart';
import '../data/live_store.dart';
import '../services/history_api.dart';
import '../services/pairing_api.dart';
import '../services/url_opener.dart';
import '../theme/app_theme.dart';
import '../theme/theme_controller.dart';
import '../widgets/common.dart';
import '../widgets/update_check_tile.dart';
import 'connect_screen.dart';
import 'cloud_chat_screen.dart';
import 'recharge_screen.dart';

/// M4.33：官方充值页。电脑端的 `deepseekAccount` 没有任何下单/付款能力，
/// 所以手机只能把人送到这里，由他自己登录付款。
const String kBalanceRechargeUrl = 'https://platform.deepseek.com/top_up';

/// 我的：账号行、连接状态、外观三选与关于。
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({
    super.key,
    required this.liveStore,
    this.onOpenMenu,
    this.urlOpener,
  });

  final LiveStore liveStore;

  /// M2.9：抽屉入口（由 RootShell 注入）。
  final VoidCallback? onOpenMenu;

  /// M4.33：拉起浏览器（测试注入假的）。
  final UrlOpener? urlOpener;

  Future<void> _openConnect(BuildContext context) async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => ConnectScreen(store: liveStore)),
    );
  }

  /// M4.41：紧急停止（从已删掉的「电脑」页搬过来）。
  ///
  /// M4.44：不再直接 `disconnect()`。先请电脑停任务、等它确认，再断连接；
  /// 结果分三种如实告诉用户——不能让「已断开」被理解成「电脑上一定停了」。
  Future<void> _emergencyStop(BuildContext context, LiveStore store) async {
    final ok = await confirmDanger(
      context,
      '紧急停止远程连接？',
      '会先请电脑停下正在执行的任务，确认（或等 3 秒）后再断开连接。'
          '断线后手机上就看不到这台电脑了，需要时可在连接页重新连接。',
    );
    if (!ok) return;
    final result = await store.emergencyStop();
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(content: Text(result.detail)));
  }

  Future<void> _showThemeSheet(
    BuildContext context,
    ThemeController controller,
  ) async {
    final palette = context.appPalette;
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: palette.lineSoft,
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  '外观模式',
                  style: TextStyle(
                    color: palette.text,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '浅色为默认，跟随系统切换深色；立即生效，重启后保留',
                  style: TextStyle(color: palette.text3, fontSize: 11.5),
                ),
                const SizedBox(height: 12),
                for (final mode in AppThemeMode.values)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () {
                        controller.select(mode);
                        Navigator.of(sheetContext).pop();
                      },
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                        decoration: BoxDecoration(
                          color: controller.mode == mode
                              ? palette.accentSoft
                              : palette.card,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: controller.mode == mode
                                ? palette.accent
                                : palette.line,
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              switch (mode) {
                                AppThemeMode.system =>
                                  Icons.brightness_auto_rounded,
                                AppThemeMode.light => Icons.light_mode_rounded,
                                AppThemeMode.dark => Icons.dark_mode_rounded,
                              },
                              size: 19,
                              color: controller.mode == mode
                                  ? palette.accent
                                  : palette.text2,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                mode.label,
                                style: TextStyle(
                                  color: controller.mode == mode
                                      ? palette.accent
                                      : palette.text,
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            if (controller.mode == mode)
                              Icon(
                                Icons.check_circle_rounded,
                                size: 18,
                                color: palette.accent,
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: liveStore,
      builder: (context, _) {
        final palette = context.appPalette;
        final theme = ThemeScope.maybeOf(context);
        final mode = theme?.mode ?? AppThemeMode.system;
        final connected = liveStore.isConnected;
        return Scaffold(
          appBar: KimiAppBar(title: '我的', onOpenMenu: onOpenMenu),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpace.page,
              10,
              AppSpace.page,
              28,
            ),
            children: [
              _AccountCard(),
              // M4.25：电脑端 DeepSeek 账号的余额（充值钱包 + 赠送钱包）。
              const SectionTitle('账户余额'),
              Panel(child: _BalanceCard(liveStore: liveStore, urlOpener: urlOpener)),
              const SectionTitle('连接与设备'),
              Panel(
                child: Column(
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: connected ? palette.success : palette.text3,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                connected
                                    ? '已连接 · ${liveStore.deviceName}'
                                    : '未连接',
                                style: TextStyle(
                                  color: palette.text,
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (connected) ...[
                                const SizedBox(height: 2),
                                Text(
                                  'Agent ${liveStore.agentVersion} · Harness ${liveStore.harnessVersion}',
                                  style: TextStyle(
                                    color: palette.text3,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (connected)
                          OutlinedButton(
                            onPressed: () => liveStore.disconnect(),
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size(0, 34),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                              ),
                            ),
                            child: const Text(
                              '断开',
                              style: TextStyle(fontSize: 12),
                            ),
                          )
                        else
                          FilledButton(
                            onPressed: () => _openConnect(context),
                            style: FilledButton.styleFrom(
                              minimumSize: const Size(0, 34),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                              ),
                            ),
                            child: const Text(
                              '连接电脑',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              Panel(
                child: _ListRow(
                  icon: Icons.battery_saver_outlined,
                  title: '后台保活',
                  subtitle: '切到后台不断连：允许后台高耗电与自启动',
                  trailing: Icon(
                    Icons.chevron_right_rounded,
                    size: 18,
                    color: palette.text3,
                  ),
                  onTap: () => showDialog<void>(
                    context: context,
                    builder: (dialogContext) => AlertDialog(
                      title: const Text('后台保活'),
                      content: const Text(
                        '1. 设置 → 电池 → 后台耗电管理 → DeepSeek Remote → 允许后台高耗电\n'
                        '2. i管家 → 自启动 → 允许 DeepSeek Remote\n'
                        '3. 最近任务里下拉本应用卡片，锁定它\n\n'
                        '完成后再切到后台，连接会保持。',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(dialogContext).pop(),
                          child: const Text('知道了'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // M4.41：原来的「电脑」页删掉了，只把紧急停止搬到「我的」——
              // 这是断连的最后一个去处，不能跟着页面一起消失。
              if (connected) ...[
                const SectionTitle('紧急停止'),
                Panel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.emergency_outlined,
                            size: 18,
                            color: palette.danger,
                          ),
                          const SizedBox(width: 7),
                          Text(
                            '紧急停止',
                            style: TextStyle(
                              color: palette.danger,
                              fontSize: 13.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '立即断开与电脑的连接，正在执行的任务可能被中断。',
                        style: TextStyle(
                          color: palette.text2,
                          fontSize: 11.8,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 12),
                      SlideToStop(onStop: () => _emergencyStop(context, liveStore)),
                    ],
                  ),
                ),
              ],
              const SectionTitle('模型'),
              Panel(
                child: _ListRow(
                  icon: Icons.key_rounded,
                  title: '模型与 API Key',
                  subtitle: '手机本地对话用的服务地址、Key 与模型名',
                  trailing: Icon(Icons.chevron_right_rounded, size: 18, color: palette.text3),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const CloudChatScreen(),
                    ),
                  ),
                ),
              ),
              const SectionTitle('通知'),
              Panel(
                child: Column(
                  children: [
                    // M4.4：电脑上任务做完 / 失败 / 取消时提醒（后台才弹）。
                    _SwitchRow(
                      icon: Icons.task_alt_rounded,
                      title: '任务做完提醒',
                      subtitle: '电脑上的任务完成、失败或被取消时通知你',
                      value: liveStore.notificationPrefs.taskDone,
                      onChanged: liveStore.setTaskDoneNotifications,
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Divider(height: 1, color: palette.line),
                    ),
                    // M4.4：需要授权时提醒，并且能在通知栏直接允许/拒绝。
                    _SwitchRow(
                      icon: Icons.verified_user_outlined,
                      title: '等待授权提醒',
                      subtitle: '电脑停下等你授权时通知，可在通知栏直接允许或拒绝',
                      value: liveStore.notificationPrefs.approvalAction,
                      onChanged: liveStore.setApprovalNotifications,
                    ),
                  ],
                ),
              ),
              const SectionTitle('外观'),
              Panel(
                child: _ListRow(
                  icon: Icons.palette_outlined,
                  title: '外观模式',
                  subtitle: '当前：${mode.label} · 浅色 / 深色 / 跟随系统',
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.chevron_right_rounded,
                        size: 18,
                        color: palette.text3,
                      ),
                    ],
                  ),
                  onTap: theme == null
                      ? null
                      : () => _showThemeSheet(context, theme),
                ),
              ),
              const SectionTitle('关于与更新'),
              Panel(
                child: Column(
                  children: [
                    _ListRow(
                      icon: Icons.info_outline_rounded,
                      title: 'DeepSeek Remote',
                      subtitle: kAppVersionLabel,
                      trailing: Text(
                        'M2.5',
                        style: TextStyle(
                          color: palette.text3,
                          fontSize: 11,
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Divider(height: 1, color: palette.line),
                    ),
                    // M2.5：应用内在线更新（检查 → 下载 → 系统安装器）。
                    UpdateCheckTile(
                      serverUrl: liveStore.serverUrl,
                      token: liveStore.token,
                      connected: connected,
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Divider(height: 1, color: palette.line),
                    ),
                    // M4.42：「插件管理」搬到新的「功能」页（抽屉里排在「我的」上面）。
                    _ListRow(
                      icon: Icons.menu_book_outlined,
                      title: '使用文档',
                      subtitle: '连接、配对与常见问题',
                      trailing: Icon(
                        Icons.chevron_right_rounded,
                        size: 18,
                        color: palette.text3,
                      ),
                      onTap: () {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('文档见仓库 docs/mobile/README.md')),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _AccountCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Panel(
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [palette.accent, palette.success],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              shape: BoxShape.circle,
            ),
            child: Text(
              'W',
              style: TextStyle(
                color: palette.onAccent,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'DeepSeek Remote',
                  style: TextStyle(
                    color: palette.text,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${kAppVersionLabel} · 本地设备',
                  style: TextStyle(color: palette.text3, fontSize: 11.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// M4.25：电脑端 DeepSeek 账号的余额。
///
/// 余额只有 Host 能查（`deepseekAccount.getBalance()` 说明里写着「only Host
/// consumers can obtain a request credential」），所以手机这边只认插件代理回来的
/// 钱包数字；未连接、未登录、查询失败三种情况都要有话说，不能只留个空白。
class _BalanceCard extends StatefulWidget {
  const _BalanceCard({required this.liveStore, this.urlOpener});

  final LiveStore liveStore;

  /// M4.33：App 内没有支付能力，只能把用户送到官方充值页。
  final UrlOpener? urlOpener;

  @override
  State<_BalanceCard> createState() => _BalanceCardState();
}

class _BalanceCardState extends State<_BalanceCard> {
  AccountBalance? _balance;
  bool _loading = false;
  String? _error;
  bool _wasConnected = false;

  @override
  void initState() {
    super.initState();
    _wasConnected = widget.liveStore.isConnected;
    widget.liveStore.addListener(_onStoreChanged);
    if (_wasConnected) {
      // 首帧之后再去请求，避免在 initState 里同步 setState。
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
  }

  @override
  void dispose() {
    widget.liveStore.removeListener(_onStoreChanged);
    super.dispose();
  }

  void _onStoreChanged() {
    final connected = widget.liveStore.isConnected;
    if (connected == _wasConnected) return;
    _wasConnected = connected;
    if (!mounted) return;
    if (connected) {
      _load();
    } else {
      setState(() {
        _balance = null;
        _error = null;
        _loading = false;
      });
    }
  }

  Future<void> _load() async {
    if (_loading || !widget.liveStore.isConnected) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final balance = await widget.liveStore.fetchAccountBalance();
      if (!mounted) return;
      setState(() {
        _balance = balance;
        _loading = false;
      });
    } on PairingApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '读取账户余额失败：$e';
        _loading = false;
      });
    }
  }

  /// M4.33：把用户送到官方充值页。电脑端的账户服务没有下单/付款能力，
  /// App 内不可能真的给账户加钱，只能跳浏览器由用户自己付款。
  ///
  /// M4.65：改成进「充值」页——那里把余额、三步流程、官方入口和
  /// 「为什么 App 里不能直接付」讲在一起，比一个直接跳走的按钮清楚。
  Future<void> _openRecharge() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RechargeScreen(
          liveStore: widget.liveStore,
          rechargeUrl: kBalanceRechargeUrl,
          urlOpener: widget.urlOpener,
        ),
      ),
    );
    if (!mounted) return;
    await _load();
  }

  /// 副标题：把「为什么没有数字」说清楚。
  String _subtitle(bool connected) {
    if (!connected) return '连接电脑后显示电脑端的 DeepSeek 余额';
    if (_loading) return '正在读取…';
    final error = _error;
    if (error != null && error.isNotEmpty) return error;
    final balance = _balance;
    if (balance == null) return '还没有读到余额';
    if (!balance.supported) return '这台电脑的插件版本太旧，读不到余额';
    if (balance.failed) {
      return balance.error.isEmpty ? '余额查询失败' : balance.error;
    }
    if (!balance.signedIn) return '电脑上还没登录 DeepSeek 账号';
    return '电脑端 DeepSeek 账号 · 点右侧刷新';
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final connected = widget.liveStore.isConnected;
    final balance = _balance;
    final primary = balance?.primary;
    final bonus = balance?.primaryBonus;
    final showAmount = connected && !_loading && _error == null && primary != null;

    // M4.32：Host 给的金额是 `"12.4137841000000000"` 这种原始定点串，
    // 直接塞进 Row 会把左边的标题挤成一列单字（实测截图），所以先格式化，
    // 再用 Flexible + FittedBox 兜住极端长的数字。
    final amountText = showAmount ? primary.display : '—';

    return Column(
      children: [
        Row(          children: [
            Icon(
              Icons.account_balance_wallet_outlined,
              size: 18,
              color: palette.text2,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '账户余额',
                    style: TextStyle(
                      color: palette.text,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    _subtitle(connected),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _error == null ? palette.text3 : palette.danger,
                      fontSize: 11.5,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (_loading)
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: palette.text3,
                ),
              )
            else
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Text(
                    amountText,
                    maxLines: 1,
                    style: TextStyle(
                      color: showAmount ? palette.text : palette.text3,
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            IconButton(
              onPressed: connected && !_loading ? _load : null,
              tooltip: '重新读取',
              iconSize: 17,
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.refresh_rounded, color: palette.text3),
            ),
          ],
        ),
        if (connected) ...[
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _openRecharge,
              icon: const Icon(Icons.open_in_new_rounded, size: 14),
              label: const Text('去充值'),
              style: TextButton.styleFrom(
                foregroundColor: palette.accent,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                minimumSize: const Size(0, 30),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                textStyle: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
        if (showAmount && bonus != null) ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Divider(height: 1, color: palette.line),
          ),
          Row(
            children: [
              Icon(
                Icons.card_giftcard_rounded,
                size: 15,
                color: palette.text3,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '赠送余额',
                  style: TextStyle(color: palette.text2, fontSize: 12.5),
                ),
              ),
              Text(
                bonus.display,
                style: TextStyle(
                  color: palette.text2,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _ListRow extends StatelessWidget {
  const _ListRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final content = Row(
      children: [
        Icon(icon, size: 19, color: palette.text2),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: palette.text,
                  fontSize: 13.2,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(
                  color: palette.text3,
                  fontSize: 11.3,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 8), trailing!],
      ],
    );
    if (onTap == null) return content;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: content,
    );
  }
}

/// M4.4：带开关的设置行（任务做完提醒 / 等待授权提醒）。
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Row(
      children: [
        Icon(icon, size: 19, color: palette.text2),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: palette.text,
                  fontSize: 13.2,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(
                  color: palette.text3,
                  fontSize: 11.3,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
        Switch.adaptive(
          value: value,
          activeThumbColor: palette.accent,
          onChanged: onChanged,
        ),
      ],
    );
  }
}
