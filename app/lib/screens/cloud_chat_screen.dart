import 'package:flutter/material.dart';

import '../services/cloud_chat.dart';
import '../services/cloud_conversations.dart';
import '../services/network_url_policy.dart';
import '../theme/app_theme.dart';
import '../widgets/attachment_bar.dart';
import '../widgets/markdown_text.dart';

/// M3.0：不连电脑也能用——填一个 OpenAI 兼容地址 + API Key，直接在手机上对话。
class CloudChatScreen extends StatefulWidget {
  const CloudChatScreen({
    super.key,
    this.store,
    this.client,
    this.embedded = false,
    this.controller,
    this.onChanged,
    this.caretaker,
    this.conversations,
  });

  final CloudChatStore? store;
  final CloudChatClient? client;

  /// 嵌进首页时不要再套一层 Scaffold/AppBar。
  final bool embedded;

  /// M4.6：首页「手机」档用它打开接口设置。
  final CloudChatController? controller;

  /// M4.6：接口配置变化（读取完成 / 保存后）通知宿主重建顶栏。
  final VoidCallback? onChanged;

  /// M4.8：非图片文件（PDF / Word / Excel…）交给它读成文字再发给模型。
  /// 首页「手机」档会传入「电脑直读」实现；为 null 时只提示文件名。
  final CaretakerReader? caretaker;

  /// M4.27：对话记录的存取（默认写应用私有目录的 `cloud_conversations.json`）。
  final CloudConversationStore? conversations;

  @override
  State<CloudChatScreen> createState() => _CloudChatScreenState();
}

/// M4.6：首页「手机」档没有 AppBar，靠这个 key 调云端页的接口设置弹层。
class CloudChatController {
  _CloudChatScreenState? _state;

  /// M4.6：内嵌在首页时，首页能观察到「云端页有没有配置」，用来决定
  /// 顶栏胶囊是「云端直连 · 未设置」还是「· 模型名」。
  VoidCallback? notifyChanged;

  /// 是否已经填好接口（地址 + Key）。
  bool get isConfigured => _state?._config?.isReady == true;

  String get modelName => _state?._config?.model ?? '';

  /// 打开接口设置（地址 / Key / 模型）。
  Future<void> editConfig() async => _state?._editConfig();

  /// M4.27：首页顶栏那颗「历史」按钮在手机档打开对话记录侧栏。
  Future<void> openHistory() async => _state?._openHistory();

  /// M4.30：「工作区 → 手机对话」点某一条时，切到这条对话。
  Future<void> openConversation(String conversationId) async =>
      _state?.openConversationById(conversationId);
}

class _CloudChatScreenState extends State<CloudChatScreen> {
  late final CloudChatStore _store = widget.store ?? CloudChatStore();
  late final CloudChatClient _client = widget.client ?? CloudChatClient();

  final _controller = TextEditingController();
  final _scroll = ScrollController();
  final List<CloudMessage> _messages = [];

  /// M4.27：手机档的对话记录。以前 `_newChat()` 只是把内存里的消息清空，
  /// 退出页面就全没了；现在每条对话单独存盘，侧边栏里随时切回去接着聊。
  late final CloudConversationStore _conversationStore =
      widget.conversations ?? CloudConversationStore();
  final List<CloudConversation> _conversations = <CloudConversation>[];
  String? _currentConversationId;

  /// M4.39：停在最新一条消息上继续往上拖（手指往上）超过这个距离，松手就开
  /// 一条新对话，不用再去点顶栏那颗按钮；拖的过程中底部浮出一枚加载圈，
  /// 圈填多少跟着手走的距离变。
  static const double _newChatPull = 130;
  double _pullDistance = 0;
  bool _pullArmed = false;

  /// M4.39：这一手是否已经滚过列表（滚动过就不算「停在最新处继续拽」）。
  bool _movedInGesture = false;

  /// M4.7：手机档也能发照片 / 文件（图片直接进视觉模型，文本文件内联）。
  final List<PendingAttachment> _attachments = [];
  final _picker = AttachmentPicker();
  bool _uploading = false;

