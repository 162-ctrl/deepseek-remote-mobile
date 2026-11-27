/// M1 中继协议：消息信封与各 payload 的解析。
///
/// 唯一契约来源：`docs/design/M1_PROTOCOL.md` §3。
/// 本文件只依赖 `dart:convert`，因此可以脱离 Flutter 与网络做纯单测。
library;

import 'dart:convert';

/// 信封版本，固定为 1。
const int kRelayProtocolVersion = 1;

/// 协议错误（收到非契约消息时抛出，UI 层捕获后转为系统提示，不能让 App 崩）。
class RelayProtocolException implements Exception {
  RelayProtocolException(this.message);

  final String message;

  @override
  String toString() => 'RelayProtocolException: $message';
}

String _newMessageId() =>
    'msg_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

/// 生成一条 App → 后端消息的 JSON 文本（信封 §3）。
String encodeRelayMessage({
  required String type,
  Map<String, dynamic> payload = const {},
  String? id,
  DateTime? ts,
}) {
  if (type.isEmpty) {
    throw RelayProtocolException('type 不能为空');
  }
  return jsonEncode(<String, dynamic>{
    'v': kRelayProtocolVersion,
    'type': type,
    if (id != null) 'id': id,
    'ts': (ts ?? DateTime.now()).toUtc().toIso8601String(),
    'payload': payload,
  });
}

/// 解析后的一条中继消息（信封 + payload）。
class RelayEvent {
  RelayEvent({
    required this.type,
    this.id,
    this.ts,
    required Map<String, dynamic> payload,
  }) : payload = Map<String, dynamic>.unmodifiable(payload);

  /// 消息类型，见协议 §3.1。
  final String type;

  /// 客户端生成 / 服务端回填的关联 id，可为空。
  final String? id;

  /// 发送方时间，解析失败时为 null。
  final DateTime? ts;

  /// payload 对象（只读）。
  final Map<String, dynamic> payload;

  /// 从一行 WSS 文本帧解析；非法消息抛 [RelayProtocolException]。
  factory RelayEvent.parse(String raw) {
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (e) {
      throw RelayProtocolException('消息不是合法 JSON：${e.message}');
    }
    if (decoded is! Map<String, dynamic>) {
      throw RelayProtocolException('消息必须是 JSON 对象');
    }
    return RelayEvent.fromJson(decoded);
  }

  factory RelayEvent.fromJson(Map<String, dynamic> json) {
    final version = json['v'];
    if (version is! num || version.toInt() != kRelayProtocolVersion) {
      throw RelayProtocolException('不支持的协议版本：$version（期望 1）');
    }
    final type = json['type'];
    if (type is! String || type.isEmpty) {
      throw RelayProtocolException('消息缺少 type');
    }
    final payloadRaw = json['payload'];
    if (payloadRaw != null && payloadRaw is! Map<String, dynamic>) {
      throw RelayProtocolException('payload 必须是 JSON 对象');
    }
    final idRaw = json['id'];
    final tsRaw = json['ts'];
    return RelayEvent(
      type: type,
      id: idRaw is String && idRaw.isNotEmpty ? idRaw : null,
      ts: tsRaw is String ? DateTime.tryParse(tsRaw) : null,
      payload: payloadRaw as Map<String, dynamic>? ?? const <String, dynamic>{},
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'v': kRelayProtocolVersion,
        'type': type,
        if (id != null) 'id': id,
        'ts': (ts ?? DateTime.now()).toUtc().toIso8601String(),
        'payload': payload,
      };

  String encode() => jsonEncode(toJson());

  // ---- 各 type 的强类型视图：type 不匹配时返回 null，便于 switch/firstWhere。 ----

  SessionUpdate? get sessionUpdate =>
      type == RelayMessageTypes.sessionUpdate
          ? SessionUpdate.fromPayload(payload)
          : null;

  TaskStateEvent? get taskState => type == RelayMessageTypes.taskState
      ? TaskStateEvent.fromPayload(payload)
      : null;

  ApprovalRequestInfo? get approvalRequest =>
      type == RelayMessageTypes.approvalRequest
          ? ApprovalRequestInfo.fromPayload(payload)
          : null;

  ApprovalResolvedInfo? get approvalResolved =>
      type == RelayMessageTypes.approvalResolved
          ? ApprovalResolvedInfo.fromPayload(payload)
          : null;

  DeviceStatusInfo? get deviceStatus => type == RelayMessageTypes.deviceStatus
      ? DeviceStatusInfo.fromPayload(payload)
      : null;

  ConversationCreatedInfo? get conversationCreated =>
      type == RelayMessageTypes.conversationCreated
          ? ConversationCreatedInfo.fromPayload(payload)
          : null;

  RelayErrorInfo? get relayError => type == RelayMessageTypes.error
      ? RelayErrorInfo.fromPayload(payload)
      : null;

  /// 供测试 / 调试打印。
  static String newId() => _newMessageId();
}

/// 协议中的消息类型常量（§3.1）。
class RelayMessageTypes {
  const RelayMessageTypes._();

