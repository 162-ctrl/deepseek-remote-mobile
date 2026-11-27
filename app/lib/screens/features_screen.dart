import 'package:flutter/material.dart';

import '../data/live_store.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import 'changelog_screen.dart';
import 'plugins_screen.dart';
import 'received_files_screen.dart';

/// 功能：抽屉里排在「我的」上面的能力入口。
///
/// M4.42：用户要求「做一个功能页面放到我的上面，先把插件拿出来放到里面」。
/// 以前「插件管理」藏在「我的 → 关于与更新」里，一个偏系统设置的位置；
/// 现在单独开一页装这类能力入口，后续再加新功能（定时任务、技能等）都往这里放。
class FeaturesScreen extends StatelessWidget {
  const FeaturesScreen({super.key, required this.liveStore, this.onOpenMenu});

  final LiveStore liveStore;

  /// M2.9：抽屉入口（由 RootShell 注入）。
  final VoidCallback? onOpenMenu;

  void _openPlugins(BuildContext context) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => PluginsScreen(liveStore: liveStore),
      ),
    );
  }

  /// M4.57：电脑端发过来的文件（AI 让我发，我放进插件的 received 目录）。
  void _openReceivedFiles(BuildContext context) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ReceivedFilesScreen(liveStore: liveStore),
      ),
    );
  }

  /// M4.66：每次发版改了什么，都收在这一页。
  void _openChangelog(BuildContext context) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ChangelogScreen(liveStore: liveStore),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return ListenableBuilder(
      listenable: liveStore,
      builder: (context, _) {
        final connected = liveStore.isConnected;
        return Scaffold(
          appBar: KimiAppBar(title: '功能', onOpenMenu: onOpenMenu),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpace.page,
              10,
              AppSpace.page,
              28,
            ),
            children: [
              const SectionTitle('扩展'),
              Panel(
                child: _FeatureRow(
                  icon: Icons.extension_outlined,
                  title: '插件管理',
                  subtitle: connected
                      ? '查看与开关电脑上的插件'
                      : '连接电脑后可以查看与开关插件',
                  enabled: true,
                  palette: palette,
                  onTap: () => _openPlugins(context),
                ),
              ),
              const SizedBox(height: 10),
              Panel(
                child: _FeatureRow(
                  icon: Icons.inbox_outlined,
                  title: '接收文件',
                  subtitle: connected
                      ? '电脑上发来的文件都在这里，点开就能看'
                      : '连接电脑后可以看电脑上发来的文件',
                  enabled: connected,
                  palette: palette,
                  onTap: () => _openReceivedFiles(context),
                ),
              ),
              const SizedBox(height: 10),
              Panel(
                child: _FeatureRow(
                  icon: Icons.history_rounded,
                  title: '更新日志',
                  subtitle: '每次发版改了什么，都在这里',
                  enabled: true,
                  palette: palette,
                  onTap: () => _openChangelog(context),
                ),
              ),
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  '这里放电脑端提供的能力入口；插件装好后会出现在「AI 助手」的回答里。',
                  style: TextStyle(
                    color: palette.text3,
                    fontSize: 11.5,
                    height: 1.6,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _FeatureRow extends StatelessWidget {
  const _FeatureRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.enabled,
    required this.palette,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool enabled;
  final AppPalette palette;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: palette.accentSoft,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              icon,
              size: 18,
              color: enabled ? palette.accent : palette.text3,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: palette.text,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: palette.text3,
                    fontSize: 11.5,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          Icon(
            Icons.chevron_right_rounded,
            size: 18,
            color: palette.text3,
          ),
        ],
      ),
    );
  }
}
