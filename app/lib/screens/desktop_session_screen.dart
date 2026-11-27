import 'dart:async';
import 'dart:io' show File;

import 'package:file_picker/file_picker.dart' as fp;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../data/live_store.dart';
import '../models.dart';
import '../services/chat_filter.dart';
import '../services/history_api.dart';
import '../services/desktop_sort.dart';
import '../services/message_text.dart';
import '../services/pairing_api.dart';
import '../services/poll_backoff.dart';
import '../theme/app_theme.dart';
import '../widgets/chat_items.dart';
import '../widgets/common.dart';

/// M2.9.3/2.9.4：桌面会话直播页。
///
/// 电脑上跑的会话不经过 relay agent，但 Host 的事件日志是完整的；
/// 这里按 seq 增量拉取，助手输出、工具调用与命令、轮次结束都会实时出现在手机上，
/// 像看直播一样「看着电脑在干活」。M2.9.4 起手机还能补一句话、应答授权。
/// M4.14：正文为空时该说什么。
///
/// 两种空完全不是一回事：一屏里连事件都没有，是这个会话确实没内容；
/// 有事件但全是工具调用，是拉取窗口只够到工具记录 —— 让人点「过程」而不是干等。
String liveEmptyHint({required bool hasEvents}) =>
    hasEvents ? '这一屏只有工具调用，点上面那条看完整记录' : '这个会话还没有可展示的内容';

/// M4.17：官方 App 顶部写的是「本机 · <目录名>」，不是一长串绝对路径。
/// 目录名取不到就返回空串，调用方退化成「本机」。
String desktopFolderName(String cwd) {
  final trimmed = cwd.trim();
  if (trimmed.isEmpty) return '';
  final parts = trimmed
      .split(RegExp(r'[\\/]'))
      .where((part) => part.isNotEmpty)
      .toList();
  return parts.isEmpty ? '' : parts.last;
}

class DesktopSessionOption {
  const DesktopSessionOption({required this.id, required this.title});

  final String id;
  final String title;
}

class DesktopSessionScreen extends StatefulWidget {
  const DesktopSessionScreen({
    super.key,
    required this.liveStore,
    required this.sessionId,
    this.title = '桌面会话',
    this.sessions = const <DesktopSessionOption>[],
    this.lastTime,
    this.archived = false,
  });

  final LiveStore liveStore;
  final String sessionId;
  final String title;
  final List<DesktopSessionOption> sessions;

  /// M4.3：任务行的最后活动时刻（毫秒）。旧插件不下发事件时间时，
  /// 「已运行」用它兜底，避免某些情况下从 0:00 开始。
  final int? lastTime;

  /// M4.10：这是电脑端存档里的会话（电脑列表里已经看不到），只能看不能发指令。
  final bool archived;

  @override
  State<DesktopSessionScreen> createState() => _DesktopSessionScreenState();
}

