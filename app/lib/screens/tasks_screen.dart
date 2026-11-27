import 'dart:async';

import 'package:flutter/material.dart';

import '../data/live_store.dart';
import '../models.dart';
import '../services/desktop_sort.dart';
import '../services/poll_coordinator.dart';
import '../services/history_api.dart' show ArchivedSession, DesktopPending, DesktopPendingQuestion;
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import '../widgets/empty_state.dart';
import '../widgets/workspace_create_dialog.dart';
import 'projects_screen.dart';
import '../widgets/timeline.dart';
import 'connect_screen.dart';
import 'desktop_session_screen.dart';
import 'workspace_screen.dart';

/// 工作区：按工作区筛任务、看会话，还能进目录浏览文件（M3.7 起与任务中心合并）。
class TasksScreen extends StatefulWidget {
  const TasksScreen({
    super.key,
    required this.liveStore,
    this.onOpenMenu,
    this.onOpenAssistant,
    this.active = true,
  });

  final LiveStore liveStore;

  /// M2.9：抽屉入口（由 RootShell 注入）。
  final VoidCallback? onOpenMenu;

  /// M4.50：工作区二级页点「新会话」时，把用户送回 AI 助手的远程对话框。
  final VoidCallback? onOpenAssistant;

  /// M4.46：这一页现在该不该轮询。
  ///
  /// IndexedStack 会把这一页一直挂在树上（切走也不销毁），所以以前用户在看
  /// AI 助手页时，这里仍然每 5 秒发一次 loadTasks + loadPending。
  /// RootShell 现在把「当前是这一页 && App 在前台」算好传进来，看着别的页就停。
  final bool active;

  @override
  State<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends State<TasksScreen> {
  static const List<TaskStatus?> _filters = <TaskStatus?>[
    null,
    TaskStatus.running,
    TaskStatus.waitingApproval,
    TaskStatus.completed,
    TaskStatus.failed,
  ];

  TaskStatus? _filter;
  String? _workspace;
  /// M4.51：被展开的项目分组（按工作区路径记）。默认全部折叠——一个项目里
  /// 二十几条会话全铺出来，既看不清有几个项目，也找不到正在跑的那条。
  final Set<String> _expanded = <String>{};
  late final Listenable _listenable = widget.liveStore;

  /// M4.46：轮询交给 [PollCoordinator]——一次只跑一个、失败翻倍退避。
  late final PollCoordinator _poller = PollCoordinator(
    interval: const Duration(seconds: 5),
    run: _pollOnce,
    active: widget.active,
  );

  LiveStore get live => widget.liveStore;

  /// M4.31：电脑上等着手机回答的提问（跨会话）。
  ///
  /// 提问以前只有「手机正停在那条会话的直播页」才会被手机接管，所以用户在电脑上
  /// 看到的「确认需求」卡片，手机上永远不出现。现在只要 App 还连着就接管，
  /// 这个字段负责在别的页面也提前告诉用户「有 1 个问题等着」。
  DesktopPending _pending = const DesktopPending();

  @override
  void initState() {
    super.initState();
    // M2.9.2：插件直连没有任务推送，靠 5 秒轮询桌面镜像保持状态接近实时。
    // M4.46：节奏交给 PollCoordinator，且只在「这一页可见 + App 在前台」时跑。
    // M4.46：先建出协调器（active=false 时它什么也不排）。
    _poller.active = widget.active;
    unawaited(live.ensureLiveData());
    // M4.10：电脑端存档里那些「已经从列表消失」的会话。
    unawaited(live.loadArchivedSessions());
    unawaited(_loadPending());
  }

  /// M4.46：轮询真正做的事（任务镜像 + 待回答摘要）。
  Future<void> _pollOnce() async {
    if (!mounted || !live.isConnected) return;
    if (!live.tasksLoading) unawaited(live.loadTasks());
    await _loadPending();
  }

  @override
  void didUpdateWidget(covariant TasksScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) _poller.active = widget.active;
  }

