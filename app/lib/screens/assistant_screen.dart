import 'dart:async';

import 'package:flutter/material.dart';

import '../data/live_store.dart';
import '../models.dart';
import '../services/cloud_chat.dart';
import '../services/cloud_chat_intent.dart';
import '../services/cloud_conversations.dart';
import '../services/mode_intro.dart';
import '../services/remote_chat_intent.dart';
import '../services/settings_gateway.dart';
import '../services/share_card.dart';
import '../services/share_gateway.dart';
import '../theme/app_theme.dart';
import '../widgets/app_mark.dart';
import '../widgets/approval_sheet.dart';
import '../widgets/attachment_bar.dart';
import '../widgets/chat_items.dart';
import '../widgets/common.dart';
import '../widgets/turn_fold.dart';
import 'cloud_chat_screen.dart';
import 'connect_screen.dart';
import 'desktop_session_screen.dart';
import 'session_center_screen.dart';

/// M4.8：手机档的「本机直读」。
///
/// 图片和文本附件手机自己能处理；PDF / Word / Excel / 压缩包这类只有电脑端
/// 会解析，于是借电脑上的 Agent 读一遍再发给云端模型——对用户来说就是
/// 「什么文件都能直接丢进来」，而不是「请先上传到电脑」。不落工作区。
class _DesktopCaretaker implements CaretakerReader {
  const _DesktopCaretaker(this._live);

  final LiveStore _live;

  @override
  Future<String?> read(PendingAttachment attachment) async {
    if (!_live.isConnected) return null;
    try {
      return await _live.readDesktopFile(
        name: attachment.name,
        bytes: attachment.bytes,
      );
    } catch (_) {
      return null;
    }
  }
}

/// 把「DeepSeek Harness (插件直连)」这类长设备名收成短名，
/// 避免顶部胶囊和问候语被撑得太长（M2.9）。
String _shortDeviceName(String name) {
  final trimmed = name.trim();
  final index = trimmed.indexOf(' (');
  if (index > 0) return trimmed.substring(0, index);
  return trimmed;
}

/// AI 助手：对话即入口。
///
/// 未连接时整页空态；连接成功后走 [LiveStore]，
/// 消息、任务状态与高风险授权都来自电脑上的 DeepSeek Harness。
class AssistantScreen extends StatefulWidget {
  const AssistantScreen({
    super.key,
    required this.liveStore,
    this.shareGateway,
    this.modeIntro,
    this.onOpenMenu,
    this.onOpenProjects,
    this.onOpenTasks,
    this.conversations,
  });

  final LiveStore liveStore;

  /// M2.2 A4：分享卡系统通道（测试可注入 Fake）。
  final ShareGateway? shareGateway;

  /// M4.48：档位说明只提示一次的标记（测试注入 Fake；为空走系统设置通道）。
  final ModeIntroPrefs? modeIntro;

  /// M2.9：左上角菜单按钮 → 打开侧边抽屉。
  final VoidCallback? onOpenMenu;

  /// M2.9：输入条上方的快捷入口。
  final VoidCallback? onOpenProjects;
  final VoidCallback? onOpenTasks;

  /// M4.34：手机档对话存储——抽屉「手机对话」用同一份，测试注入内存版。
  final CloudConversationStore? conversations;

  @override
  State<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends State<AssistantScreen> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();

  /// M4.6：AI 助手页两档——「本机对话」= 云端 API Key 直连，「远程电脑」= 和电脑上的 AI 对话。
  /// 恢复 M2.9 的切换，但按用户要求**默认停在本机对话档**，切到远程电脑会记住。
  String _mode = 'phone';

  /// M4.48：档位说明只挂一次——第一次切换时把两档差别说清楚。
  late final ModeIntroPrefs _modeIntro;
  bool _showModeIntro = false;

  /// M4.6：「手机」档内嵌的云端对话页控制器（顶栏点击 → 打开接口设置）。
  final _cloudController = CloudChatController();

  /// 审批弹层是否正在展示，避免重复弹出。
  bool _approvalOpen = false;

  /// M4.44：用户明确「先不处理」过的授权（下滑 / 返回 / 超时）。
  /// 记着它能避免同一秒钟又弹一次；点通知进来时会解除。
  final Set<String> _deferredApprovals = <String>{};

  /// 连接后是否已经触发过一次真实数据加载（会话列表 / 任务列表）。
  bool _liveDataRequested = false;

  /// M3.0：待发送的附件（照片 / 文档）。
  final List<PendingAttachment> _attachments = [];

  /// M4.7：拍照 / 相册 / 文件的选择逻辑与手机档共用。
  final _picker = AttachmentPicker();

  bool _uploading = false;

  LiveStore get live => widget.liveStore;

  /// 点「+」里的照片：从相册挑一张或多张。
  Future<void> _pickPhotos() async {
    try {
      final picked = await _picker.pickPhotos();
      if (!mounted || picked.isEmpty) return;
      setState(() => _attachments.addAll(picked));
    } catch (error) {
      _toast('选照片失败：$error');
    }
  }

  /// 点「+」里的拍照：直接调用相机拍一张。
  Future<void> _pickCamera() async {
    try {
      final picked = await _picker.pickCamera();
      if (!mounted || picked == null) return;
      setState(() => _attachments.add(picked));
    } catch (error) {
      _toast('拍照失败：$error');
    }
  }