class _DesktopSessionScreenState extends State<DesktopSessionScreen>
    with WidgetsBindingObserver {
  final List<DesktopSessionEvent> _events = <DesktopSessionEvent>[];
  final List<DesktopApproval> _approvals = <DesktopApproval>[];

  /// M4.23：电脑端正等手机回答的问题（「确认需求」卡片）。
  final List<DesktopQuestion> _questions = <DesktopQuestion>[];
  bool _questionBusy = false;
  final ScrollController _scroll = ScrollController();
  /// M4.16：列表 reverse 后「在最新」= 滚动位置接近 0；底部状态条据此说真话。
  bool _atLatest = true;
  final TextEditingController _composer = TextEditingController();
  Timer? _poll;
  int _lastSeq = 0;
  bool _loading = true;
  bool _running = false;

  /// M4.38：一次只允许有一个在途请求。
  ///
  /// 以前 `Timer.periodic` 到点就发，不看上一个是否还挂着；首屏一次一百多 KB，
  /// 超时 10 秒时后面已经排了六七个，彼此抢同一条隧道 —— 越刷越慢。
  bool _inFlight = false;

  /// M4.38：连续失败次数，用来决定下一次重试等多久（见 `poll_backoff.dart`）。
  int _pollFailures = 0;
  DateTime? _runStart;

  /// M4.3：旧插件不下发事件时间（`turn-start` 的 time=0）时的兜底起点。
  DateTime? get _sessionUpdatedAt =>
      (widget.lastTime != null && widget.lastTime! > 0)
          ? DateTime.fromMillisecondsSinceEpoch(widget.lastTime!)
          : null;
  Timer? _ticker;
  bool _sending = false;
  bool _uploading = false;
  /// M4.19：存档页发过话之后，这条会话就被电脑唤醒成「活着」的了——从此按直播
  /// 轮询，而不是继续按静态快照渲染（否则回复永远不出现）。
  bool _revived = false;
  bool get _isArchived => widget.archived && !_revived;
  /// M4.21：电脑端那排「N 条排队消息」——队列快照、是否展开、是否有操作在飞。
  DesktopQueue _queue = const DesktopQueue();
  bool _queueOpen = false;
  bool _queueBusy = false;
  final List<_PendingAttachment> _attachments = <_PendingAttachment>[];
  String _title = '';
  String _cwd = '';
  String? _error;

  Future<void> _pickSession() async {
    final picked = await showModalBottomSheet<DesktopSessionOption>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final option in widget.sessions)
              ListTile(
                title: Text(option.title),
                selected: option.id == widget.sessionId,
                onTap: () => Navigator.of(sheetContext).pop(option),
              ),
          ],
        ),
      ),
    );
    if (picked == null || picked.id == widget.sessionId || !mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => DesktopSessionScreen(
          liveStore: widget.liveStore,
          sessionId: picked.id,
          title: picked.title,
          sessions: widget.sessions,
        ),
      ),
    );
  }
  @override
  void initState() {
    super.initState();
    // M3.6：回到前台时整段重拉，避免手机锁屏期间错过事件。
    WidgetsBinding.instance.addObserver(this);
    _title = widget.title;
    _scroll.addListener(_onScroll);
    _load(initial: true);
    // M4.10：存档会话是静态快照，不需要轮询；M4.19 里发过话之后会切成直播。
    // M4.38：不再 `Timer.periodic` 盲目打点，改成「上一次回来之后再排下一次」，
    // 并且失败会退避 —— 详见 _schedulePoll 与 services/poll_backoff.dart。
    if (!_isArchived) _schedulePoll();
  }

  /// M4.38：排下一次轮询。
  ///
  /// 注意不要在这里立刻补一次拉取：`initState` 已经直接 `_load(initial: true)`
  /// 了，再补一个 0 秒定时器就会在失败时立刻重试一次，退避白做。
  void _schedulePoll() {
    _poll?.cancel();
    _poll = Timer(desktopPollDelay(_pollFailures), () async {
      await _load();
      if (!mounted) return;
      _schedulePoll();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _ticker?.cancel();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _composer.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      _load(initial: true);
    }
  }

  String _elapsedLabel() {
    final start = _runStart;
    if (start == null) return '0:00';
    // M4.3：起点来自会话日志里最新一条 turn-start（电脑上的真实开始时刻），
    // 不是「手机打开页面」的时刻；超过 1 小时显示 H:MM:SS。
    return formatElapsed(DateTime.now().difference(start));
  }

  Future<void> _load({bool initial = false}) async {
    // M4.38：在途就不发新的。宁可等这一次回来，也不要让六七个请求排队抢
    // 同一条隧道（那正是「经常连接超时」的放大器）。
    if (_inFlight) return;
    _inFlight = true;
    try {
      // M4.10：存档会话走存档接口，不会被电脑的 404 影响。
      // M4.19：一旦发过话（_revived），改回直播接口——电脑那边已经把它唤醒了。
      final feed = _isArchived
          ? await widget.liveStore.fetchArchivedSession(widget.sessionId)
          : await widget.liveStore.fetchDesktopSession(
              widget.sessionId,
              afterSeq: initial ? null : _lastSeq,
            );
      if (!mounted) return;
      setState(() {
        _title = feed.title;
        _cwd = feed.cwd;
        if (initial) {
          _events
            ..clear()
            ..addAll(feed.events);
          _lastSeq = feed.lastSeq;
          _loading = false;
        } else {
          final known = _events.isEmpty ? 0 : _events.last.seq;
          for (final event in feed.events) {
            if (event.seq > known) _events.add(event);
          }
          if (feed.lastSeq > _lastSeq) _lastSeq = feed.lastSeq;
          if (feed.lastSeq == 0) _loading = false;
        }
        // M4.3：起点跟着日志里最新一条 turn-start 走，和电脑端「已运行」一致；
        // 不再每次打开页面从 0:00 开始数。
        _runStart = feed.running
            ? resolveRunStart(
                events: _events,
                lastTime: widget.lastTime,
                updatedAt: _sessionUpdatedAt,
              )
            : null;
        if (feed.running) {
          _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) {
            if (mounted) setState(() {});
          });
        } else {
          _runStart = null;
          _ticker?.cancel();
          _ticker = null;
        }
        _running = feed.running;
        _approvals
          ..clear()
          ..addAll(feed.approvals);
        _questions
          ..clear()
          ..addAll(feed.questions);
        _error = null;
      });
      if (initial || feed.events.isNotEmpty) _scrollToEnd(force: initial);
      // M4.21：顺便把排队消息也跟上。单独 try，队列读不到不该把整页标成错误。
      if (!_isArchived) await _loadQueue();
      // M4.38：成功一次就把退避清零，下一次轮询回到 1.5 秒。
      _pollFailures = 0;
    } catch (e) {
      // M4.38：失败累计，下一次重试会等更久（3s → 6s → 12s → 24s → 30s 封顶），
      // 免得网络恢复之前每 1.5 秒又堵一个超时请求上去。
      _pollFailures += 1;
      // M4.38：立刻按新的退避重排下一次。不这么做的话，`_schedulePoll` 在开始时
      // 就已经按 1.5 秒上好了定时器，首次失败后仍会在 1.5 秒又撞一次。
      if (mounted && !_isArchived) _schedulePoll();
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is PairingApiException
            ? e.message
            : '读取桌面会话失败：$e';
      });
    } finally {
      _inFlight = false;
    }
  }

  // ---- M4.21：排队消息 ----
  //
  // 电脑端聊天页在「正在跑的这一轮」下面会列出一条「N 条排队消息」，每条能编辑、
  // 删除、上移（=插话送进这一轮）。手机上以前完全没有这个概念：发出去的话要么进
  // 队列看不到，要么得等这一轮结束。这里把队列原样搬过来。

  Future<void> _loadQueue() async {
    if (_isArchived) return;
    try {
      final queue = await widget.liveStore.fetchDesktopQueue(widget.sessionId);
      if (!mounted) return;
      // 队列空了就把展开态收回去，免得留一块空面板占地方。
      setState(() {
        _queue = queue;
        if (queue.items.isEmpty) _queueOpen = false;
      });
    } catch (_) {
      // 老电脑端没有这条接口：静默忽略，不打扰正在看对话的人。
    }
  }

  Future<void> _applyQueueAction(
    DesktopQueueItem item,
    String action, {
    String? text,
  }) async {
    if (_queueBusy) return;
    setState(() => _queueBusy = true);
    try {
      final queue = await widget.liveStore.updateDesktopQueue(
        widget.sessionId,
        item.id,
        action: action,
        text: text,
      );
      if (!mounted) return;
      setState(() {
        _queue = queue;
        _queueBusy = false;
        if (queue.items.isEmpty) _queueOpen = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _queueBusy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            e is PairingApiException ? e.message : '改排队消息失败：$e',
          ),
        ),
      );
    }
  }

  Future<void> _editQueueItem(DesktopQueueItem item) async {
    final controller = TextEditingController(text: item.text);
    final changed = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('修改排队消息'),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 2,
          maxLines: 6,
          decoration: const InputDecoration(
            hintText: '改完之后电脑会用这句',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (changed == null || changed.isEmpty) return;
    await _applyQueueAction(item, 'edit', text: changed);
  }

  /// 全部插话：电脑端是 Cmd/Ctrl+Enter，手机上一个按钮挨个送进去。
  Future<void> _steerAllQueue() async {
    if (_queueBusy) return;
    final pending =
        _queue.items.where((item) => item.pending).toList(growable: false);
    if (pending.isEmpty) return;
    for (final item in pending) {
      await _applyQueueAction(item, 'steer');
      if (!mounted) return;
    }
  }

  /// 从相册挑照片（可多选）。
  Future<void> _pickPhotos() async {
    try {
      final picked = await ImagePicker().pickMultiImage(maxWidth: 2400);
      if (!mounted || picked.isEmpty) return;
      final added = <_PendingAttachment>[];
      for (final file in picked) {
        added.add(_PendingAttachment(
          name: file.name,
          bytes: await File(file.path).readAsBytes(),
        ));
      }
      if (!mounted) return;
      setState(() => _attachments.addAll(added));
    } catch (error) {
      _toast('选照片失败：$error', error: true);
    }
  }

  /// 从相机拍一张。
  Future<void> _pickCamera() async {
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.camera,
        maxWidth: 2400,
      );
      if (!mounted || picked == null) return;
      final bytes = await File(picked.path).readAsBytes();
      if (!mounted) return;
      setState(() => _attachments.add(_PendingAttachment(
            name: picked.name,
            bytes: bytes,
          )));
    } catch (error) {
      _toast('拍照失败：$error', error: true);
    }
  }

  /// 挑任意文件（可多选）。
  Future<void> _pickFiles() async {
    try {
      final result = await fp.FilePicker.platform.pickFiles(
        allowMultiple: true,
        withData: true,
      );
      if (!mounted || result == null || result.files.isEmpty) return;
      final added = <_PendingAttachment>[];
      for (final file in result.files) {
        final bytes = file.bytes ??
            (file.path == null ? null : await File(file.path!).readAsBytes());
        if (bytes == null) continue;
        added.add(_PendingAttachment(name: file.name, bytes: bytes));
      }
      if (!mounted) return;
      setState(() => _attachments.addAll(added));
    } catch (error) {
      _toast('选文件失败：$error', error: true);
    }
  }

  Future<void> _send() async {
    final text = _composer.text.trim();
    if ((text.isEmpty && _attachments.isEmpty) || _sending) return;
    if (_attachments.isNotEmpty && !widget.liveStore.isConnected) {
      _toast('附件要先连上电脑才能发过去', error: true);
      return;
    }
    setState(() => _sending = true);
    try {
      var body = text;
      if (_attachments.isNotEmpty) {
        setState(() => _uploading = true);
        final lines = <String>[];
        for (final attachment in _attachments) {
          final uploaded = await widget.liveStore.uploadDesktopFile(
            name: attachment.name,
            bytes: attachment.bytes,
          );
          lines.add('- ${uploaded.path}');
        }
        final list = lines.join('\n');
        body = body.isEmpty
            ? '我发了一些附件，请看一下：\n附件（已保存到电脑）：\n$list'
            : '$body\n\n附件（已保存到电脑）：\n$list';
      }
      final sent = await widget.liveStore.sendDesktopPrompt(widget.sessionId, body);
      if (!mounted) return;
      _composer.clear();
      final revived = _isArchived;
      // M4.24：存档会话是在**同一条会话**里继续的（插件先用
      // workspaceController.unarchiveSession 抬起 ArchivedSessionGate，再往原
      // sessionId 发话），所以这里不用跳转，把页面切成直播轮询就行。
      // `forked` 是 M4.19 的旧电脑行为，留着兼容。
      final movedTo = sent.forked && sent.sessionId != widget.sessionId
          ? sent.sessionId
          : null;
      setState(() {
        _attachments.clear();
        _uploading = false;
        if (revived && movedTo == null) _revived = true;
      });
      if (movedTo != null) {
        await Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(
            builder: (_) => DesktopSessionScreen(
              liveStore: widget.liveStore,
              sessionId: movedTo,
              title: _title.isEmpty ? widget.title : _title,
              sessions: widget.sessions,
            ),
          ),
        );
        return;
      }
      if (revived) {
        await _load(initial: true);
        // M4.38：接回直播之后走同一条带退避的调度，不要再另起一个 periodic
        // （否则同一个页面会有两条轮询链，等于自己给自己加倍）。
        _schedulePoll();
      } else {
        await _load();
      }
      if (mounted) _toast(revived ? '已把这条会话接回原对话' : '已发送到电脑');
    } catch (e) {
      if (mounted) {
        setState(() => _uploading = false);
        _toast(e is PairingApiException ? e.message : '发送失败：$e', error: true);
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _decide(DesktopApproval approval, {required bool approve}) async {
    try {
      await widget.liveStore.decideDesktopApproval(
        widget.sessionId,
        approval.approvalId,
        approve: approve,
      );
      if (!mounted) return;
      setState(() {
        _approvals.removeWhere((item) => item.approvalId == approval.approvalId);
      });
      _toast(approve ? '已允许这次操作' : '已拒绝这次操作');
      await _load();
    } catch (e) {
      if (mounted) {
        _toast(e is PairingApiException ? e.message : '应答失败：$e', error: true);
      }
    }
  }

  /// M4.23：把手机上的答案发回电脑。
  ///
  /// 授权（`approval/request`）和提问（`user-questions/request`）是两条不同的通道，
  /// 以前只接了前者，所以电脑上弹「确认需求」时手机上什么都没有。
  Future<void> _answerQuestion(
    DesktopQuestion question,
    List<DesktopQuestionAnswer> answers,
  ) async {
    if (_questionBusy) return;
    setState(() => _questionBusy = true);
    try {
      await widget.liveStore.answerDesktopQuestion(
        widget.sessionId,
        question.questionId,
        answers: answers,
      );
      if (!mounted) return;
      setState(() {
        _questions.removeWhere((item) => item.questionId == question.questionId);
      });
      _toast(answers.isEmpty ? '已跳过这个问题' : '已把答案发回电脑');
      await _load();
    } catch (e) {
      if (mounted) {
        _toast(e is PairingApiException ? e.message : '回答失败：$e', error: true);
      }
    } finally {
      if (mounted) setState(() => _questionBusy = false);
    }
  }

  void _toast(String message, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: error ? context.appPalette.danger : null,
      ),
    );
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final atLatest = _scroll.position.pixels < 160;
    if (atLatest == _atLatest) return;
    setState(() => _atLatest = atLatest);
  }

  void _scrollToEnd({bool force = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final position = _scroll.position;
      // M4.16：列表改成 reverse，最新一条在 offset 0。以前 jumpTo(maxScrollExtent)
      // 在长列表里只能跳到「已构建的那一屏」，于是点进去停在中段（截图里 agent 的
      // turn 3 出现在第 30 条），用户以为内容不是最新的。
      if (!force) {
        final nearBottom = position.pixels < 160;
        if (!nearBottom && _events.length > 6) return;
      }
      if (force) {
        _scroll.jumpTo(0);
        return;
      }
      _scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOut,
      );
    });
  }

  /// 过程事件（工具调用/结果、轮次标记）：默认折叠，点开才看。
  List<DesktopSessionEvent> get _processEvents => [
        for (final event in _events)
          if (event.kind == 'tool-call' ||
              event.kind == 'tool-result' ||
              event.kind == 'turn-start' ||
              event.kind == 'turn-end')
            event,
      ];

  int get _toolCallCount =>
      _processEvents.where((event) => event.kind == 'tool-call').length;

  void _openProcessSheet() {
    final palette = context.appPalette;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: palette.card,
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(AppRadius.sheetTop)),
      ),
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.92,
        minChildSize: 0.4,
        builder: (context, controller) => Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: palette.line,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
              child: Row(
                children: [
                  Text(
                    '执行过程',
                    style: TextStyle(
                      color: palette.text,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${_processEvents.length} 条',
                    style: TextStyle(color: palette.text3, fontSize: 12),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                controller: controller,
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                itemCount: _processEvents.length,
                itemBuilder: (context, index) =>
                    _EventRow(event: _processEvents[index]),
              ),
            ),
          ],
        ),
      ),
    );
  }


    /// 只留对话内容：用户与助手的话；工具调用、结果、轮次标记都算过程，默认折叠。
  /// 同一轮里助手会边想边写多段，手机只看最后那段结论，中间的推理不进正文。
  List<DesktopSessionEvent> get _messages {
    final out = <DesktopSessionEvent>[];
    int? lastAssistant;
    for (final event in _events) {
      if (event.kind == 'user') {
        // M4.16：Host 每轮注入的运行时上下文/提醒不是人说的话，不能变成用户气泡。
        if (looksInjectedUserText(event.text)) {
          lastAssistant = null;
          continue;
        }
        // 附件路径只是给电脑上的模型看的，手机里显示成「发了 N 个附件」。
        final parsed = parseUserText(event.text);
        final display = parsed.body.isNotEmpty
            ? parsed.body
            : (parsed.hasAttachments ? '发了 ${parsed.attachments.length} 个附件' : '');
        if (display.isNotEmpty) out.add(event.withText(display));
        lastAssistant = null;
      } else if (event.kind == 'assistant') {
        // 代码块整段替换成占位，手机上看结论就好；插件侧也会做同样的过滤。
        final text = event.text
            .replaceAll(RegExp(r'```[\s\S]*?```'), '〔代码已省略〕')
            .replaceAll(RegExp(r'\n{3,}'), '\n\n')
            .trim();
        if (text.isEmpty) continue;
        if (lastAssistant != null) {
          out[lastAssistant] = event.withText(text);
        } else {
          out.add(event.withText(text));
          lastAssistant = out.length - 1;
        }
      } else if (event.kind == 'turn-end') {
        lastAssistant = null;
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final messages = _messages;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '桌面直播',
              style: TextStyle(
                color: palette.text,
                fontSize: 22,
                fontWeight: FontWeight.w700,
              ),
            ),
            // M4.10：存档会话只读，标题旁给个标记，避免误以为还在跑。
            // M4.19：发过话之后它已经被唤醒成直播，标记随之消失。
            if (_isArchived) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: palette.lineSoft,
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                ),
                child: Text(
                  '已存档',
                  style: TextStyle(
                    color: palette.text2,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
            // M4.14：有授权在等手机应答时，标题栏常驻一个红点计数——
            // 授权卡在列表上方，正文滚下去以后就看不见了。
            // M4.23：等待回答的问题同样计数（它也会拦住电脑上的这一轮）。
            if (_approvals.length + _questions.length > 0) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: palette.danger.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                ),
                child: Text(
                  _questions.isEmpty
                      ? '待应答 ${_approvals.length}'
                      : '待回答 ${_questions.length}',
                  style: TextStyle(
                    color: palette.danger,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ],
        ),
        actions: [
          if (widget.sessions.length > 1)
            IconButton(
              tooltip: '切换会话',
              icon: const Icon(Icons.swap_horiz_rounded),
              onPressed: _pickSession,
            ),
          IconButton(
            tooltip: '刷新',
            onPressed: () => _load(initial: true),
            icon: const Icon(Icons.refresh_rounded, size: 20),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, limits) {
          // M4.40 审计：只有在「真的放不下」时才给上下两块封顶——正常手机
          // 竖屏（body 高度 >= 520）内容本来就放得下，封顶反而会把提问卡的
          // 提交按钮挤到可视区外（M4.36 的老毛病）。封顶按 body 真正有多高
          // 算，不按整屏算（AppBar 在大字号下也会变高）。
          final cramped = limits.maxHeight < 520;
          final maxTop = cramped ? limits.maxHeight * 0.45 : double.infinity;
          final maxBottom = cramped ? limits.maxHeight * 0.45 : double.infinity;
          return Column(
        children: [
          // M4.40 审计：320x480 + 系统字号 2.0 时，头部 + 提问卡 + 过程条加起来
          // 超过一屏，这里以前直接 overflow（渲染成黄黑条）。现在这一块自己
          // 封顶到半屏、超出就在里面滚，中间的消息列表永远还剩一点高度。
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: maxTop,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
          _LiveHeader(
            title: _title,
            cwd: _cwd,
            running: _running,
            count: messages.length,
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpace.page, 0, AppSpace.page, 8),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: palette.danger.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(AppRadius.code),
                ),
                child: Text(
                  _error!,
                  style: TextStyle(color: palette.danger, fontSize: 12, height: 1.5),
                ),
              ),
            ),
          // M4.35：提问卡可能很长（一个问题三四个选项），以前它和授权卡一起钉在
          // 对话列表上方、自己不滚，结果把列表挤成 0 高，整页看起来「划不动」。
          // 现在给这块固定一个最大高度，卡片自己在里面滚。
          if (_approvals.isNotEmpty || _questions.isNotEmpty)
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.55,
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(AppSpace.page, 0, AppSpace.page, 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final approval in _approvals)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _ApprovalCard(
                          approval: approval,
                          onApprove: () => _decide(approval, approve: true),
                          onReject: () => _decide(approval, approve: false),
                        ),
                      ),
                    // M4.23：电脑端弹「确认需求」时，手机上也出现同一张卡。
                    // M4.35.1：卡片拿到的是有界高度，选项区在里面滚，
                    // 「提交/跳过」始终钉在卡片底部（否则按钮会被顶出屏幕）。
                    for (final question in _questions)
                      Flexible(
                        fit: FlexFit.loose,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _QuestionCard(
                            question: question,
                            busy: _questionBusy,
                            onSubmit: (answers) => _answerQuestion(question, answers),
                            onSkip: () => _answerQuestion(
                              question,
                              const <DesktopQuestionAnswer>[],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          if (_processEvents.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpace.page, 0, AppSpace.page, 8),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: _openProcessSheet,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  decoration: BoxDecoration(
                    color: palette.lineSoft,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      // M4.17：对齐官方 App 的「已完成 · N 次工具调用」——不是
                      // 「过程 N 步」这种只有我们自己看得懂的写法。
                      Icon(
                        _running
                            ? Icons.autorenew_rounded
                            : Icons.check_circle_outline_rounded,
                        size: 15,
                        color: _running ? palette.accent : palette.text2,
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          '${_running ? '进行中' : '已完成'} · ${_toolCallCount} 次工具调用',
                          style: TextStyle(
                            color: palette.text2,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      Icon(Icons.expand_more_rounded,
                          size: 18, color: palette.text3),
                    ],
                  ),
                ),
              ),
            ),
                ],
              ),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2.4))
                : messages.isEmpty
                    // M4.14：把「真的没东西」和「这一屏只有工具调用、对话在更早处」
                    // 分开说。以前两种情况都显示「还没有可展示的内容」，用户以为
                    // 对话加载失败，其实是窗口没够到正文。
                    ? EmptyHint(
                        icon: Icons.podcasts_rounded,
                        text: liveEmptyHint(hasEvents: _events.isNotEmpty),
                      )
                    : ListView.builder(
                        controller: _scroll,
                        // M4.16：reverse 让「最新一条」天然在底部，一进来就是最新，
                        // 不依赖 jumpTo 猜真实高度（长列表里那一步永远猜不准）。
                        reverse: true,
                        padding: const EdgeInsets.fromLTRB(
                          AppSpace.page,
                          8,
                          AppSpace.page,
                          8,
                        ),
                        itemCount: messages.length,
                        itemBuilder: (context, index) {
                          final event =
                              messages[messages.length - 1 - index];
                          // M4.17：助手回复就是正文（Markdown 排版 + 底部动作行），
                          // 不再套一层卡片 —— 官方 App 里回复从不装在框里。
                          return _EventRow(event: event);
                        },
                      ),
          ),
          // M4.40 审计：小屏 + 2.0 字号时，运行中那一行 + 底部状态 + 输入框
          // 也能把这一列顶破（实测溢出 242px）。底部这块同样封顶并允许滚动。
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: maxBottom,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
          if (_running)
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpace.page, 0, AppSpace.page, 8),
              child: Row(
                children: [
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  // M4.40：字号拉满时这行会撑出屏幕，改成可换行、可省略。
                  Expanded(
                    child: Text(
                      '深度求索中…  已运行 ${_elapsedLabel()}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: context.appPalette.text2,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (_queue.items.isNotEmpty)
            _QueuePanel(
              queue: _queue,
              open: _queueOpen,
              busy: _queueBusy,
              onToggle: () => setState(() => _queueOpen = !_queueOpen),
              onEdit: _editQueueItem,
              onRemove: (item) => _applyQueueAction(item, 'remove'),
              onSteer: (item) => _applyQueueAction(item, 'steer'),
              onSteerAll: _steerAllQueue,
            ),
          _LiveFooter(
            running: _running,
            atLatest: _atLatest,
            onJumpLatest: () => _scrollToEnd(force: true),
          ),
          // M4.19：存档会话现在也能继续对话——发一句话，电脑会把它复制成一条新会话
          // 再接上，手机随之跳过去直播。所以这里不再是「只能看」的死鸟，而是说明。
          if (_isArchived)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.page,
                0,
                AppSpace.page,
                10,
              ),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: palette.lineSoft,
                  borderRadius: BorderRadius.circular(AppRadius.card),
                ),
                child: Row(
                  children: [
                    Icon(Icons.history_rounded,
                        size: 16, color: palette.text3),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '存档会话 · 发一句话，电脑会把它接回原来那条对话，接着说',
                        style: TextStyle(
                          color: palette.text2,
                          fontSize: 12,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (_attachments.isNotEmpty)
            _AttachmentBar(
              attachments: _attachments,
              uploading: _uploading,
              onRemove: (index) =>
                  setState(() => _attachments.removeAt(index)),
            ),
          _LiveComposer(
            controller: _composer,
            sending: _sending,
            onSend: _send,
            onPickPhoto: _uploading ? null : _pickPhotos,
            onPickCamera: _uploading ? null : _pickCamera,
            onPickFile: _uploading ? null : _pickFiles,
            attachmentCount: _attachments.length,
          ),
                ],
              ),
            ),
          ),
        ],
          );
        },
      ),
    );
  }
}