  CloudChatConfig? _config;
  bool _loading = true;
  bool _sending = false;
  CancellationToken? _cancel;

  @override
  void initState() {
    super.initState();
    widget.controller?._state = this;
    _boundController = widget.controller;
    _boundController?.notifyChanged = _refreshSetup;
    _load();
  }

  /// M4.6：首页用 IndexedStack 常驻两档，云端页会一直活着——没有配置时
  /// 不要一直转圈（那会让页面永不停帧，`pumpAndSettle` 直接超时）。
  CloudChatController? _boundController;

  @override
  void didUpdateWidget(covariant CloudChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      if (oldWidget.controller?._state == this) {
        oldWidget.controller?._state = null;
      }
      widget.controller?._state = this;
      _boundController = widget.controller;
    }
  }

  @override
  void dispose() {
    if (widget.controller?._state == this) {
      widget.controller?._state = null;
    }
    _cancel?.cancel();
    _client.close();
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final config = await _store.load();
    if (!mounted) return;
    setState(() {
      _config = config;
      _loading = false;
    });
    _boundController?.notifyChanged?.call();
    widget.onChanged?.call();
    // M4.27：对话记录单独读，别让它拖住首屏（读盘慢或坏文件时页面也要能开）。
    await _loadConversations();
  }

  Future<void> _loadConversations() async {
    final saved = await _conversationStore.load();
    if (!mounted) return;
    setState(() {
      _conversations
        ..clear()
        ..addAll(saved);
      if (_conversations.isEmpty) {
        final created = _createConversation();
        _conversations.add(created);
      }
      final current = _conversations.firstWhere(
        (item) => item.id == _currentConversationId,
        orElse: () => _conversations.first,
      );
      _currentConversationId = current.id;
      _restoreMessages(current);
    });
    if (saved.isEmpty) await _persist();
  }

  /// M4.27：当前这条对话（侧边栏切换时换的就是它）。
  CloudConversation? get _currentConversation {
    for (final item in _conversations) {
      if (item.id == _currentConversationId) return item;
    }
    return _conversations.isEmpty ? null : _conversations.first;
  }

  CloudConversation _createConversation() => CloudConversation(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

  void _restoreMessages(CloudConversation conversation) {
    _messages
      ..clear()
      ..addAll(
        conversation.messages.map(
          (record) => record.role == 'assistant'
              ? CloudMessage.assistant(record.text)
              : CloudMessage.user(record.text),
        ),
      );
    final last = _messages.isEmpty ? null : _messages.last;
    if (last != null && last.role == 'assistant' && last.text.trim().isEmpty) {
      _messages.removeLast();
    }
  }

  /// M4.27：把内存里的消息写回当前对话（标题取第一句），然后存盘。
  Future<void> _persist() async {
    final conversation = _currentConversation;
    if (conversation == null) return;
    conversation.messages
      ..clear()
      ..addAll(
        _messages
            .where((message) => message.text.trim().isNotEmpty || message.failed)
            .map(
              (message) => CloudChatRecord(
                role: message.role,
                text: message.text,
                failed: message.failed,
              ),
            ),
      );
    if (conversation.title.trim().isEmpty) {
      final firstUser = conversation.messages.firstWhere(
        (record) => record.role == 'user' && record.text.trim().isNotEmpty,
        orElse: () => const CloudChatRecord(role: 'user', text: ''),
      );
      final derived = conversationTitle(firstUser.text);
      if (derived.isNotEmpty) conversation.title = derived;
    }
    conversation.updatedAt = DateTime.now();
    final snapshot = List<CloudConversation>.of(_conversations);
    await _conversationStore.save(snapshot);
  }

  /// M4.6：接口设置变化后同步给首页顶栏。
  void _refreshSetup() {
    if (!mounted) return;
    setState(() {});
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _editConfig() async {
    final result = await showModalBottomSheet<CloudChatConfig>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.appPalette.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.sheetTop)),
      ),
      builder: (context) => _ConfigSheet(initial: _config),
    );
    if (result == null || !mounted) return;
    await _store.save(result);
    setState(() => _config = result);
    _boundController?.notifyChanged?.call();
    widget.onChanged?.call();
    _toast('已保存，可以开始对话了');
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    final config = _config;
    if ((text.isEmpty && _attachments.isEmpty) ||
        _sending ||
        config == null ||
        !config.isReady) {
      return;
    }
    _controller.clear();
    final attachments = List<PendingAttachment>.of(_attachments);
    final assistant = CloudMessage.assistantStreaming();
    setState(() {
      _messages.add(CloudMessage.user(text, attachments: attachments));
      _messages.add(assistant);
      _attachments.clear();
      _sending = true;
      _cancel = CancellationToken();
    });
    _scrollToEnd();
    // M4.27：先把这一问存下来，后面就算网络断了也不会丢。
    _persist();
    try {
      final reply = await _client.complete(
        config: config,
        history: _messages.where((message) => !message.streaming).toList(),
        cancel: _cancel,
        caretaker: widget.caretaker,
        onDelta: (delta) {
          if (!mounted) return;
          setState(() => assistant.text += delta);
          _scrollToEnd();
        },
      );
      if (!mounted) return;
      setState(() {
        assistant.streaming = false;
        if (reply.trim().isEmpty && assistant.text.trim().isEmpty) {
          assistant.failed = true;
          assistant.text = '模型没有返回内容，换个说法再试一次。';
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        assistant.streaming = false;
        assistant.failed = true;
        assistant.text = '$error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
          _cancel = null;
        });
        // M4.27：回复（或失败原因）也要落盘，下次打开还能看到。
        _persist();
      }
    }
  }

  void _stop() {
    _cancel?.cancel();
    setState(() => _sending = false);
  }

  // ---- M4.7 附件：拍照 / 相册 / 文件 ----

  Future<void> _pickCamera() async {
    setState(() => _uploading = true);
    try {
      final picked = await _picker.pickCamera();
      if (!mounted) return;
      if (picked != null) setState(() => _attachments.add(picked));
    } catch (error) {
      _toast('拍照失败：$error');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _pickPhotos() async {
    setState(() => _uploading = true);
    try {
      final picked = await _picker.pickPhotos();
      if (!mounted) return;
      if (picked.isNotEmpty) setState(() => _attachments.addAll(picked));
    } catch (error) {
      _toast('选照片失败：$error');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _pickFiles() async {
    setState(() => _uploading = true);
    try {
      final picked = await _picker.pickFiles();
      if (!mounted) return;
      if (picked.isNotEmpty) setState(() => _attachments.addAll(picked));
    } catch (error) {
      _toast('选文件失败：$error');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  void _removeAttachment(int index) {
    if (index < 0 || index >= _attachments.length) return;
    setState(() => _attachments.removeAt(index));
  }

  /// 测试用：往待发送附件里塞一个文件。
  @visibleForTesting
  void attachForTest({required String name, required List<int> bytes}) {
    setState(() => _attachments.add(PendingAttachment(name: name, bytes: bytes)));
  }

  /// 测试用：走与点发送按钮完全相同的路径。
  @visibleForTesting
  Future<void> sendForTest(String text) async {
    _controller.text = text;
    await _send();
  }

  @visibleForTesting
  List<PendingAttachment> get pendingAttachmentsForTest =>
      List<PendingAttachment>.of(_attachments);

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent + 120,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  /// M4.39：在最新那条消息下面继续往上滑，滑够了松手就新建对话。
  ///
  /// M4.37 把方向做反了：它要人先翻到最老的那一条，再往下拽。实际用起来是
  /// 「已经停在新消息上，手指往上滑」——那才是顺手的方向，抖音/豆包这类也是
  /// 往上滑出一个加载圈。这里只认这一侧的越界量（`overscroll > 0`），正常翻
  /// 历史不会触发。
  bool _onScrollNotification(ScrollNotification notification) {
    if (notification is ScrollStartNotification) {
      _movedInGesture = false;
      if (_pullArmed || _pullDistance != 0) {
        setState(() {
          _pullDistance = 0;
          _pullArmed = false;
        });
      }
      return false;
    }
    if (notification is OverscrollNotification) {
      // M4.39：这一手只要中途滚过（`_movedInGesture`），就不算「停在最新处
      // 继续往上拽」——否则从半路一甩到底也会攒够越界量，手一松就把对话
      // 换掉。要新建就再单独拽一下。
      if (notification.overscroll > 0 && !_movedInGesture) {
        _pullDistance += notification.overscroll;
        final armed = _pullDistance >= _newChatPull;
        // M4.39：加载圈的进度跟着手走，所以每一点位移都要重画，不能只在
        // 「过阈值」那一刻 setState 一次（那样圈是死的）。
        setState(() => _pullArmed = armed);
      } else if (_pullDistance > 0) {
        // 手指反向拖回来，越界量跟着退。
        _pullDistance += notification.overscroll;
        if (_pullDistance < 0) _pullDistance = 0;
        setState(() => _pullArmed = _pullDistance >= _newChatPull);
      }
      return false;
    }
    if (notification is ScrollUpdateNotification) {
      // 列表真的开始滚了说明已经离开这一端，作废这次「拽出新建」。
      _movedInGesture = true;
      if (_pullArmed || _pullDistance != 0) {
        setState(() {
          _pullDistance = 0;
          _pullArmed = false;
        });
      }
      return false;
    }
    if (notification is ScrollEndNotification) {
      final armed = _pullArmed;
      if (armed) {
        setState(() {
          _pullDistance = 0;
          _pullArmed = false;
        });
        _newChat();
      } else if (_pullDistance != 0) {
        setState(() => _pullDistance = 0);
      }
      return false;
    }
    return false;
  }

  void _newChat() {
    if (_sending) _stop();
    // M4.27：当前这条还空着就直接复用，别每点一次就多一条空记录。
    final current = _currentConversation;
    if (current != null && current.messages.isEmpty) {
      setState(_messages.clear);
      return;
    }
    final created = _createConversation();
    setState(() {
      _conversations.insert(0, created);
      _currentConversationId = created.id;
      _messages.clear();
    });
    _persist();
  }

  /// M4.27：侧边栏里切到另一条对话。
  void _switchConversation(String id) {
    if (id == _currentConversationId) return;
    if (_sending) _stop();
    setState(() {
      _currentConversationId = id;
      final conversation = _currentConversation;
      if (conversation != null) _restoreMessages(conversation);
    });
    _scrollToEnd();
  }

  /// M4.30：「工作区 → 手机对话」点进来时，直接切到那一条。
  ///
  /// 如果内存里还没有这条（比如刚从别的页面进来），先读一次盘再切。
  Future<void> openConversationById(String conversationId) async {
    if (conversationId.trim().isEmpty) return;
    if (_conversations.isEmpty) await _loadConversations();
    if (!mounted) return;
    if (_conversations.every((item) => item.id != conversationId)) {
      await _loadConversations();
      if (!mounted) return;
    }
    if (_conversations.every((item) => item.id != conversationId)) return;
    _switchConversation(conversationId);
  }

  Future<void> _deleteConversation(String id) async {
    if (_sending && id == _currentConversationId) _stop();
    setState(() {
      _conversations.removeWhere((item) => item.id == id);
      if (_conversations.isEmpty) {
        _conversations.add(_createConversation());
      }
      if (_currentConversationId == id || _currentConversation == null) {
        _currentConversationId = _conversations.first.id;
        _restoreMessages(_conversations.first);
      }
    });
    await _persist();
  }

  /// M4.27：从左侧滑出的对话记录（首页顶栏那颗「历史」按钮也走这里）。
  Future<void> _openHistory() async {
    if (!mounted) return;
    final palette = context.appPalette;
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '对话记录',
      barrierColor: Colors.black.withValues(alpha: 0.32),
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (context, animation, secondaryAnimation) => Align(
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: 0.82,
          heightFactor: 1,
          child: Material(
            color: palette.bg,
            child: SafeArea(
              child: _ConversationPanel(
                conversations: List<CloudConversation>.of(_conversations),
                currentId: _currentConversationId,
                palette: palette,
                onNew: () {
                  Navigator.of(context).pop();
                  _newChat();
                },
                onSelect: (id) {
                  Navigator.of(context).pop();
                  _switchConversation(id);
                },
                onDelete: (id) => _deleteConversation(id),
              ),
            ),
          ),
        ),
      ),
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final offset =
            Tween<Offset>(begin: const Offset(-1, 0), end: Offset.zero)
                .chain(CurveTween(curve: Curves.easeOutCubic))
                .animate(animation);
        return SlideTransition(position: offset, child: child);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final ready = _config?.isReady == true;
    final body = SafeArea(
      top: false,
      child: _loading
          // M4.6：转圈动画会让整页永不停帧（首页两档常驻时 pumpAndSettle 会超时），
          // 这里改成静态占位 + 一行说明。
          ? Center(
              child: Text(
                '正在读取云端接口设置…',
                style: TextStyle(color: palette.text3, fontSize: 12.5),
              ),
            )
          : Column(
              children: [
                Expanded(
                  child: ready
                      ? _buildMessages(palette)
                      : _SetupHint(onSetup: _editConfig, palette: palette),
                ),
                if (ready)
                  _CloudComposer(
                    controller: _controller,
                    sending: _sending,
                    onSend: _send,
                    onStop: _stop,
                    model: _config?.model ?? '',
                    attachments: _attachments,
                    uploading: _uploading,
                    onRemoveAttachment: _removeAttachment,
                    onPickCamera: _pickCamera,
                    onPickPhoto: _pickPhotos,
                    onPickFile: _pickFiles,
                  ),
              ],
            ),
    );
    if (widget.embedded) return body;
    return Scaffold(
      backgroundColor: palette.bg,
      appBar: AppBar(
        backgroundColor: palette.bg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text(
          '云端对话',
          style: TextStyle(
            color: palette.text,
            fontSize: 20,
            fontWeight: FontWeight.w600,
          ),
        ),
        actions: [
          IconButton(
            tooltip: '对话记录',
            onPressed: _openHistory,
            icon: Icon(Icons.history_rounded, color: palette.text2),
          ),
          if (_messages.isNotEmpty)
            IconButton(
              tooltip: '新对话',
              onPressed: _newChat,
              icon: Icon(Icons.add_comment_outlined, color: palette.text2),
            ),
          IconButton(
            tooltip: '接口设置',
            onPressed: _editConfig,
            icon: Icon(Icons.tune_rounded, color: palette.text2),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: body,
    );
  }

  Widget _buildMessages(AppPalette palette) {
    if (_messages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 36),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_outlined, size: 30, color: palette.text3),
              const SizedBox(height: 12),
              Text(
                '云端直连',
                style: TextStyle(
                  color: palette.text,
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '用 ${_config?.model ?? '模型'} 直接对话，不经电脑。\n下面可以拍照、选相册或发文件。',
                textAlign: TextAlign.center,
                style: TextStyle(color: palette.text3, fontSize: 12.5, height: 1.6),
              ),
            ],
          ),
        ),
      );
    }
    final list = ListView.builder(
      controller: _scroll,
      // M4.39：即使内容不够一屏也要能拖（否则在短对话里没法用「往上滑新建」）。
      physics: const AlwaysScrollableScrollPhysics(
        parent: ClampingScrollPhysics(),
      ),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      itemCount: _messages.length,
      itemBuilder: (context, index) => _Bubble(
        message: _messages[index],
        palette: palette,
      ),
    );
    return NotificationListener<ScrollNotification>(
      onNotification: _onScrollNotification,
      child: Stack(
        children: [
          list,
          if (_pullDistance > 0)
            Positioned(
              bottom: 10,
              left: 0,
              right: 0,
              child: Center(
                child: _NewChatPullHint(
                  palette: palette,
                  progress: (_pullDistance / _newChatPull).clamp(0.0, 1.0),
                  armed: _pullArmed,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// M4.39：往上滑时浮在底部的那枚加载圈。
///
/// 圈里填多少跟着手指走的距离变（`progress`），滑过阈值就补满并换成
/// 「松手开始新对话」；松手就开新对话，中途退回去它自己消失。
class _NewChatPullHint extends StatelessWidget {
  const _NewChatPullHint({
    required this.palette,
    required this.progress,
    required this.armed,
  });

  final AppPalette palette;
  final double progress;
  final bool armed;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: palette.accentSoft,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              value: progress,
              strokeWidth: 2.2,
              backgroundColor: palette.accent.withValues(alpha: 0.18),
              valueColor: AlwaysStoppedAnimation<Color>(palette.accent),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            armed ? '松手开始新对话' : '继续上滑新建对话',
            style: TextStyle(
              color: palette.accent,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.palette});

  final CloudMessage message;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == 'user';
    final text = message.text.isEmpty && message.streaming ? '…' : message.text;
    final attachments = message.attachments;
    // M4.12：双方都按 Markdown 排（官方 App 的输入框也支持 `代码`、列表）。
    // 助手去气泡打字，用户保持右侧浅色气泡。
    final body = isUser
        ? Text(
            text,
            style: TextStyle(
              color: message.failed ? palette.danger : palette.bubbleUserText,
              fontSize: 14.5,
              height: 1.65,
            ),
          )
        : DefaultTextStyle.merge(
            style: TextStyle(
              color: message.failed ? palette.danger : palette.text,
              fontSize: 15,
              height: 1.75,
            ),
            child: MarkdownText(text),
          );
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: EdgeInsets.symmetric(
        horizontal: isUser ? 14 : 0,
        vertical: isUser ? 10 : 0,
      ),
      decoration: isUser
          ? BoxDecoration(
              color: palette.bubbleUser,
              borderRadius: BorderRadius.circular(AppRadius.bubble),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (attachments.isNotEmpty)
            AttachmentThumbnails(
              attachments: attachments,
              onLight: isUser,
            ),
          if (attachments.isNotEmpty && text.isNotEmpty)
            const SizedBox(height: 6),
          if (text.isNotEmpty) body,
        ],
      ),
    );
  }
}

class _SetupHint extends StatelessWidget {
  const _SetupHint({required this.onSetup, required this.palette});

  final VoidCallback onSetup;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.key_rounded, size: 30, color: palette.text3),
            const SizedBox(height: 12),
            Text(
              '填一个 API Key 就能用',
              style: TextStyle(
                color: palette.text,
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '本机对话不经过电脑，直接用你自己的 API Key 回答，\n不连电脑也能用。',
              textAlign: TextAlign.center,
              style: TextStyle(color: palette.text3, fontSize: 12.5, height: 1.7),
            ),
            const SizedBox(height: 6),
            Text(
              '支持 DeepSeek、Kimi、OpenAI 等 OpenAI 兼容接口；\n要发图片，选支持视觉的模型（如 gpt-4o、Kimi vision）。',
              textAlign: TextAlign.center,
              style: TextStyle(color: palette.text3, fontSize: 11.5, height: 1.6),
            ),
            const SizedBox(height: 6),
            Text(
              'Key 只保存在这台手机上。',
              textAlign: TextAlign.center,
              style: TextStyle(color: palette.text3, fontSize: 11, height: 1.5),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: onSetup,
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 44),
                shape: const StadiumBorder(),
              ),
              child: const Text('填写 API Key'),
            ),
            const SizedBox(height: 6),
            _StepsBlock(palette: palette),
          ],
        ),
      ),
    );
  }
}