  /// 点「+」里的文件：任意文档。
  Future<void> _pickFiles() async {
    try {
      final picked = await _picker.pickFiles();
      if (!mounted || picked.isEmpty) return;
      setState(() => _attachments.addAll(picked));
    } catch (error) {
      _toast('选文件失败：$error');
    }
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// 点击空态里的建议，把文案填进输入框并聚焦（不直接发送）。
  void _draft(String text) {
    _controller.text = text;
    _controller.selection = TextSelection.collapsed(offset: text.length);
    _focus.requestFocus();
  }

  @override
  void initState() {
    super.initState();
    live.addListener(_onLiveChanged);
    // M4.48：说明横幅的「看过」标记（读设置是异步的，读到后再决定挂不挂）。
    _modeIntro = widget.modeIntro ??
        ModeIntroPrefs(gateway: MethodChannelSettingsGateway());
    unawaited(_modeIntro.load());
    // M4.30：「工作区 → 手机对话」点开某一条时，切到手机档并选中它。
    CloudChatIntent.instance.addListener(_onCloudIntent);
    // M4.50：「工作区 → 新会话」要切到远程电脑档，并把新会话绑到那个目录。
    RemoteChatIntent.instance.addListener(_onRemoteIntent);
    _maybeShowApproval();
    if (live.isConnected) {
      _liveDataRequested = true;
      live.ensureLiveData();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _onCloudIntent());
    WidgetsBinding.instance.addPostFrameCallback((_) => _onRemoteIntent());
  }

  @override
  void dispose() {
    CloudChatIntent.instance.removeListener(_onCloudIntent);
    RemoteChatIntent.instance.removeListener(_onRemoteIntent);
    live.removeListener(_onLiveChanged);
    _focus.dispose();
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// M4.30：把「打开这条手机对话」的意图变成「切手机档 + 选中它」。
  void _onCloudIntent() {
    final id = CloudChatIntent.instance.take();
    if (id == null || !mounted) return;
    setState(() => _mode = 'phone');
    _cloudController.openConversation(id);
  }

  /// M4.50：工作区页点了「新会话」——切到远程电脑档、把这个目录绑给下一场对话，
  /// 并聚焦输入框。真正的对话框在这里，不在工作区那一页。
  void _onRemoteIntent() {
    final request = RemoteChatIntent.instance.take();
    if (request == null || !mounted) return;
    final path = request.workspacePath;
    if (_mode != 'desktop') setState(() => _mode = 'desktop');
    if (live.isBusy) {
      // 还在跑上一条时不打断它：只把目录记下来，等这一条结束再开新会话。
      if (path != null && path.isNotEmpty) live.setPendingWorkspace(path);
      _toast('电脑还在忙这一条，等它结束再开新会话');
    } else {
      live.startNewConversation(workspacePath: path);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  void _onLiveChanged() {
    if (!mounted) return;
    _maybeShowApproval();
    if (!live.isConnected) {
      _liveDataRequested = false;
      return;
    }
    if (!_liveDataRequested) {
      _liveDataRequested = true;
      live.ensureLiveData();
    }
  }

  void _maybeShowApproval() {
    final approval = live.pendingApproval;
    if (approval == null || _approvalOpen) return;
    // 后台/锁屏时由系统通知提醒，回到前台再弹 ApprovalSheet。
    if (!live.appInForeground) return;
    // M4.44：用户刚把这一条「暂缓」过，就别立刻再弹一次（通知点进来除外）。
    final fromNotification = live.approvalToOpenId == approval.approvalId;
    if (!fromNotification && _deferredApprovals.contains(approval.approvalId)) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final current = live.pendingApproval;
      if (current == null || _approvalOpen) return;
      if (!fromNotification && _deferredApprovals.contains(current.approvalId)) {
        return;
      }
      _showLiveApproval(current);
    });
  }

  Future<void> _showLiveApproval(PendingApproval approval) async {
    if (_approvalOpen) return;
    _approvalOpen = true;
    // 从通知点击进来：弹过之后清掉标记，并解除这条的「暂缓」。
    live.clearApprovalToOpen();
    _deferredApprovals.remove(approval.approvalId);
    final workspace = approval.workspace.isNotEmpty
        ? approval.workspace
        : (live.workspacePath?.isNotEmpty == true
              ? live.workspacePath!
              : '未知工作区');
    ApprovalDecision? decision;
    try {
      decision = await showModalBottomSheet<ApprovalDecision>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => ApprovalSheet(
          tool: approval.tool,
          command: approval.command,
          deviceName: live.deviceName,
          workspace: workspace,
        ),
      );
    } finally {
      _approvalOpen = false;
    }
    if (!mounted) return;

    // M4.44：只有明确点按钮才发送决定。下滑/返回/超时（都是 null 或 later）
    // 一律「暂缓」——不发 approved 也不发 denied，电脑那头会继续等（它有自己的超时）。
    if (decision == ApprovalDecision.approved) {
      live.decideApproval(true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已允许本次操作，电脑正在执行…')),
      );
      return;
    }
    if (decision == ApprovalDecision.denied) {
      live.decideApproval(false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已拒绝本次操作，电脑端已取消')),
      );
      return;
    }
    _deferredApprovals.add(approval.approvalId);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('先不处理。电脑仍在等你回答，可以从通知或工作区再进来'),
      ),
    );
  }

  Future<void> _openConnect() async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => ConnectScreen(store: live)),
    );
    if (!mounted) return;
    if (live.isConnected) _scrollToEnd();
  }

  /// M4.43：历史会话。
  ///
  /// 以前走 `loadConversations()`（老后端 `/api/v1/conversations`），插件直连下
  /// 必然 404，弹层永远是空的。现在数据源换成插件真实提供的桌面会话镜像 +
  /// 存档（[LiveStore.recentDesktopSessions]），点一条直接打开那场直播。
  Future<void> _showHistory() async {
    // M4.47：顶栏历史按钮不再弹自己的列表，统一进「会话」中心。
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SessionCenterScreen(
          liveStore: live,
          conversations: widget.conversations ?? CloudConversationStore(),
          onOpenLocal: _openLocalConversation,
        ),
      ),
    );
  }

  /// 会话中心里选了一条本机对话：切到手机档并打开那一条。
  void _openLocalConversation(String conversationId) {
    if (!mounted) return;
    setState(() => _mode = 'phone');
    CloudChatIntent.instance.open(conversationId);
  }

  /// M4.6：测试用——直接切档（本机 / 远程），不走手势。
  @visibleForTesting
  void switchModeForTest(String mode) => setState(() => _mode = mode);

  /// M4.50：测试用——看当前在哪一档。
  @visibleForTesting
  String get modeForTest => _mode;

  /// M4.48：用户点档位胶囊。第一次切档顺便把两档差别挂出来。
  void _setMode(String next) {
    if (next == _mode) return;
    setState(() {
      _mode = next;
      if (!_modeIntro.seen) _showModeIntro = true;
    });
  }

  /// 点「知道了」或关掉：收起横幅并记住，之后不再打扰。
  void _dismissModeIntro() {
    if (!_showModeIntro) return;
    setState(() => _showModeIntro = false);
    unawaited(_modeIntro.markSeen());
  }

  Future<void> _send(String text) async {
    final value = text.trim();
    if (value.isEmpty && _attachments.isEmpty) return;
    if (_uploading) return;
    if (_attachments.isNotEmpty && !live.isConnected) {
      _toast('附件要先连上电脑才能发过去');
      return;
    }
    var outgoing = value;
    if (_attachments.isNotEmpty) {
      final folder = _uploadWorkspace;
      setState(() => _uploading = true);
      final lines = <String>[];
      try {
        for (final attachment in _attachments) {
          final uploaded = await live.uploadDesktopFile(
            name: attachment.name,
            bytes: attachment.bytes,
            workspace: folder,
          );
          lines.add('- ${uploaded.path}');
        }
      } catch (error) {
        if (mounted) setState(() => _uploading = false);
        _toast('附件上传失败：$error');
        return;
      }
      if (!mounted) return;
      setState(() {
        _uploading = false;
        _attachments.clear();
      });
      // M4.2：把落盘路径直接写进指令，AI 才知道要读哪个文件。
      // M4.8：只说「已经能读了」，不再向用户播报「上传/已保存到电脑」。
      final listing = '附件：\n${lines.join('\n')}';
      outgoing =
          outgoing.isEmpty ? '我发了一些附件，请看一下：\n$listing' : '$outgoing\n\n$listing';
    }
    _controller.clear();
    live.sendPrompt(outgoing);
    _scrollToEnd();
  }

  /// M4.2：附件应该落到哪个工作区（名字，不是路径）——电脑端插件 0.2.11+
  /// 会在该工作区下建「手机附件」文件夹。没选过工作区时返回 null，落默认目录。
  String? get _uploadWorkspace {
    final path = live.pendingWorkspacePath?.trim() ?? '';
    if (path.isNotEmpty) return _leafName(path);
    final label = _conversationTitle?.trim() ?? '';
    final sep = label.lastIndexOf(' · ');
    return _leafName(sep >= 0 ? label.substring(0, sep) : label);
  }

  static String _leafName(String path) {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return '';
    final parts = trimmed.split(RegExp(r'[\\/]'));
    for (var i = parts.length - 1; i >= 0; i--) {
      if (parts[i].trim().isNotEmpty) return parts[i].trim();
    }
    return '';
  }

  void _cancel() => live.cancel();

  /// 测试用：往待发送附件里塞一个文件（真实入口走系统相册/文件选择器）。
  @visibleForTesting
  void attachForTest({required String name, required List<int> bytes}) {
    setState(() =>
        _attachments.add(PendingAttachment(name: name, bytes: bytes)));
  }

  /// 测试用：走与点发送按钮完全相同的路径。
  @visibleForTesting
  Future<void> sendForTest(String text) => _send(text);
  void _removeAttachment(int index) {
    if (index < 0 || index >= _attachments.length) return;
    setState(() => _attachments.removeAt(index));
  }

  /// M2.2 A5：长按「重新发送」把文本写回输入框（不自动发送）。
  void _resendText(String text) {
    _controller.text = text;
    _controller.selection = TextSelection.collapsed(offset: text.length);
    _focus.requestFocus();
  }

  /// M2.2 A4：当前是否有可分享的内容。
  bool get _canShare => live.isConnected && live.messages.isNotEmpty;

  String? get _conversationTitle {
    final id = live.conversationId;
    if (id == null) return null;
    for (final item in live.conversations) {
      if (item.conversationId == id) return item.title;
    }
    return null;
  }

  /// M2.2 A4：把最近一轮对话渲染成竖版分享卡并调起系统分享。
  Future<void> _shareConversation() async {
    final data = buildShareCardData(
      messages: live.messages,
      deviceName: live.deviceName,
      conversationTitle: _conversationTitle,
      summary: live.latestCompletedTurnStats?.summaryLabel ?? '',
      now: DateTime.now(),
    );
    if (data == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('暂无可分享的对话内容')),
      );
      return;
    }
    final ok = await ShareCardService(gateway: widget.shareGateway).share(
      data: data,
      palette: context.appPalette,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? '分享卡已生成' : '分享失败，请稍后重试')),
    );
  }

  bool get _isLive => live.isConnected;

  /// 当前是否在「手机」档（云端直连）。没连电脑时一样保留用户选的档，
  /// 只是「电脑」档会显示「还没有连接」的空态。
  bool get _phoneMode => _mode == 'phone';

  /// M3.0：不连电脑，直接用 API Key 云端对话（「手机」档）。
  Future<void> _openCloudChat() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (context) => const CloudChatScreen()),
    );
  }

  /// 「手机」档顶部胶囊：直接打开云端接口设置（不用再进二级页）。
  void _openCloudSettings() => _cloudController.editConfig();

  void _onCloudChanged() {
    if (mounted) setState(() {});
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent + 160,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: live,
      builder: (context, _) {
        final isLive = _isLive;
        final phone = _phoneMode;
        final running = isLive && !phone && live.isBusy;
        return Scaffold(
          body: SafeArea(
            bottom: false,
            child: Column(
              children: [
              // M4.6：手机档不显示设备胶囊（没接电脑，显示「未连接」只会误导），
              // 只留菜单与接口设置；电脑档沿用原来的设备胶囊 + 历史。
              if (phone)
                _HomeHeader(
                  connected: isLive,
                  deviceName: _shortDeviceName(live.deviceName),
                  onOpenMenu: widget.onOpenMenu,
                  onOpenConnect: _openCloudSettings,
                  // M4.27：手机档顶栏的「历史」打开云端对话记录（像豆包的侧栏）。
                  onHistory: () => _cloudController.openHistory(),
                  cloudMode: true,
                  cloudModel: _cloudController.modelName,
                  cloudConfigured: _cloudController.isConfigured,
                )
              else
                _HomeHeader(
                  connected: isLive,
                  deviceName: _shortDeviceName(live.deviceName),
                  onOpenMenu: widget.onOpenMenu,
                  onOpenConnect: _openConnect,
                  onHistory: isLive && !live.conversationsLoading
                      ? _showHistory
                      : null,
                  onShare: _canShare ? _shareConversation : null,
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpace.page, 2, AppSpace.page, 6),
                child: _ModeSwitch(
                  mode: phone ? 'phone' : 'desktop',
                  onChanged: _setMode,
                ),
              ),
              // M4.48：第一次切档时说明「本机对话 / 远程电脑」差在哪。
              if (_showModeIntro)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpace.page,
                    0,
                    AppSpace.page,
                    8,
                  ),
                  child: _ModeIntroCard(onDismiss: _dismissModeIntro),
                ),
              Expanded(
                // M4.6：两档都常驻在这棵树里（IndexedStack），切回「手机」时
                // 云端对话的历史和输入不会丢。
                child: IndexedStack(
                  index: phone ? 0 : 1,
                  sizing: StackFit.expand,
                  children: [
                    CloudChatScreen(
                      embedded: true,
                      controller: _cloudController,
                      conversations: widget.conversations,
                      onChanged: _onCloudChanged,
                      caretaker: _DesktopCaretaker(live),
                    ),
                    isLive
                        ? Column(
                            children: [
                              if (live.errorText != null)
                                _LiveErrorBar(
                                  text: live.errorText!,
                                  onDismiss: live.clearError,
                                ),
                              Expanded(child: _buildMessages(running)),
                              if (live.pendingWorkspacePath != null)
                                _PendingWorkspaceChip(
                                  path: live.pendingWorkspacePath!,
                                  onRemove: () => live.setPendingWorkspace(null),
                                ),

                              _Composer(
                                controller: _controller,
                                focusNode: _focus,
                                onSend: _send,
                                onPick: _draft,
                                running: running,
                                queued: live.hasQueuedPrompt,
                                onCancel: _cancel,
                                onOpenProjects: widget.onOpenProjects,
                                onOpenTasks: widget.onOpenTasks,
                                onOpenConnect: _openConnect,
                                onPickPhoto: _uploading ? null : _pickPhotos,
                                onPickCamera: _uploading ? null : _pickCamera,
                                onPickFile: _uploading ? null : _pickFiles,
                                attachmentCount: _attachments.length,
                                uploading: _uploading,
                                workspaceLabel: _uploadWorkspace,
                                pendingAttachments: _attachments,
                                onRemoveAttachment:
                                    _uploading ? null : _removeAttachment,
                              ),
                            ],
                          )
                        : _ConnectEmpty(
                            onConnect: _openConnect,
                            onCloudChat: null,
                          ),
                  ],
                ),
              ),
            ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildMessages(bool running) {
    final palette = context.appPalette;
    final messages = live.messages;
    if (messages.isEmpty && live.historyLoading) {
      return ListView(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(AppSpace.page, 8, AppSpace.page, 12),
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 48),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2.4)),
          ),
          Center(
            child: Text(
              '正在从电脑同步历史消息…',
              style: TextStyle(color: palette.text3, fontSize: 11.5),
            ),
          ),
        ],
      );
    }
    if (messages.isEmpty) {
      return ListView(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(AppSpace.page, 8, AppSpace.page, 12),
        children: [
          if (live.catchUpLoading) _catchUpLoadingRow(palette),
          if (live.catchUpError != null)
            _LiveErrorBar(
              text: '断线期间的事件同步失败：${live.catchUpError!}',
              onDismiss: live.clearCatchUpError,
              onRetry: live.catchUpEvents,
            ),
          if (live.historyError != null)
            _LiveErrorBar(
              text: live.historyError!,
              onDismiss: live.clearHistoryError,
              onRetry: () => live.syncHistory(reset: true),
            ),
          // M4.2：空对话不再整屏放欢迎大图——直接一行提示 + 建议胶囊，
          // 输入框就在下面，打开就能打字。
          if (!running && live.pendingWorkspacePath == null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.page,
                10,
                AppSpace.page,
                6,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '直接说想做什么，电脑上的 AI 会在这里跑起来',
                    style: TextStyle(
                      color: palette.text2,
                      fontSize: 13,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _QuickChip(
                        icon: Icons.attach_file_rounded,
                        label: '看这张图里的报错',
                        onTap: () => _draft('看这张图里的报错，告诉我怎么修'),
                      ),
                      _QuickChip(
                        icon: Icons.folder_open_rounded,
                        label: '整理这个目录',
                        onTap: () => _draft('帮我整理一下当前工作区的文件，说明每个文件的作用'),
                      ),
                      _QuickChip(
                        icon: Icons.terminal_rounded,
                        label: '跑通构建和测试',
                        onTap: () => _draft('写个脚本跑通构建和测试'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          if (running)
            _LiveRunningBanner(status: live.taskState, onCancel: live.cancel),
        ],
      );
    }
    return Column(
      children: [
        if (live.catchUpLoading) _catchUpLoadingRow(palette),
        if (live.catchUpError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpace.page,
              6,
              AppSpace.page,
              2,
            ),
            child: _LiveErrorBar(
              text: '断线期间的事件同步失败：${live.catchUpError!}',
              onDismiss: live.clearCatchUpError,
              onRetry: live.catchUpEvents,
            ),
          ),
        Expanded(
          child: Builder(
            builder: (context) {
              // 终态轮的工具/思考卡片折叠为一行摘要。
              final entries = groupTurnMessages(messages, live.turnStats);
              return ListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.page,
                  8,
                  AppSpace.page,
                  12,
                ),
                itemCount: entries.length + (running ? 1 : 0),
                itemBuilder: (context, index) {
                  if (index >= entries.length) {
                    return _LiveRunningBanner(
                      status: live.taskState,
                      onCancel: live.cancel,
                    );
                  }
                  final entry = entries[index];
                  Widget buildItem(ChatItem item) => ChatItemView(
                        item: item,
                        onRemoveQueued: live.removeQueuedPrompt,
                        onSendNow: item.queued
                            ? live.interruptAndSendQueuedPrompt
                            : null,
                        interrupting: live.isInterrupting,
                        onResend: _resendText,
                      );
                  if (entry is TurnFeedGroup) {
                    return TurnSummaryCard(
                      key: ValueKey('turn-${entry.turnId}'),
                      group: entry,
                      itemBuilder: (context, item) => buildItem(item),
                    );
                  }
                  return buildItem((entry as TurnFeedMessage).item);
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _catchUpLoadingRow(AppPalette palette) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 1.6),
          ),
          const SizedBox(width: 8),
          Text(
            '正在同步断线期间的事件…',
            style: TextStyle(color: palette.text3, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

/// M2.9：Kimi 风格顶栏——左侧圆形菜单、中间设备胶囊、右侧历史/分享。
class _HomeHeader extends StatelessWidget {
  const _HomeHeader({
    required this.connected,
    required this.deviceName,
    required this.onOpenMenu,
    required this.onOpenConnect,
    this.onHistory,
    this.onShare,
    this.cloudMode = false,
    this.cloudModel = '',
    this.cloudConfigured = false,
  });

  final bool connected;
  final String deviceName;
  final VoidCallback? onOpenMenu;
  final VoidCallback onOpenConnect;
  final VoidCallback? onHistory;
  final VoidCallback? onShare;

  /// M4.6：「手机」档的顶栏——中间胶囊显示「云端直连 · <模型名>」，
  /// 点击进入云端对话页改接口；不再是电脑设备名。
  final bool cloudMode;
  final String cloudModel;
  final bool cloudConfigured;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final name = deviceName.trim();
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
      child: Row(
        children: [
          _CircleIconButton(
            icon: Icons.menu_rounded,
            tooltip: '打开菜单',
            onTap: onOpenMenu,
          ),
          Expanded(
            child: Center(
              child: Material(
                color: palette.lineSoft,
                borderRadius: BorderRadius.circular(AppRadius.pill),
                child: InkWell(
                  onTap: onOpenConnect,
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 8, 11, 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          cloudMode
                              ? Icons.cloud_outlined
                              : Icons.circle,
                          size: cloudMode ? 15 : 6,
                          color: cloudMode
                              ? palette.accent
                              : (connected ? palette.success : palette.text3),
                        ),
                        const SizedBox(width: 7),
                        Flexible(
                          child: Text(
                            cloudMode
                                ? (cloudConfigured
                                      ? (cloudModel.trim().isEmpty
                                            ? '云端直连'
                                            : '云端直连 · ${cloudModel.trim()}')
                                      : '云端直连 · 未设置接口')
                                : (connected
                                      ? (name.isEmpty ? '已连接电脑' : name)
                                      : '未连接'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: palette.text,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -0.1,
                            ),
                          ),
                        ),
                        const SizedBox(width: 3),
                        Icon(
                          Icons.expand_more_rounded,
                          size: 17,
                          color: palette.text3,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (onShare != null)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: _CircleIconButton(
                icon: Icons.ios_share_rounded,
                tooltip: '分享最近一轮',
                onTap: onShare,
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: _CircleIconButton(
              icon: Icons.history_rounded,
              tooltip: cloudMode ? '对话记录' : '历史会话',
              onTap: onHistory ?? onOpenConnect,
            ),
          ),
        ],
      ),
    );
  }
}

/// M4.48：「本机对话 / 远程电脑」两档切换（默认本机对话）。
/// 本机对话 = 云端 API Key 直连；远程电脑 = 和电脑上的 AI 对话（附件、直播、通知在这一档）。
class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({required this.mode, required this.onChanged});

  final String mode;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    Widget item(String key, String label, IconData icon) {
      final active = mode == key;
      return Expanded(
        child: Material(
          color: active ? palette.card : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          child: InkWell(
            onTap: active ? null : () => onChanged(key),
            borderRadius: BorderRadius.circular(AppRadius.pill),
            child: SizedBox(
              height: 34,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    icon,
                    size: 15,
                    color: active ? palette.accent : palette.text3,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    label,
                    style: TextStyle(
                      color: active ? palette.text : palette.text3,
                      fontSize: 12.5,
                      fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      height: 38,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: palette.lineSoft,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        children: [
          item('phone', '本机对话', Icons.smartphone_rounded),
          item('desktop', '远程电脑', Icons.computer_rounded),
        ],
      ),
    );
  }
}

/// M4.48：第一次切档时挂在输入框上面的说明卡——点「知道了」或右上角 × 收起，
/// 收起后记进设置（[ModeIntroPrefs]），之后不再出现。
class _ModeIntroCard extends StatelessWidget {
  const _ModeIntroCard({required this.onDismiss});

  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final body = TextStyle(color: palette.text2, fontSize: 11.5, height: 1.55);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 4),
      decoration: BoxDecoration(
        color: palette.accentSoft,
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.swap_horiz_rounded, size: 15, color: palette.accent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  ModeIntroCopy.title,
                  style: TextStyle(
                    color: palette.text,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              InkWell(
                key: const ValueKey('modeIntroClose'),
                onTap: onDismiss,
                borderRadius: BorderRadius.circular(AppRadius.pill),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(Icons.close_rounded, size: 15, color: palette.text3),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Text(ModeIntroCopy.local, style: body),
          ),
          const SizedBox(height: 3),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Text(ModeIntroCopy.remote, style: body),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: onDismiss,
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 30),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text(ModeIntroCopy.dismiss),
            ),
          ),
        ],
      ),
    );
  }
}

class _CircleIconButton extends StatelessWidget {
  const _CircleIconButton({
    required this.icon,
    required this.onTap,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final String? tooltip;

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
          width: 40,
          height: 40,
          child: Icon(icon, size: 19, color: palette.text),
        ),
      ),
    );
    if (tooltip == null) return button;
    return Tooltip(message: tooltip!, child: button);
  }
}

/// 未连接时的整页空态：品牌标记 + 一句说明 + 连接按钮。
class _ConnectEmpty extends StatelessWidget {
  const _ConnectEmpty({required this.onConnect, this.onCloudChat});

  final VoidCallback onConnect;

  /// M3.0：不连电脑，直接用 API Key 云端对话。
  final VoidCallback? onCloudChat;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const AppMark(size: 58),
            const SizedBox(height: 26),
            Text(
              '还没有连接电脑',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: palette.text,
                fontSize: 22,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '连接后在这里和电脑上的 DeepSeek Harness 对话',
              textAlign: TextAlign.center,
              style: TextStyle(color: palette.text3, fontSize: 13.5, height: 1.6),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: onConnect,
              style: FilledButton.styleFrom(
                backgroundColor: palette.accent,
                foregroundColor: palette.onAccent,
                minimumSize: const Size(0, 44),
                padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 13),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                ),
              ),
              child: const Text(
                '连接你的电脑',
                style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
              ),
            ),
            if (onCloudChat != null) ...[
              const SizedBox(height: 6),
              TextButton.icon(
                onPressed: onCloudChat,
                icon: Icon(Icons.key_rounded, size: 16, color: palette.text2),
                label: Text(
                  '用 API Key 直接对话',
                  style: TextStyle(color: palette.text2, fontSize: 13),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 真实模式下的错误提示条（如 DEVICE_OFFLINE / SESSION_BUSY）。
class _LiveErrorBar extends StatelessWidget {
  const _LiveErrorBar({
    required this.text,
    required this.onDismiss,
    this.onRetry,
  });

  final String text;
  final VoidCallback onDismiss;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Container(
      margin: const EdgeInsets.fromLTRB(AppSpace.page, 6, AppSpace.page, 0),
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
      decoration: BoxDecoration(
        color: palette.dangerSoft,
        borderRadius: BorderRadius.circular(AppRadius.code),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, size: 15, color: palette.danger),
          const SizedBox(width: 7),
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
          if (onRetry != null)
            IconButton(
              tooltip: '重试',
              onPressed: onRetry,
              visualDensity: VisualDensity.compact,
              icon: Icon(
                Icons.refresh_rounded,
                size: 16,
                color: palette.danger,
              ),
            ),
          IconButton(
            tooltip: '关闭提示',
            onPressed: onDismiss,
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.close_rounded, size: 16, color: palette.danger),
          ),
        ],
      ),
    );
  }
}

/// 真实模式下的运行中条（用不确定进度条）。
class _LiveRunningBanner extends StatelessWidget {
  const _LiveRunningBanner({required this.status, required this.onCancel});

  final TaskStatus? status;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final label = status == TaskStatus.waitingApproval
        ? 'AI 等待你的授权'
        : (status?.label ?? 'AI 正在执行任务');
    return Container(
      margin: const EdgeInsets.only(top: 14, right: 40),
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        color: palette.accentSoft,
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 1.8,
                  color: palette.accent,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: palette.accent,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              TextButton(
                onPressed: onCancel,
                style: TextButton.styleFrom(
                  foregroundColor: palette.danger,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 28),
                ),
                child: const Text('取消', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              minHeight: 5,
              backgroundColor: palette.lineSoft,
              valueColor: AlwaysStoppedAnimation<Color>(palette.accent),
            ),
          ),
        ],
      ),
    );
  }
}

