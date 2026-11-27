import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../models.dart';
import '../services/desktop_sort.dart';
import '../services/history_api.dart';
import '../services/notification_gateway.dart';
import '../services/notification_prefs.dart';
import '../services/pairing_api.dart';
import '../services/relay_client.dart';
import '../services/relay_protocol.dart';
import '../services/session_store.dart';
import '../services/workspace_models.dart';

/// 真实连接状态（UI 只关心这 4 种）。
enum LiveConnectionState { idle, connecting, connected, error }

/// M4.43：抽屉与顶栏「历史会话」用的一行。
///
/// 以前这两个入口读 `liveStore.conversations`，而那是 M1.1 老后端的
/// `/api/v1/conversations`——插件直连下这个路由根本不存在，所以永远是空的。
/// 现在换成插件真实提供的两处数据：桌面会话镜像（[LiveStore.tasks]）与
/// 存档里当前列表已经没有的会话（[LiveStore.hiddenArchivedSessions]）。
class RecentDesktopSession {
  const RecentDesktopSession({
    required this.id,
    required this.title,
    this.lastTime = 0,
    this.archived = false,
  });

  final String id;
  final String title;

  /// 毫秒时间戳；0 表示不知道，排序时沉底。
  final int lastTime;

  /// true 表示这条只在存档里（电脑上已经看不到），点开要用只读直播。
  final bool archived;
}

/// 配对函数，可注入（单测里替换掉真实 HTTP）。
typedef PairFunction = Future<PairResult> Function(
    String baseUrl, String pairingCode);

/// M4.44：紧急停止的真实结果。
///
/// 以前「紧急停止」按钮只做了一件事——`disconnect()`。用户看到「已断开」会
/// 以为电脑上的任务停了，实际上电脑可能还在跑，只是手机不再看它。现在拆成三种
/// 结果，界面必须如实说明究竟做到了哪一步。
enum EmergencyStopOutcome {
  /// 电脑确认任务已进入终态（完成/失败/取消），然后才断开。
  taskCancelled,

  /// 本来就没有在跑的任务，只断了连接。
  disconnectedOnly,

  /// 发了取消请求但电脑没在超时内确认——只断了连接，任务可能还在跑。
  cancelUnconfirmed,
}

/// 紧急停止的结果，附一句可以直接展示给用户的人话。
class EmergencyStopResult {
  const EmergencyStopResult(this.outcome, this.detail);

  final EmergencyStopOutcome outcome;
  final String detail;

  /// 只有这一种才算「电脑上的任务真的停了」。
  bool get taskStopped => outcome == EmergencyStopOutcome.taskCancelled;
}


/// 一条待处理的授权请求。
class PendingApproval {
  PendingApproval({required this.info, DateTime? receivedAt})
      : receivedAt = receivedAt ?? DateTime.now();

  final ApprovalRequestInfo info;
  final DateTime receivedAt;

  String get tool => info.tool;
  String get command => info.command;
  String get workspace => info.workspace;
  String get approvalId => info.approvalId;
}

/// 真实连接数据源：把中继 WebSocket 消息翻译成聊天视图模型。
///
/// - 状态：连接状态、设备状态、消息列表、任务状态、待授权请求、错误文本。
/// - 不依赖 Flutter UI，`applyEvent` 是公开的纯状态迁移入口，方便单测。
class LiveStore extends ChangeNotifier {
  LiveStore({
    RelayClient? relayClient,
    PairFunction? pairer,
    PairingApi? pairingApi,
    HistoryApi? historyApi,
    NotificationGateway? notificationGateway,
    SessionStore? sessionStore,
    this.interruptTimeout = const Duration(seconds: 3),
    this.workspaceRequestTimeout = defaultWorkspaceRequestTimeout,
  })  : _relay = relayClient ?? RelayClient(),
        _pairingApi = pairingApi ?? PairingApi(),
        _historyApi = historyApi ?? HistoryApi(),
        _pairer = pairer,
        _notifications = notificationGateway,
        _sessionStore = sessionStore {
    _eventSubscription = _relay.events.listen(applyEvent);
    _stateSubscription = _relay.states.listen(_onRelayState);
    _authSubscription = _relay.authFailures.listen((_) {
      unawaited(_handleAuthFailure());
    });
  }

  /// 默认配对码（与契约默认值一致）。
  static const String defaultPairingCode = '000000';

  /// M2.2 A2：点「立即发送」后等待打断生效的兜底时长。
  final Duration interruptTimeout;

  /// M2.6：项目同步请求（workspace.list / file.read）的默认超时。
  static const Duration defaultWorkspaceRequestTimeout = Duration(seconds: 20);

  /// M2.6：项目同步请求的超时（单测可注入更短的值）。
  final Duration workspaceRequestTimeout;

  /// 默认服务器地址占位（连接页会把它放进输入框）。
  /// M4.44：不再内置任何个人内网地址——正式包交给用户扫码或手填。
  /// 想在某次构建里预填，用 `--dart-define=DSH_DEFAULT_SERVER=https://...`。
  static const String defaultServerUrl = String.fromEnvironment(
    'DSH_DEFAULT_SERVER',
    defaultValue: '',
  );

  final RelayClient _relay;
  final PairingApi _pairingApi;
  final HistoryApi _historyApi;
  final PairFunction? _pairer;
  final NotificationGateway? _notifications;
  final SessionStore? _sessionStore;

  late final StreamSubscription<RelayEvent> _eventSubscription;
  late final StreamSubscription<RelayClientState> _stateSubscription;
  StreamSubscription<void>? _authSubscription;
  StreamSubscription<String>? _tapSubscription;

  final List<ChatItem> _messages = <ChatItem>[];
  final Map<String, int> _toolCallIndex = <String, int>{};

  LiveConnectionState _connectionState = LiveConnectionState.idle;
  String _serverUrl = '';
  String _pairingCode = defaultPairingCode;
  String? _token;
  String? _deviceId;
  DeviceStatusInfo? _deviceStatus;
  TaskStatus? _taskState;
  PendingApproval? _pendingApproval;
  String? _errorText;
  String? _conversationId;
  String? _sessionId;
  String? _workspacePath;
  List<String> _workspaceRoots = const <String>[];
  int? _contextUsed;
  int? _contextSize;
  String? _queuedPrompt;
  bool _conversationRequested = false;
  bool _wasConnectedBefore = false;
  DateTime? _lastReconnectNoticeAt;
  bool _disposed = false;

  // ---- M1.1 REST 状态（历史会话 / 任务） ----
  final List<ConversationSummary> _conversations = <ConversationSummary>[];
  bool _conversationsLoading = false;
  String? _conversationsError;
  bool _conversationsFetched = false;
  final List<TaskItem> _tasks = <TaskItem>[];
  bool _tasksLoading = false;
  String? _tasksError;
  DateTime? _tasksFetchedAt;
  bool _tasksFetched = false;
  TaskRecord? _selectedTask;
  bool _taskDetailLoading = false;
  String? _taskDetailError;
  bool _historyLoading = false;
  String? _historyError;
  int _lastSeq = 0;
  bool _historyLoaded = false;

  /// 是否用过 REST（纯 WebSocket 的单测不会触碰网络）。
  bool _restUsed = false;

  // ---- M2 通知 / 前台服务 / 自动重配对 ----
  bool _appInForeground = true;
  bool _notificationsInitialized = false;
  bool _permissionRequested = false;
  String? _foregroundDeviceName;
  bool _reauthInFlight = false;
  int _reauthAttempts = 0;
  String? _approvalToOpenId;
  bool _disconnectedNoticeShown = false;

  // ---- M4.4 任务完成 / 等待授权通知 ----
  /// 通知偏好（注入后从手机本地读取；为空时用默认「开启」）。
  NotificationPrefs _notifyPrefs = NotificationPrefs();
  StreamSubscription<ApprovalDecisionResult>? _decisionSubscription;

  /// M4.4：用户点了「任务完成」通知后要切到的页（'tasks'），RootShell 消费后清空。
  String? _pendingNotificationRoute;

  String? get pendingNotificationRoute => _pendingNotificationRoute;

  /// RootShell 打开目标页后调用。
  void clearPendingNotificationRoute() {
    if (_pendingNotificationRoute == null) return;
    _pendingNotificationRoute = null;
    _notify();
  }

  /// 每个会话上次看到的「忙碌」状态与最近任务状态（用于判断是否刚做完）。
  final Map<String, bool> _taskBusyByKey = <String, bool>{};
  final Map<String, TaskStatus> _taskStatusByKey = <String, TaskStatus>{};
  bool _tasksSnapshotPrimed = false;

  /// 等待授权通知里的 id（避免重复弹多条）。
  String? _approvalNoticeId;

  /// M4.35：已经为哪些 questionId 发过「等你回答」通知（回答完或超时后收回）。
  final Set<String> _questionNotices = <String>{};

  // ---- M2.1 事件补拉 / 排队指令 ----
  /// 已应用过的事件 seq（历史 messages / 实时帧 / 补拉共用，用于去重）。
  final Set<int> _seenSeqs = <int>{};
  bool _catchUpLoading = false;
  String? _catchUpError;
  DateTime? _lastCatchUpAt;

  /// 服务端没有实现增量事件接口（M2.8：插件直连只有中继、没有历史接口）。
  /// 命中一次 404 后本会话不再补拉，也不弹「同步失败」——插件模式下没有事件可补。
  bool _eventsUnavailable = false;

  /// 插件直连没有任务列表/详情的 REST 接口（M2.9.1）：命中 404 后不再请求，
  /// 任务改由 WSS 的 `task.state` / `session.update` 推送维护。
  bool _tasksRestUnavailable = false;

  /// M4.10：电脑端存档的会话（DSH 重启后列表里会丢的那些）。
  List<ArchivedSession> _archivedSessions = const <ArchivedSession>[];
  bool _archiveLoading = false;
  String? _archiveError;
  bool _archiveUnavailable = false;

  /// 排队指令气泡在 [_messages] 中的下标（队列深度 1）。
  int? _queuedTurnIndex;

  // ---- M2.2 轮次（完成自动折叠）与「立即发送」 ----
  /// 每轮的统计信息（turnId → TurnStats），供 UI 折叠已完成轮使用。
  final Map<int, TurnStats> _turns = <int, TurnStats>{};
  int _turnCounter = 0;
  int? _currentTurnId;
  bool _interruptInFlight = false;
  Timer? _interruptTimer;

  // ---- M4.44 紧急停止 ----
  /// 等「电脑把这一轮跑到终态」的哨兵；`_applyTaskState` 收到终态时兑现。
  Completer<bool>? _taskTerminalWaiter;

  /// 紧急停止正在执行（同一时刻只允许一次）。
  bool _emergencyStopInFlight = false;

  // ---- M2.6 项目同步（workspace.list / file.read 请求-响应） ----
  /// 挂起的项目同步请求：requestId → Completer。
  final Map<String, _PendingWorkspaceRequest> _pendingWorkspaceRequests =
      <String, _PendingWorkspaceRequest>{};
  int _workspaceRequestCounter = 0;

  /// 下一个新会话要绑定到的工作区（项目内发指令）。
  String? _pendingWorkspacePath;

  // ---- 只读状态 ----

  LiveConnectionState get connectionState => _connectionState;

  String get serverUrl => _serverUrl;

  String get pairingCode => _pairingCode;

  String? get token => _token;

  String? get deviceId => _deviceId;

  DeviceStatusInfo? get deviceStatus => _deviceStatus;

  UnmodifiableListView<ChatItem> get messages =>
      UnmodifiableListView<ChatItem>(_messages);

  TaskStatus? get taskState => _taskState;

  PendingApproval? get pendingApproval => _pendingApproval;

  String? get errorText => _errorText;

  String? get conversationId => _conversationId;

  String? get sessionId => _sessionId;

  String? get workspacePath => _workspacePath;

  // ---- M2.6 项目同步 ----

  /// 下一个新会话要绑定到的工作区（项目内发指令时设置）。
  String? get pendingWorkspacePath => _pendingWorkspacePath;

  /// 电脑端 Agent 是否支持目录浏览（`capabilities.workspaceList`）。
  bool get canListWorkspace =>
      _deviceStatus?.capabilities['workspaceList'] == true;

  /// 电脑端 Agent 是否支持文件读取（`capabilities.fileRead`）。
  bool get canReadWorkspaceFiles =>
      _deviceStatus?.capabilities['fileRead'] == true;

  /// 电脑端 Agent 是否支持写入（`capabilities.fileWrite`，M2.8）。
  bool get canWriteWorkspaceFiles =>
      _deviceStatus?.capabilities['fileWrite'] == true;

  /// 当前挂起的项目同步请求数（调试/单测用）。
  int get pendingWorkspaceRequestCount => _pendingWorkspaceRequests.length;

  List<String> get workspaceRoots =>
      List<String>.unmodifiable(_workspaceRoots);

  int? get contextUsed => _contextUsed;

  int? get contextSize => _contextSize;

