import 'dart:async';

import 'package:flutter/material.dart';

import '../app_version.dart';
import '../data/live_store.dart';
import '../models.dart';
import '../services/cloud_chat_intent.dart';
import '../services/cloud_conversations.dart';
import '../services/share_gateway.dart';
import '../theme/app_theme.dart';
import '../widgets/app_mark.dart';
import 'assistant_screen.dart';
import 'desktop_session_screen.dart';
import 'features_screen.dart';
import 'plugins_screen.dart';
import 'profile_screen.dart';
import 'session_center_screen.dart';
import 'tasks_screen.dart';

/// 三页外壳：助手 / 工作区 / 我的。
///
/// M2.9：Kimi 风格——去掉底部导航，改成左侧抽屉 + 对话页左上角圆形菜单按钮；
/// 抽屉里放设备信息、四个入口、历史会话与版本号，页面用 IndexedStack 保活。
///
/// M4.41：删掉「电脑」页——用户的原话是「可以把这个页面删了」。那一页独占的
/// 内容只有「Agent / Harness 版本」「权限说明」和「紧急停止」，前两项在
/// 「我的 → 连接与设备」本来就有，所以只把**紧急停止**搬到「我的」页里保住，
/// 页面本身与它的「浏览电脑 / 停止任务」入口一起去掉。
class RootShell extends StatefulWidget {
  const RootShell({
    super.key,
    required this.liveStore,
    this.shareGateway,
    this.conversations,
  });

  final LiveStore liveStore;
  final ShareGateway? shareGateway;

  /// M4.34：手机档（云端直连）的对话存储，抽屉「手机对话」用；测试注入假的。
  final CloudConversationStore? conversations;

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> with WidgetsBindingObserver {
  int _index = 0;

  /// M4.46：App 是否在前台。IndexedStack 保活让工作区页「看不见也在轮询」，
  /// 这里把前台状态和当前页一起算成 `active` 传下去。
  bool _foreground = true;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  /// M4.34：手机档聊过的对话——用户要求「不放在工作区，放在抽屉里」，所以抽屉
  /// 「历史会话」上面多一段「手机对话」。存储与 AI 助手页共用同一份文件。
  late final CloudConversationStore _chatStore =
      widget.conversations ?? CloudConversationStore();
  List<CloudConversation> _phoneChats = const <CloudConversation>[];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // M4.4：点了「任务完成 / 等待授权」通知后直接切到对应页面。
    widget.liveStore.addListener(_consumeNotificationRoute);
    WidgetsBinding.instance.addPostFrameCallback((_) => _consumeNotificationRoute());
    unawaited(_loadPhoneChats());
  }

  Future<void> _loadPhoneChats() async {
    final saved = await _chatStore.load();
    if (!mounted) return;
    setState(() {
      _phoneChats = saved
          .where((item) => item.messages.isNotEmpty)
          .take(6)
          .toList(growable: false);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.liveStore.removeListener(_consumeNotificationRoute);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final bool foreground = state == AppLifecycleState.resumed;
    if (foreground == _foreground) return;
    setState(() => _foreground = foreground);
  }

  void _consumeNotificationRoute() {
    if (!mounted) return;
    final route = widget.liveStore.pendingNotificationRoute;
    if (route == null) return;
    widget.liveStore.clearPendingNotificationRoute();
    if (route == 'tasks' && _index != 1) setState(() => _index = 1);
  }

  void _openDrawer() {
    // 抽屉里要显示最新的手机对话，所以每次打开前重读一次。
    unawaited(_loadPhoneChats());
    _scaffoldKey.currentState?.openDrawer();
  }

  /// 抽屉里选中某项：先关抽屉再切页。
  void _selectFromDrawer(int index) {
    Navigator.of(context).pop();
    _select(index);
  }

  /// M3.5：抽屉「插件」——手机端查看/开关电脑上的插件。
  void _openPlugins() {
    Navigator.of(context).pop();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PluginsScreen(liveStore: widget.liveStore),
      ),
    );
  }

  void _select(int index) {
    if (index == _index) return;
    setState(() => _index = index);
  }