class _Composer extends StatefulWidget {
  const _Composer({
    required this.controller,
    this.focusNode,
    required this.onSend,
    required this.onPick,
    required this.running,
    required this.onCancel,
    this.queued = false,
    this.onOpenProjects,
    this.onOpenTasks,
    this.onOpenConnect,
    this.onPickPhoto,
    this.onPickCamera,
    this.onPickFile,
    this.attachmentCount = 0,
    this.uploading = false,
    this.workspaceLabel,
    this.pendingAttachments = const <PendingAttachment>[],
    this.onRemoveAttachment,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final ValueChanged<String> onSend;
  final ValueChanged<String> onPick;
  final bool running;
  final VoidCallback onCancel;

  /// M2.1：当前会话已有一条排队中的指令。
  final bool queued;

  /// M2.9：输入条上方的快捷入口与「+」菜单。
  final VoidCallback? onOpenProjects;
  final VoidCallback? onOpenTasks;
  final VoidCallback? onOpenConnect;

  /// M3.0：照片 / 拍照 / 文件附件。
  final VoidCallback? onPickPhoto;
  final VoidCallback? onPickCamera;
  final VoidCallback? onPickFile;
  final int attachmentCount;
  final bool uploading;

  /// M4.2：附件会落到电脑上的哪个工作区（显示在附件条上，让用户知道文件去哪了）。
  final String? workspaceLabel;

  /// M4.2：当前待发送的附件，直接显示在输入框上方的附件条里（可逐个移除）。
  final List<PendingAttachment> pendingAttachments;
  final ValueChanged<int>? onRemoveAttachment;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    super.dispose();
  }

  void _onTextChanged() {
    if (mounted) setState(() {});
  }

  bool get _hasText => widget.controller.text.trim().isNotEmpty;

  void _showMore() {
    final palette = context.appPalette;
    final actions = <Widget>[
      if (widget.onPickCamera != null)
        _SheetTile(
          icon: Icons.photo_camera_outlined,
          label: '拍照',
          onTap: () {
            Navigator.of(context).pop();
            widget.onPickCamera!();
          },
        ),
      if (widget.onPickPhoto != null)
        _SheetTile(
          icon: Icons.photo_library_outlined,
          label: '照片',
          onTap: () {
            Navigator.of(context).pop();
            widget.onPickPhoto!();
          },
        ),
      if (widget.onPickFile != null)
        _SheetTile(
          icon: Icons.attach_file_rounded,
          label: '文件',
          onTap: () {
            Navigator.of(context).pop();
            widget.onPickFile!();
          },
        ),
      if (widget.onOpenProjects != null)
        _SheetTile(
          icon: Icons.folder_open_rounded,
          label: '全部项目',
          onTap: () {
            Navigator.of(context).pop();
            widget.onOpenProjects!();
          },
        ),
      if (widget.onOpenTasks != null)
        _SheetTile(
          icon: Icons.task_alt_rounded,
          label: '任务中心',
          onTap: () {
            Navigator.of(context).pop();
            widget.onOpenTasks!();
          },
        ),
      if (widget.onOpenConnect != null)
        _SheetTile(
          icon: Icons.settings_ethernet_rounded,
          label: '连接设置',
          onTap: () {
            Navigator.of(context).pop();
            widget.onOpenConnect!();
          },
        ),
    ];
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: palette.card,
      showDragHandle: false,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadius.sheetTop),
        ),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: palette.line,
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                ),
              ),
              const SizedBox(height: 10),
              ...actions,
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final canSend = _hasText || widget.attachmentCount > 0;
    final hasAttachAction =
        widget.onPickCamera != null ||
        widget.onPickPhoto != null ||
        widget.onPickFile != null;
    return Column(
      children: [
        SizedBox(
          height: 34,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            children: [
              if (widget.onOpenProjects != null) ...[
                _QuickChip(
                  icon: Icons.folder_open_rounded,
                  label: '全部项目',
                  onTap: widget.onOpenProjects!,
                ),
                const SizedBox(width: 8),
              ],
              if (hasAttachAction) ...[
                if (widget.onPickCamera != null) ...[
                  _QuickChip(
                    icon: Icons.photo_camera_outlined,
                    label: '拍照',
                    onTap: () => widget.onPickCamera!(),
                  ),
                  const SizedBox(width: 8),
                ],
                if (widget.onPickPhoto != null) ...[
                  _QuickChip(
                    icon: Icons.photo_library_outlined,
                    label: '相册',
                    onTap: () => widget.onPickPhoto!(),
                  ),
                  const SizedBox(width: 8),
                ],
                if (widget.onPickFile != null) ...[
                  _QuickChip(
                    icon: Icons.attach_file_rounded,
                    label: '文件',
                    onTap: () => widget.onPickFile!(),
                  ),
                  const SizedBox(width: 8),
                ],
              ] else ...[
                _QuickChip(
                  icon: Icons.auto_awesome_rounded,
                  label: '总结这次改动',
                  onTap: () => widget.onPick('帮我把最近的改动总结一下'),
                ),
                const SizedBox(width: 8),
                _QuickChip(
                  icon: Icons.terminal_rounded,
                  label: '跑通构建和测试',
                  onTap: () => widget.onPick('写个脚本跑通构建和测试'),
                ),
              ],
            ],
          ),
        ),
        if (hasAttachAction) const SizedBox(height: 8),
        const SizedBox(height: 8),
        // M4.2：附件按钮常驻在输入框上方——拍照 / 相册 / 文件一眼可见，
        // 不用先点「+」再翻二级菜单（电脑端聊天窗也是这个位置）。
        AttachmentBar(
          attachments: widget.pendingAttachments,
          uploading: widget.uploading,
          onRemove: widget.onRemoveAttachment,
          onPickCamera: widget.onPickCamera,
          onPickPhoto: widget.onPickPhoto,
          onPickFile: widget.onPickFile,
          hint: widget.workspaceLabel == null
              ? null
              : '附件会存到电脑「${widget.workspaceLabel}/手机附件」',
        ),
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: palette.card,
              borderRadius: BorderRadius.circular(30),
              border: Border.all(color: palette.line),
              boxShadow: const <BoxShadow>[
                BoxShadow(
                  color: Color(0x0A000000),
                  blurRadius: 18,
                  offset: Offset(0, 6),
                ),
              ],
            ),
            child: Row(
              children: [
                _PlusButton(onTap: _showMore),
                const SizedBox(width: 4),
                Expanded(
                  child: TextField(
                    controller: widget.controller,
                    focusNode: widget.focusNode,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.send,
                    onSubmitted: widget.onSend,
                    style: TextStyle(
                      color: palette.text,
                      fontSize: 15,
                      height: 1.5,
                    ),
                    decoration: InputDecoration(
                      isDense: true,
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(vertical: 10),
                      hintText: widget.queued
                          ? '已排队一条指令，等待当前任务结束后自动发送…'
                          : widget.running
                              ? 'AI 正在执行，可继续输入排队…'
                              : '尽管问，或让电脑上的 AI 做点什么…',
                      hintStyle: TextStyle(
                        color: palette.text3,
                        fontSize: 14.5,
                      ),
                    ),
                  ),
                ),
                if (widget.running)
                  IconButton(
                    tooltip: '取消当前任务',
                    onPressed: widget.onCancel,
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      Icons.stop_circle_outlined,
                      size: 21,
                      color: palette.text3,
                    ),
                  ),
                _SendButton(
                  enabled: canSend && !widget.uploading,
                  onTap: canSend && !widget.uploading
                      ? () => widget.onSend(widget.controller.text)
                      : null,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '内容由 AI 生成',
          style: TextStyle(color: palette.text3, fontSize: 10.5),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

class _PlusButton extends StatelessWidget {
  const _PlusButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: palette.lineSoft,
          shape: BoxShape.circle,
        ),
        child: Icon(Icons.add_rounded, size: 21, color: palette.text2),
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  const _SendButton({required this.enabled, required this.onTap});

  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: enabled ? palette.accent : palette.lineSoft,
          shape: BoxShape.circle,
        ),
        child: Icon(
          Icons.arrow_upward_rounded,
          size: 19,
          color: enabled ? palette.onAccent : palette.text3,
        ),
      ),
    );
  }
}