  // ---- M1.1 只读状态（历史会话 / 任务） ----

  UnmodifiableListView<ConversationSummary> get conversations =>
      UnmodifiableListView<ConversationSummary>(_conversations);

  bool get conversationsLoading => _conversationsLoading;

  String? get conversationsError => _conversationsError;

  UnmodifiableListView<TaskItem> get tasks =>
      UnmodifiableListView<TaskItem>(_tasks);

  bool get tasksLoading => _tasksLoading;

  String? get tasksError => _tasksError;

  /// M2.9.2：插件直连时任务列表来自插件的桌面镜像接口，需要轮询刷新。
  bool get usesDesktopTaskMirror => _tasksRestUnavailable;

  /// M4.10：电脑端存档里、但当前列表里已经没有的会话（DSH 重启后常见）。
  UnmodifiableListView<ArchivedSession> get archivedSessions =>
      UnmodifiableListView<ArchivedSession>(_archivedSessions);

  /// 当前列表里已经不存在的存档（手机端显示为「已存档」）。
  List<ArchivedSession> get hiddenArchivedSessions {
    final liveIds = <String>{for (final task in _tasks) task.id};
    return archivedSessions
        .where((session) => !liveIds.contains(session.id))
        .toList(growable: false);
  }

  /// M4.43：抽屉/顶栏「历史会话」的真实数据源。
  ///
  /// 活的桌面会话 + 只在存档里的会话，按最近活动倒序，最多 12 条
  /// （抽屉本来就只展示 12 条，这里截断免得角标数字跟列表对不上）。
  List<RecentDesktopSession> get recentDesktopSessions {
    final rows = <RecentDesktopSession>[
      for (final task in _tasks)
        RecentDesktopSession(
          id: task.id,
          title: task.title.trim().isEmpty ? '未命名会话' : task.title.trim(),
          lastTime: task.lastTime ?? 0,
        ),
      for (final session in hiddenArchivedSessions)
        RecentDesktopSession(
          id: session.id,
          title: session.title.trim().isEmpty ? '未命名会话' : session.title.trim(),
          lastTime: session.lastTime,
          archived: true,
        ),
    ];
    rows.sort((left, right) => right.lastTime.compareTo(left.lastTime));
    return rows.length > 12 ? rows.sublist(0, 12) : rows;
  }

  bool get archiveLoading => _archiveLoading;

  String? get archiveError => _archiveError;

  DateTime? get tasksFetchedAt => _tasksFetchedAt;

  TaskRecord? get selectedTask => _selectedTask;

  TaskItem? get selectedTaskItem => _selectedTask?.toTaskItem();

  bool get taskDetailLoading => _taskDetailLoading;

  String? get taskDetailError => _taskDetailError;

  bool get historyLoading => _historyLoading;

  String? get historyError => _historyError;

  /// 已收到的最大消息序号（断线重连后按它做增量补齐）。
  int get lastSeq => _lastSeq;

  bool get historyLoaded => _historyLoaded;

  // ---- M2.1 事件补拉 / 排队状态 ----

  /// 是否正在补拉断线/后台期间错过的会话事件。
  bool get catchUpLoading => _catchUpLoading;

  /// 补拉失败的错误文案（可调用 [catchUpEvents] 重试）。
  String? get catchUpError => _catchUpError;

  /// 最近一次成功补拉的时间。
  DateTime? get lastCatchUpAt => _lastCatchUpAt;

  /// 是否有排队中的指令（队列深度 1）。
  bool get hasQueuedPrompt {
    final index = _queuedTurnIndex;
    return index != null &&
        index >= 0 &&
        index < _messages.length &&
        _messages[index].queued;
  }

  /// 排队中的指令文本。
  String? get queuedPromptText {
    final index = _queuedTurnIndex;
    if (index == null || index < 0 || index >= _messages.length) return null;
    return _messages[index].queued ? _messages[index].text : null;
  }

  // ---- M2.2 轮次统计 / 立即发送 ----

  /// 所有轮的统计信息（按 turnId 索引，供完成自动折叠使用）。
  Map<int, TurnStats> get turnStats =>
      UnmodifiableMapView<int, TurnStats>(_turns);

  /// 当前轮（用户最近一条指令所在轮）的统计信息。
  TurnStats? get currentTurnStats {
    final id = _currentTurnId;
    return id == null ? null : _turns[id];
  }

  /// 最近一个已进入终态的轮（分享卡摘要用）。
  TurnStats? get latestCompletedTurnStats {
    TurnStats? latest;
    for (final stats in _turns.values) {
      if (!stats.isTerminal) continue;
      if (latest == null || stats.turnId > latest.turnId) latest = stats;
    }
    return latest;
  }

  /// 是否正在「立即发送」打断当前任务。
  bool get isInterrupting => _interruptInFlight;

  // ---- M2 通知 / 前台服务 ----

  /// App 是否在前台（后台时审批请求改发系统通知）。
  bool get appInForeground => _appInForeground;

  /// 从通知点击进来、等待 UI 打开的 approvalId（处理完调用
  /// [clearApprovalToOpen]）。null 表示没有待打开的通知。
  String? get approvalToOpenId => _approvalToOpenId;

  bool get isConnected => _connectionState == LiveConnectionState.connected;

  bool get isBusy =>
      isConnected &&
      (_taskState == TaskStatus.queued ||
          _taskState == TaskStatus.running ||
          _taskState == TaskStatus.waitingApproval);

  /// 是否处于「真实模式」（连接中或已连接）。
  bool get isLiveMode =>
      _connectionState == LiveConnectionState.connected ||
      _connectionState == LiveConnectionState.connecting;

  bool get deviceOnline =>
      isConnected && (_deviceStatus?.online ?? true);

  String get deviceName => _deviceStatus?.deviceName ?? '真实电脑';

  String get agentVersion => _deviceStatus?.agentVersion ?? '未知';

  String get harnessVersion => _deviceStatus?.harnessVersion ?? '未知';

  String get connectionLabel => switch (_connectionState) {
        LiveConnectionState.idle => '未连接',
        LiveConnectionState.connecting => '正在连接…',
        LiveConnectionState.connected => '已连接 $deviceName',
        LiveConnectionState.error => '连接失败',
      };

  String? get contextLabel {
    if (_contextUsed == null || _contextSize == null || _contextSize == 0) {
      return null;
    }
    final percent = (_contextUsed! / _contextSize! * 100).clamp(0, 100);
    return '上下文 ${percent.toStringAsFixed(0)}% · '
        '${_contextUsed!} / ${_contextSize!}';
  }

  // ---- 连接管理 ----