  /// M4.31：读一次待回答摘要。失败就当没有——这是提示性信息，不该弹错。
  Future<void> _loadPending() async {
    if (!live.isConnected) return;
    try {
      final pending = await live.fetchDesktopPending();
      if (!mounted) return;
      setState(() => _pending = pending);
      // M4.35：新提问发一条系统通知，别等人自己点进来才发现。
      unawaited(live.notePendingQuestions(pending.questions));
    } on Exception {
      if (!mounted) return;
      setState(() => _pending = const DesktopPending());
    }
  }

  @override
  void dispose() {
    _poller.dispose();
    super.dispose();
  }

  String _filterLabel(TaskStatus? status) {
    if (status == null) return '全部';
    if (status == TaskStatus.running) return '进行中';
    if (status == TaskStatus.waitingApproval) return '等待授权';
    if (status == TaskStatus.completed) return '已完成';
    if (status == TaskStatus.failed) return '失败';
    return status.label;
  }

  bool _matches(TaskItem task) {
    final workspace = _workspace;
    if (workspace != null && (task.workspace?.trim() ?? '') != workspace) {
      return false;
    }
    final filter = _filter;
    if (filter == null) return true;
    if (filter == TaskStatus.running) {
      return task.status == TaskStatus.running ||
          task.status == TaskStatus.waitingApproval;
    }
    return task.status == filter;
  }

  int _countFor(TaskStatus? status) {
    if (status == null) return live.tasks.length;
    return live.tasks.where((task) {
      if (status == TaskStatus.running) {
        return task.status == TaskStatus.running ||
            task.status == TaskStatus.waitingApproval;
      }
      return task.status == status;
    }).length;
  }

