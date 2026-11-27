import 'dart:async';

import 'package:flutter/material.dart';

import '../data/live_store.dart';
import '../models.dart';
import '../services/desktop_sort.dart';
import '../services/poll_coordinator.dart';
import '../services/remote_chat_intent.dart';
import '../services/history_api.dart' show ArchivedSession;
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import 'desktop_session_screen.dart';
import 'project_browser_screen.dart';
import 'projects_screen.dart' show projectNameOf;

/// M4.0：某个工作区的二级页——列出该目录下的会话/任务，底部可直接发指令。
///
/// M4.0 起：会话按最后活动时间倒序、状态用 [TaskStatusBadge]、显示消息数与时间；
/// 这一页自己轮询 [LiveStore.loadTasks]，进入时立即刷新一次，不再依赖上一页。
class WorkspaceScreen extends StatefulWidget {
  const WorkspaceScreen({
    super.key,
    required this.liveStore,
    required this.workspacePath,
    this.workspaceName,
    this.onOpenAssistant,
  });

  final LiveStore liveStore;
  final String workspacePath;
  final String? workspaceName;

  /// M4.50：点「新会话」时把用户送到 AI 助手的「远程电脑」对话框。
  /// 由 [RootShell] 经 [TasksScreen] 传进来（切到助手那一页）。
  final VoidCallback? onOpenAssistant;

  @override
  State<WorkspaceScreen> createState() => _WorkspaceScreenState();
}

class _WorkspaceScreenState extends State<WorkspaceScreen> with WidgetsBindingObserver {
  final TextEditingController _controller = TextEditingController();

  /// M4.0：工作区页也会停留很久（边看边发指令），用与任务页一致的 5 秒轮询保新鲜。
  static const Duration _pollInterval = Duration(seconds: 5);

  late final Listenable _listenable = widget.liveStore;

  /// M4.46：与任务页用同一套节奏（一次只跑一个、失败翻倍退避），
  /// 并且切到后台就停——这一页是自己 push 上来的，可见性等于「App 在前台」。
  late final PollCoordinator _poller = PollCoordinator(
    interval: _pollInterval,
    run: _pollOnce,
  );
  bool _sending = false;