  /// 连接真实电脑：先 HTTP 配对拿 token，再建 WSS 长连接。
  ///
  /// [rawUrl] 可以是 `https://<公网隧道>.trycloudflare.com`、`http://192.168.1.5:8080`
  /// 或误粘贴的 `wss://host/ws`；内部统一规范化。
  Future<void> connect(String rawUrl, {String? code}) async {
    if (_connectionState == LiveConnectionState.connecting) return;
    final String normalized;
    try {
      normalized = PairingApi.normalizeBaseUrl(rawUrl);
    } on PairingApiException catch (e) {
      _fail(e.message);
      return;
    }
    _serverUrl = normalized;
    _pairingCode = (code == null || code.trim().isEmpty)
        ? defaultPairingCode
        : code.trim();
    _setConnectionState(LiveConnectionState.connecting);
    _errorText = null;
    _resetConversationState();
    _notify();

    try {
      final pairer = _pairer ?? _defaultPair;
      final result = await pairer(_serverUrl, _pairingCode);
      _token = result.token;
      _deviceId = result.deviceId;
      await _relay.connect(_serverUrl, token: result.token);
      if (_connectionState != LiveConnectionState.connected) {
        _setConnectionState(LiveConnectionState.connected);
      }
      _errorText = null;
      _maybeCreateConversation();
      unawaited(_onConnectedSideEffects());
      unawaited(
        _sessionStore?.save(
          SavedSession(
            serverUrl: _serverUrl,
            token: result.token,
            deviceId: result.deviceId,
            savedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        ),
      );
      _notify();
    } on PairingApiException catch (e) {
      _fail(e.message);
    } on RelayClientException catch (e) {
      _fail(e.message);
    } on TimeoutException {
      _fail('连接超时：请检查服务器地址与网络');
    } catch (e) {
      _fail(PairingApi.describeException(e));
    }
  }

  /// M2.9.6：冷启动时用上次保存的地址与 token 直接续连。
  ///
  /// 失败（token 失效/换了网络）不打扰用户：清掉存档，回到未连接态。
  Future<bool> restoreSession() async {
    if (_connectionState == LiveConnectionState.connected ||
        _connectionState == LiveConnectionState.connecting) {
      return true;
    }
    final saved = await _sessionStore?.load();
    if (saved == null) return false;
    _serverUrl = saved.serverUrl;
    _token = saved.token;
    _deviceId = saved.deviceId;
    _setConnectionState(LiveConnectionState.connecting);
    _errorText = null;
    _notify();
    try {
      await _relay.connect(_serverUrl, token: saved.token);
      if (_connectionState != LiveConnectionState.connected) {
        _setConnectionState(LiveConnectionState.connected);
      }
      _errorText = null;
      _maybeCreateConversation();
      unawaited(_onConnectedSideEffects());
      _notify();
      return true;
    } catch (_) {
      await _sessionStore?.clear();
      _token = null;
      _deviceId = null;
      _setConnectionState(LiveConnectionState.idle);
      _errorText = null;
      _notify();
      return false;
    }
  }

  /// M3.1：回到前台或网络恢复时补一次重连。
  ///
  /// 与 [restoreSession] 的区别：不读存档、失败也不清 token，只是尝试
  /// 用内存里的地址重连；连不上就交给中继客户端按退避继续重试。
  Future<void> ensureReconnected() async {
    if (_connectionState == LiveConnectionState.connected ||
        _connectionState == LiveConnectionState.connecting) {
      return;
    }
    if (_token == null || _serverUrl.isEmpty) {
      await restoreSession();
      return;
    }
    _setConnectionState(LiveConnectionState.connecting);
    _errorText = null;
    _notify();
    try {
      await _relay.connect(_serverUrl, token: _token!);
      _errorText = null;
      _maybeCreateConversation();
      unawaited(_onConnectedSideEffects());
      _notify();
    } catch (_) {
      _errorText = '连接已断开，正在自动重连…';
      _setConnectionState(LiveConnectionState.error);
      _notify();
      _relay.reconnectInBackground();
    }
  }

  /// M4.44：紧急停止——把「停任务」和「断连接」拆开，并如实汇报做到了哪一步。
  ///
  /// 顺序固定为：发 `task.cancel` → 等电脑把这一轮跑到终态（或超时）→ 断开连接。
  /// 之所以不再直接 `disconnect()`：断开之后既收不到终态、也没法告诉用户任务
  /// 到底停没停，用户会误以为电脑上已经停了。
  Future<EmergencyStopResult> emergencyStop({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    if (_emergencyStopInFlight) {
      return const EmergencyStopResult(
        EmergencyStopOutcome.cancelUnconfirmed,
        '上一次紧急停止还没结束',
      );
    }
    _emergencyStopInFlight = true;
    try {
      if (!isConnected) {
        await disconnect();
        return const EmergencyStopResult(
          EmergencyStopOutcome.disconnectedOnly,
          '本来就没有连接',
        );
      }

      final id = _conversationId;
      final busy = _taskState == TaskStatus.running ||
          _taskState == TaskStatus.queued ||
          _taskState == TaskStatus.waitingApproval;
      if (!busy || id == null) {
        await disconnect();
        return const EmergencyStopResult(
          EmergencyStopOutcome.disconnectedOnly,
          '电脑上没有在跑的任务，只断开了连接',
        );
      }

      // 紧急停止意味着「不要再自动发下一条」，本地排队先丢掉。
      final droppedQueued = _queuedPrompt != null;
      _queuedPrompt = null;

      final waiter = _taskTerminalWaiter = Completer<bool>();
      final sent = _relay.send(RelayMessageTypes.taskCancel, <String, dynamic>{
        'conversationId': id,
      });
      if (!sent) {
        if (identical(_taskTerminalWaiter, waiter)) _taskTerminalWaiter = null;
        await disconnect();
        return EmergencyStopResult(
          EmergencyStopOutcome.cancelUnconfirmed,
          '取消请求没能发出去（连接已断），电脑上的任务可能还在跑',
        );
      }
      _addSystemNotice('已发送停止请求，等电脑确认…');
      _notify();

      final confirmed = await waiter.future.timeout(
        timeout,
        onTimeout: () => false,
      );
      if (identical(_taskTerminalWaiter, waiter)) _taskTerminalWaiter = null;

      await disconnect();
      if (confirmed) {
        return EmergencyStopResult(
          EmergencyStopOutcome.taskCancelled,
          droppedQueued ? '任务已停下（排队的那条也已丢弃）' : '任务已停下',
        );
      }
      return EmergencyStopResult(
        EmergencyStopOutcome.cancelUnconfirmed,
        '电脑 ${timeout.inSeconds} 秒内没确认停下，已先断开连接，任务可能还在跑',
      );
    } finally {
      _emergencyStopInFlight = false;
    }
  }

  /// 断开连接并清空真实会话。
  Future<void> disconnect() async {
    // M4.44：如果有紧急停止在等终态，先把它叫醒（按「没确认」处理），
    // 否则并发调用 disconnect 会让那边挂到超时才返回。
    final waiter = _taskTerminalWaiter;
    _taskTerminalWaiter = null;
    if (waiter != null && !waiter.isCompleted) waiter.complete(false);    final pendingApprovalId = _pendingApproval?.approvalId;
    _cancelInterrupt();
    await _relay.disconnect();
    if (pendingApprovalId != null) {
      unawaited(_cancelApprovalNotificationId(pendingApprovalId));
    }
    unawaited(_stopForegroundService());
    unawaited(_sessionStore?.clear());
    _token = null;
    _deviceId = null;
    _deviceStatus = null;
    _approvalToOpenId = null;
    _disconnectedNoticeShown = false;
    _setConnectionState(LiveConnectionState.idle);
    _errorText = null;
    _resetConversationState();
    _notify();
  }

  /// 用上次的地址与配对码重连。
  Future<void> retry() async {
    if (_serverUrl.isEmpty) {
      _warn('还没有填写过服务器地址');
      return;
    }
    await connect(_serverUrl, code: _pairingCode);
  }

  void clearError() {
    if (_errorText == null) return;
    _errorText = null;
    _notify();
  }

  /// 清空历史消息同步失败提示（不改变连接状态）。
  void clearHistoryError() {
    if (_historyError == null) return;
    _historyError = null;
    _notify();
  }

  /// 测试连接：直接打 `/api/v1/health`，不改变连接状态。
  Future<HealthResult> checkHealth(String rawUrl, {PairingApi? api}) {
    return (api ?? _pairingApi).health(rawUrl);
  }

  Future<PairResult> _defaultPair(String baseUrl, String code) =>
      _pairingApi.pair(baseUrl, pairingCode: code);

  // ---- M1.1 历史会话 / 任务（REST） ----

  /// 拉取最近会话列表（契约 §3.1）。连接成功后由 UI 触发。
  ///
  /// M4.43 起**不再使用**：这是 `backend/` 老后端的 `/api/v1/conversations`，
  /// 插件直连下该路由不存在（必然 404），抽屉与顶栏「历史会话」已改走
  /// [recentDesktopSessions]。保留方法只为不破坏既有调用方与测试。
  Future<void> loadConversations({int limit = 50}) async {
    final token = _token;
    if (!isConnected || token == null || _serverUrl.isEmpty) {
      _warn('还未连接真实电脑，无法拉取历史会话');
      return;
    }
    _restUsed = true;
    _conversationsLoading = true;
    _conversationsError = null;
    _notify();
    try {
      final items = await _withAuthRetry(() => _historyApi.conversations(
            _serverUrl,
            token: _activeToken(),
            limit: limit,
          ));
      _conversations
        ..clear()
        ..addAll(items);
      _conversations.sort((a, b) => b.activityAt.compareTo(a.activityAt));
      _conversationsFetched = true;
    } on PairingApiException catch (e) {
      _conversationsError = e.message;
    } catch (e) {
      _conversationsError = PairingApi.describeException(e);
    } finally {
      _conversationsLoading = false;
      _notify();
    }
  }

  /// 打开一个历史会话并回填历史消息（契约 §3.2，`afterSeq=0`）。
  Future<void> openConversation(ConversationSummary conversation) async {
    if (!isConnected) {
      _warn('还未连接真实电脑，无法打开历史会话');
      return;
    }
    _conversationId = conversation.conversationId;
    _sessionId = conversation.sessionId;
    _workspacePath = conversation.workspacePath ?? _workspacePath;
    _messages.clear();
    _toolCallIndex.clear();
    _taskState = null;
    _pendingApproval = null;
    _lastSeq = 0;
    _historyLoaded = false;
    _historyError = null;
    _seenSeqs.clear();
    _catchUpError = null;
    _queuedTurnIndex = null;
    _cancelInterrupt();
    _turns.clear();
    _currentTurnId = null;
    _errorText = null;
    _notify();
    await syncHistory(reset: true);
    await catchUpEvents();
  }

  /// 同步历史消息：`reset` 时从 seq 0 全量回填，否则按
  /// `afterSeq=lastSeq` 增量补齐（重连后调用，契约 §5）。
  Future<void> syncHistory({bool reset = false}) async {
    final token = _token;
    final conversationId = _conversationId;
    if (!isConnected || token == null || conversationId == null) {
      if (!isConnected) _warn('还未连接真实电脑，无法同步历史消息');
      return;
    }
    if (reset) {
      _messages.clear();
      _toolCallIndex.clear();
      _lastSeq = 0;
      _historyError = null;
      _seenSeqs.clear();
    }
    _restUsed = true;
    _historyLoading = true;
    _notify();
    final afterSeq = _lastSeq;
    try {
      final page = await _withAuthRetry(() => _historyApi.messages(
            _serverUrl,
            token: _activeToken(),
            conversationId: conversationId,
            afterSeq: afterSeq,
          ));
      // 期间切换了会话：这批数据已经不属于当前会话。
      if (_conversationId != conversationId) return;
      for (final message in page.messages) {
        _seenSeqs.add(message.seq);
        if (message.seq <= _lastSeq) continue;
        final item = message.toChatItem();
        _messages.add(item);
        _lastSeq = message.seq;
        final callId = message.callId;
        if (callId != null && item.kind == ChatItemKind.toolCall) {
          _toolCallIndex[callId] = _messages.length - 1;
        }
      }
      _historyLoaded = true;
      if (_taskState == null || _taskState == TaskStatus.queued) {
        _taskState = TaskStatus.running;
      }
    } on PairingApiException catch (e) {
      _historyError = e.message;
    } catch (e) {
      _historyError = PairingApi.describeException(e);
    } finally {
      _historyLoading = false;
      _notify();
    }
  }

  /// 拉取真实任务列表（契约 §3.3），供任务中心使用。
  Future<void> loadTasks({int limit = 50, List<String>? statuses}) async {
    final token = _token;
    if (!isConnected || token == null || _serverUrl.isEmpty) {
      _warn('还未连接真实电脑，无法拉取任务');
      return;
    }
    _restUsed = true;
    _tasksError = null;
    if (_tasksRestUnavailable) {
      // 插件直连：走插件自带的桌面任务镜像（只读）。
      await _loadDesktopTasks();
      return;
    }
    _tasksLoading = true;
    _notify();
    try {
      final records = await _withAuthRetry(() => _historyApi.tasks(
            _serverUrl,
            token: _activeToken(),
            limit: limit,
            statuses: statuses,
          ));
      _tasks
        ..clear()
        ..addAll(records.map((r) => r.toTaskItem()));
      _tasks.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      _tasksFetchedAt = DateTime.now();
      _tasksFetched = true;
      // M4.4：REST 任务列表同样要比对「刚做完」的会话。
      _notifyFinishedTasks();
    } on PairingApiException catch (e) {
      if (e.statusCode == 404) {
        // 插件直连没有任务 REST 接口：改走插件的桌面任务镜像。
        _tasksRestUnavailable = true;
        _tasksError = null;
        await _loadDesktopTasks();
      } else {
        _tasksError = e.message;
      }
    } catch (e) {
      _tasksError = PairingApi.describeException(e);
    } finally {
      _tasksLoading = false;
      _notify();
    }
  }

  /// M2.9.2：插件直连时从桌面任务镜像刷新任务页（只读）。
  Future<void> _loadDesktopTasks() async {
    _tasksLoading = true;
    _notify();
    try {
      final records = await _withAuthRetry(
        () => _historyApi.desktopTasks(_serverUrl, token: _activeToken()),
      );
      // M3.6：桌面会话按「最后活动时刻」倒序——最新的排最前。
      _tasks
        ..clear()
        ..addAll(sortDesktopTasks(records).map((r) => r.toTaskItem()));
      _tasksFetchedAt = DateTime.now();
      _tasksFetched = true;
      _tasksError = null;
      _notifyFinishedTasks();
    } on PairingApiException catch (e) {
      // 老版本插件没有这个接口：保持静默空列表。
      _tasksError = e.statusCode == 404 ? null : e.message;
    } catch (e) {
      _tasksError = PairingApi.describeException(e);
    } finally {
      _tasksLoading = false;
      _notify();
    }
  }

  /// M4.10：拉电脑端的会话存档（插件 0.2.14+）。
  ///
  /// DSH 重启后旧会话会从列表里消失，这份存档让手机端仍然看得到它们。
  Future<void> loadArchivedSessions() async {
    final token = _token;
    if (_archiveUnavailable) return;
    if (!isConnected || token == null || _serverUrl.isEmpty) return;
    if (_archiveLoading) return;
    _archiveLoading = true;
    _archiveError = null;
    _notify();
    try {
      final sessions = await _withAuthRetry(
        () => _historyApi.archivedSessions(_serverUrl, token: _activeToken()),
      );
      _archivedSessions = sessions;
    } on PairingApiException catch (e) {
      // 老版本插件没有存档接口：静默降级，不再反复请求。
      if (e.statusCode == 404 || e.statusCode == 501) {
        _archiveUnavailable = true;
        _archiveError = null;
      } else {
        _archiveError = e.message;
      }
    } catch (e) {
      _archiveError = PairingApi.describeException(e);
    } finally {
      _archiveLoading = false;
      _notify();
    }
  }

  /// M4.10：读一份存档的完整事件，交给只读直播页渲染。
  Future<DesktopSessionFeed> fetchArchivedSession(String sessionId) async {
    final token = _token;
    if (!isConnected || token == null || _serverUrl.isEmpty) {
      throw const PairingApiException('还未连接电脑，无法查看历史会话');
    }
    return _withAuthRetry(
      () => _historyApi.archivedSession(
        _serverUrl,
        token: _activeToken(),
        sessionId: sessionId,
      ),
    );
  }

  /// M4.10：把手机端本地保存的一份会话补传到电脑（电脑那边丢档时手动恢复）。
  Future<void> uploadArchivedSession(
    ArchivedSession session,
    List<DesktopSessionEvent> events,
  ) async {
    final token = _token;
    if (!isConnected || token == null || _serverUrl.isEmpty) {
      throw const PairingApiException('还未连接电脑，无法恢复历史会话');
    }
    await _withAuthRetry(
      () => _historyApi.postArchivedSession(
        _serverUrl,
        token: _activeToken(),
        session: session,
        events: events,
      ),
    );
    await loadArchivedSessions();
  }

  /// M2.9.3：拉取桌面会话的直播流（只读）。`afterSeq` 为空时取尾部一屏。
  Future<DesktopSessionFeed> fetchDesktopSession(
    String sessionId, {
    int? afterSeq,
    int limit = 80,
  }) async {
    final token = _token;
    if (!isConnected || token == null || _serverUrl.isEmpty) {
      throw const PairingApiException('还未连接电脑，无法查看桌面会话');
    }
    return _withAuthRetry(
      () => _historyApi.desktopSessionEvents(
        _serverUrl,
        token: _activeToken(),
        sessionId: sessionId,
        afterSeq: afterSeq,
        limit: limit,
      ),
    );
  }

  /// M2.9.4：替电脑给桌面会话发一句话（手机接管输入）。
  ///
  /// M4.19：存档会话会被电脑恢复成新会话，返回值里带着新 id。
  Future<DesktopPromptResult> sendDesktopPrompt(
    String sessionId,
    String text,
  ) async {
    final token = _token;
    if (!isConnected || token == null || _serverUrl.isEmpty) {
      throw const PairingApiException('还未连接电脑，无法发送');
    }
    return _withAuthRetry(
      () => _historyApi.sendDesktopPrompt(
        _serverUrl,
        token: _activeToken(),
        sessionId: sessionId,
        text: text,
      ),
    );
  }

  /// M4.25：读电脑端的 DeepSeek 账户余额。
  Future<AccountBalance> fetchAccountBalance() async {
    final token = _token;
    if (!isConnected || token == null || _serverUrl.isEmpty) {
      throw const PairingApiException('还未连接电脑，读不到账户余额');
    }
    return _withAuthRetry(
      () => _historyApi.fetchAccountBalance(
        _serverUrl,
        token: _activeToken(),
      ),
    );
  }

  /// M4.31：跨会话的「电脑在等你选一项」。
  Future<DesktopPending> fetchDesktopPending() async {
    if (!isConnected || _token == null || _serverUrl.isEmpty) {
      throw const PairingApiException('还未连接电脑，看不到待回答的提问');
    }
    return _withAuthRetry(
      () => _historyApi.fetchDesktopPending(_serverUrl, token: _activeToken()),
    );
  }

  /// M4.21：读桌面会话的排队消息。
  Future<DesktopQueue> fetchDesktopQueue(String sessionId) async {
    final token = _token;
    if (!isConnected || token == null || _serverUrl.isEmpty) {
      throw const PairingApiException('还未连接电脑，读不到排队消息');
    }
    return _withAuthRetry(
      () => _historyApi.fetchDesktopQueue(
        _serverUrl,
        token: _activeToken(),
        sessionId: sessionId,
      ),
    );
  }

  /// M4.21：删除 / 改字 / 插话一条排队消息。
  Future<DesktopQueue> updateDesktopQueue(
    String sessionId,
    String itemId, {
    required String action,
    String? text,
  }) async {
    final token = _token;
    if (!isConnected || token == null || _serverUrl.isEmpty) {
      throw const PairingApiException('还未连接电脑，改不了排队消息');
    }
    return _withAuthRetry(
      () => _historyApi.updateDesktopQueue(
        _serverUrl,
        token: _activeToken(),
        sessionId: sessionId,
        itemId: itemId,
        action: action,
        text: text,
      ),
    );
  }

  /// M2.9.4：应答桌面会话里等待的授权。
  Future<void> decideDesktopApproval(
    String sessionId,
    String approvalId, {
    required bool approve,
  }) async {
    final token = _token;
    if (!isConnected || token == null || _serverUrl.isEmpty) {
      throw const PairingApiException('还未连接电脑，无法应答授权');
    }
    await _withAuthRetry(
      () => _historyApi.decideDesktopApproval(
        _serverUrl,
        token: _activeToken(),
        sessionId: sessionId,
        approvalId: approvalId,
        approve: approve,
      ),
    );
  }

  /// M4.23：回答电脑端「确认需求」卡片里的问题（空列表＝跳过）。
  Future<void> answerDesktopQuestion(
    String sessionId,
    String questionId, {
    required List<DesktopQuestionAnswer> answers,
  }) async {
    final token = _token;
    if (!isConnected || token == null || _serverUrl.isEmpty) {
      throw const PairingApiException('还未连接电脑，无法回答这个问题');
    }
    await _withAuthRetry(
      () => _historyApi.answerDesktopQuestion(
        _serverUrl,
        token: _activeToken(),
        sessionId: sessionId,
        questionId: questionId,
        answers: answers,
      ),
    );
  }

  /// M3.0：把手机上的照片/文档传到电脑，返回落盘路径。
  Future<DesktopUpload> uploadDesktopFile({
    required String name,
    required List<int> bytes,
    String? workspace,
  }) async {
    final token = _token;
    if (!isConnected || token == null || _serverUrl.isEmpty) {
      throw const PairingApiException('还未连接电脑，无法上传附件');
    }
    return _withAuthRetry(
      () => _historyApi.uploadDesktopFile(
        _serverUrl,
        token: _activeToken(),
        name: name,
        bytes: bytes,
        workspace: workspace,
      ),
    );
  }

  /// M4.8：请电脑把附件读成文字（PDF / Word / Excel 等手机解析不了的格式）。
  ///
  /// 不落工作区、不留文件；没连电脑或电脑端插件过旧时抛异常，调用方退回
  /// 「只告诉模型文件名」。
  Future<String> readDesktopFile({
    required String name,
    required List<int> bytes,
  }) async {
    final token = _token;
    if (!isConnected || token == null || _serverUrl.isEmpty) {
      throw const PairingApiException('还未连接电脑，无法读取这个文件');
    }
    return _withAuthRetry(
      () => _historyApi.readDesktopFile(
        _serverUrl,
        token: _activeToken(),
        name: name,
        bytes: bytes,
      ),
    );
  }

  /// M4.9：取工作区里某个文件的原始字节（图片 / PDF 预览、「用其他应用打开」）。
  ///
  /// 插件会校验 [workspacePath] 必须是授权根之一，相对路径不许含 `..`；
  /// 需要电脑端插件 0.2.13+（旧版没有 `/desktop/file/raw`，会 404）。
  Future<List<int>> downloadWorkspaceFile({
    required String workspacePath,
    required String relativePath,
  }) async {
    final token = _token;
    if (!isConnected || token == null || _serverUrl.isEmpty) {
      throw const PairingApiException('还未连接电脑，无法打开这个文件');
    }
    return _withAuthRetry(
      () => _historyApi.downloadWorkspaceFile(
        _serverUrl,
        token: _activeToken(),
        workspacePath: workspacePath,
        relativePath: relativePath,
      ),
    );
  }

  /// M4.57：「功能 → 接收文件」——电脑端放进插件 received 目录的文件。
  /// 需要电脑端插件 0.2.42+（旧版没有 `/api/v1/received`，会 404）。
  Future<List<ReceivedFile>> loadReceivedFiles() async {
    final token = _token;
    if (!isConnected || token == null || _serverUrl.isEmpty) {
      throw const PairingApiException('还未连接电脑，无法读取接收文件');
    }
    return _withAuthRetry(
      () => _historyApi.listReceivedFiles(_serverUrl, token: _activeToken()),
    );
  }

  /// M4.66：「功能 → 更新日志」——电脑上 `docs/UPDATE_NOTES.md` 的版本列表。
  /// 需要电脑端插件 0.2.69+（旧版没有 `/api/v1/app/notes`，会 404）。
  Future<List<UpdateNote>> loadUpdateNotes() async {
    final token = _token;
    if (!isConnected || token == null || _serverUrl.isEmpty) {
      throw const PairingApiException('还未连接电脑，读不到更新日志');
    }
    return _withAuthRetry(
      () => _historyApi.listUpdateNotes(_serverUrl, token: _activeToken()),
    );
  }

  /// M4.57：下载一个接收文件（图片 / PDF / Office / 文本都能交给文件预览）。
  Future<List<int>> downloadReceivedFile(String name) async {
    final token = _token;
    if (!isConnected || token == null || _serverUrl.isEmpty) {
      throw const PairingApiException('还未连接电脑，无法打开这个文件');
    }
    return _withAuthRetry(
      () => _historyApi.downloadReceivedFile(
        _serverUrl,
        token: _activeToken(),
        name: name,
      ),
    );
  }

  /// M4.0：在电脑端新建工作区（默认第一个授权根目录下的子目录）。
  ///
  /// M4.13：可带 [parentDir]，把新项目固定建在「项目根」（如 `D:\Projects\项目`）
  /// 下，而不是碰运气落到授权根的第一个。
  ///
  /// 成功后把新目录并进 [workspaceRoots]，工作区页无需等下一次设备状态就能看到它；
  /// 若旧版本电脑端没有这个接口（404），抛出的 [PairingApiException] 带可读提示。
  Future<DesktopWorkspaceCreated> createDesktopWorkspace(
    String name, {
    String? parentDir,
  }) async {
    final token = _token;
    if (!isConnected || token == null || _serverUrl.isEmpty) {
      throw const PairingApiException('还未连接电脑，无法新建工作区');
    }
    final created = await _withAuthRetry(
      () => _historyApi.createDesktopWorkspace(
        _serverUrl,
        token: _activeToken(),
        name: name,
        parentDir: parentDir,
      ),
    );
    final path = created.path.trim();
    if (path.isNotEmpty && !_workspaceRoots.contains(path)) {
      _workspaceRoots = <String>[..._workspaceRoots, path];
    }
    _notify();
    return created;
  }

  /// M3.5：电脑上已安装的插件清单。
  Future<List<PluginInfo>> listPlugins() async {
    final token = _token;
    if (!isConnected || token == null || _serverUrl.isEmpty) {
      throw const PairingApiException('还未连接电脑，无法读取插件列表');
    }
    return _withAuthRetry(
      () => _historyApi.listPlugins(_serverUrl, token: _activeToken()),
    );
  }

  /// M3.5：启用或停用一个插件。
  Future<void> setPluginEnabled(String id, bool enabled) async {
    final token = _token;
    if (!isConnected || token == null || _serverUrl.isEmpty) {
      throw const PairingApiException('还未连接电脑，无法切换插件');
    }
    await _withAuthRetry(
      () => _historyApi.setPluginEnabled(
        _serverUrl,
        token: _activeToken(),
        id: id,
        enabled: enabled,
      ),
    );
  }
  /// M3.6：按插件包分组的插件列表（旧插件返回 404）。
  Future<List<PluginBundle>> listPluginBundles() async {
    final token = _token;
    if (!isConnected || token == null || _serverUrl.isEmpty) {
      throw const PairingApiException('还未连接电脑，无法读取插件包');
    }
    return _withAuthRetry(
      () => _historyApi.listPluginBundles(_serverUrl, token: _activeToken()),
    );
  }

  /// M3.6：启用/停用一个插件包。
  Future<void> setBundleEnabled(String name, bool enabled) async {
    final token = _token;
    if (!isConnected || token == null || _serverUrl.isEmpty) {
      throw const PairingApiException('还未连接电脑，无法切换插件包');
    }
    await _withAuthRetry(
      () => _historyApi.setBundleEnabled(
        _serverUrl,
        token: _activeToken(),
        name: name,
        enabled: enabled,
      ),
    );
  }

  /// M4.1：电脑端已安装插件（内置配置 / 实验性 / 其他 分组，带启用状态）。
  Future<PluginGallery> pluginGallery() async {
    final token = _token;
    if (!isConnected || token == null || _serverUrl.isEmpty) {
      throw const PairingApiException('还未连接电脑，无法读取已安装插件');
    }
    return _withAuthRetry(
      () => _historyApi.pluginGallery(_serverUrl, token: _activeToken()),
    );
  }

  /// M3.6：搜索电脑端插件市场。
  Future<MarketSearchResult> marketSearch({
    String? url,
    String query = '',
  }) async {
    final token = _token;
    if (!isConnected || token == null || _serverUrl.isEmpty) {
      throw const PairingApiException('还未连接电脑，无法搜索插件市场');
    }
    return _withAuthRetry(
      () => _historyApi.marketSearch(
        _serverUrl,
        token: _activeToken(),
        url: url,
        query: query,
      ),
    );
  }

  /// M4.18：电脑端插件市场目录（与电脑端「设置 → 插件市场」同一份数据）。
  Future<PluginCatalog> pluginCatalog() async {
    final token = _token;
    if (!isConnected || token == null || _serverUrl.isEmpty) {
      throw const PairingApiException('还未连接电脑，无法读取插件市场');
    }
    return _withAuthRetry(
      () => _historyApi.listPluginCatalog(_serverUrl, token: _activeToken()),
    );
  }

  /// M3.6：从市场安装插件（可带已确认的构建脚本白名单）。
  Future<Map<String, dynamic>> installPlugin(
    String spec, {
    List<String>? approvedBuilds,
  }) async {
    final token = _token;
    if (!isConnected || token == null || _serverUrl.isEmpty) {
      throw const PairingApiException('还未连接电脑，无法安装插件');
    }
    return _withAuthRetry(
      () => _historyApi.installPlugin(
        _serverUrl,
        token: _activeToken(),
        spec: spec,
        approvedBuilds: approvedBuilds,
      ),
    );
  }

  /// M3.6：卸载电脑端插件。
  Future<void> removePlugin(String name) async {
    final token = _token;
    if (!isConnected || token == null || _serverUrl.isEmpty) {
      throw const PairingApiException('还未连接电脑，无法卸载插件');
    }
    await _withAuthRetry(
      () => _historyApi.removePlugin(
        _serverUrl,
        token: _activeToken(),
        name: name,
      ),
    );
  }

  /// 拉取任务详情（含 `events` 时间线）。
  Future<void> loadTaskDetail(String taskId) async {
    final token = _token;
    final id = taskId.trim();
    if (!isConnected || token == null || _serverUrl.isEmpty) {
      _warn('还未连接真实电脑，无法拉取任务详情');
      return;
    }
    if (id.isEmpty) {
      _taskDetailError = '任务 id 为空';
      _notify();
      return;
    }
    if (_tasksRestUnavailable) {
      // 插件直连：详情随 WSS 推送，无需 REST。
      _taskDetailLoading = false;
      _taskDetailError = null;
      _notify();
      return;
    }
    _restUsed = true;
    _taskDetailLoading = true;
    _taskDetailError = null;
    _notify();
    try {
      final record = await _withAuthRetry(() => _historyApi.taskDetail(
            _serverUrl,
            token: _activeToken(),
            taskId: id,
          ));
      _selectedTask = record;
      final item = record.toTaskItem();
      final index = _tasks.indexWhere((t) => t.id == record.taskId);
      if (index >= 0) {
        _tasks[index] = item;
      }
    } on PairingApiException catch (e) {
      if (e.statusCode == 404) {
        _tasksRestUnavailable = true;
        _taskDetailError = null;
      } else {
        _taskDetailError = e.message;
      }
    } catch (e) {
      _taskDetailError = PairingApi.describeException(e);
    } finally {
      _taskDetailLoading = false;
      _notify();
    }
  }

  /// 连接后由 UI 调用：并发拉取会话与任务列表（幂等）。
  Future<void> ensureLiveData({bool force = false}) async {
    if (!isConnected) return;
    final futures = <Future<void>>[];
    // M4.43：不再拉 `loadConversations()`——它打的是老后端 `/api/v1/conversations`，
    // 插件直连下必然 404，白费一次请求。历史会话改用 recentDesktopSessions。
    if (force || (!_tasksFetched && !_tasksLoading)) {
      futures.add(loadTasks());
    }
    if (futures.isEmpty) return;
    await Future.wait(futures);
  }

  /// 断线重连后补齐 REST 数据。
  ///
  /// 仅当本次会话用过 REST 才执行：纯 WebSocket 的单测不触碰网络。
  Future<void> _refreshAfterReconnect() async {
    if (!_restUsed && _conversationId == null) return;
    unawaited(loadTasks());
    // M4.43：同上，老后端的 conversations 不再请求。
    // M2.1：断线恢复后不再靠 messages 兜底，改走 events 增量补拉（契约 §4.1）。
    if (_conversationId != null) {
      await catchUpEvents();
    }
  }

  // ---- M2 通知 / 前台服务 / 自动重配对 ----

  /// 注册通知点击回调（App 启动时调用一次；未注入 gateway 时为空操作）。
  Future<void> initNotifications() async {
    final gateway = _notifications;
    if (gateway == null || _notificationsInitialized) return;
    _notificationsInitialized = true;
    _tapSubscription = gateway.approvalTaps.listen(handleApprovalTap);
    // M4.4：通知栏直接「允许 / 拒绝」。
    _decisionSubscription =
        gateway.approvalDecisions.listen(_handleNotificationDecision);
    await gateway.init();
    final initialId = await gateway.getInitialApprovalId();
    if (initialId != null && initialId.isNotEmpty) handleApprovalTap(initialId);
  }

  /// M4.4：注入通知偏好（「我的 → 通知」里的开关）；为空表示全部开启。
  Future<void> attachNotificationPrefs(NotificationPrefs prefs) async {
    _notifyPrefs = prefs;
    await prefs.load();
    _notify();
  }

  /// 当前通知偏好（只读，供「我的」页展示）。
  NotificationPrefs get notificationPrefs => _notifyPrefs;

  /// 切换「任务做完提醒」。
  Future<void> setTaskDoneNotifications(bool value) async {
    await _notifyPrefs.setTaskDone(value);
    _notify();
  }

  /// 切换「等待授权提醒」。
  Future<void> setApprovalNotifications(bool value) async {
    await _notifyPrefs.setApprovalAction(value);
    _notify();
  }

  /// 用户在通知栏直接点了「允许 / 拒绝」：按审批决定发给电脑端。
  void _handleNotificationDecision(ApprovalDecisionResult result) {
    final pending = _pendingApproval;
    if (pending == null || pending.approvalId != result.approvalId) {
      _addSystemNotice('这条授权请求已经处理过了，通知里的操作没有生效。');
      _notify();
      return;
    }
    _pendingApproval = null;
    if (_taskState == TaskStatus.waitingApproval) {
      _taskState = TaskStatus.running;
    }
    _addSystemNotice(
      result.approved ? '已在通知里允许这次操作。' : '已在通知里拒绝这次操作。',
    );
    _cancelApprovalNotice();
    unawaited(_cancelApprovalNotificationId(result.approvalId));
    decideApproval(result.approved);
  }

  /// App 生命周期变化：切到后台时若有待审批，补发系统通知；
  /// 回到前台时撤掉通知（由 ApprovalSheet 接管）。
  void setAppForeground(bool foreground) {
    if (_appInForeground == foreground) return;
    _appInForeground = foreground;
    final pending = _pendingApproval;
    if (!foreground && pending != null) {
      unawaited(_showApprovalNotification(pending));
      // M4.4：切到后台时补一条可操作通知，回来前也能直接决定。
      unawaited(_showApprovalActionNotice(pending));
    } else if (foreground && pending != null) {
      unawaited(_cancelApprovalNotificationId(pending.approvalId));
      _cancelApprovalNotice();
    }
    // M2.1：回到前台补拉后台期间错过的事件（契约 §4.1）。
    if (foreground && isConnected && _conversationId != null) {
      unawaited(catchUpEvents());
    }
    _notify();
  }

  /// 用户点了审批通知：审批仍挂起则标记给 UI 自动弹窗；已失效则提示。
  void handleApprovalTap(String approvalId) {
    final pending = _pendingApproval;
    if (pending != null && pending.approvalId == approvalId) {
      _approvalToOpenId = approvalId;
      _notify();
      return;
    }
    _approvalToOpenId = null;
    _addSystemNotice('该审批已失效：它可能已被处理或已超时。');
    unawaited(_cancelApprovalNotificationId(approvalId));
    _notify();
  }

  /// UI 弹完审批弹层后调用，清掉「从通知打开」的标记。
  void clearApprovalToOpen() {
    if (_approvalToOpenId == null) return;
    _approvalToOpenId = null;
    _notify();
  }

  String _activeToken() {
    final token = _token;
    if (token == null) {
      throw const PairingApiException('认证信息已失效，请重新连接');
    }
    return token;
  }

  /// REST 401/403：自动重新配对后重试一次（M2 §2.4）。
  Future<T> _withAuthRetry<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } on PairingApiException catch (e) {
      if (e.statusCode != 401 && e.statusCode != 403) rethrow;
      final repaired = await _handleAuthFailure();
      if (!repaired) rethrow;
      return await operation();
    }
  }