class _LiveHeader extends StatelessWidget {
  const _LiveHeader({
    required this.title,
    required this.cwd,
    required this.running,
    required this.count,
  });

  final String title;
  final String cwd;
  final bool running;
  final int count;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    // M4.17：对齐官方 App 顶部那条胶囊——标题一行，下面一行「● 本机 · 目录」。
    final folder = desktopFolderName(cwd);
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpace.page, 2, AppSpace.page, 10),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 11, 14, 11),
        decoration: BoxDecoration(
          color: palette.card,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: palette.line),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title.isEmpty ? '桌面会话' : title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: palette.text,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: running ? palette.success : palette.text3,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          folder.isEmpty ? '本机' : '本机 · $folder',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: palette.text3, fontSize: 11.5),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: running
                    ? palette.success.withValues(alpha: 0.12)
                    : palette.lineSoft,
                borderRadius: BorderRadius.circular(AppRadius.pill),
              ),
              child: Text(
                running ? '直播中 · $count 条' : '已结束 · $count 条',
                style: TextStyle(
                  color: running ? palette.success : palette.text2,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// M4.21：电脑端那排「N 条排队消息」的手机版。
///
/// 折叠时只占一行（有多少条等着发）；展开后每条都能改字 / 删除 / 插话，
/// 右上角还能「全部插话」——对应电脑端的 Cmd/Ctrl+Enter。
class _QueuePanel extends StatelessWidget {
  const _QueuePanel({
    required this.queue,
    required this.open,
    required this.busy,
    required this.onToggle,
    required this.onEdit,
    required this.onRemove,
    required this.onSteer,
    required this.onSteerAll,
  });

  final DesktopQueue queue;
  final bool open;
  final bool busy;
  final VoidCallback onToggle;
  final ValueChanged<DesktopQueueItem> onEdit;
  final ValueChanged<DesktopQueueItem> onRemove;
  final ValueChanged<DesktopQueueItem> onSteer;
  final VoidCallback onSteerAll;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final count = queue.items.length;
    final pending = queue.items.where((item) => item.pending).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpace.page, 0, AppSpace.page, 8),
      child: Container(
        decoration: BoxDecoration(
          color: palette.lineSoft,
          borderRadius: BorderRadius.circular(AppRadius.card),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(AppRadius.card),
              onTap: onToggle,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
                child: Row(
                  children: [
                    Icon(Icons.pending_actions_rounded,
                        size: 16, color: palette.text2),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '$count 条排队消息',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: palette.text,
                        ),
                      ),
                    ),
                    if (open && pending > 1)
                      TextButton(
                        onPressed: busy ? null : onSteerAll,
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: const Size(0, 30),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: const Text(
                          '全部插话',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                      ),
                    Icon(
                      open
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 18,
                      color: palette.text3,
                    ),
                  ],
                ),
              ),
            ),
            if (open)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final item in queue.items)
                      _QueueRow(
                        item: item,
                        busy: busy,
                        onEdit: () => onEdit(item),
                        onRemove: () => onRemove(item),
                        onSteer: () => onSteer(item),
                      ),
                    const SizedBox(height: 2),
                    Text(
                      '插话＝立刻送进这一轮（电脑端是 Cmd/Ctrl+Enter）',
                      style: TextStyle(
                        fontSize: 11,
                        color: palette.text3,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _QueueRow extends StatelessWidget {
  const _QueueRow({
    required this.item,
    required this.busy,
    required this.onEdit,
    required this.onRemove,
    required this.onSteer,
  });

  final DesktopQueueItem item;
  final bool busy;
  final VoidCallback onEdit;
  final VoidCallback onRemove;
  final VoidCallback onSteer;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final body = item.text.isEmpty ? '（空消息）' : item.text;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(AppRadius.navPill),
        border: Border.all(color: palette.line),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              body,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.45,
                color: palette.text,
              ),
            ),
          ),
          if (item.pending) ...[
            _QueueIconButton(
              icon: Icons.edit_outlined,
              tooltip: '改这句话',
              onPressed: busy ? null : onEdit,
            ),
            _QueueIconButton(
              icon: Icons.delete_outline_rounded,
              tooltip: '从队列里删掉',
              onPressed: busy ? null : onRemove,
            ),
            _QueueIconButton(
              icon: Icons.arrow_upward_rounded,
              tooltip: '插话：立刻送进这一轮',
              onPressed: busy ? null : onSteer,
            ),
          ] else
            Padding(
              padding: const EdgeInsets.only(top: 6, right: 4),
              child: Text(
                '插话中',
                style: TextStyle(fontSize: 11, color: palette.text3),
              ),
            ),
        ],
      ),
    );
  }
}