  LiveStore get live => widget.liveStore;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _poller.active = true;
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poller.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _poller.active = true;
      _refresh();
      return;
    }
    // M4.46：切后台就不轮询，回来再续上（resume 时还会立刻补一次）。
    _poller.active = false;
  }

  /// M4.46：轮询真正做的事（只拉任务镜像，失败交给 PollCoordinator 退避）。
  Future<void> _pollOnce() async {
    if (!mounted || !live.isConnected || live.tasksLoading) return;
    await live.loadTasks();
  }

  void _refresh() {
    if (!live.isConnected) return;
    unawaited(live.loadTasks());
    // M4.10：顺带把存档里的会话也拉一次（电脑列表里已经看不到的那些）。
    unawaited(live.loadArchivedSessions());
  }

  /// M4.10：本工作区、电脑列表里已经没有的存档会话。
  List<ArchivedSession> get _archived => live.hiddenArchivedSessions
      .where((session) => session.workspace.trim() == widget.workspacePath)
      .toList(growable: false);

  void _openArchived(ArchivedSession session) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DesktopSessionScreen(
          liveStore: live,
          sessionId: session.id,
          title: session.title.isEmpty ? '历史会话' : session.title,
          lastTime: session.lastTime == 0 ? null : session.lastTime,
          archived: true,
        ),
      ),
    );
  }

  /// 已按新鲜度倒序排好的本工作区会话（M4.0）。
  List<TaskItem> get _tasks {
    final matched = live.tasks
        .where((task) => task.workspace.trim() == widget.workspacePath)
        .toList(growable: false);
    return live.usesDesktopTaskMirror ? sortDesktopTaskItems(matched) : matched;
  }

  TaskItem? get _latest => _tasks.isEmpty ? null : _tasks.first;

  String get _title =>
      widget.workspaceName ?? projectNameOf(widget.workspacePath);

  void _toast(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _browse() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ProjectBrowserScreen(
          liveStore: live,
          workspacePath: widget.workspacePath,
        ),
      ),
    );
  }

  /// M4.50：在这里点「新会话」= 去 AI 助手「远程电脑」的对话框发第一条消息。
  ///
  /// 以前是 `live.createConversation()` 发完即忘：电脑端的 Agent 子进程确实建了一个
  /// 空会话，但这一页的会话列表读的是**电脑端自己的**会话（两边是两个进程、两套
  /// 内存里的会话表），所以页面永远停在「还没有会话」，用户拿不到任何对话框。
  /// 现在改成把这一个工作区绑给下一场对话，再把用户送到真正有输入框的那一页。
  void _startNewChat() {
    final path = widget.workspacePath;
    live.setPendingWorkspace(path);
    final open = widget.onOpenAssistant;
    if (open == null) {
      _toast('已选择工作区「$_title」，回 AI 助手输入指令即可新建会话');
      return;
    }
    RemoteChatIntent.instance.open(workspacePath: path);
    open();
    if (mounted) Navigator.of(context).maybePop();
  }

  void _openSession(TaskItem task) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DesktopSessionScreen(
          liveStore: live,
          sessionId: task.id,
          sessions: <DesktopSessionOption>[
            for (final item in _tasks)
              DesktopSessionOption(id: item.id, title: item.title),
          ],
          title: task.title,
          lastTime: task.lastTime,
        ),
      ),
    );
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;
    final task = _latest;
    if (task == null) {
      _toast('还没有会话，先点「新会话」发第一条消息');
      return;
    }
    setState(() {
      _sending = true;
    });
    try {
      await live.sendDesktopPrompt(task.id, text);
      _controller.clear();
      if (!mounted) return;
      _toast('已发送到「${task.title}」，点会话可看进度');
    } catch (error) {
      if (!mounted) return;
      _toast('发送失败：$error');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  PreferredSizeWidget _buildAppBar() {
    final palette = context.appPalette;
    return AppBar(
      backgroundColor: palette.bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      toolbarHeight: 64,
      titleSpacing: 4,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: palette.text,
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            widget.workspacePath,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: palette.text3, fontSize: 11),
          ),
        ],
      ),
      actions: [
        IconButton(
          tooltip: '浏览工作区文件',
          onPressed: live.canListWorkspace ? _browse : null,
          icon: const Icon(Icons.folder_open_rounded, size: 20),
        ),
        IconButton(
          tooltip: '新建会话',
          onPressed: _startNewChat,
          icon: const Icon(Icons.add_comment_outlined, size: 20),
        ),
        IconButton(
          tooltip: '刷新会话',
          onPressed: live.tasksLoading ? null : _refresh,
          icon: const Icon(Icons.refresh_rounded, size: 20),
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  Widget _buildBody(List<TaskItem> tasks) {
    final palette = context.appPalette;
    final loading = live.tasksLoading && live.tasks.isEmpty;
    final error = live.tasksError;
    final archived = _archived;
    return RefreshIndicator(
      onRefresh: () async {
        await live.loadTasks();
        await live.loadArchivedSessions();
      },
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(
          AppSpace.page,
          8,
          AppSpace.page,
          _fabClearance,
        ),
        children: [
          if (loading)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: ClipRRect(
                borderRadius: BorderRadius.all(Radius.circular(3)),
                child: LinearProgressIndicator(minHeight: 3),
              ),
            ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                error,
                style: TextStyle(color: palette.danger, fontSize: 12),
              ),
            ),
          if (tasks.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 56),
              child: Column(
                children: [
                  const EmptyHint(
                    icon: Icons.forum_outlined,
                    text: '这个工作区还没有会话',
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '点下面的按钮去 AI 助手的「远程电脑」里发第一条消息，\n电脑就会在这个目录里开一个新对话。',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: palette.text3,
                      fontSize: 12,
                      height: 1.6,
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _startNewChat,
                    icon: const Icon(Icons.add_comment_rounded, size: 16),
                    label: const Text('去对话框发第一条消息'),
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 38)),
                  ),
                  TextButton(
                    onPressed: _startNewChat,
                    child: const Text('或在 AI 助手里发指令'),
                  ),
                ],
              ),
            )
          else
            for (final task in tasks) ...[
              _WorkspaceSessionCard(task: task, onTap: () => _openSession(task)),
              const SizedBox(height: AppSpace.cardGap),
            ],
          // M4.10：电脑端存档里保住的历史会话（电脑列表里已经看不到）。
          if (archived.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              '以前跑过、电脑上已经看不到的会话（${archived.length}）',
              style: TextStyle(color: palette.text3, fontSize: 12),
            ),
            const SizedBox(height: 8),
            for (final session in archived) ...[
              _ArchivedSessionCard(
                session: session,
                onTap: () => _openArchived(session),
              ),
              const SizedBox(height: AppSpace.cardGap),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildComposer(List<TaskItem> tasks) {
    final palette = context.appPalette;
    final hasTask = tasks.isNotEmpty;
    final hint = hasTask
        ? '发给「${tasks.first.title}」：在此工作区发指令…'
        : '点这里去 AI 助手发第一条消息，电脑会在这个目录里开新对话';
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                // M4.50：还没有会话时这一格不发送，改成点一下就带你去有对话框的那一页。
                readOnly: !hasTask,
                onTap: hasTask ? null : _startNewChat,
                onSubmitted: (_) => _send(),
                decoration: InputDecoration(
                  hintText: hint,
                  filled: true,
                  fillColor: palette.lineSoft,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 44,
              height: 44,
              child: FilledButton(
                onPressed: _sending || !hasTask ? null : _send,
                style: FilledButton.styleFrom(
                  padding: EdgeInsets.zero,
                  shape: const CircleBorder(),
                ),
                child: _sending
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.arrow_upward_rounded, size: 20),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _listenable,
      builder: (context, _) {
        final tasks = _tasks;
        return Scaffold(
          appBar: _buildAppBar(),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: _startNewChat,
            icon: const Icon(Icons.add_comment_rounded, size: 18),
            label: const Text('新会话'),
          ),
          body: Column(
            children: [
              Expanded(child: _buildBody(tasks)),
              _buildComposer(tasks),
            ],
          ),
        );
      },
    );
  }
}