  /// 自动重配对：用本地 serverUrl + pairingCode 重新配对并重连一次。
  /// 返回是否成功；失败时保留提示，由 UI 引导回连接页。
  Future<bool> _handleAuthFailure() async {
    if (_reauthInFlight) return false;
    if (!isConnected || _serverUrl.isEmpty) return false;
    if (_reauthAttempts >= 2) {
      _errorText = '自动重新配对多次失败，请到连接页重新配对。';
      _setConnectionState(LiveConnectionState.error);
      _addSystemNotice(_errorText!);
      _notify();
      return false;
    }
    _reauthInFlight = true;
    _reauthAttempts += 1;
    try {
      _addSystemNotice('登录状态已失效，正在自动重新配对…');
      _notify();
      final pair = _pairer ?? _defaultPair;
      final result = await pair(_serverUrl, _pairingCode);
      _token = result.token;
      _deviceId = result.deviceId;
      await _relay.connect(_serverUrl, token: result.token);
      if (_connectionState != LiveConnectionState.connected) {
        _setConnectionState(LiveConnectionState.connected);
      }
      _errorText = null;
      _reauthAttempts = 0;
      _addSystemNotice('已自动重新配对并恢复连接。');
      unawaited(_onConnectedSideEffects());
      _notify();
      return true;
    } catch (e) {
      final message = e is PairingApiException
          ? e.message
          : e is RelayClientException
              ? e.message
              : PairingApi.describeException(e);
      _errorText = '自动重新配对失败：$message。请到连接页重新配对。';
      _setConnectionState(LiveConnectionState.error);
      _addSystemNotice(_errorText!);
      _notify();
      return false;
    } finally {
      _reauthInFlight = false;
    }
  }