  // App → 后端
  static const String conversationCreate = 'conversation.create';
  static const String promptSend = 'prompt.send';
  static const String taskCancel = 'task.cancel';
  static const String approvalDecide = 'approval.decide';

  // M2.6 项目同步：WSS 请求-响应（不进入会话消息流）。
  static const String workspaceList = 'workspace.list';
  static const String fileRead = 'file.read';

  // M2.8 手机端写入（保存/新建，带 sha256 乐观锁）。
  static const String fileWrite = 'file.write';

  // 后端 → App
  static const String deviceStatus = 'device.status';
  static const String agentOnline = 'agent.online';
  static const String agentOffline = 'agent.offline';
  static const String conversationCreated = 'conversation.created';
  static const String sessionUpdate = 'session.update';
  static const String taskState = 'task.state';
  static const String approvalRequest = 'approval.request';
  static const String approvalResolved = 'approval.resolved';
  static const String error = 'error';

  // M2.6 项目同步：后端只广播、不分配 seq、不落 task_events。
  static const String workspaceListResult = 'workspace.list.result';
  static const String fileReadResult = 'file.read.result';

  // M2.8 写入结果（同样只广播、不分配 seq）。
  static const String fileWriteResult = 'file.write.result';
}

// ---------------------------------------------------------------------------
// 基础取值工具：payload 里字段缺失/类型不对时退化为默认值，保证 UI 不崩。
// ---------------------------------------------------------------------------

String _asString(Object? value) => value is String ? value : '';

String? _asNullableString(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

int? _asInt(Object? value) => switch (value) {
      int value => value,
      num value => value.toInt(),
      String value => int.tryParse(value),
      _ => null,
    };

bool _asBool(Object? value) => switch (value) {
      bool value => value,
      String value => value == 'true' || value == '1',
      num value => value != 0,
      _ => false,
    };

DateTime? _asDateTime(Object? value) =>
    value is String ? DateTime.tryParse(value) : null;

List<String> _asStringList(Object? value) => value is List
    ? value.whereType<String>().toList(growable: false)
    : const <String>[];

Map<String, bool> _asBoolMap(Object? value) {
  if (value is! Map) return const <String, bool>{};
  return <String, bool>{
    for (final entry in value.entries)
      if (entry.key is String) entry.key as String: _asBool(entry.value),
  };
}

// ---------------------------------------------------------------------------
// session.update（§3.2）
// ---------------------------------------------------------------------------

/// `session.update.kind`。
enum SessionUpdateKind {
  output('output'),
  thinking('thinking'),
  toolCall('tool_call'),
  toolCallUpdate('tool_call_update'),
  usage('usage'),

  /// 契约外的新 kind：忽略而不是报错。
  unknown('');

  const SessionUpdateKind(this.wireName);

  final String wireName;

  static SessionUpdateKind parse(String? raw) {
    for (final kind in values) {
      if (kind != unknown && kind.wireName == raw) return kind;
    }
    return unknown;
  }
}

/// 一条流式事件。单条消息的所有可能字段都放在一起（kind 决定哪些有值）。
class SessionUpdate {
  const SessionUpdate({
    required this.conversationId,
    required this.seq,
    required this.kind,
    this.text = '',
    this.callId,
    this.tool,
    this.input,
    this.status,
    this.resultExcerpt,
    this.contextUsed,
    this.contextSize,
  });

  factory SessionUpdate.fromPayload(Map<String, dynamic> payload) {
    return SessionUpdate(
      conversationId: _asString(payload['conversationId']),
      seq: _asInt(payload['seq']) ?? 0,
      kind: SessionUpdateKind.parse(_asNullableString(payload['kind'])),
      text: _asString(payload['text']),
      callId: _asNullableString(payload['callId']),
      tool: _asNullableString(payload['tool']),
      input: payload['input'],
      status: _asNullableString(payload['status']),
      resultExcerpt: _asNullableString(payload['resultExcerpt']),
      contextUsed: _asInt(payload['contextUsed']),
      contextSize: _asInt(payload['contextSize']),
    );
  }

  final String conversationId;

  /// 单会话内从 1 递增，App 用它排序/去重。
  final int seq;
  final SessionUpdateKind kind;

  /// output / thinking 的增量文本。
  final String text;

  /// tool_call / tool_call_update 的调用 id。
  final String? callId;

  /// tool_call 的工具名。
  final String? tool;

  /// tool_call 的原始参数（通常为 Map，也可能是字符串）。
  final Object? input;

  /// tool_call_update 的状态（pending / in_progress / completed / failed / cancelled）。
  final String? status;

  /// tool_call_update 的结果摘要。
  final String? resultExcerpt;

  /// usage 事件。
  final int? contextUsed;
  final int? contextSize;
}

/// 把 tool_call 的 `input` 压成单行命令展示文本。
///
/// 协议里 `input` 是全量 `rawInput`（任意 JSON），命令行工具通常带 `command`。
String toolCommandFromInput(Object? input) {
  if (input == null) return '';
  if (input is String) return input;
  if (input is Map) {
    for (final key in const ['command', 'cmd', 'script', 'code']) {
      final value = input[key];
      if (value is String && value.trim().isNotEmpty) return value;
    }
  }
  try {
    final encoded = jsonEncode(input);
    if (encoded.length <= 400) return encoded;
    return '${encoded.substring(0, 400)}…';
  } catch (_) {
    return input.toString();
  }
}

/// tool_call / tool_call_update 的状态 → 聊天卡片里的 step 状态（UI 只认 4 种）。
String toolCallStepStatus(String? rawStatus) => switch (rawStatus) {
      'completed' || 'done' || 'success' => 'done',
      'failed' || 'error' || 'cancelled' || 'canceled' => 'failed',
      _ => 'running',
    };

// ---------------------------------------------------------------------------
// task.state（§3.2）
// ---------------------------------------------------------------------------

/// 任务状态机（§3.2 的 5 态）。
enum RelayTaskState {
  queued('queued'),
  running('running'),
  completed('completed'),
  failed('failed'),
  cancelled('cancelled'),

  /// 契约外状态：保持上一次 UI 状态。
  unknown('');

  const RelayTaskState(this.wireName);

  final String wireName;

  static RelayTaskState parse(String? raw) {
    for (final state in values) {
      if (state != unknown && state.wireName == raw) return state;
    }
    return unknown;
  }
}

class TaskStateEvent {
  const TaskStateEvent({
    required this.conversationId,
    required this.state,
    this.errorCode,
    this.errorMessage,
  });

  factory TaskStateEvent.fromPayload(Map<String, dynamic> payload) {
    final detail = payload['detail'];
    Map<String, dynamic> detailMap = const <String, dynamic>{};
    if (detail is Map<String, dynamic>) {
      detailMap = detail;
    } else if (detail is Map) {
      detailMap = detail.cast<String, dynamic>();
    }
    return TaskStateEvent(
      conversationId: _asString(payload['conversationId']),
      state: RelayTaskState.parse(_asNullableString(payload['state'])),
      errorCode: _asNullableString(detailMap['code'] ?? payload['code']),
      errorMessage:
          _asNullableString(detailMap['message'] ?? payload['message']),
    );
  }

  final String conversationId;
  final RelayTaskState state;

  /// 仅 failed 时有值。
  final String? errorCode;
  final String? errorMessage;
}

// ---------------------------------------------------------------------------
// approval.request / approval.resolved（§3.2）
// ---------------------------------------------------------------------------

class ApprovalOption {
  const ApprovalOption({required this.kind, required this.label});

  factory ApprovalOption.fromJson(Map<String, dynamic> json) => ApprovalOption(
        kind: _asString(json['kind']),
        label: _asString(json['label']),
      );

  final String kind;
  final String label;
}

class ApprovalRequestInfo {
  const ApprovalRequestInfo({
    required this.conversationId,
    required this.approvalId,
    required this.tool,
    required this.input,
    required this.workspace,
    this.options = const <ApprovalOption>[],
    this.permissionLevel = 6,
    this.riskLevel = 'high',
    this.expiresAt,
  });

  factory ApprovalRequestInfo.fromPayload(Map<String, dynamic> payload) {
    final optionsRaw = payload['options'];
    final options = optionsRaw is List
        ? optionsRaw
            .whereType<Map>()
            .map((e) => ApprovalOption.fromJson(e.cast<String, dynamic>()))
            .toList(growable: false)
        : const <ApprovalOption>[];
    return ApprovalRequestInfo(
      conversationId: _asString(payload['conversationId']),
      approvalId: _asString(payload['approvalId']),
      tool: _asString(payload['tool']).isEmpty
          ? '未知工具'
          : _asString(payload['tool']),
      input: payload['input'],
      workspace: _asString(payload['workspace']),
      options: options,
      permissionLevel: _asInt(payload['permissionLevel']) ?? 6,
      riskLevel: _asNullableString(payload['riskLevel']) ?? 'high',
      expiresAt: _asDateTime(payload['expiresAt']),
    );
  }

  final String conversationId;
  final String approvalId;
  final String tool;

  /// 原始参数（通常含 command）。
  final Object? input;
  final String workspace;
  final List<ApprovalOption> options;
  final int permissionLevel;
  final String riskLevel;
  final DateTime? expiresAt;

  /// 展示给用户的命令行文本。
  String get command => toolCommandFromInput(input);
}

class ApprovalResolvedInfo {
  const ApprovalResolvedInfo({
    required this.conversationId,
    required this.approvalId,
    required this.decision,
    required this.decidedBy,
  });

  factory ApprovalResolvedInfo.fromPayload(Map<String, dynamic> payload) =>
      ApprovalResolvedInfo(
        conversationId: _asString(payload['conversationId']),
        approvalId: _asString(payload['approvalId']),
        decision: _asString(payload['decision']),
        decidedBy: _asString(payload['decidedBy']),
      );

  final String conversationId;
  final String approvalId;

  /// approved | denied | expired
  final String decision;

  /// phone | timeout | policy
  final String decidedBy;

  bool get approved => decision == 'approved';

  /// 中文标签，例如「已通过（来源：手机）」。
  String get readableLabel {
    final decisionLabel = switch (decision) {
      'approved' => '已通过',
      'denied' => '已拒绝',
      'expired' => '已超时（按拒绝处理）',
      _ => decision.isEmpty ? '已处理' : decision,
    };
    final byLabel = switch (decidedBy) {
      'phone' => '手机',
      'timeout' => '超时',
      'policy' => '策略',
      _ => decidedBy.isEmpty ? '未知来源' : decidedBy,
    };
    return '$decisionLabel · 来源：$byLabel';
  }

  /// 聊天里展示的系统提示。
  String get systemNotice => '授权$readableLabel。';
}

// ---------------------------------------------------------------------------
// device.status / conversation.created / error（§3.2）
// ---------------------------------------------------------------------------

class DeviceStatusInfo {
  const DeviceStatusInfo({
    required this.online,
    required this.deviceName,
    required this.agentVersion,
    required this.harnessVersion,
    this.capabilities = const <String, bool>{},
    this.workspaceRoots = const <String>[],
    this.lastSeen,
  });

  factory DeviceStatusInfo.fromPayload(Map<String, dynamic> payload) {
    final name = _asNullableString(payload['deviceName']);
    return DeviceStatusInfo(
      online: _asBool(payload['online']),
      deviceName: name ?? '未知设备',
      agentVersion: _asNullableString(payload['agentVersion']) ?? '未知',
      harnessVersion: _asNullableString(payload['harnessVersion']) ?? '未知',
      capabilities: _asBoolMap(payload['capabilities']),
      workspaceRoots: _asStringList(payload['workspaceRoots']),
      lastSeen: _asDateTime(payload['lastSeen']),
    );
  }

  final bool online;
  final String deviceName;
  final String agentVersion;
  final String harnessVersion;
  final Map<String, bool> capabilities;
  final List<String> workspaceRoots;
  final DateTime? lastSeen;
}

class ConversationCreatedInfo {
  const ConversationCreatedInfo({
    required this.conversationId,
    this.sessionId,
    this.workspacePath,
    this.title,
  });

  factory ConversationCreatedInfo.fromPayload(Map<String, dynamic> payload) =>
      ConversationCreatedInfo(
        conversationId: _asString(payload['conversationId']),
        sessionId: _asNullableString(payload['sessionId']),
        workspacePath: _asNullableString(payload['workspacePath']),
        title: _asNullableString(payload['title']),
      );

  final String conversationId;
  final String? sessionId;
  final String? workspacePath;
  final String? title;
}

/// 后端错误码 → 中文提示（§3.2 错误码表）。
const Map<String, String> relayErrorLabels = <String, String>{
  'AUTH_FAILED': '认证失败：配对码或 token 无效，请重新配对',
  'BAD_REQUEST': '请求格式不正确',
  'DEVICE_OFFLINE': '电脑 Agent 不在线，请确认电脑端已启动',
  'CONVERSATION_NOT_FOUND': '会话不存在，请重新创建会话',
  'SESSION_BUSY': '电脑正忙：上一个任务还没结束',
  'PATH_NOT_ALLOWED': '工作区路径不在允许范围内',
  'INTERNAL': '服务器内部错误，请稍后再试',
};

String describeRelayErrorCode(String? code) {
  if (code == null || code.isEmpty) return '未知错误';
  return relayErrorLabels[code] ?? '未知错误（$code）';
}

class RelayErrorInfo {
  const RelayErrorInfo({
    required this.code,
    required this.message,
    this.conversationId,
  });

  factory RelayErrorInfo.fromPayload(Map<String, dynamic> payload) =>
      RelayErrorInfo(
        code: _asString(payload['code']),
        message: _asString(payload['message']),
        conversationId: _asNullableString(payload['conversationId']),
      );

  final String code;
  final String message;
  final String? conversationId;

  String get friendlyMessage => describeRelayErrorCode(code);

  /// 聊天里展示的系统提示（中文提示 + 原始 message）。
  String get systemNotice {
    final detail = message.trim();
    return detail.isEmpty
        ? '出错：$friendlyMessage'
        : '出错：$friendlyMessage（$detail）';
  }
}