class _QueueIconButton extends StatelessWidget {
  const _QueueIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      iconSize: 17,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
      padding: EdgeInsets.zero,
      icon: Icon(icon, color: palette.text2),
    );
  }
}

class _LiveFooter extends StatelessWidget {
  const _LiveFooter({
    required this.running,
    required this.atLatest,
    required this.onJumpLatest,
  });

  final bool running;

  /// M4.16：是不是停在最新一条。以前这个状态条是固定文案，用户往上翻到中段
  /// 它也照样写「已同步到最新」，等于骗人。
  final bool atLatest;

  final VoidCallback onJumpLatest;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final label = running
        ? '实时同步 · 可直接发指令，授权也能在手机上应答'
        : (atLatest ? '已同步到最新 · 可直接发指令' : '往上是更早的对话 · 点这里回到最新');
    final icon = running
        ? Icons.bolt_rounded
        : (atLatest ? Icons.visibility_outlined : Icons.arrow_downward_rounded);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppSpace.page, 0, AppSpace.page, 10),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.pill),
          onTap: atLatest ? null : onJumpLatest,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 13, color: palette.text3),
                const SizedBox(width: 5),
                // M4.40：这行文案在窄屏 + 大字号下会把 Row 撑破（曾 overflow
                // 73px），改成可缩、可换行、最居中。
                Flexible(
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: palette.text3, fontSize: 10.5),
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