  /// 连接成功后的副作用：清断开通知、请求一次通知权限、起前台服务。
  Future<void> _onConnectedSideEffects() async {
    final gateway = _notifications;
    _disconnectedNoticeShown = false;
    // M4.4：重连后第一次任务快照只做基线，不把历史结果当成「刚做完」。
    primeTaskNotifications();
    // M2.1：连接恢复后补拉事件，并尝试发出排队指令。
    if (isConnected && _conversationId != null) {
      unawaited(catchUpEvents());
    }
    _sendQueuedTurnPrompt();
    if (gateway == null) return;
    unawaited(gateway.clearDisconnected());
    if (!_permissionRequested) {
      _permissionRequested = true;
      unawaited(gateway.requestPermission());
    }
    await _startForegroundService();
  }

  Future<void> _startForegroundService() async {
    final gateway = _notifications;
    if (gateway == null || !isConnected) return;
    final name = deviceName;
    if (_foregroundDeviceName == name) return;
    _foregroundDeviceName = name;
    try {
      await gateway.startForegroundService(name);
    } catch (_) {
      // Android 12+ 后台启动受限：失败不影响连接主流程。
    }
  }

  Future<void> _stopForegroundService() async {
    final gateway = _notifications;
    _foregroundDeviceName = null;
    if (gateway == null) return;
    try {
      await gateway.stopForegroundService();
    } catch (_) {
      // 忽略平台异常。
    }
  }

  Future<void> _showApprovalNotification(PendingApproval pending) async {
    final gateway = _notifications;
    if (gateway == null) return;
    final firstLine = pending.command.split('\n').first.trim();
    final summary = firstLine.length > 60
        ? '${firstLine.substring(0, 60)}…'
        : firstLine;
    final body = summary.isEmpty ? pending.tool : '${pending.tool} · $summary';
    try {
      await gateway.showApproval(
        approvalId: pending.approvalId,
        title: '有一项操作需要授权',
        body: body,
      );
    } catch (_) {
      // 通知失败不影响审批流程。
    }
  }

  Future<void> _cancelApprovalNotificationId(String approvalId) async {
    try {
      await _notifications?.cancelApproval(approvalId);
    } catch (_) {
      // 忽略平台异常。
    }
  }

  // ---- M4.4 任务完成 / 等待授权通知 ----

  // ---- M4.35 待回答提问的通知 ----

  /// 手机上轮询到「电脑在等你回答」时调用。
  ///
  /// 两个方向：新出现的提问发一条通知；已经回答/超时的不再发，并把旧通知收回。
  /// 走的是「等待授权提醒」那个开关（都属于「电脑停下来等你」这一类）。
  Future<void> notePendingQuestions(Iterable<DesktopPendingQuestion> questions) async {
    final ids = <String>{
      for (final question in questions)
        if (question.questionId.isNotEmpty) question.questionId,
    };
    for (final id in _questionNotices.difference(ids)) {
      _questionNotices.remove(id);
      await _cancelTaskNotice('question-$id');
    }
    final gateway = _notifications;
    if (gateway == null || !_notifyPrefs.approvalAction) return;
    for (final question in questions) {
      final id = question.questionId;
      if (id.isEmpty || _questionNotices.contains(id)) continue;
      _questionNotices.add(id);
      final header = question.header.trim().isEmpty ? '确认需求' : question.header.trim();
      final line = question.question.trim().isEmpty ? '电脑在等你选一项' : question.question.trim();
      // 点这条通知落到「工作区」（那里的横幅会把人带进会话）。
      _pendingNotificationRoute = 'tasks';
      try {
        await gateway.showTaskUpdate(
          sessionKey: 'question-$id',
          title: '电脑在等你回答 · $header',
          body: notificationExcerpt(line),
          status: 'waiting',
          sessionId: question.sessionId,
        );
      } catch (_) {
        // 通知失败不影响回答流程。
      }
    }
  }

  /// 等待授权时在通知栏发一条可操作的通知（允许 / 拒绝直接点）。
  Future<void> _showApprovalActionNotice(PendingApproval pending) async {
    final gateway = _notifications;
    if (gateway == null || !_notifyPrefs.approvalAction) return;
    final firstLine = pending.command.split('\n').first.trim();
    final body = firstLine.isEmpty
        ? '请确认是否允许 ${pending.tool}'
        : '${pending.tool} · $firstLine';
    final id = approvalNoticeId(pending.approvalId);
    _approvalNoticeId = id;
    try {
      await gateway.showApprovalAction(
        notificationId: id,
        approvalId: pending.approvalId,
        title: '需要你在手机上授权',
        body: notificationExcerpt(body, max: 80),
      );
    } catch (_) {
      // 通知失败不影响审批流程。
    }
  }

  /// 等待授权通知的 id（公开给单测对齐断言）。
  static String approvalNoticeId(String approvalId) => 'approval-$approvalId';

  void _cancelApprovalNotice() {
    final id = _approvalNoticeId;
    if (id == null) return;
    _approvalNoticeId = null;
    unawaited(_cancelTaskNotice(id));
  }

  /// 电脑上的某个会话刚做完 / 失败 / 取消：在后台时发系统通知。
  Future<void> _notifyTaskFinished({
    required String key,
    required String title,
    required String body,
    required String status,
    String? sessionId,
  }) async {
    final gateway = _notifications;
    if (gateway == null || !_notifyPrefs.taskDone) return;
    // 点这条通知要能落到「工作区」页（由 RootShell 消费）。
    _pendingNotificationRoute = 'tasks';
    try {
      await gateway.showTaskUpdate(
        sessionKey: key,
        title: title,
        body: notificationExcerpt(body),
        status: status,
        sessionId: sessionId,
      );
    } catch (_) {
      // 通知失败不影响主流程。
    }
  }

  Future<void> _cancelTaskNotice(String id) async {
    try {
      await _notifications?.cancelTaskUpdate(id);
    } catch (_) {
      // 忽略平台异常。
    }
  }