/// M4.8：首次使用的两步说明（去官网生成 Key → 回这里粘贴）。
class _StepsBlock extends StatelessWidget {
  const _StepsBlock({required this.palette});

  final AppPalette palette;

  static const _steps = <String>[
    '去 DeepSeek 开放平台（platform.deepseek.com）生成一个 API Key',
    '回到这里点「填写 API Key」粘贴进去，接口地址与模型保持默认即可',
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var index = 0; index < _steps.length; index++)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 18,
                  height: 18,
                  margin: const EdgeInsets.only(top: 1),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: palette.accentSoft,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Text(
                    '${index + 1}',
                    style: TextStyle(
                      color: palette.accent,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _steps[index],
                    style: TextStyle(
                      color: palette.text3,
                      fontSize: 11.5,
                      height: 1.55,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _CloudComposer extends StatelessWidget {
  const _CloudComposer({
    required this.controller,
    required this.sending,
    required this.onSend,
    required this.onStop,
    required this.model,
    this.attachments = const <PendingAttachment>[],
    this.uploading = false,
    this.onRemoveAttachment,
    this.onPickCamera,
    this.onPickPhoto,
    this.onPickFile,
  });

  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;
  final VoidCallback onStop;
  final String model;
  final List<PendingAttachment> attachments;
  final bool uploading;
  final ValueChanged<int>? onRemoveAttachment;
  final Future<void> Function()? onPickCamera;
  final Future<void> Function()? onPickPhoto;
  final Future<void> Function()? onPickFile;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final hasAttach = onPickCamera != null ||
        onPickPhoto != null ||
        onPickFile != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
      child: Column(
        children: [
          // M4.7：与电脑档同一套附件条——拍照 / 相册 / 文件常驻可见。
          if (hasAttach)
            AttachmentBar(
              attachments: attachments,
              uploading: uploading,
              onRemove: onRemoveAttachment,
              onPickCamera: onPickCamera == null ? null : () => onPickCamera!(),
              onPickPhoto: onPickPhoto == null ? null : () => onPickPhoto!(),
              onPickFile: onPickFile == null ? null : () => onPickFile!(),
              hint: '图片和文本直接发给模型',
            ),
          if (hasAttach) const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.fromLTRB(16, 4, 6, 4),
            decoration: BoxDecoration(
              color: palette.card,
              borderRadius: BorderRadius.circular(30),
              border: Border.all(color: palette.line),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x0A000000),
                  blurRadius: 18,
                  offset: Offset(0, 6),
                ),
              ],
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: controller,
                    minLines: 1,
                    maxLines: 5,
                    textInputAction: TextInputAction.newline,
                    style: TextStyle(color: palette.text, fontSize: 15),
                    decoration: InputDecoration(
                      hintText: '说点什么…',
                      hintStyle: TextStyle(color: palette.text3, fontSize: 15),
                      border: InputBorder.none,
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                if (sending)
                  IconButton(
                    tooltip: '停止生成',
                    onPressed: onStop,
                    icon: Icon(Icons.stop_circle_outlined,
                        color: palette.text3, size: 24),
                  )
                else
                  IconButton(
                    tooltip: '发送',
                    onPressed: onSend,
                    icon: Icon(Icons.arrow_upward_rounded,
                        color: palette.accent, size: 22),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            model.isEmpty ? '云端直连' : model,
            style: TextStyle(color: palette.text3, fontSize: 10.5),
          ),
        ],
      ),
    );
  }
}

class _ConfigSheet extends StatefulWidget {
  const _ConfigSheet({this.initial});