  /// M4.43：抽屉「历史会话」点一条 → 关抽屉、打开那场直播。
  ///
  /// 以前这里是 `_openConversation(ConversationSummary)`，读的是老后端数据，
  /// 插件直连下永远是空列表；现在数据源换成 [LiveStore.recentDesktopSessions]。
  void _openSession(RecentDesktopSession session) {
    Navigator.of(context).pop();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DesktopSessionScreen(
          liveStore: widget.liveStore,
          sessionId: session.id,
          title: session.title,
          lastTime: session.lastTime,
          archived: session.archived,
        ),
      ),
    );
  }

  /// M4.34：抽屉里点一条手机对话 → 关抽屉、切到 AI 助手页、打开那一条。
  void _openPhoneChat(String conversationId) {
    Navigator.of(context).pop();
    setState(() => _index = 0);
    CloudChatIntent.instance.open(conversationId);
  }

  /// M4.47：抽屉里只有一段「会话」，点「全部会话」进这里。
  Future<void> _openSessionCenter() async {
    Navigator.of(context).pop();
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SessionCenterScreen(
          liveStore: widget.liveStore,
          conversations: _chatStore,
          onOpenLocal: _openPhoneChatDirect,
        ),
      ),
    );
  }

  /// 会话中心选了一条本机对话：不关抽屉（它已经关了），直接切页并打开。
  void _openPhoneChatDirect(String conversationId) {
    if (!mounted) return;
    setState(() => _index = 0);
    CloudChatIntent.instance.open(conversationId);
  }

  @override
  Widget build(BuildContext context) {
    final liveStore = widget.liveStore;
    return Scaffold(
      key: _scaffoldKey,
      drawer: _AppDrawer(
        index: _index,
        liveStore: liveStore,
        phoneChats: _phoneChats,
        onSelected: _selectFromDrawer,
        onOpenSession: _openSession,
        onOpenPhoneChat: _openPhoneChat,
        onOpenSessions: _openSessionCenter,
        onOpenPlugins: _openPlugins,
      ),
      body: IndexedStack(
        index: _index,
        children: [
          AssistantScreen(
            liveStore: liveStore,
            conversations: widget.conversations,
            shareGateway: widget.shareGateway,
            onOpenMenu: _openDrawer,
            onOpenProjects: () => _select(1),
            onOpenTasks: () => _select(1),
          ),
          TasksScreen(
            liveStore: liveStore,
            onOpenMenu: _openDrawer,
            // M4.50：工作区页「新会话」把用户送回 AI 助手的远程对话框。
            onOpenAssistant: () => _select(0),
            // M4.46：只在这一页可见且 App 在前台时轮询。
            active: _index == 1 && _foreground,
          ),
          // M4.42：能力入口单独一页，抽屉里排在「我的」上面。
          FeaturesScreen(liveStore: liveStore, onOpenMenu: _openDrawer),
          ProfileScreen(liveStore: liveStore, onOpenMenu: _openDrawer),
        ],
      ),
    );
  }
}

class _NavItem {
  const _NavItem(this.label, this.icon, this.selectedIcon);

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

/// 抽屉里的四个入口（顺序与 IndexedStack 一致，便于单测直接校验）。
///
/// M4.42：新增「功能」（能力入口，插件管理先在里头），排在「我的」上面。
const List<_NavItem> RootShellItems = <_NavItem>[
  _NavItem('AI 助手', Icons.auto_awesome_outlined, Icons.auto_awesome_rounded),
  _NavItem('工作区', Icons.space_dashboard_outlined, Icons.space_dashboard_rounded),
  _NavItem('功能', Icons.widgets_outlined, Icons.widgets_rounded),
  _NavItem('我的', Icons.person_outline_rounded, Icons.person_rounded),
];

class _AppDrawer extends StatelessWidget {
  const _AppDrawer({
    required this.index,
    required this.liveStore,
    required this.phoneChats,
    required this.onSelected,
    required this.onOpenSession,
    required this.onOpenPhoneChat,
    required this.onOpenSessions,
    required this.onOpenPlugins,
  });

  final int index;
  final LiveStore liveStore;

  /// M4.34：手机档（云端直连）的对话，点一条切回 AI 助手继续聊。
  final List<CloudConversation> phoneChats;
  final ValueChanged<int> onSelected;
  final ValueChanged<RecentDesktopSession> onOpenSession;
  final ValueChanged<String> onOpenPhoneChat;