  /// 下一次 [loadTasks] 只记录基线、不发通知（避免把旧结果当成新完成）。
  void primeTaskNotifications() {
    _tasksSnapshotPrimed = false;
  }

  /// M4.4：对比两次任务快照，找出「刚做完」的会话并提醒。
  ///
  /// 只在后台（[appInForeground] 为 false）时发通知——用户正看着屏幕时
  /// 消息流和状态徽标已经足够，不必再弹一条。第一次快照只记录基线。
  void _notifyFinishedTasks() {
    final active = <String>{};
    for (final task in _tasks) {
      final key = task.id;
      active.add(key);
      final busy = task.status == TaskStatus.running ||
          task.status == TaskStatus.queued ||
          task.status == TaskStatus.waitingApproval;
      final previousBusy = _taskBusyByKey[key];
      final previousStatus = _taskStatusByKey[key];
      _taskBusyByKey[key] = busy;
      _taskStatusByKey[key] = task.status;
      if (!_tasksSnapshotPrimed || previousBusy != true || busy) continue;
      if (!_appInForeground) {
        final (title, status) = switch (task.status) {
          TaskStatus.completed => ('任务已完成', 'completed'),
          TaskStatus.failed => ('任务失败了', 'failed'),
          TaskStatus.cancelled => ('任务已取消', 'cancelled'),
          _ => ('任务状态更新', 'completed'),
        };
        final workspaceLeaf = _leafName(task.workspace);
        final where = workspaceLeaf.isEmpty ? task.title : '${task.title} · $workspaceLeaf';
        unawaited(_notifyTaskFinished(
          key: 'task-${task.id}',
          title: '$title：$where',
          body: '点开看结果，可以直接在手机上继续发指令。',
          status: status,
          sessionId: task.conversationId ?? task.id,
        ));
      }
    }
    _taskBusyByKey.removeWhere((key, _) => !active.contains(key));
    _taskStatusByKey.removeWhere((key, _) => !active.contains(key));
    _tasksSnapshotPrimed = true;
  }

  /// M4.4：通知文案里的会话名（优先历史会话标题，其次工作区名）。
  String _conversationLabel() {
    final id = _conversationId;
    if (id != null) {
      for (final item in _conversations) {
        if (item.conversationId == id && item.title.trim().isNotEmpty) {
          return item.title.trim();
        }
      }
    }
    final leaf = _leafName(_workspacePath ?? '');
    return leaf.isEmpty ? '电脑上的任务' : leaf;
  }

  static String _leafName(String path) {
    final trimmed = path.replaceAll(RegExp(r'[\\/]+$'), '');
    if (trimmed.isEmpty) return '';
    final parts = trimmed.split(RegExp(r'[\\/]'));
    return parts.isEmpty ? trimmed : parts.last;
  }

  Future<void> _notifyDisconnected() async {
    if (_disconnectedNoticeShown) return;
    _disconnectedNoticeShown = true;
    // M4.4：断线时撤掉旧的「等待授权」通知，避免点了没反应。
    _cancelApprovalNotice();
    try {
      await _notifications?.showDisconnected(reason: '已断开与电脑的连接');
    } catch (_) {
      // 忽略平台异常。
    }
  }

  // ---- 会话操作 ----

  /// 创建会话（契约 §3.1 `conversation.create`）。
  void createConversation({String? workspacePath, String? title}) {
    if (!isConnected) {
      _warn('还未连接真实电脑');
      return;
    }
    final path = workspacePath ??
        _pendingWorkspacePath ??
        _workspacePath ??
        (_workspaceRoots.isEmpty ? null : _workspaceRoots.first);
    _conversationRequested = true;
    final payload = <String, dynamic>{'title': title ?? '手机发起的会话'};
    if (path != null && path.isNotEmpty) payload['workspacePath'] = path;
    _relay.send(RelayMessageTypes.conversationCreate, payload);
    _notify();
  }

  // ---- M2.6 项目同步（workspace.list / file.read） ----

  /// 设置下一个新会话要绑定的工作区（传 null 取消）。
  void setPendingWorkspace(String? path) {
    final next = (path == null || path.trim().isEmpty) ? null : path.trim();
    if (_pendingWorkspacePath == next) return;
    _pendingWorkspacePath = next;
    _notify();
  }

  /// 列出工作区内的目录（相对路径为空 = 根目录）。
  ///
  /// 失败抛 [WorkspaceRequestException]（`friendlyMessage` 可直接展示）；
  /// 未连接时 code 为 `OFFLINE`。
  Future<WorkspaceListing> listDirectory({
    required String workspacePath,
    String relativePath = '',
  }) async {
    final payload = await _sendWorkspaceRequest(
      type: RelayMessageTypes.workspaceList,
      payload: <String, dynamic>{
        'workspacePath': workspacePath,
        'relativePath': relativePath,
      },
    );
    return WorkspaceListing.fromResult(
      payload,
      workspacePath: workspacePath,
      relativePath: relativePath,
    );
  }

  /// 读取工作区内的文本文件（只读，服务端按 maxBytes 截断）。
  Future<WorkspaceFileContent> readWorkspaceFile({
    required String workspacePath,
    required String relativePath,
    int? maxBytes,
  }) async {
    final payload = await _sendWorkspaceRequest(
      type: RelayMessageTypes.fileRead,
      payload: <String, dynamic>{
        'workspacePath': workspacePath,
        'relativePath': relativePath,
        if (maxBytes != null) 'maxBytes': maxBytes,
      },
    );
    return WorkspaceFileContent.fromResult(payload);
  }

  /// 保存/新建工作区内的文本文件（M2.8，写操作会先在 App 侧弹确认）。
  ///
  /// [baseSha256] 是打开文件时拿到的 sha256：与电脑端当前内容不一致时返回
  /// `CONFLICT`，调用方应提示用户重新加载或强制覆盖；新建文件不传。
  /// [force] 为 true 时跳过乐观锁（需要用户明确确认）。
  Future<WorkspaceWriteResult> writeWorkspaceFile({
    required String workspacePath,
    required String relativePath,
    required String content,
    String? baseSha256,
    bool force = false,
  }) async {
    final payload = await _sendWorkspaceRequest(
      type: RelayMessageTypes.fileWrite,
      payload: <String, dynamic>{
        'workspacePath': workspacePath,
        'relativePath': relativePath,
        'content': content,
        if (baseSha256 != null && baseSha256.isNotEmpty)
          'baseSha256': baseSha256,
        if (force) 'force': true,
      },
    );
    return WorkspaceWriteResult.fromResult(payload);
  }

  /// 发送一条 WSS 请求并把回包按 requestId 配对给挂起的 Future。
  Future<Map<String, dynamic>> _sendWorkspaceRequest({
    required String type,
    required Map<String, dynamic> payload,
  }) {
    if (!isConnected) {
      return Future<Map<String, dynamic>>.error(
        const WorkspaceRequestException('OFFLINE', '电脑端未连接，请先连接电脑'),
      );
    }
    final requestId =
        'req_${DateTime.now().microsecondsSinceEpoch}_${_workspaceRequestCounter++}';
    final completer = Completer<Map<String, dynamic>>();
    _pendingWorkspaceRequests[requestId] = _PendingWorkspaceRequest(
      type: type,
      completer: completer,
    );
    final sent = _relay.send(type, <String, dynamic>{
      ...payload,
      'requestId': requestId,
    });
    if (!sent) {
      _pendingWorkspaceRequests.remove(requestId);
      return Future<Map<String, dynamic>>.error(
        const WorkspaceRequestException('OFFLINE', '连接已断开，请重新连接电脑'),
      );
    }
    return completer.future.timeout(
      workspaceRequestTimeout,
      onTimeout: () {
        _pendingWorkspaceRequests.remove(requestId);
        throw const WorkspaceRequestException(
          'TIMEOUT',
          '请求超时：电脑端没有响应，请重试',
        );
      },
    );
  }

  /// 把 `workspace.list.result` / `file.read.result` / `file.write.result`
  /// 交给挂起请求表。
  ///
  /// 返回 true 表示这条消息已被处理（不会进入消息流/任务时间线）；
  /// 找不到 requestId 时也直接丢弃，不报错。
  bool _handleWorkspaceResult(RelayEvent event) {
    final isList = event.type == RelayMessageTypes.workspaceListResult;
    final isFile = event.type == RelayMessageTypes.fileReadResult;
    final isWrite = event.type == RelayMessageTypes.fileWriteResult;
    if (!isList && !isFile && !isWrite) return false;
    final rawRequestId = event.payload['requestId'];
    if (rawRequestId is! String || rawRequestId.isEmpty) return true;
    final pending = _pendingWorkspaceRequests.remove(rawRequestId);
    if (pending == null || pending.completer.isCompleted) return true;
    if (event.payload['ok'] == true) {
      pending.completer.complete(event.payload);
    } else {
      final code = event.payload['code'] is String
          ? event.payload['code'] as String
          : 'INTERNAL';
      final message = event.payload['message'] is String
          ? event.payload['message'] as String
          : '';
      pending.completer.completeError(
        WorkspaceRequestException(code, message),
      );
    }
    return true;
  }

  /// 断开/重置时让所有挂起请求失败，避免页面一直转圈。
  void _failPendingWorkspaceRequests(String message) {
    if (_pendingWorkspaceRequests.isEmpty) return;
    final pending = _pendingWorkspaceRequests.values.toList(growable: false);
    _pendingWorkspaceRequests.clear();
    for (final request in pending) {
      if (!request.completer.isCompleted) {
        request.completer.completeError(
          WorkspaceRequestException('OFFLINE', message),
        );
      }
    }
  }

  /// M4.50：开一场新对话——把当前会话号与聊天记录清掉，但不碰连接和工作区列表。
  ///
  /// 清完之后下一次 [sendPrompt] 会走 [createConversation]，并且把新会话落到
  /// [workspacePath]（不传就沿用 [setPendingWorkspace] 记住的那个目录）。
  ///
  /// 以前「新建会话」是直接发 conversation.create 建一个空会话：电脑端的 Agent
  /// 子进程确实建出来了，可两端的会话列表都看不到它，用户只能拿到一句 toast。
  void startNewConversation({String? workspacePath}) {
    setPendingWorkspace(workspacePath);
    _messages.clear();
    _toolCallIndex.clear();
    _seenSeqs.clear();
    _lastSeq = 0;
    _conversationId = null;
    _sessionId = null;
    _workspacePath = null;
    _taskState = null;
    _queuedPrompt = null;
    _contextUsed = null;
    _contextSize = null;
    _conversationRequested = false;
    _notify();
  }

  /// 发送提示词。没有会话时自动创建，并记住这条提示。
  void sendPrompt(String rawText) {
    final text = rawText.trim();
    if (text.isEmpty) return;
    if (!isConnected) {
      _warn('还未连接真实电脑，无法发送');
      return;
    }
    _errorText = null;
    // M2.1 契约 §4.2：会话 busy 时进入本地队列（深度 1），不丢弃、不报错。
    if (isBusy) {
      _queuePromptForTurn(text);
      return;
    }
    _beginTurn();
    _addUserMessage(text);
    _queuedPrompt = text;
    if (_conversationId == null) {
      createConversation();
    } else {
      _flushQueuedPrompt();
    }
    _notify();
  }

  /// 取消当前任务（契约 §3.1 `task.cancel`）。
  void cancel() {
    final id = _conversationId;
    if (!isConnected || id == null) {
      _warn('当前没有可取消的任务');
      return;
    }
    _relay.send(RelayMessageTypes.taskCancel, <String, dynamic>{
      'conversationId': id,
    });
    _addSystemNotice('已发送取消请求，等待电脑确认…');
    _notify();
  }

  /// 审批决定（契约 §3.1 `approval.decide`）。
  void decideApproval(bool approved) {
    final pending = _pendingApproval;
    if (pending == null) return;
    final conversation = pending.info.conversationId.isNotEmpty
        ? pending.info.conversationId
        : _conversationId;
    if (conversation == null) {
      _pendingApproval = null;
      unawaited(_cancelApprovalNotificationId(pending.info.approvalId));
      _warn('授权请求缺少会话 id，无法回传决定');
      return;
    }
    final sent = _relay.send(RelayMessageTypes.approvalDecide, <String, dynamic>{
      'conversationId': conversation,
      'approvalId': pending.info.approvalId,
      'decision': approved ? 'approved' : 'denied',
    });
    if (!sent) {
      _warn('授权决定发送失败：连接已断开');
      return;
    }
    _pendingApproval = null;
    unawaited(_cancelApprovalNotificationId(pending.info.approvalId));
    _addSystemNotice(approved ? '已允许本次操作，等待电脑执行…' : '已拒绝本次操作。');
    _notify();
  }