  Future<void> _openConnect() async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => ConnectScreen(store: live)),
    );
  }

  /// M4.10：当前筛选下、电脑列表里已经没有的存档会话。
  ///
  /// M4.11：不再只限「已完成」——这些会话已经不在电脑列表里了，「进行中 /
  /// 等待授权 / 失败」这几档描述的是电脑上**正在跑**的会话，用它们去筛存档只会
  /// 让用户点了「进行中」就找不到刚才那个会话。所以只要开了工作区胶囊之外的
  /// 筛选，存档组照样展示（它自己的标题已经写明「电脑上已经看不到」）。
  List<ArchivedSession> get _hiddenArchived {
    final workspace = _workspace;
    final liveIds = <String>{for (final task in live.tasks) task.id};
    return live.hiddenArchivedSessions.where((session) {
      // 电脑列表里还在的会话不重复显示成「已存档」。
      if (liveIds.contains(session.id)) return false;
      if (workspace != null && session.workspace.trim() != workspace) {
        return false;
      }
      return true;
    }).toList(growable: false);
  }

  /// M4.11：电脑端授权了、但当前电脑列表里还没有会话的工作区。
  ///
  /// M4.13：改成给分组用——空目录不再单独成卡，而是作为「0 个会话」的项目卡出现。
  List<String> get _idleWorkspaces {
    final filter = _filter;
    final workspace = _workspace;
    // 「进行中 / 等待授权 / 失败」这几档描述的是会话状态，没有会话的目录不该出现在里面。
    if (filter != null && filter != TaskStatus.completed) return const <String>[];
    final busy = <String>{};
    for (final task in live.tasks) {
      final path = task.workspace?.trim() ?? '';
      if (path.isNotEmpty) busy.add(path);
    }
    for (final session in _hiddenArchived) {
      final path = session.workspace.trim();
      if (path.isNotEmpty) busy.add(path);
    }
    final paths = <String>[];
    for (final root in live.workspaceRoots) {
      final path = root.trim();
      if (path.isEmpty || paths.contains(path) || busy.contains(path)) continue;
      if (workspace != null && path != workspace) continue;
      paths.add(path);
    }
    return paths;
  }

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

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _listenable,
      builder: (context, _) {
        if (!live.isConnected) {
          return Scaffold(
            appBar: KimiAppBar(
              title: '工作区',
              onOpenMenu: widget.onOpenMenu,
            ),
            body: ListView(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.page,
                10,
                AppSpace.page,
                28,
              ),
              children: [
                const SizedBox(height: 40),
                EmptyState(
                  icon: Icons.task_alt_outlined,
                  title: '连接后在这里看工作区',
                  description: '连接电脑后，这里按工作区列出任务与会话，也能进目录看文件',
                  actionLabel: '连接电脑',
                  onAction: _openConnect,
                ),
              ],
            ),
          );
        }
        final filtered = live.tasks.where(_matches).toList(growable: false);
        // M3.6：桌面会话镜像按 lastTime 新鲜度排序，最新的会话排在最前。
        final tasks = live.usesDesktopTaskMirror
            ? sortDesktopTaskItems(filtered)
            : filtered;
        final loading = live.tasksLoading && live.tasks.isEmpty;
        final error = live.tasksError;
        // M4.13：按项目分组后的行，整页只算一次。
        final groups = _groupRows;
        return Scaffold(
          appBar: KimiAppBar(
            title: '工作区',
            onOpenMenu: widget.onOpenMenu,
            actions: [
              IconButton(
                tooltip: '浏览工作区文件',
                onPressed: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ProjectsScreen(
                        liveStore: widget.liveStore,
                        onOpenAssistant: () {},
                      ),
                    ),
                  );
                },
                icon: const Icon(Icons.folder_open_rounded, size: 20),
              ),
              IconButton(
                tooltip: '刷新任务',
                onPressed: live.tasksLoading ? null : live.loadTasks,
                icon: const Icon(Icons.refresh_rounded, size: 20),
              ),
            ],
          ),
          body: RefreshIndicator(
            onRefresh: live.loadTasks,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(
                AppSpace.page,
                10,
                AppSpace.page,
                28,
              ),
              children: [
                if (loading)
                  const Padding(
                    padding: EdgeInsets.only(top: 4, bottom: 8),
                    child: ClipRRect(
                      borderRadius: BorderRadius.all(Radius.circular(3)),
                      child: LinearProgressIndicator(minHeight: 3),
                    ),
                  ),
                if (error != null)
                  _TasksError(text: error, onRetry: live.loadTasks),
                // M4.31：电脑在等你选一项时，先在这里说一声，点进去直接答。
                if (!_pending.isEmpty) ...[
                  _PendingQuestionBanner(
                    pending: _pending,
                    onOpen: _openPendingQuestion,
                  ),
                  const SizedBox(height: 10),
                ],
                _buildFilterChips(),
                _buildWorkspaceChips(),
                const SizedBox(height: 10),
                // M4.13：按项目分组、可折叠——对齐电脑端侧边栏的「项目 → 会话」树。
                if (groups.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 48),
                    child: EmptyHint(
                      icon: Icons.inbox_outlined,
                      text: error != null ? '任务列表加载失败' : '这个筛选下还没有任务',
                    ),
                  )
                else
                  for (final group in groups) ...[                    _ProjectGroupCard(
                      group: group,
                      expanded: _expanded.contains(group.path),
                      onToggle: () => _toggleGroup(group.path),
                      onOpenWorkspace: () => _openWorkspace(group.path),
                      onOpenTask: _openTask,
                      onOpenArchived: _openArchived,
                    ),
                    const SizedBox(height: AppSpace.cardGap),
                  ],
              ],
            ),
          ),
        );
      },
    );
  }

  /// M4.13：把任务与会话按项目分组。
  ///
  /// 顺序沿用电脑端：先按工作区（组），组内按最后活动时间从新到旧。没有会话的
  /// 目录照样占一张卡（M4.11 的「别让整页看起来全没了」）。
  List<_ProjectGroup> get _groupRows {
    final tasks = live.usesDesktopTaskMirror
        ? sortDesktopTaskItems(live.tasks.where(_matches).toList(growable: false))
        : live.tasks.where(_matches).toList(growable: false);
    final archived = _hiddenArchived;
    final paths = <String>[];
    void push(String? path) {
      final value = (path ?? '').trim();
      if (value.isEmpty || paths.contains(value)) return;
      paths.add(value);
    }

    for (final root in live.workspaceRoots) {
      push(root);
    }
    for (final task in tasks) {
      push(task.workspace);
    }
    for (final session in archived) {
      push(session.workspace);
    }
    // 其他分组的会话已经挂在各自的路径上；这里只保留有东西可展示的组。
    final rows = <_ProjectGroup>[];
    for (final path in paths) {
      final group = _ProjectGroup(
        path: path,
        name: _workspaceName(path),
        tasks: tasks
            .where((task) => (task.workspace ?? '').trim() == path)
            .toList(growable: false),
        archived: archived
            .where((session) => session.workspace.trim() == path)
            .toList(growable: false),
      );
      if (group.isEmpty && _workspace != null && _workspace != path) continue;
      if (group.isEmpty && _filter != null && _filter != TaskStatus.completed) {
        continue;
      }
      rows.add(group);
    }
    // 有运行中会话的项目排最前，然后是有会话的，空目录垫底。
    rows.sort((a, b) {
      if (a.runningCount != b.runningCount) {
        return b.runningCount - a.runningCount;
      }
      if (a.isEmpty != b.isEmpty) return a.isEmpty ? 1 : -1;
      return b.lastTime.compareTo(a.lastTime);
    });
    return rows;
  }

  void _toggleGroup(String path) {
    setState(() {
      if (!_expanded.remove(path)) _expanded.add(path);
    });
  }

  /// M4.31：点提示条 → 进那条会话，问题卡片就在页面顶部。
  void _openPendingQuestion(DesktopPendingQuestion question) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DesktopSessionScreen(
          liveStore: live,
          sessionId: question.sessionId,
          title: question.title.isEmpty ? '电脑上的会话' : question.title,
        ),
      ),
    );
  }

  void _openTask(TaskItem task) {
    if (live.usesDesktopTaskMirror) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => DesktopSessionScreen(
            liveStore: live,
            sessionId: task.id,
            title: task.title,
            lastTime: task.lastTime,
          ),
        ),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LiveTaskDetailScreen(
          liveStore: live,
          taskId: task.id,
          initialTask: task,
        ),
      ),
    );
  }

  Widget _buildFilterChips() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final status in _filters) ...[
            _FilterChip(
              label: '${_filterLabel(status)} ${_countFor(status)}',
              selected: _filter == status,
              onTap: () => setState(() => _filter = status),
            ),
            if (status != _filters.last) const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  /// M3.5：按工作区筛——只列当前任务里出现过的工作区，名称取目录名。
  ///
  /// M4.0：胶囊右侧追加电脑端授权但还没有会话的目录，末尾是「新建工作区」。
  Widget _buildWorkspaceChips() {
    final paths = <String>[];
    for (final root in live.workspaceRoots) {
      final path = root.trim();
      if (path.isNotEmpty && !paths.contains(path)) paths.add(path);
    }
    for (final task in live.tasks) {
      final path = task.workspace?.trim() ?? '';
      if (path.isNotEmpty && !paths.contains(path)) paths.add(path);
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            if (paths.length >= 2) ...[
              _FilterChip(
                label: '全部工作区',
                selected: _workspace == null,
                onTap: () => setState(() => _workspace = null),
              ),
              const SizedBox(width: 8),
            ],
            for (final path in paths) ...[
              _FilterChip(
                label: _workspaceName(path),
                selected: _workspace == path,
                onTap: () => _openWorkspace(path),
              ),
              const SizedBox(width: 8),
            ],
            _NewWorkspaceChip(onTap: _createWorkspace),
          ],
        ),
      ),
    );
  }

  void _openWorkspace(String path) {
    setState(() => _workspace = path);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => WorkspaceScreen(
          liveStore: widget.liveStore,
          workspacePath: path,
          workspaceName: _workspaceName(path),
          onOpenAssistant: widget.onOpenAssistant,
        ),
      ),
    );
  }

  /// M4.0：在电脑端第一个授权根目录下新建工作区子目录，成功后直接进这个工作区。
  Future<void> _createWorkspace() async {
    final created = await showWorkspaceCreateDialog(context, liveStore: live);
    if (!mounted || created == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已在电脑上创建工作区：${created.path}')),
    );
    _openWorkspace(created.path);
  }

  String _workspaceName(String path) {
    final trimmed = path.replaceAll(RegExp(r'[\\/]+$'), '');
    final parts = trimmed.split(RegExp(r'[\\/]'));
    return parts.isEmpty ? trimmed : parts.last;
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.pill),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? palette.accent : palette.card,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: Border.all(color: selected ? palette.accent : palette.line),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? palette.onAccent : palette.text2,
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _NewWorkspaceChip extends StatelessWidget {
  const _NewWorkspaceChip({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.pill),
      child: Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: palette.accentSoft,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: Border.all(color: palette.line),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.add_rounded, size: 15, color: palette.accent),
            const SizedBox(width: 4),
            Text(
              '新建项目',
              style: TextStyle(
                color: palette.accent,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// M4.31：电脑上正等着手机选一项时的提示条。
///
/// 以前只有「手机停在那条会话的直播页」才接管提问，所以电脑上弹出「确认需求」
/// 时手机一无所知。现在只要 App 连着就由手机接管，这条提示负责在其他页面先说
/// 一声，点进去就是那张带选项的卡片。
class _PendingQuestionBanner extends StatelessWidget {
  const _PendingQuestionBanner({required this.pending, required this.onOpen});

  final DesktopPending pending;
  final void Function(DesktopPendingQuestion question) onOpen;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final first = pending.questions.first;
    final extra = pending.questions.length - 1;
    final headline = first.header.isEmpty ? '电脑在等你选一项' : first.header;
    final detail = first.question.isEmpty
        ? '点开可以在手机上直接回答'
        : first.question;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.card),
        onTap: () => onOpen(first),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          decoration: BoxDecoration(
            color: palette.accent.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(color: palette.accent.withValues(alpha: 0.28)),
          ),
          child: Row(
            children: [
              Icon(Icons.help_outline_rounded, size: 18, color: palette.accent),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            headline,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: palette.text,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (extra > 0)
                          Text(
                            '还有 $extra 个',
                            style: TextStyle(
                              color: palette.accent,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      detail,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.text2,
                        fontSize: 12.5,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Icon(Icons.chevron_right_rounded, size: 20, color: palette.text3),
            ],
          ),
        ),
      ),
    );
  }
}