class _EventRow extends StatelessWidget {
  const _EventRow({required this.event});

  final DesktopSessionEvent event;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    switch (event.kind) {
      case 'user':
        // M3.6：与首页同款气泡，保证「桌面直播」看起来就是一段对话。
        return ChatItemView(
          item: ChatItem(
            role: ChatRole.user,
            kind: ChatItemKind.text,
            text: event.text,
          ),
        );
      case 'assistant':
        return ChatItemView(
          item: ChatItem(
            role: ChatRole.assistant,
            kind: ChatItemKind.text,
            text: event.text,
          ),
        );
      case 'tool-call':
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: _ToolCallCard(event: event),
        );
      case 'tool-result':
        return Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                event.ok ? Icons.check_circle_rounded : Icons.cancel_rounded,
                size: 14,
                color: event.ok ? palette.success : palette.danger,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  event.text.isEmpty
                      ? (event.ok ? '执行完成' : '执行失败')
                      : event.text,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: palette.text3,
                    fontSize: 11.5,
                    height: 1.45,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ],
          ),
        );
      case 'turn-end':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            children: [
              Expanded(child: Divider(color: palette.line)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text(
                  (event.reason ?? '').isEmpty || event.reason == 'completed'
                      ? '本轮结束'
                      : '本轮结束 · ${event.reason}',
                  style: TextStyle(color: palette.text3, fontSize: 10.5),
                ),
              ),
              Expanded(child: Divider(color: palette.line)),
            ],
          ),
        );
      case 'turn-start':
        return Padding(
          padding: const EdgeInsets.only(top: 14, bottom: 2),
          child: Text(
            '开始新一轮',
            style: TextStyle(
              color: palette.text3,
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
            ),
          ),
        );
      case 'approval':
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: palette.warn.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(AppRadius.code),
              border: Border.all(color: palette.warn.withValues(alpha: 0.35)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.lock_clock_rounded, size: 15, color: palette.warn),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '电脑上正在等待授权：${event.text}',
                    style: TextStyle(color: palette.text, fontSize: 12, height: 1.5),
                  ),
                ),
              ],
            ),
          ),
        );
      default:
        return const SizedBox.shrink();
    }
  }
}