  final CloudChatConfig? initial;

  @override
  State<_ConfigSheet> createState() => _ConfigSheetState();
}

class _ConfigSheetState extends State<_ConfigSheet> {
  late final TextEditingController _base =
      TextEditingController(text: widget.initial?.baseUrl ?? 'https://api.deepseek.com/v1');
  late final TextEditingController _model =
      TextEditingController(text: widget.initial?.model ?? 'deepseek-chat');
  late final TextEditingController _key =
      TextEditingController(text: widget.initial?.apiKey ?? '');

  String? _error;

  @override
  void dispose() {
    _base.dispose();
    _model.dispose();
    _key.dispose();
    super.dispose();
  }

  void _submit() {
    var base = _base.text.trim();
    final key = _key.text.trim();
    final model = _model.text.trim();
    // M4.44：公网明文接口一律拒绝（Key 与对话内容都会裸奔），内网明文放行。
    final check = NetworkUrlPolicy.inspect(base);
    if (!check.allowed) {
      setState(() => _error = check.error);
      return;
    }
    base = check.uri.toString();
    if (key.isEmpty) {
      setState(() => _error = 'API Key 不能为空');
      return;
    }
    if (model.isEmpty) {
      setState(() => _error = '模型名不能为空');
      return;
    }
    Navigator.of(context).pop(CloudChatConfig(
      baseUrl: base,
      apiKey: key,
      model: model,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, 16 + inset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '接口设置',
            style: TextStyle(
              color: palette.text,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'OpenAI 兼容接口。Key 只存在本机。',
            style: TextStyle(color: palette.text3, fontSize: 12),
          ),
          const SizedBox(height: 14),
          _Field(label: '接口地址', controller: _base, hint: 'https://api.deepseek.com/v1'),
          const SizedBox(height: 10),
          _Field(label: '模型', controller: _model, hint: 'deepseek-chat'),
          const SizedBox(height: 10),
          _Field(label: 'API Key', controller: _key, hint: 'sk-…', obscure: true),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, style: TextStyle(color: palette.danger, fontSize: 12)),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, 46)),
                  child: const Text('取消'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: _submit,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 46),
                    shape: const StadiumBorder(),
                  ),
                  child: const Text('保存'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.controller,
    required this.hint,
    this.obscure = false,
  });

  final String label;
  final TextEditingController controller;
  final String hint;
  final bool obscure;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: palette.text2, fontSize: 12)),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          obscureText: obscure,
          autocorrect: false,
          enableSuggestions: false,
          style: TextStyle(color: palette.text, fontSize: 14),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: palette.text3, fontSize: 13),
            isDense: true,
            filled: true,
            fillColor: palette.lineSoft,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      ],
    );
  }
}