/// M4.10：电脑端存档里的会话卡片（只读，点开进「已存档」直播）。
class _ArchivedCard extends StatelessWidget {
  const _ArchivedCard({required this.session, required this.onTap});

  final ArchivedSession session;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final workspace = session.workspace.trim();
    return Container(
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: palette.line),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.card),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      session.title.isEmpty ? '历史会话' : session.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
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
                ],
              ),
              if (workspace.isNotEmpty) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    Icon(Icons.folder_outlined, size: 14, color: palette.text3),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        workspace,
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
              const SizedBox(height: 4),
              Text(
                session.lastTime > 0
                    ? '最后活动 ${relativeTime(DateTime.fromMillisecondsSinceEpoch(session.lastTime))}'
                    : '电脑上已经没有这条会话',
                style: TextStyle(color: palette.text3, fontSize: 11.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// M4.13：一个项目分组——工作区目录 + 它下面的会话。
class _ProjectGroup {
  const _ProjectGroup({
    required this.path,
    required this.name,
    required this.tasks,
    required this.archived,
  });

  final String path;
  final String name;
  final List<TaskItem> tasks;
  final List<ArchivedSession> archived;

  bool get isEmpty => tasks.isEmpty && archived.isEmpty;

  int get runningCount =>
      tasks.where((task) => task.status == TaskStatus.running ||
          task.status == TaskStatus.waitingApproval).length;

  int get sessionCount => tasks.length + archived.length;

  /// 组内最新活动时间，用来排组间顺序和「最后活动」。
  int get lastTime {
    var latest = 0;
    for (final task in tasks) {
      final value = task.lastTime ?? task.updatedAt.millisecondsSinceEpoch;
      if (value > latest) latest = value;
    }
    for (final session in archived) {
      if (session.lastTime > latest) latest = session.lastTime;
    }
    return latest;
  }

  String get lastActiveLabel {
    if (lastTime <= 0) return '还没有会话';
    return '最后活动 ${relativeTime(DateTime.fromMillisecondsSinceEpoch(lastTime))}';
  }
}

/// M4.13：项目分组卡——对齐电脑端侧边栏的「项目 → 会话」。
///
/// 头部整行可点：折叠/展开；右侧箭头进工作区页（新建会话、看存档、浏览文件）。
/// 展开后按最后活动时间从新到旧列会话，跑着的在前。
class _ProjectGroupCard extends StatelessWidget {
  const _ProjectGroupCard({
    required this.group,
    required this.expanded,
    required this.onToggle,
    required this.onOpenWorkspace,
    required this.onOpenTask,
    required this.onOpenArchived,
  });

  final _ProjectGroup group;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback onOpenWorkspace;
  final ValueChanged<TaskItem> onOpenTask;
  final ValueChanged<ArchivedSession> onOpenArchived;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final items = <Widget>[];
    for (final task in group.tasks) {
      items.add(
        _SessionRow(
          title: task.title.isEmpty ? '未命名会话' : task.title,
          running: task.status == TaskStatus.running,
          waiting: task.status == TaskStatus.waitingApproval,
          archived: false,
          lastTime: task.lastTime ?? task.updatedAt.millisecondsSinceEpoch,
          onTap: () => onOpenTask(task),
        ),
      );
    }
    for (final session in group.archived) {
      items.add(
        _SessionRow(
          title: session.title.isEmpty ? '历史会话' : session.title,
          running: false,
          waiting: false,
          archived: true,
          lastTime: session.lastTime,
          onTap: () => onOpenArchived(session),
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: palette.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(AppRadius.card),
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
              child: Row(
                children: [
                  Icon(
                    expanded
                        ? Icons.folder_open_rounded
                        : Icons.folder_rounded,
                    size: 17,
                    color: palette.accent,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                group.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: palette.text,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            if (group.isEmpty) ...[
                              const SizedBox(width: 6),
                              _MiniPill(text: '空项目'),
                            ],
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          group.path,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: palette.text3,
                            fontSize: 11.5,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          [
                            if (group.sessionCount > 0)
                              '${group.sessionCount} 个会话',
                            if (group.runningCount > 0)
                              '${group.runningCount} 个进行中',
                            if (group.sessionCount == 0) '还没有会话',
                            if (group.sessionCount > 0) group.lastActiveLabel,
                          ].join(' · '),
                          style: TextStyle(
                            color: palette.text3,
                            fontSize: 11.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // M4.51：默认折叠后，这里要有个明确的「能点开」暗示。
                  if (items.isNotEmpty)
                    AnimatedRotation(
                      turns: expanded ? 0.5 : 0,
                      duration: const Duration(milliseconds: 150),
                      child: Icon(
                        Icons.expand_more_rounded,
                        size: 20,
                        color: palette.text3,
                      ),
                    ),
                  IconButton(
                    tooltip: '打开工作区',
                    visualDensity: VisualDensity.compact,
                    onPressed: onOpenWorkspace,
                    icon: Icon(
                      Icons.chevron_right_rounded,
                      size: 20,
                      color: palette.text3,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (expanded && items.isNotEmpty) ...[
            Divider(height: 1, color: palette.lineSoft),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
              child: Column(children: items),
            ),
          ],
        ],
      ),
    );
  }
}

class _MiniPill extends StatelessWidget {
  const _MiniPill({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: palette.lineSoft,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: palette.text2,
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 项目卡里的一行会话（比外面的卡片轻，靠左侧竖线挂在项目下）。
class _SessionRow extends StatelessWidget {
  const _SessionRow({
    required this.title,
    required this.running,
    required this.waiting,
    required this.archived,
    required this.lastTime,
    required this.onTap,
  });

  final String title;
  final bool running;
  final bool waiting;
  final bool archived;
  final int lastTime;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final String trailing;
    if (waiting) {
      trailing = '等待授权';
    } else if (running) {
      trailing = '直播中';
    } else if (archived) {
      trailing = '已存档';
    } else if (lastTime > 0) {
      trailing = relativeTime(DateTime.fromMillisecondsSinceEpoch(lastTime));
    } else {
      trailing = '已完成';
    }
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.code),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 9, 6, 9),
        child: Row(
          children: [
            Container(
              width: 3,
              height: 16,
              decoration: BoxDecoration(
                color: waiting
                    ? palette.danger
                    : running
                        ? palette.accent
                        : palette.line,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: palette.text, fontSize: 13),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              trailing,
              style: TextStyle(
                color: waiting
                    ? palette.danger
                    : running
                        ? palette.accent
                        : palette.text3,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TasksError extends StatelessWidget {
  const _TasksError({required this.text, required this.onRetry});
  final String text;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
      decoration: BoxDecoration(
        color: palette.dangerSoft,
        borderRadius: BorderRadius.circular(AppRadius.code),
      ),
      child: Row(
        children: [
          Icon(Icons.cloud_off_rounded, size: 16, color: palette.danger),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: palette.danger,
                fontSize: 11.5,
                height: 1.4,
              ),
            ),
          ),
          TextButton(
            onPressed: onRetry,
            style: TextButton.styleFrom(
              foregroundColor: palette.danger,
              minimumSize: const Size(0, 30),
            ),
            child: const Text('重试', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

class _TaskCard extends StatelessWidget {
  const _TaskCard({required this.task, required this.onTap});

  final TaskItem task;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final active = task.status == TaskStatus.running ||
        task.status == TaskStatus.waitingApproval;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: Container(
        padding: const EdgeInsets.all(AppSpace.card),
        decoration: BoxDecoration(
          color: palette.card,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: palette.line),
          boxShadow: palette.cardShadow,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    task.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: palette.text,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      height: 1.4,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                TaskStatusBadge(status: task.status),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.folder_outlined, size: 13, color: palette.text3),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    task.workspace,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: palette.text3,
                      fontSize: 10.5,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                // M3.6：桌面镜像额外展示消息条数与最后活动时间。
                if (task.messageCount > 0)
                  Text(
                    '${task.messageCount} 条消息',
                    style: TextStyle(color: palette.text3, fontSize: 10.5),
                  ),
                if (task.messageCount > 0) ...[
                  const SizedBox(width: 6),
                  Text(
                    '·',
                    style: TextStyle(color: palette.text3, fontSize: 10.5),
                  ),
                  const SizedBox(width: 6),
                ],
                Text(
                  formatLastTime(task.lastTime).isNotEmpty
                      ? formatLastTime(task.lastTime)
                      : relativeTime(task.updatedAt),
                  style: TextStyle(color: palette.text3, fontSize: 10.5),
                ),
              ],
            ),
            if (active) ...[
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(99),
                child: task.status == TaskStatus.waitingApproval
                    ? LinearProgressIndicator(
                        minHeight: 5,
                        backgroundColor: palette.lineSoft,
                        valueColor:
                            AlwaysStoppedAnimation<Color>(palette.warn),
                      )
                    : LinearProgressIndicator(
                        value: task.progress,
                        minHeight: 5,
                        backgroundColor: palette.lineSoft,
                        valueColor:
                            AlwaysStoppedAnimation<Color>(palette.accent),
                      ),
              ),
              const SizedBox(height: 7),
              Text(
                task.status == TaskStatus.waitingApproval
                    ? '需要你确认一条高风险命令'
                    : '正在执行 · ${(task.progress * 100).round()}%',
                style: TextStyle(
                  color: task.status == TaskStatus.waitingApproval
                      ? palette.warn
                      : palette.text2,
                  fontSize: 11.5,
                ),
              ),
            ],
            if (task.result != null && task.result!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                task.result!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: palette.text2,
                  fontSize: 11.8,
                  height: 1.45,
                ),
              ),
            ],
            if (task.errorCode != null && task.errorCode!.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                task.errorCode!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: palette.danger, fontSize: 11),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 任务详情：真实模式下从 `GET /api/v1/tasks/{id}` 拉取并渲染事件时间线。
class LiveTaskDetailScreen extends StatefulWidget {
  const LiveTaskDetailScreen({
    super.key,
    required this.liveStore,
    required this.taskId,
    this.initialTask,
  });

  final LiveStore liveStore;
  final String taskId;
  final TaskItem? initialTask;

  @override
  State<LiveTaskDetailScreen> createState() => _LiveTaskDetailScreenState();
}

class _LiveTaskDetailScreenState extends State<LiveTaskDetailScreen> {
  @override
  void initState() {
    super.initState();
    widget.liveStore.addListener(_onChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.liveStore.loadTaskDetail(widget.taskId);
    });
  }

  @override
  void dispose() {
    widget.liveStore.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.liveStore,
      builder: (context, _) {
        final live = widget.liveStore;
        final selected = live.selectedTask;
        final task = selected != null && selected.taskId == widget.taskId
            ? selected.toTaskItem()
            : widget.initialTask;
        final loading = live.taskDetailLoading;
        final error = live.taskDetailError;
        return Scaffold(
          appBar: AppBar(
            titleSpacing: 0,
            title: Text(
              '任务详情',
              style: TextStyle(
                color: context.appPalette.text,
                fontSize: 22,
                fontWeight: FontWeight.w700,
              ),
            ),
            actions: [
              IconButton(
                tooltip: '刷新',
                onPressed: loading
                    ? null
                    : () => live.loadTaskDetail(widget.taskId),
                icon: const Icon(Icons.refresh_rounded, size: 20),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpace.page,
              4,
              AppSpace.page,
              28,
            ),
            children: [
              if (error != null)
                _TasksError(
                  text: error,
                  onRetry: () => live.loadTaskDetail(widget.taskId),
                ),
              if (task == null)
                Padding(
                  padding: const EdgeInsets.only(top: 48),
                  child: loading
                      ? const Center(
                          child: CircularProgressIndicator(strokeWidth: 2.4),
                        )
                      : const EmptyHint(
                          icon: Icons.timeline_rounded,
                          text: '没有找到这个任务',
                        ),
                )
              else ...[
                _TaskSummaryPanel(task: task),
                const SectionTitle('执行时间线'),
                if (task.events.isEmpty)
                  EmptyHint(
                    icon: Icons.timeline_rounded,
                    text: loading ? '正在加载事件…' : '任务还没有事件记录',
                  )
                else
                  for (var i = 0; i < task.events.length; i++)
                    TaskTimelineTile(
                      event: task.events[i],
                      isLast: i == task.events.length - 1,
                    ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _TaskSummaryPanel extends StatelessWidget {
  const _TaskSummaryPanel({required this.task});

  final TaskItem task;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            task.title,
            style: TextStyle(
              color: palette.text,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              TaskStatusBadge(status: task.status),
              const SizedBox(width: 8),
              Text(
                relativeTime(task.updatedAt),
                style: TextStyle(color: palette.text3, fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 10),
          InfoRow('工作区', task.workspace),
          InfoRow('会话', task.conversationId ?? '—'),
          if (task.errorCode != null && task.errorCode!.isNotEmpty)
            InfoRow('错误码', task.errorCode!, valueColor: palette.danger),
          if (task.result != null && task.result!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              task.result!,
              style: TextStyle(
                color: palette.text2,
                fontSize: 12,
                height: 1.5,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