class _ToolCallCard extends StatefulWidget {
  const _ToolCallCard({required this.event});

  final DesktopSessionEvent event;

  @override
  State<_ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<_ToolCallCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final args = widget.event.args ?? '';
    final preview = args.length > 220 ? '${args.substring(0, 220)}…' : args;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: palette.lineSoft,
        borderRadius: BorderRadius.circular(AppRadius.code),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.terminal_rounded, size: 14, color: palette.accent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  widget.event.name ?? 'tool',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: palette.text,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              if (args.length > 220)
                GestureDetector(
                  onTap: () => setState(() => _expanded = !_expanded),
                  child: Text(
                    _expanded ? '收起' : '展开',
                    style: TextStyle(color: palette.accent, fontSize: 11),
                  ),
                ),
            ],
          ),
          if (args.isNotEmpty) ...[
            const SizedBox(height: 6),
            SelectableText(
              _expanded ? args : preview,
              style: TextStyle(
                color: palette.text2,
                fontSize: 11,
                height: 1.5,
                fontFamily: 'monospace',
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ApprovalCard extends StatelessWidget {
  const _ApprovalCard({
    required this.approval,
    required this.onApprove,
    required this.onReject,
  });

  final DesktopApproval approval;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: palette.warn.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: palette.warn.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.shield_outlined, size: 16, color: palette.warn),
              const SizedBox(width: 6),
              Text(
                '电脑在等你授权',
                style: TextStyle(
                  color: palette.text,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '工具：${approval.toolName}',
            style: TextStyle(
              color: palette.text2,
              fontSize: 12,
              fontFamily: 'monospace',
            ),
          ),
          if (approval.reason.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              approval.reason,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: palette.text2, fontSize: 12, height: 1.5),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: onReject,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 40),
                    foregroundColor: palette.danger,
                    side: BorderSide(color: palette.danger.withValues(alpha: 0.4)),
                  ),
                  child: const Text('拒绝'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: onApprove,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 40),
                    backgroundColor: palette.warn,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('允许一次'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// M4.23：电脑端「确认需求」卡片在手机上的对应物。
///
/// 电脑端那张卡的右上角是「1/2」翻页，手机上不翻页——一屏把几页问题顺着列出来，
/// 选完点「提交」。`跳过` 发空答案，Host 会当作用户什么都没选，让这一轮继续。
class _QuestionCard extends StatefulWidget {
  const _QuestionCard({
    required this.question,
    required this.busy,
    required this.onSubmit,
    required this.onSkip,
  });

  final DesktopQuestion question;
  final bool busy;
  final ValueChanged<List<DesktopQuestionAnswer>> onSubmit;
  final VoidCallback onSkip;

  @override
  State<_QuestionCard> createState() => _QuestionCardState();
}

class _QuestionCardState extends State<_QuestionCard> {
  final Map<String, Set<String>> _selected = <String, Set<String>>{};
  final Map<String, TextEditingController> _custom =
      <String, TextEditingController>{};

  @override
  void dispose() {
    for (final controller in _custom.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Set<String> _selectionOf(String id) =>
      _selected.putIfAbsent(id, () => <String>{});

  TextEditingController _customOf(String id) =>
      _custom.putIfAbsent(id, TextEditingController.new);

  void _toggle(DesktopQuestionItem item, String label) {
    setState(() {
      final set = _selectionOf(item.id);
      if (item.multiSelect) {
        if (!set.add(label)) set.remove(label);
      } else {
        set
          ..clear()
          ..add(label);
      }
    });
  }

  List<DesktopQuestionAnswer> _collect() {
    final answers = <DesktopQuestionAnswer>[];
    for (final item in widget.question.items) {
      final selected = _selectionOf(item.id).toList(growable: false);
      final custom = _customOf(item.id).text.trim();
      if (selected.isEmpty && custom.isEmpty) continue;
      answers.add(
        DesktopQuestionAnswer(id: item.id, selected: selected, custom: custom),
      );
    }
    return answers;
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final hasAnswer = widget.question.items.any(
      (item) =>
          _selectionOf(item.id).isNotEmpty ||
          _customOf(item.id).text.trim().isNotEmpty,
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: palette.accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: palette.accent.withValues(alpha: 0.3)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.help_outline_rounded, size: 16, color: palette.accent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  widget.question.items.length > 1
                      ? '电脑在等你回答（${widget.question.items.length} 个问题）'
                      : '电脑在等你回答',
                  style: TextStyle(
                    color: palette.text,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          Flexible(
            fit: FlexFit.loose,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final item in widget.question.items) ...[
            const SizedBox(height: 10),
            if (item.header.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(
                  item.header,
                  style: TextStyle(
                    color: palette.text3,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            Text(
              item.question,
              style: TextStyle(
                color: palette.text,
                fontSize: 14.5,
                fontWeight: FontWeight.w600,
                height: 1.45,
              ),
            ),
            if (item.detail.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  item.detail,
                  style: TextStyle(
                    color: palette.text2,
                    fontSize: 12.5,
                    height: 1.5,
                  ),
                ),
              ),
            for (final option in item.options)
              _QuestionOptionRow(
                option: option,
                selected: _selectionOf(item.id).contains(option.label),
                multi: item.multiSelect,
                onTap: () => _toggle(item, option.label),
              ),
            TextField(
              controller: _customOf(item.id),
              onChanged: (_) => setState(() {}),
              style: const TextStyle(fontSize: 13.5),
              decoration: InputDecoration(
                isDense: true,
                hintText: item.options.isEmpty ? '输入你的答案' : '或者自己写一个答案（可选）',
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
            ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: widget.busy ? null : widget.onSkip,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 40),
                    foregroundColor: palette.text2,
                    side: BorderSide(color: palette.line),
                  ),
                  child: const Text('跳过'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: widget.busy || !hasAnswer
                      ? null
                      : () => widget.onSubmit(_collect()),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 40),
                    backgroundColor: palette.accent,
                    foregroundColor: Colors.white,
                  ),
                  child: Text(widget.busy ? '发送中…' : '提交'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _QuestionOptionRow extends StatelessWidget {
  const _QuestionOptionRow({
    required this.option,
    required this.selected,
    required this.multi,
    required this.onTap,
  });

  final DesktopQuestionOption option;
  final bool selected;
  final bool multi;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.input),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              multi
                  ? (selected
                      ? Icons.check_box_rounded
                      : Icons.check_box_outline_blank_rounded)
                  : (selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded),
              size: 18,
              color: selected ? palette.accent : palette.text3,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    option.label,
                    style: TextStyle(
                      color: palette.text,
                      fontSize: 13,
                      height: 1.45,
                    ),
                  ),
                  if (option.description.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        option.description,
                        style: TextStyle(
                          color: palette.text3,
                          fontSize: 11.5,
                          height: 1.45,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LiveComposer extends StatelessWidget {
  const _LiveComposer({
    required this.controller,
    required this.sending,
    required this.onSend,
    this.onPickPhoto,
    this.onPickCamera,
    this.onPickFile,
    this.attachmentCount = 0,
  });

  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;
  final VoidCallback? onPickPhoto;
  final VoidCallback? onPickCamera;
  final VoidCallback? onPickFile;
  final int attachmentCount;

  void _openPicker(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.appPalette.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.sheetTop)),
      ),
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('拍照'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                onPickCamera?.call();
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('照片'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                onPickPhoto?.call();
              },
            ),
            ListTile(
              leading: const Icon(Icons.attach_file_rounded),
              title: const Text('文件'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                onPickFile?.call();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppSpace.page, 0, AppSpace.page, 10),
        child: Container(
          padding: const EdgeInsets.fromLTRB(6, 4, 4, 4),
          decoration: BoxDecoration(
            color: palette.card,
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: palette.line),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              IconButton(
                tooltip: '添加附件',
                onPressed:
                    (onPickPhoto == null && onPickFile == null) ? null : () => _openPicker(context),
                icon: Icon(Icons.add_rounded, color: palette.text2),
              ),
              Expanded(
                child: TextField(
                  controller: controller,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => onSend(),
                  style: TextStyle(color: palette.text, fontSize: 14.5),
                  decoration: InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    hintText: '在电脑上继续说点什么…',
                    hintStyle: TextStyle(color: palette.text3, fontSize: 14.5),
                  ),
                ),
              ),
              IconButton(
                tooltip: '发送',
                onPressed: sending ? null : onSend,
                icon: sending
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: palette.accent,
                        ),
                      )
                    : Icon(Icons.arrow_upward_rounded, color: palette.accent),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PendingAttachment {
  const _PendingAttachment({required this.name, required this.bytes});

  final String name;
  final List<int> bytes;
}

class _AttachmentBar extends StatelessWidget {
  const _AttachmentBar({
    required this.attachments,
    required this.onRemove,
    this.uploading = false,
  });

  final List<_PendingAttachment> attachments;
  final ValueChanged<int> onRemove;
  final bool uploading;

  String _size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpace.page, 0, AppSpace.page, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (uploading)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                '正在传到电脑…',
                style: TextStyle(color: palette.text3, fontSize: 12),
              ),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (var i = 0; i < attachments.length; i++)
                Container(
                  padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
                  decoration: BoxDecoration(
                    color: palette.lineSoft,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.insert_drive_file_outlined,
                          size: 14, color: palette.text2),
                      const SizedBox(width: 6),
                      Text(
                        '${attachments[i].name}  ${_size(attachments[i].bytes.length)}',
                        style: TextStyle(color: palette.text2, fontSize: 12),
                      ),
                      InkWell(
                        onTap: () => onRemove(i),
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(Icons.close_rounded,
                              size: 14, color: palette.text3),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