  /// 忽略当前授权请求（例如 App 退出前台时；不会回传后端，等超时自动拒绝）。
  void dismissApproval() {
    final pending = _pendingApproval;
    if (pending == null) return;
    _pendingApproval = null;
    unawaited(_cancelApprovalNotificationId(pending.info.approvalId));
    _notify();
  }

  // ---- M2.1 事件补拉（断线 / 后台恢复） ----

  /// 从服务端补拉 `afterSeq=lastSeq` 之后的会话事件，循环直到拉完
  /// （单页不足 [limit] 或游标不再前进）。
  ///
  /// 事件与实时帧走同一入口（[_applyFrame]），按 seq 去重并保持升序；
  /// 失败不阻塞当前会话，只记录 [catchUpError] 供 UI 展示“重试”。
  Future<void> catchUpEvents({int limit = 500}) async {
    final conversationId = _conversationId;
    if (!isConnected || conversationId == null) return;
    if (_catchUpLoading) return;
    if (_eventsUnavailable) return;
    _restUsed = true;
    _catchUpLoading = true;
    _catchUpError = null;
    _notify();
    try {
      var afterSeq = _lastSeq;
      for (var round = 0; round < 20; round++) {
        final page = await _withAuthRetry(() => _historyApi.events(
              _serverUrl,
              token: _activeToken(),
              conversationId: conversationId,
              afterSeq: afterSeq,
              limit: limit,
            ));
        // 期间切换了会话：这批事件已经不属于当前会话。
        if (_conversationId != conversationId) return;
        for (final record in page.events) {
          _applyFrame(record.toRelayEvent(), seq: record.seq);
        }
        final cursor = page.cursor;
        if (cursor <= afterSeq) break;
        afterSeq = cursor;
        if (page.events.length < limit) break;
      }
      _lastCatchUpAt = DateTime.now();
    } on PairingApiException catch (e) {
      if (e.statusCode == 404) {
        // 插件直连：没有历史接口，静默跳过（不是用户能修的错误）。
        _eventsUnavailable = true;
      } else {
        _catchUpError = e.message;
      }
    } catch (e) {
      _catchUpError = PairingApi.describeException(e);
    } finally {
      _catchUpLoading = false;
      _notify();
    }
  }

  /// 清掉补拉错误提示。
  void clearCatchUpError() {
    if (_catchUpError == null) return;
    _catchUpError = null;
    _notify();
  }

  // ---- M2.1 排队指令（队列深度 1，契约 §4.2） ----

  /// 移除排队中的指令（不会发送）。
  void removeQueuedPrompt() {
    final index = _queuedTurnIndex;
    _queuedTurnIndex = null;
    if (index == null) return;
    if (index >= 0 && index < _messages.length && _messages[index].queued) {
      _messages.removeAt(index);
      // 修正工具调用下标（排队气泡通常追加在末尾，这里只做保守处理）。
      final fixed = <String, int>{};
      _toolCallIndex.forEach((callId, value) {
        fixed[callId] = value > index ? value - 1 : value;
      });
      _toolCallIndex
        ..clear()
        ..addAll(fixed);
    }
    _notify();
  }

  // ---- M2.2 A2：「立即发送」排队指令 ----

  /// 立即发送排队中的指令（M2.2 A2）。
  ///
  /// 先发 `task.cancel` 打断当前任务：收到该任务终态或超过
  /// [interruptTimeout]（默认 3s）后，把排队消息作为新 prompt 发出。
  /// 已知限制：这不是 turn 内插话，而是「打断当前任务 + 改说这句」。
  void interruptAndSendQueuedPrompt() {
    if (!isConnected) {
      _warn('还未连接真实电脑，无法立即发送');
      return;
    }
    if (!hasQueuedPrompt) return;
    final id = _conversationId;
    if (id == null) {
      _warn('会话还没建立，无法立即发送排队指令');
      return;
    }
    if (_interruptInFlight) return;
    _interruptInFlight = true;
    _relay.send(RelayMessageTypes.taskCancel, <String, dynamic>{
      'conversationId': id,
    });
    _addSystemNotice('正在打断当前任务，随后发送排队指令…');
    _interruptTimer?.cancel();
    _interruptTimer = Timer(interruptTimeout, () {
      _finishInterrupt(sendQueued: true);
    });
    _notify();
  }

  /// 结束打断状态：按需把排队指令作为新 prompt 发出。
  void _finishInterrupt({required bool sendQueued}) {
    if (!_interruptInFlight) return;
    _interruptInFlight = false;
    _interruptTimer?.cancel();
    _interruptTimer = null;
    if (sendQueued) _sendQueuedTurnPrompt(force: true);
    _notify();
  }

  /// 清掉打断状态（断线/重置会话时调用，排队气泡保留）。
  void _cancelInterrupt() {
    _interruptInFlight = false;
    _interruptTimer?.cancel();
    _interruptTimer = null;
  }

  // ---- M2.2 轮次统计（内部） ----

  /// 开始新一轮（用户发出新指令）。
  void _beginTurn() {
    _turnCounter += 1;
    final id = _turnCounter;
    _turns[id] = TurnStats(turnId: id);
    _currentTurnId = id;
  }

  /// 记录该轮有工具/思考活动（首条活动时间 + toolCall 步数）。
  void _touchTurn({bool tool = false}) {
    final id = _currentTurnId;
    if (id == null) return;
    final stats = _turns[id];
    if (stats == null) return;
    stats.startedAt ??= DateTime.now();
    if (tool) stats.toolCount += 1;
  }

  /// 记录该轮进入终态（completed/failed/cancelled）。
  void _finishTurn(TaskStatus status) {
    final id = _currentTurnId;
    if (id == null) return;
    final stats = _turns[id];
    if (stats == null || stats.isTerminal) return;
    stats
      ..endedAt = DateTime.now()
      ..status = status;
  }


  /// 把一条中继消息应用到本地状态。所有 UI 变化都经由此处。
  void applyEvent(RelayEvent event) {
    _applyFrame(event);
  }

  /// 实时帧与补拉事件的统一入口：按 seq 去重，再交给 [_dispatchEvent]。
  void _applyFrame(RelayEvent event, {int? seq}) {
    final effectiveSeq = seq ?? _eventSeq(event);
    if (effectiveSeq != null) {
      if (_seenSeqs.contains(effectiveSeq)) return;
      _seenSeqs.add(effectiveSeq);
      if (effectiveSeq > _lastSeq) _lastSeq = effectiveSeq;
    }
    _dispatchEvent(event, seq: effectiveSeq);
  }

  /// 只有真正的正 seq 才参与去重；旧协议帧/本地事件可能缺 seq（协议层解析为 0），
  /// 不能把它们当成同一个事件反复吞掉。
  int? _eventSeq(RelayEvent event) {
    final seq = event.sessionUpdate?.seq;
    return (seq != null && seq > 0) ? seq : null;
  }

  void _dispatchEvent(RelayEvent event, {int? seq}) {
    // M2.6：项目同步回包优先配对给挂起请求，不进入消息流/任务时间线。
    if (_handleWorkspaceResult(event)) return;
    switch (event.type) {
      case RelayMessageTypes.sessionUpdate:
        final update = event.sessionUpdate;
        if (update != null) _applySessionUpdate(update, explicitSeq: seq);
        break;
      case RelayMessageTypes.taskState:
        final state = event.taskState;
        if (state != null) _applyTaskState(state);
        break;
      case RelayMessageTypes.approvalRequest:
        final request = event.approvalRequest;
        if (request != null) _applyApprovalRequest(request);
        break;
      case RelayMessageTypes.approvalResolved:
        final resolved = event.approvalResolved;
        if (resolved != null) _applyApprovalResolved(resolved);
        break;
      case RelayMessageTypes.deviceStatus:
        final status = event.deviceStatus;
        if (status != null) _applyDeviceStatus(status);
        break;
      case RelayMessageTypes.conversationCreated:
        final created = event.conversationCreated;
        if (created != null) _applyConversationCreated(created);
        break;
      case RelayMessageTypes.agentOnline:
        _addSystemNotice('电脑 Agent 已上线。');
        _notify();
        break;
      case RelayMessageTypes.agentOffline:
        _addSystemNotice('电脑 Agent 已离线，任务无法继续。');
        _notify();
        break;
      case RelayMessageTypes.error:
        final error = event.relayError;
        if (error != null) _applyRelayError(error);
        break;
      default:
        // 契约外消息：忽略，不影响现有状态。
        break;
    }
  }

  void _applySessionUpdate(SessionUpdate update, {int? explicitSeq}) {
    // 缺省 seq 在协议层会被解析成 0，这里统一归一化为 null（不参与去重/排序）。
    final rawSeq = explicitSeq ?? update.seq;
    final seq = (rawSeq > 0) ? rawSeq : null;
    switch (update.kind) {
      case SessionUpdateKind.output:
        _appendAssistantText(update.text, seq: seq);
        break;
      case SessionUpdateKind.thinking:
        _appendAssistantThinking(update.text, seq: seq);
        break;
      case SessionUpdateKind.toolCall:
        _applyToolCall(update, seq: seq);
        break;
      case SessionUpdateKind.toolCallUpdate:
        _applyToolCallUpdate(update);
        break;
      case SessionUpdateKind.usage:
        _contextUsed = update.contextUsed;
        _contextSize = update.contextSize;
        break;
      case SessionUpdateKind.unknown:
        break;
    }
    if (_taskState == null || _taskState == TaskStatus.queued) {
      _taskState = TaskStatus.running;
    }
    _notify();
  }

  void _applyToolCall(SessionUpdate update, {int? seq}) {
    final callId = update.callId ?? '';
    final tool = update.tool ?? '工具';
    final command = toolCommandFromInput(update.input);
    _touchTurn(tool: true);
    final item = ChatItem(
      role: ChatRole.assistant,
      kind: ChatItemKind.toolCall,
      text: tool,
      time: DateTime.now(),
      seq: seq,
      turnId: _currentTurnId,
      steps: <ToolStep>[
        ToolStep(
          title: tool,
          command: command.isEmpty ? '（无参数）' : command,
          status: 'running',
        ),
      ],
      collapsed: false,
    );
    _messages.add(item);
    if (callId.isNotEmpty) _toolCallIndex[callId] = _messages.length - 1;
  }

  void _applyToolCallUpdate(SessionUpdate update) {
    final callId = update.callId ?? '';
    final index = _toolCallIndex[callId];
    if (index == null || index < 0 || index >= _messages.length) return;
    final item = _messages[index];
    if (item.kind != ChatItemKind.toolCall || item.steps.isEmpty) return;
    final step = item.steps.first;
    final excerpt = update.resultExcerpt ?? step.output;
    _messages[index] = ChatItem(
      role: item.role,
      kind: item.kind,
      text: item.text,
      time: item.time,
      steps: <ToolStep>[
        ToolStep(
          title: step.title,
          command: step.command,
          status: toolCallStepStatus(update.status),
          durationMs: step.durationMs,
          exitCode: step.exitCode,
          output: excerpt,
        ),
      ],
      collapsed: item.collapsed,
      seq: item.seq,
      queued: item.queued,
      turnId: item.turnId,
    );
  }

  void _applyTaskState(TaskStateEvent state) {
    final mapped = switch (state.state) {
      RelayTaskState.queued => TaskStatus.queued,
      RelayTaskState.running => TaskStatus.running,
      RelayTaskState.completed => TaskStatus.completed,
      RelayTaskState.failed => TaskStatus.failed,
      RelayTaskState.cancelled => TaskStatus.cancelled,
      RelayTaskState.unknown => null,
    };
    if (mapped != null) _taskState = mapped;
    final pendingId = _pendingApproval?.approvalId;
    // M4.4：等待授权结束（完成/失败/取消）时撤掉可操作通知。
    if (state.state == RelayTaskState.completed ||
        state.state == RelayTaskState.failed ||
        state.state == RelayTaskState.cancelled) {
      _cancelApprovalNotice();
      // M4.44：紧急停止在等这个信号。
      final waiter = _taskTerminalWaiter;
      if (waiter != null && !waiter.isCompleted) waiter.complete(true);
    }
    switch (state.state) {
      case RelayTaskState.completed:
        _pendingApproval = null;
        if (pendingId != null) {
          unawaited(_cancelApprovalNotificationId(pendingId));
        }
        _addSystemNotice('任务已完成。');
        break;
      case RelayTaskState.failed:
        _pendingApproval = null;
        if (pendingId != null) {
          unawaited(_cancelApprovalNotificationId(pendingId));
        }
        final reason = state.errorMessage?.trim() ?? '';
        final code = state.errorCode;
        final base = code == null || code.isEmpty
            ? '任务失败。'
            : '任务失败：${describeRelayErrorCode(code)}';
        _addSystemNotice(reason.isEmpty ? base : '$base（$reason）');
        break;
      case RelayTaskState.cancelled:
        _pendingApproval = null;
        if (pendingId != null) {
          unawaited(_cancelApprovalNotificationId(pendingId));
        }
        _addSystemNotice('任务已取消。');
        break;
      case RelayTaskState.queued:
      case RelayTaskState.running:
      case RelayTaskState.unknown:
        break;
    }
    // M2.1：turn 结束（completed/failed/cancelled）后自动发出排队指令。
    // M2.2 A2：如果是「立即发送」中的打断，则由它来结束打断并发出队列。
    if (mapped != null) _finishTurn(mapped);
    // M4.4：电脑上这一轮刚结束——App 在后台时提醒一次（前台不打扰）。
    if (mapped == TaskStatus.completed ||
        mapped == TaskStatus.failed ||
        mapped == TaskStatus.cancelled) {
      _cancelApprovalNotice();
      if (!_appInForeground) {
        final title = _conversationLabel();
        final (headline, status) = switch (mapped) {
          TaskStatus.completed => ('任务已完成', 'completed'),
          TaskStatus.failed => ('任务失败了', 'failed'),
          _ => ('任务已取消', 'cancelled'),
        };
        unawaited(_notifyTaskFinished(
          key: 'task-${_sessionId ?? _conversationId ?? 'current'}',
          title: '$headline：$title',
          body: switch (mapped) {
            TaskStatus.completed => '点开看结果，可以直接在手机上继续发指令。',
            TaskStatus.failed => state.errorMessage?.trim().isNotEmpty == true
                ? state.errorMessage!.trim()
                : '点开看日志，可以接着发指令让它修。',
            _ => '这一轮已经停下，可以直接发新的指令。',
          },
          status: status,
          sessionId: _sessionId ?? _conversationId,
        ));
      }
    }
    if (_interruptInFlight) {
      _finishInterrupt(sendQueued: true);
    } else {
      _sendQueuedTurnPrompt();
    }
    _notify();
  }