/// M4.27：左侧滑出的对话记录（像豆包的会话列表：新对话 + 最近用过的对话）。
class _ConversationPanel extends StatelessWidget {
  const _ConversationPanel({
    required this.conversations,
    required this.currentId,
    required this.palette,
    required this.onNew,
    required this.onSelect,
    required this.onDelete,
  });

  final List<CloudConversation> conversations;
  final String? currentId;
  final AppPalette palette;
  final VoidCallback onNew;
  final ValueChanged<String> onSelect;
  final ValueChanged<String> onDelete;

  @override
  Widget build(BuildContext context) {
    final sorted = List<CloudConversation>.of(conversations);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 8, 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '对话记录',
                  style: TextStyle(
                    color: palette.text,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: onNew,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('新对话'),
                style: TextButton.styleFrom(foregroundColor: palette.accent),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: palette.line),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 6),
            itemCount: sorted.length,
            itemBuilder: (context, index) {
              final item = sorted[index];
              final active = item.id == currentId;
              return Material(
                color: active ? palette.accentSoft : Colors.transparent,
                child: InkWell(
                  onTap: () => onSelect(item.id),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
                    child: Row(
                      children: [
                        Icon(
                          Icons.chat_bubble_outline_rounded,
                          size: 16,
                          color: active ? palette.accent : palette.text3,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                item.displayTitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: palette.text,
                                  fontSize: 14,
                                  fontWeight:
                                      active ? FontWeight.w600 : FontWeight.w400,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                _conversationSubtitle(item),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: palette.text3,
                                  fontSize: 11.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: '删除这条对话',
                          onPressed: () => onDelete(item.id),
                          icon: Icon(
                            Icons.delete_outline_rounded,
                            size: 18,
                            color: palette.text3,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        Divider(height: 1, color: palette.line),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
          child: Text(
            '共 ${conversations.length} 条对话 · 只存在这台手机上',
            style: TextStyle(color: palette.text3, fontSize: 11.5),
          ),
        ),
      ],
    );
  }
}

String _conversationSubtitle(CloudConversation conversation) {
  final count = conversation.messages.length;
  final when = _relativeTime(conversation.updatedAt);
  return count == 0 ? '还没有说话 · $when' : '$count 条消息 · $when';
}

String _relativeTime(DateTime time) {
  final diff = DateTime.now().difference(time);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  if (diff.inHours < 24) return '${diff.inHours} 小时前';
  if (diff.inDays < 8) return '${diff.inDays} 天前';
  final month = time.month.toString().padLeft(2, '0');
  final day = time.day.toString().padLeft(2, '0');
  return '${time.year}-$month-$day';
}