class _QuickChip extends StatelessWidget {
  const _QuickChip({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Material(
      color: palette.lineSoft,
      borderRadius: BorderRadius.circular(AppRadius.pill),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: palette.text2),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: palette.text2,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SheetTile extends StatelessWidget {
  const _SheetTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        child: Row(
          children: [
            Icon(icon, size: 20, color: palette.text2),
            const SizedBox(width: 14),
            Text(
              label,
              style: TextStyle(
                color: palette.text,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// M2.6：项目内发指令时，输入框上方显示待绑定的工作区胶囊（可移除）。
class _PendingWorkspaceChip extends StatelessWidget {
  const _PendingWorkspaceChip({required this.path, required this.onRemove});

  final String path;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpace.page, 0, AppSpace.page, 6),
      child: Row(
        children: [
          Flexible(
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 5, 4, 5),
              decoration: BoxDecoration(
                color: palette.accentSoft,
                borderRadius: BorderRadius.circular(AppRadius.pill),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.folder_outlined, size: 14, color: palette.accent),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      '项目：${_workspaceNameOf(path)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.accent,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 2),
                  InkWell(
                    onTap: onRemove,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(
                        Icons.close_rounded,
                        size: 14,
                        color: palette.accent,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// M2.9：Kimi 风格空态——正中品牌标记 + 两行问候 + 连接状态胶囊。
class _GreetingBlock extends StatelessWidget {
  const _GreetingBlock({required this.deviceName, required this.onPick});

  final String deviceName;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final name = deviceName.trim().isEmpty ? '电脑' : deviceName.trim();
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 64, 28, 12),
      child: Column(
        children: [
          const AppMark(size: 58),
          const SizedBox(height: 30),
          Text(
            '嗨，今天要和 DeepSeek\n一起做点什么',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: palette.text,
              fontSize: 24,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.4,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 20),
          Material(
            color: palette.lineSoft,
            borderRadius: BorderRadius.circular(AppRadius.pill),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.bolt_rounded, size: 16, color: palette.accent),
                  const SizedBox(width: 6),
                  Text(
                    '已连接 · $name',
                    style: TextStyle(
                      color: palette.accent,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _workspaceNameOf(String path) {
  final normalized = path.replaceAll('\\', '/');
  final segments =
      normalized.split('/').where((segment) => segment.isNotEmpty).toList();
  return segments.isEmpty ? path : segments.last;
}
