import 'package:flutter/material.dart';

import '../data/live_store.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import '../widgets/empty_state.dart';
import 'connect_screen.dart';
import 'project_browser_screen.dart';

/// 工作区页（M2.6）：展示 Agent 上报的真实工作区根，可浏览目录并在工作区内发指令。
class ProjectsScreen extends StatelessWidget {
  const ProjectsScreen({
    super.key,
    required this.liveStore,
    this.onOpenAssistant,
    this.onOpenMenu,
  });

  final LiveStore liveStore;

  /// 选择工作区工作区后切到「AI 助手」Tab（由 RootShell 注入）。
  final VoidCallback? onOpenAssistant;

  /// M2.9：抽屉入口（由 RootShell 注入）。
  final VoidCallback? onOpenMenu;

  Future<void> _openConnect(BuildContext context) async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => ConnectScreen(store: liveStore)),
    );
  }

  void _openBrowser(BuildContext context, String root) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ProjectBrowserScreen(
          liveStore: liveStore,
          workspacePath: root,
          onOpenAssistant: onOpenAssistant,
        ),
      ),
    );
  }

  void _useProject(BuildContext context, String root) {
    liveStore.setPendingWorkspace(root);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已选择工作区：${projectNameOf(root)}，去 AI 助手输入指令'),
      ),
    );
    onOpenAssistant?.call();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: liveStore,
      builder: (context, _) {
        final connected = liveStore.isConnected;
        final roots = liveStore.workspaceRoots;
        return Scaffold(
          appBar: KimiAppBar(title: '工作区', onOpenMenu: onOpenMenu),
          body: connected
              ? _buildConnected(context, roots)
              : EmptyState(
                  icon: Icons.folder_copy_outlined,
                  title: '连接电脑后在这里浏览工作区',
                  description: '连接后可以逐级浏览电脑上的工作区目录，并直接在工作区里发指令',
                  actionLabel: '连接电脑',
                  onAction: () => _openConnect(context),
                ),
        );
      },
    );
  }

  Widget _buildConnected(BuildContext context, List<String> roots) {
    final palette = context.appPalette;
    return RefreshIndicator(
      onRefresh: () async {},
      child: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpace.page,
          10,
          AppSpace.page,
          28,
        ),
        children: [
          Row(
            children: [
              Icon(Icons.lock_outline_rounded, size: 13, color: palette.text3),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  'AI 只能看到你授权的工作区目录',
                  style: TextStyle(color: palette.text3, fontSize: 11.5),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (roots.isEmpty)
            const EmptyHint(
              icon: Icons.folder_off_outlined,
              text: '电脑端还没有配置工作区（M1_WORKSPACE_ROOT）',
            )
          else if (!liveStore.canListWorkspace)
            const EmptyHint(
              icon: Icons.system_update_alt_rounded,
              text: '电脑端 Agent 版本过低，暂不支持工作区浏览，请升级后重试',
            )
          else
            for (var i = 0; i < roots.length; i++) ...[
              _ProjectRootCard(
                path: roots[i],
                onBrowse: () => _openBrowser(context, roots[i]),
                onUse: () => _useProject(context, roots[i]),
              ),
              if (i != roots.length - 1) const SizedBox(height: 10),
            ],
          const SizedBox(height: 18),
          Text(
            '目录由电脑端 Agent 配置，手机端只读浏览；「在此工作区发指令」会让新会话绑定该目录。',
            style: TextStyle(color: palette.text3, fontSize: 11, height: 1.5),
          ),
        ],
      ),
    );
  }
}

/// 取路径最后一段作为工作区名（兼容 Windows 反斜杠）。
String projectNameOf(String path) {
  final normalized = path.replaceAll('\\', '/');
  final segments =
      normalized.split('/').where((segment) => segment.isNotEmpty).toList();
  return segments.isEmpty ? path : segments.last;
}

class _ProjectRootCard extends StatelessWidget {
  const _ProjectRootCard({
    required this.path,
    required this.onBrowse,
    required this.onUse,
  });

  final String path;
  final VoidCallback onBrowse;
  final VoidCallback onUse;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Container(
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: palette.line),
        boxShadow: palette.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: onBrowse,
            borderRadius: BorderRadius.circular(AppRadius.card),
            child: Padding(
              padding: const EdgeInsets.all(AppSpace.card),
              child: Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: palette.accentSoft,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.folder_rounded,
                      size: 19,
                      color: palette.accent,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          projectNameOf(path),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: palette.text,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          path,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: palette.text3,
                            fontSize: 10.5,
                            fontFamily: 'monospace',
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 20,
                    color: palette.text3,
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpace.card, 0, AppSpace.card, 12),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onBrowse,
                    icon: const Icon(Icons.folder_open_rounded, size: 16),
                    label: const Text('浏览'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 38),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: FilledButton.icon(
                    onPressed: onUse,
                    icon: const Icon(Icons.terminal_rounded, size: 16),
                    label: const Text('在此工作区发指令'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 38),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