  void _applyApprovalRequest(ApprovalRequestInfo request) {
    final previous = _pendingApproval;
    if (previous != null && previous.approvalId != request.approvalId) {
      unawaited(_cancelApprovalNotificationId(previous.approvalId));
    }
    final pending = PendingApproval(info: request);
    _pendingApproval = pending;
    _taskState = TaskStatus.waitingApproval;
    _addSystemNotice(
        '收到 ${request.tool} 的高风险操作授权请求，请在弹窗中处理。');
    // 前台由 ApprovalSheet 处理；后台/锁屏改发系统通知（tag=approvalId）。
    if (!_appInForeground) {
      unawaited(_showApprovalNotification(pending));
      // M4.4：再发一条可操作的「允许 / 拒绝」通知，通知栏里直接决定。
      unawaited(_showApprovalActionNotice(pending));
    }
    _notify();
  }

  void _applyApprovalResolved(ApprovalResolvedInfo resolved) {
    final pending = _pendingApproval;
    if (pending != null &&
        (resolved.approvalId.isEmpty ||
            pending.info.approvalId == resolved.approvalId)) {
      _pendingApproval = null;
      unawaited(_cancelApprovalNotificationId(pending.info.approvalId));
    }
    if (_taskState == TaskStatus.waitingApproval) {
      _taskState = TaskStatus.running;
    }
    _cancelApprovalNotice();
    _addSystemNotice(resolved.systemNotice);
    _notify();
  }

  void _applyDeviceStatus(DeviceStatusInfo status) {
    // M4.0：Hub 骨架 device.status（设备名写死 DeepSeek Harness、不带
    // workspaceRoots）与 Agent 的完整 device.status 会先后到达；骨架只清能力位，
    // 不能清掉工作区目录，否则「我的 → 工作区」和新建工作区会瞬间变空。
    // Agent 真正上报空目录（如未授权任何根目录）时仍照常清空。
    final skeleton = status.deviceName.trim() == 'DeepSeek Harness';
    final roots = status.workspaceRoots;
    if (!skeleton || roots.isNotEmpty) {
      _workspaceRoots = roots;
    }
    _deviceStatus = status;
    _maybeCreateConversation();
    _notify();
    // 设备名变化时刷新前台服务通知文案。
    unawaited(_startForegroundService());
  }

  void _applyConversationCreated(ConversationCreatedInfo created) {
    _conversationId = created.conversationId;
    _sessionId = created.sessionId;
    _workspacePath = created.workspacePath;
    // M2.6：会话已按项目工作区创建，清掉「项目内发指令」的待绑定标记。
    _pendingWorkspacePath = null;
    _flushQueuedPrompt();
    _sendQueuedTurnPrompt();
    _notify();
  }

  void _applyRelayError(RelayErrorInfo error) {
    _errorText = error.friendlyMessage;
    _addSystemNotice(error.systemNotice);
    if (error.code == 'DEVICE_OFFLINE') {
      _taskState = TaskStatus.queued;
    }
    _notify();
  }

  // ---- 内部 ----

  void _onRelayState(RelayClientState state) {
    switch (state) {
      case RelayClientState.connecting:
        _setConnectionState(LiveConnectionState.connecting);
        break;
      case RelayClientState.connected:
        final wasReconnect = _wasConnectedBefore;
        _wasConnectedBefore = true;
        _setConnectionState(LiveConnectionState.connected);
        _errorText = null;
        if (wasReconnect && !_reauthInFlight) {
          // 断线重连可能被中继重试和回前台续连同时触发，5 秒内只提示一次。
          final now = DateTime.now();
          final last = _lastReconnectNoticeAt;
          if (last == null || now.difference(last) > const Duration(seconds: 5)) {
            _lastReconnectNoticeAt = now;
            _addSystemNotice('连接已恢复。');
          }
          unawaited(_refreshAfterReconnect());
        }
        _maybeCreateConversation();
        unawaited(_onConnectedSideEffects());
        break;
      case RelayClientState.reconnecting:
        _setConnectionState(LiveConnectionState.connecting);
        _errorText = '连接已断开，正在自动重连…';
        break;
      case RelayClientState.error:
        _setConnectionState(LiveConnectionState.error);
        final autoRepairMessage = _errorText;
        if (autoRepairMessage == null ||
            !autoRepairMessage.startsWith('自动重新配对失败')) {
          _errorText = _relay.lastError ?? '连接出错，请重试';
        }
        _addSystemNotice('连接已断开：${_errorText ?? '未知原因'}');
        unawaited(_stopForegroundService());
        if (!_reauthInFlight) unawaited(_notifyDisconnected());
        break;
      case RelayClientState.idle:
        if (_connectionState != LiveConnectionState.idle) {
          _setConnectionState(LiveConnectionState.idle);
        }
        break;
    }
    _notify();
  }

  void _maybeCreateConversation() {
    if (!isConnected || _conversationId != null || _conversationRequested) {
      return;
    }
    createConversation();
  }

  void _flushQueuedPrompt() {
    final text = _queuedPrompt;
    final id = _conversationId;
    if (text == null || id == null) return;
    _queuedPrompt = null;
    _relay.send(RelayMessageTypes.promptSend, <String, dynamic>{
      'conversationId': id,
      'text': text,
    });
    _taskState = TaskStatus.queued;
  }

  /// busy 时把用户指令放入本地队列（深度 1，契约 §4.2）。
  void _queuePromptForTurn(String text) {
    if (hasQueuedPrompt) {
      _warn('已有一条排队中的指令，请先等待它发送或移除');
      return;
    }
    _messages.add(ChatItem(
      role: ChatRole.user,
      kind: ChatItemKind.text,
      text: text,
      time: DateTime.now(),
      queued: true,
    ));
    _queuedTurnIndex = _messages.length - 1;
    _notify();
  }

  /// turn 结束后自动发送排队指令：气泡转为普通用户消息并发 `prompt.send`。
  ///
  /// [force] 为 true 时用于「立即发送」的 3s 超时兜底（任务可能还没进入终态）。
  void _sendQueuedTurnPrompt({bool force = false}) {
    final index = _queuedTurnIndex;
    final id = _conversationId;
    if (!isConnected || id == null) return;
    if (!force && isBusy) return;
    if (index == null) return;
    if (index < 0 || index >= _messages.length || !_messages[index].queued) {
      _queuedTurnIndex = null;
      return;
    }
    final queued = _messages[index];
    _messages[index] = ChatItem(
      role: queued.role,
      kind: queued.kind,
      text: queued.text,
      time: queued.time,
      steps: queued.steps,
      collapsed: queued.collapsed,
      approvalTitle: queued.approvalTitle,
      approvalDetail: queued.approvalDetail,
    );
    _queuedTurnIndex = null;
    _beginTurn();
    _relay.send(RelayMessageTypes.promptSend, <String, dynamic>{
      'conversationId': id,
      'text': queued.text,
    });
    _taskState = TaskStatus.queued;
    _queuedPrompt = null;
    _notify();
  }

  void _appendAssistantText(String delta, {int? seq}) {
    if (delta.isEmpty) return;
    _appendAssistantDelta(ChatItemKind.text, delta, seq: seq);
  }

  void _appendAssistantThinking(String delta, {int? seq}) {
    if (delta.isEmpty) return;
    _touchTurn();
    _appendAssistantDelta(ChatItemKind.thinking, delta, seq: seq);
  }

  /// 相邻同 kind 的助手消息合并成一条，模拟流式输出。
  void _appendAssistantDelta(ChatItemKind kind, String delta, {int? seq}) {
    if (_messages.isNotEmpty) {
      final last = _messages.last;
      if (last.role == ChatRole.assistant &&
          last.kind == kind &&
          last.steps.isEmpty) {
        _messages[_messages.length - 1] = ChatItem(
          role: last.role,
          kind: last.kind,
          text: '${last.text}$delta',
          time: last.time,
          steps: last.steps,
          collapsed: last.collapsed,
          approvalTitle: last.approvalTitle,
          approvalDetail: last.approvalDetail,
          seq: last.seq ?? seq,
          queued: last.queued,
          turnId: last.turnId,
        );
        return;
      }
    }
    _messages.add(ChatItem(
      role: ChatRole.assistant,
      kind: kind,
      text: delta,
      time: DateTime.now(),
      seq: seq,
      turnId: _currentTurnId,
    ));
  }

  void _addUserMessage(String text) {
    _messages.add(ChatItem(
      role: ChatRole.user,
      kind: ChatItemKind.text,
      text: text,
      time: DateTime.now(),
    ));
  }

  void _addSystemNotice(String text) {
    _messages.add(ChatItem(
      role: ChatRole.system,
      kind: ChatItemKind.text,
      text: text,
      time: DateTime.now(),
    ));
  }

  void _resetConversationState() {
    _messages.clear();
    _toolCallIndex.clear();
    _taskState = null;
    _pendingApproval = null;
    _conversationId = null;
    _sessionId = null;
    _workspacePath = null;
    _workspaceRoots = const <String>[];
    _contextUsed = null;
    _contextSize = null;
    _queuedPrompt = null;
    _conversationRequested = false;
    _wasConnectedBefore = false;
    // M1.1：会话级 REST 状态一并清空。
    _lastSeq = 0;
    _historyLoaded = false;
    _historyLoading = false;
    _historyError = null;
    _selectedTask = null;
    _taskDetailLoading = false;
    _taskDetailError = null;
    _conversations.clear();
    _conversationsLoading = false;
    _conversationsError = null;
    _conversationsFetched = false;
    _tasks.clear();
    _tasksLoading = false;
    _tasksError = null;
    _tasksFetchedAt = null;
    _tasksFetched = false;
    _restUsed = false;
    // M2.1：事件去重 / 补拉 / 排队状态一并清空。
    _seenSeqs.clear();
    _catchUpLoading = false;
    _catchUpError = null;
    _lastCatchUpAt = null;
    _eventsUnavailable = false;
    _tasksRestUnavailable = false;
    _queuedTurnIndex = null;
    // M2.2：轮次统计与打断状态一并清空。
    _turns.clear();
    _turnCounter = 0;
    _currentTurnId = null;
    _cancelInterrupt();
    // M2.6：项目同步请求与「待绑定工作区」一并清理。
    _failPendingWorkspaceRequests('连接已断开，请重新连接电脑');
    _pendingWorkspacePath = null;
  }

  /// 操作类错误：只提示，不改变连接状态（例如未连接时误点发送）。
  void _warn(String message) {
    _errorText = message;
    _notify();
  }

  void _fail(String message) {
    _errorText = message;
    _setConnectionState(LiveConnectionState.error);
    _notify();
  }

  void _setConnectionState(LiveConnectionState next) {
    _connectionState = next;
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _interruptTimer?.cancel();
    _interruptTimer = null;
    _failPendingWorkspaceRequests('页面已关闭，请求已取消');
    unawaited(_eventSubscription.cancel());
    unawaited(_stateSubscription.cancel());
    unawaited(_authSubscription?.cancel());
    unawaited(_tapSubscription?.cancel());
    unawaited(_relay.dispose());
    super.dispose();
  }
}

/// M2.6：一条挂起的项目同步请求（按 requestId 配对回包）。
class _PendingWorkspaceRequest {
  _PendingWorkspaceRequest({required this.type, required this.completer});

  final String type;
  final Completer<Map<String, dynamic>> completer;
}