/// 底部输入条会盖住列表最后一张卡，给列表留出悬浮按钮的落脚空间。
const double _fabClearance = 72;

/// 工作区页里的一张会话卡：标题 + 状态徽标 + 消息数 / 最后活动时间。
class _WorkspaceSessionCard extends StatelessWidget {
  const _WorkspaceSessionCard({required this.task, required this.onTap});

  final TaskItem task;
  final VoidCallback onTap;

  String get _meta {
    final parts = <String>[];
    if (task.messageCount > 0) parts.add('${task.messageCount} 条消息');
    final time = task.lastTime != null && task.lastTime! > 0
        ? formatLastTime(task.lastTime)
        : '';
    if (time.isNotEmpty) {
      parts.add(time);
    } else {
      parts.add(relativeTime(task.updatedAt));
    }
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Material(
      color: palette.card,
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.card),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        TaskStatusBadge(status: task.status),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _meta,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: palette.text3,
                              fontSize: 11.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: palette.text3),
            ],
          ),
        ),
      ),
    );
  }
}

/// M4.10：存档会话卡（电脑列表里已经没有，只能看）。
class _ArchivedSessionCard extends StatelessWidget {
  const _ArchivedSessionCard({required this.session, required this.onTap});

  final ArchivedSession session;
  final VoidCallback onTap;

  String get _meta {
    final count = session.messageCount > 0
        ? session.messageCount
        : session.eventCount;
    final parts = <String>[];
    if (count > 0) parts.add('$count 条消息');
    parts.add(
      session.lastTime > 0
          ? relativeTime(DateTime.fromMillisecondsSinceEpoch(session.lastTime))
          : '电脑上已经没有这条会话',
    );
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Material(
      color: palette.card,
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.card),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      session.title.isEmpty ? '历史会话' : session.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: palette.lineSoft,
                            borderRadius: BorderRadius.circular(AppRadius.pill),
                          ),
                          child: Text(
                            '已存档',
                            style: TextStyle(
                              color: palette.text2,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _meta,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: palette.text3,
                              fontSize: 11.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: palette.text3),
            ],
          ),
        ),
      ),
    );
  }
}
