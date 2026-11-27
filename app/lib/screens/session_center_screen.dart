import 'package:flutter/material.dart';

import '../data/live_store.dart';
import '../services/cloud_conversations.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import 'desktop_session_screen.dart';

/// M4.47：统一「会话」中心（第二阶段第 ⑧ 条）。
///
/// 以前会话散在三个地方：顶栏历史按钮（桌面会话弹层）、抽屉「手机对话」、
/// 抽屉「历史会话」——同一个概念两套入口，用户要记「想找的那条在哪」。
/// 现在只留这一页，分两组：
///
/// * **远程电脑**：[LiveStore.recentDesktopSessions]（任务镜像 + 只在存档里的
///   会话），点一条打开那场直播；存档会话进去后仍能接着发话。
/// * **本机对话**：存在这台手机上的 [CloudConversationStore] 对话，点一条
///   先把本页关掉，再交给调用方切到 AI 助手页并打开那一条。
class SessionCenterScreen extends StatefulWidget {
  const SessionCenterScreen({
    super.key,
    required this.liveStore,
    required this.conversations,
    required this.onOpenLocal,
  });

  final LiveStore liveStore;
  final CloudConversationStore conversations;

  /// 选了一条「本机对话」的对话；调用方负责切页并打开。
  final ValueChanged<String> onOpenLocal;

  @override
  State<SessionCenterScreen> createState() => _SessionCenterScreenState();
}

class _SessionCenterScreenState extends State<SessionCenterScreen> {
  List<CloudConversation> _local = const <CloudConversation>[];
  bool _loadingLocal = true;
  String? _localError;

  @override
  void initState() {
    super.initState();
    _loadLocal();
    // 桌面会话镜像还在别处刷新；这里只读，不额外发请求。
    widget.liveStore.addListener(_onLiveChanged);
  }

  @override
  void dispose() {
    widget.liveStore.removeListener(_onLiveChanged);
    super.dispose();
  }

  /// 桌面会话变了（拉完任务、任务状态推进）就重画，不必手动刷新。
  void _onLiveChanged() {
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _loadLocal() async {
    setState(() {
      _loadingLocal = true;
      _localError = null;
    });
    try {
      final items = await widget.conversations.load();
      if (!mounted) return;
      setState(() {
        _local = items.where((item) => item.messages.isNotEmpty).toList();
        _loadingLocal = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _localError = '读取手机上的对话失败：$error';
        _loadingLocal = false;
      });
    }
  }

  Future<void> _refresh() async {
    await Future.wait<void>([
      widget.liveStore.loadTasks(),
      _loadLocal(),
    ]);
  }

  void _openRemote(RecentDesktopSession session) {
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

  void _openLocal(CloudConversation conversation) {
    Navigator.of(context).pop();
    widget.onOpenLocal(conversation.id);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Scaffold(
      backgroundColor: palette.bg,
      appBar: KimiAppBar(
        title: '会话',
        leading: IconButton(
          tooltip: '返回',
          onPressed: () => Navigator.of(context).maybePop(),
          icon: Icon(Icons.arrow_back_rounded, color: palette.text),
        ),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _refresh,
            icon: Icon(Icons.refresh_rounded, color: palette.text2),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: widget.liveStore,
        builder: (context, _) {
          final remote = widget.liveStore.recentDesktopSessions;
          return ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpace.page,
              4,
              AppSpace.page,
              AppSpace.page,
            ),
            children: [
              _SectionHeader(
                icon: Icons.computer_rounded,
                title: '远程电脑',
                count: remote.length,
                subtitle: widget.liveStore.isConnected
                    ? '在电脑上跑的任务；点一条看直播，存档的也能接着聊'
                    : '连接电脑后这里会列出电脑上的会话',
              ),
              if (remote.isEmpty)
                _EmptyRow(
                  text: widget.liveStore.isConnected
                      ? '电脑上还没有会话；发第一条指令就会创建会话'
                      : '还没有连接电脑',
                )
              else
                for (final session in remote)
                  _RemoteRow(
                    session: session,
                    onTap: () => _openRemote(session),
                  ),
              const SizedBox(height: 22),
              _SectionHeader(
                icon: Icons.phone_iphone_rounded,
                title: '本机对话',
                count: _local.length,
                subtitle: '只存在这台手机上，换手机或重装会丢',
              ),
              if (_localError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _localError!,
                    style: TextStyle(
                      color: palette.danger,
                      fontSize: 11.5,
                      height: 1.4,
                    ),
                  ),
                ),
              if (_loadingLocal)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 18),
                  child: Center(
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2.2),
                    ),
                  ),
                )
              else if (_local.isEmpty)
                const _EmptyRow(text: '还没有本机对话；在 AI 助手页发一条就会存下来')
              else
                for (final conversation in _local)
                  _LocalRow(
                    conversation: conversation,
                    onTap: () => _openLocal(conversation),
                  ),
            ],
          );
        },
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.icon,
    required this.title,
    required this.count,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final int count;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 15, color: palette.text2),
              const SizedBox(width: 6),
              Text(
                title,
                style: TextStyle(
                  color: palette.text,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              if (count > 0)
                Text(
                  '$count',
                  style: TextStyle(color: palette.text3, fontSize: 12),
                ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            subtitle,
            style: TextStyle(color: palette.text3, fontSize: 11.5, height: 1.4),
          ),
        ],
      ),
    );
  }
}

class _EmptyRow extends StatelessWidget {
  const _EmptyRow({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 8, 2, 4),
      child: Text(
        text,
        style: TextStyle(color: palette.text3, fontSize: 12.5, height: 1.5),
      ),
    );
  }
}

class _RemoteRow extends StatelessWidget {
  const _RemoteRow({required this.session, required this.onTap});

  final RecentDesktopSession session;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return _RowShell(
      onTap: onTap,
      leading: Icon(
        session.archived
            ? Icons.inventory_2_outlined
            : Icons.chat_bubble_outline_rounded,
        size: 17,
        color: palette.text2,
      ),
      title: session.title,
      trailing: session.archived
          ? Text(
              '已存档',
              style: TextStyle(color: palette.text3, fontSize: 11),
            )
          : null,
    );
  }
}

class _LocalRow extends StatelessWidget {
  const _LocalRow({required this.conversation, required this.onTap});

  final CloudConversation conversation;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final count = conversation.messages.length;
    return _RowShell(
      onTap: onTap,
      leading: Icon(
        Icons.smartphone_rounded,
        size: 17,
        color: palette.text2,
      ),
      title: conversation.displayTitle,
      subtitle: '$count 条消息 · ${_relativeTime(conversation.updatedAt)}',
      trailing: Icon(
        Icons.chevron_right_rounded,
        size: 18,
        color: palette.text3,
      ),
    );
  }
}

class _RowShell extends StatelessWidget {
  const _RowShell({
    required this.onTap,
    required this.leading,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  final VoidCallback onTap;
  final Widget leading;
  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: palette.card,
        borderRadius: BorderRadius.circular(AppRadius.card),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.card),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Row(
              children: [
                leading,
                const SizedBox(width: 10),
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
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: palette.text3,
                            fontSize: 11.5,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (trailing != null) ...[
                  const SizedBox(width: 8),
                  trailing!,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 与抽屉里的相对时间保持同一套说法，避免同一个会话两处显示不同。
String _relativeTime(DateTime time) {
  final diff = DateTime.now().difference(time);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
  if (diff.inDays < 1) return '${diff.inHours} 小时前';
  if (diff.inDays < 30) return '${diff.inDays} 天前';
  final local = time.toLocal();
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  return '${local.year}-$month-$day';
}