  /// M4.47：打开统一的「会话」中心。
  final VoidCallback onOpenSessions;
  final VoidCallback onOpenPlugins;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final width = MediaQuery.sizeOf(context).width;
    return Drawer(
      width: width > 460 ? 400 : width * 0.86,
      backgroundColor: palette.bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.only(
          topRight: Radius.circular(26),
          bottomRight: Radius.circular(26),
        ),
      ),
      child: SafeArea(
        child: ListenableBuilder(
          listenable: liveStore,
          builder: (context, _) {
            final connected = liveStore.isConnected;
            final name = liveStore.deviceName.trim();
            // M4.43：历史会话的数据源——桌面会话镜像 + 只在存档里的会话。
            final sessions = liveStore.recentDesktopSessions;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _DrawerHeader(
                  title: name.isEmpty ? 'DeepSeek 手机端' : name,
                  subtitle: connected ? '已连接电脑' : '未连接电脑',
                  onNewChat: () => onSelected(0),
                ),
                const SizedBox(height: 6),
                for (var i = 0; i < RootShellItems.length; i++)
                  _DrawerTile(
                    item: RootShellItems[i],
                    selected: i == index,
                    onTap: () => onSelected(i),
                  ),
                const SizedBox(height: 18),
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 0, 22, 6),
                  child: Row(
                    children: [
                      Text(
                        '会话',
                        style: TextStyle(
                          color: palette.text3,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: onOpenSessions,
                        style: TextButton.styleFrom(
                          minimumSize: Size.zero,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: Text(
                          '全部会话',
                          style: TextStyle(color: palette.accent, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    children: [
                      if (sessions.isEmpty && phoneChats.isEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(10, 4, 10, 0),
                          child: Text(
                            connected
                                ? '电脑上还没有会话，手机上也没有对话'
                                : '连接电脑后显示远程会话',
                            style: TextStyle(
                              color: palette.text3,
                              fontSize: 12.5,
                            ),
                          ),
                        ),
                      if (sessions.isNotEmpty) ...[
                        _DrawerGroupLabel(
                          label: '远程电脑',
                          count: sessions.length,
                        ),
                        for (final session in sessions.take(3))
                          _SessionTile(
                            session: session,
                            onTap: () => onOpenSession(session),
                          ),
                      ],
                      if (phoneChats.isNotEmpty) ...[
                        _DrawerGroupLabel(
                          label: '本机对话',
                          count: phoneChats.length,
                        ),
                        for (final chat in phoneChats.take(3))
                          _PhoneChatDrawerTile(
                            conversation: chat,
                            onTap: () => onOpenPhoneChat(chat.id),
                          ),
                      ],
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 6, 22, 16),
                  child: Text(
                    '手机端 v$kAppVersionName',
                    style: TextStyle(color: palette.text3, fontSize: 11),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// M4.47：抽屉会话区里的子分组（远程电脑 / 本机对话）。
class _DrawerGroupLabel extends StatelessWidget {
  const _DrawerGroupLabel({required this.label, required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(
              color: palette.text3,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '$count',
            style: TextStyle(color: palette.text3, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _DrawerHeader extends StatelessWidget {
  const _DrawerHeader({
    required this.title,
    required this.subtitle,
    required this.onNewChat,
  });

  final String title;
  final String subtitle;
  final VoidCallback onNewChat;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 14, 10),
      child: Row(
        children: [
          const AppMark(size: 42, withShadow: false),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: palette.text,
                    fontSize: 16.5,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: TextStyle(color: palette.text3, fontSize: 11.5),
                ),
              ],
            ),
          ),
          _CircleButton(
            icon: Icons.add_rounded,
            onTap: onNewChat,
            tooltip: '回到对话',
          ),
        ],
      ),
    );
  }
}

class _DrawerTile extends StatelessWidget {
  const _DrawerTile({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final _NavItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final color = selected ? palette.accent : palette.text;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
      child: Material(
        color: selected ? palette.accentSoft : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
            child: Row(
              children: [
                Icon(
                  selected ? item.selectedIcon : item.icon,
                  size: 21,
                  color: color,
                ),
                const SizedBox(width: 14),
                Text(
                  item.label,
                  style: TextStyle(
                    color: color,
                    fontSize: 15.5,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// M4.34：抽屉里的一条手机对话（手机档云端直连，只存在这台手机上）。
class _PhoneChatDrawerTile extends StatelessWidget {
  const _PhoneChatDrawerTile({required this.conversation, required this.onTap});

  final CloudConversation conversation;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final count = conversation.messages.length;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
              Icon(
                Icons.chat_bubble_outline_rounded,
                size: 16,
                color: palette.text3,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      conversation.displayTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: palette.text, fontSize: 13.5),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      count == 0
                          ? '还没有说话'
                          : '$count 条消息 · ${relativeTime(conversation.updatedAt)}',
                      style: TextStyle(color: palette.text3, fontSize: 11.5),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// M4.43：抽屉「历史会话」的一行——活会话与存档会话共用，存档那条加个小标。
class _SessionTile extends StatelessWidget {
  const _SessionTile({required this.session, required this.onTap});

  final RecentDesktopSession session;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        child: Row(
          children: [
            Icon(
              session.archived ? Icons.inventory_2_outlined : Icons.chat_bubble_outline_rounded,
              size: 16,
              color: palette.text3,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                session.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: palette.text2, fontSize: 13.5),
              ),
            ),
            if (session.archived)
              Text(
                '已存档',
                style: TextStyle(color: palette.text3, fontSize: 11),
              ),
          ],
        ),
      ),
    );
  }
}

class _CircleButton extends StatelessWidget {
  const _CircleButton({
    required this.icon,
    required this.onTap,
    this.tooltip,
    this.size = 38,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final String? tooltip;
  final double size;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final button = Material(
      color: palette.card,
      shape: CircleBorder(side: BorderSide(color: palette.line)),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, size: 19, color: palette.text2),
        ),
      ),
    );
    if (tooltip == null) return button;
    return Tooltip(message: tooltip!, child: button);
  }
}
