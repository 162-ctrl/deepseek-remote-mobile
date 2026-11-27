import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models.dart';
import 'pairing_api.dart';
import 'relay_protocol.dart';

/// 一次带 `Authorization: Bearer <token>` 的 HTTP 调用。
///
/// 与 [JsonHttpSender] 分开定义，是因为 M1.1 的 REST 需要先带上配对 token；
/// 做成可注入的发送器后，纯单测里可以直接断言路径、query 与请求头。
typedef AuthorizedHttpSender = Future<JsonHttpResponse> Function(
  String method,
  Uri uri,
  Map<String, String> headers,
  Map<String, dynamic>? body,
);

/// M1.1：会话摘要（`GET /api/v1/conversations`）。
class ConversationSummary {
  const ConversationSummary({
    required this.conversationId,
    this.title = '未命名会话',
    this.workspacePath,
    this.sessionId,
    this.lastMessageAt,
    this.messageCount = 0,
    this.createdAt,
  });

  factory ConversationSummary.fromJson(Map<String, dynamic> json) {
    final id = json['conversationId'] ?? json['id'];
    if (id is! String || id.trim().isEmpty) {
      throw const PairingApiException('历史会话数据缺少 conversationId');
    }
    return ConversationSummary(
      conversationId: id,
      title: _nonEmpty(json['title']) ?? '未命名会话',
      workspacePath: _nonEmpty(json['workspacePath']),
      sessionId: _nonEmpty(json['sessionId']),
      lastMessageAt: _parseDate(json['lastMessageAt']),
      messageCount: _asInt(json['messageCount']) ?? 0,
      createdAt: _parseDate(json['createdAt']),
    );
  }

  final String conversationId;
  final String title;
  final String? workspacePath;
  final String? sessionId;
  final DateTime? lastMessageAt;
  final int messageCount;
  final DateTime? createdAt;

  /// 排序/展示用：最后消息时间优先，其次创建时间。
  DateTime get activityAt =>
      lastMessageAt ?? createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);

  /// 工作区目录名（没有路径时回退标题）。
  String get workspaceName {
    final path = workspacePath;
    if (path == null || path.isEmpty) return '未指定工作区';
    final parts =
        path.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).toList();
    return parts.isEmpty ? path : parts.last;
  }
}

/// 解析工具调用文本得到的结构化信息。
class ToolCallSummary {
  const ToolCallSummary({required this.tool, required this.command});

  final String tool;
  final String command;
}

/// 把后端存的 `tool_call` 文本解析成「工具名 + 命令」。
///
/// 后端按契约把 tool_call 存成 `{"tool":"pwsh","input":"rg -n ..."}` 或
/// `{"tool":"pwsh","input":{"command":"rg -n ..."}}`；解析失败时按纯文本处理，
/// 避免 UI 直接显示原始 JSON 片段。
ToolCallSummary parseToolCallText(String text, {String? fallbackTool}) {
  final raw = text.trim();
  final fallback = (fallbackTool ?? '').trim();
  if (raw.startsWith('{')) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        final tool = _nonEmpty(decoded['tool']) ??
            _nonEmpty(decoded['toolName']) ??
            (fallback.isEmpty ? '工具' : fallback);
        Object? input;
        if (decoded.containsKey('input')) input = decoded['input'];
        var command = toolCommandFromInput(input);
        if (command.trim().isEmpty) {
          command = toolCommandFromInput(decoded);
        }
        return ToolCallSummary(tool: tool, command: command);
      }
    } catch (_) {
      // 不是 JSON：按纯文本命令处理。
    }
  }
  return ToolCallSummary(
    tool: fallback.isEmpty ? '工具' : fallback,
    command: raw,
  );
}

/// M1.1：一条历史消息（`GET /api/v1/conversations/{id}/messages`）。
class HistoryMessage {
  const HistoryMessage({
    required this.seq,
    required this.role,
    required this.kind,
    required this.text,
    this.messageId,
    this.toolName,
    this.metadata = const <String, dynamic>{},
    this.createdAt,
  });

  factory HistoryMessage.fromJson(Map<String, dynamic> json) {
    return HistoryMessage(
      seq: _asInt(json['seq']) ?? 0,
      role: _nonEmpty(json['role']) ?? 'assistant',
      kind: _nonEmpty(json['kind']) ?? 'text',
      text: json['text'] is String ? json['text'] as String : '',
      messageId: _nonEmpty(json['messageId']),
      toolName: _nonEmpty(json['toolName']),
      metadata: _asMap(json['metadata']) ?? const <String, dynamic>{},
      createdAt: _parseDate(json['createdAt']),
    );
  }

  final int seq;
  final String role;
  final String kind;
  final String text;
  final String? messageId;
  final String? toolName;
  final Map<String, dynamic> metadata;
  final DateTime? createdAt;

  String? get status => _nonEmpty(metadata['status']);

  int? get durationMs => _asInt(metadata['durationMs']);

  int? get exitCode => _asInt(metadata['exitCode']);

  String? get callId => _nonEmpty(metadata['callId']);

  /// 历史消息 → 聊天视图模型。`tool_call` 解析成结构化命令，
  /// `tool_result` 走独立的输出块，不再显示原始 JSON。
  ChatItem toChatItem() {
    switch (kind) {
      case 'thinking':
        return ChatItem(
          role: ChatRole.assistant,
          kind: ChatItemKind.thinking,
          text: text,
          time: createdAt,
          seq: seq,
        );
      case 'tool_call':
        final call = parseToolCallText(text, fallbackTool: toolName);
        return ChatItem(
          role: ChatRole.assistant,
          kind: ChatItemKind.toolCall,
          text: call.tool,
          time: createdAt,
          seq: seq,
          steps: <ToolStep>[
            ToolStep(
              title: call.tool,
              command: call.command.isEmpty ? '（无参数）' : call.command,
              status: toolCallStepStatus(status ?? 'completed'),
              durationMs: durationMs,
              exitCode: exitCode,
            ),
          ],
          collapsed: false,
        );
      case 'tool_result':
        final output = text.trim();
        return ChatItem(
          role: ChatRole.assistant,
          kind: ChatItemKind.toolResult,
          text: output,
          time: createdAt,
          seq: seq,
          steps: <ToolStep>[
            ToolStep(
              title: toolName ?? '工具输出',
              command: '',
              status: toolCallStepStatus(status ?? 'completed'),
              durationMs: durationMs,
              exitCode: exitCode,
              output: output,
            ),
          ],
          collapsed: true,
        );
      case 'system':
        return ChatItem(
          role: ChatRole.system,
          kind: ChatItemKind.text,
          text: text,
          time: createdAt,
          seq: seq,
        );
      default:
        return ChatItem(
          role: role == 'user' ? ChatRole.user : ChatRole.assistant,
          kind: ChatItemKind.text,
          text: text,
          time: createdAt,
          seq: seq,
        );
    }
  }
}

/// 历史消息分页结果。
class ConversationMessagesPage {
  const ConversationMessagesPage({
    required this.conversationId,
    required this.messages,
  });

  factory ConversationMessagesPage.fromJson(
    Map<String, dynamic> json, {
    String fallbackConversationId = '',
  }) {
    final raw = json['messages'];
    final messages = raw is List
        ? raw
            .whereType<Map<String, dynamic>>()
            .map(HistoryMessage.fromJson)
            .toList()
        : <HistoryMessage>[];
    messages.sort((a, b) => a.seq.compareTo(b.seq));
    return ConversationMessagesPage(
      conversationId: _nonEmpty(json['conversationId']) ?? fallbackConversationId,
      messages: messages,
    );
  }

  final String conversationId;
  final List<HistoryMessage> messages;

  int get maxSeq =>
      messages.fold<int>(0, (max, m) => m.seq > max ? m.seq : max);

  List<ChatItem> toChatItems() =>
      messages.map((m) => m.toChatItem()).toList();
}

/// M2.1：增量补拉的一条会话事件（`GET /api/v1/conversations/{id}/events`）。
///
/// `payload` 与 WebSocket 实时帧的 payload 完全一致，因此可以转成
/// [RelayEvent] 后走与实时流相同的处理入口。
class ConversationEventRecord {
  const ConversationEventRecord({
    required this.seq,
    required this.type,
    this.kind,
    this.payload = const <String, dynamic>{},
    this.createdAt,
  });

  factory ConversationEventRecord.fromJson(Map<String, dynamic> json) {
    return ConversationEventRecord(
      seq: _asInt(json['seq']) ?? 0,
      type: _nonEmpty(json['type']) ?? 'unknown',
      kind: _nonEmpty(json['kind']),
      payload: _asMap(json['payload']) ?? const <String, dynamic>{},
      createdAt: _parseDate(json['createdAt']),
    );
  }

  final int seq;
  final String type;
  final String? kind;
  final Map<String, dynamic> payload;
  final DateTime? createdAt;

  RelayEvent toRelayEvent() => RelayEvent.fromJson(<String, dynamic>{
        'v': 1,
        'type': type,
        'payload': payload,
      });
}

/// M2.1：增量事件分页结果（events 按 seq 升序）。
class ConversationEventsPage {
  const ConversationEventsPage({
    required this.conversationId,
    required this.events,
    this.nextSeq,
  });

  factory ConversationEventsPage.fromJson(
    Map<String, dynamic> json, {
    String fallbackConversationId = '',
  }) {
    final raw = json['events'];
    final events = raw is List
        ? raw
            .whereType<Map<String, dynamic>>()
            .map(ConversationEventRecord.fromJson)
            .toList()
        : <ConversationEventRecord>[];
    events.sort((a, b) => a.seq.compareTo(b.seq));
    return ConversationEventsPage(
      conversationId:
          _nonEmpty(json['conversationId']) ?? fallbackConversationId,
      events: events,
      nextSeq: _asInt(json['nextSeq']),
    );
  }

  final String conversationId;
  final List<ConversationEventRecord> events;

  /// 服务端建议的下一次 `afterSeq`；缺失时回退到最大 seq。
  final int? nextSeq;

  bool get isEmpty => events.isEmpty;

  int get maxSeq => events.fold<int>(0, (max, e) => e.seq > max ? e.seq : max);

  /// 下一次补拉应该使用的游标。
  int get cursor {
    final next = nextSeq;
    if (next != null && next > maxSeq) return next;
    return maxSeq;
  }
}

/// M1.1：任务详情里的一条事件（`GET /api/v1/tasks/{id}` → `events[]`）。
class TaskEventRecord {
  const TaskEventRecord({
    required this.seq,
    required this.type,
    required this.title,
    this.at,
    this.tool,
    this.detail = '',
  });

  factory TaskEventRecord.fromJson(Map<String, dynamic> json) {
    return TaskEventRecord(
      seq: _asInt(json['seq']) ?? 0,
      at: _parseDate(json['at']),
      type: _nonEmpty(json['type']) ?? 'event',
      title: _nonEmpty(json['title']) ?? '',
      tool: _nonEmpty(json['tool']),
      detail: json['detail'] is String ? json['detail'] as String : '',
    );
  }

  final int seq;
  final DateTime? at;
  final String type;
  final String title;
  final String? tool;
  final String detail;

  bool get isFailure =>
      type == 'failed' ||
      type == 'error' ||
      type == 'cancelled' ||
      type == 'canceled';

  bool get isToolCall => type == 'tool_call' || type == 'tool_call_update';

  bool get done =>
      !isFailure && type != 'running' && type != 'pending' && type != 'queued';

  TaskEvent toTaskEvent() {
    return TaskEvent(
      time: at ?? DateTime.now(),
      title: title.isEmpty ? type : title,
      detail: detail,
      done: done,
      tool: tool,
      type: type,
      seq: seq,
    );
  }
}

/// M2.9.3：桌面会话直播流里的一条事件（只读）。
class DesktopSessionEvent {
  const DesktopSessionEvent({
    required this.seq,
    required this.kind,
    this.text = '',
    this.name,
    this.args,
    this.callId,
    this.ok = true,
    this.reason,
    this.time = 0,
  });

  factory DesktopSessionEvent.fromJson(Map<String, dynamic> json) {
    return DesktopSessionEvent(
      seq: _asInt(json['seq']) ?? 0,
      kind: _nonEmpty(json['kind']) ?? 'other',
      text: _nonEmpty(json['text']) ?? '',
      name: _nonEmpty(json['name']),
      args: _nonEmpty(json['args']),
      callId: _nonEmpty(json['callId']),
      ok: json['ok'] != false,
      reason: _nonEmpty(json['reason']),
      time: _asInt(json['time']) ?? 0,
    );
  }

  final int seq;
  final String kind;
  final String text;
  final String? name;
  final String? args;
  final String? callId;
  final bool ok;
  final String? reason;

  /// M4.3：事件发生时刻（毫秒时间戳）——插件 0.2.12 起下发，用于和电脑端对齐「已运行」。
  final int time;

  /// 只换文本，用于把相邻的助手消息并成一段。
  DesktopSessionEvent withText(String value) => DesktopSessionEvent(
        seq: seq,
        kind: kind,
        text: value,
        name: name,
        args: args,
        callId: callId,
        ok: ok,
        reason: reason,
        time: time,
      );
}

/// M2.9.4：桌面会话里等待手机应答的一次授权。
class DesktopApproval {
  const DesktopApproval({
    required this.approvalId,
    required this.toolName,
    this.reason = '',
    this.createdAt = 0,
  });

  factory DesktopApproval.fromJson(Map<String, dynamic> json) {
    return DesktopApproval(
      approvalId: _nonEmpty(json['approvalId']) ?? '',
      toolName: _nonEmpty(json['toolName']) ?? '工具',
      reason: _nonEmpty(json['reason']) ?? '',
      createdAt: _asInt(json['createdAt']) ?? 0,
    );
  }

  final String approvalId;
  final String toolName;
  final String reason;
  final int createdAt;
}

/// M4.23：桌面会话里等待手机回答的一个问题选项。
class DesktopQuestionOption {
  const DesktopQuestionOption({required this.label, this.description = ''});

  factory DesktopQuestionOption.fromJson(Map<String, dynamic> json) {
    return DesktopQuestionOption(
      label: _nonEmpty(json['label']) ?? '',
      description: _nonEmpty(json['description']) ?? '',
    );
  }

  final String label;
  final String description;
}

/// M4.23：一个问题（对应电脑端「确认需求」卡片里的一页）。
class DesktopQuestionItem {
  const DesktopQuestionItem({
    required this.id,
    required this.question,
    this.header = '',
    this.detail = '',
    this.options = const <DesktopQuestionOption>[],
    this.multiSelect = false,
  });

  factory DesktopQuestionItem.fromJson(Map<String, dynamic> json) {
    final rawOptions = json['options'];
    return DesktopQuestionItem(
      id: _nonEmpty(json['id']) ?? '',
      question: _nonEmpty(json['question']) ?? '',
      header: _nonEmpty(json['header']) ?? '',
      detail: _nonEmpty(json['detail']) ?? '',
      multiSelect: json['multiSelect'] == true,
      options: rawOptions is List
          ? rawOptions
              .whereType<Map<String, dynamic>>()
              .map(DesktopQuestionOption.fromJson)
              .where((option) => option.label.isNotEmpty)
              .toList(growable: false)
          : const <DesktopQuestionOption>[],
    );
  }

  final String id;
  final String question;
  final String header;
  final String detail;
  final List<DesktopQuestionOption> options;
  final bool multiSelect;
}

/// M4.23：一批待回答的问题（电脑端那张「确认需求」卡）。
class DesktopQuestion {
  const DesktopQuestion({
    required this.questionId,
    this.items = const <DesktopQuestionItem>[],
    this.createdAt = 0,
  });

  factory DesktopQuestion.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    return DesktopQuestion(
      questionId: _nonEmpty(json['questionId']) ?? '',
      createdAt: _asInt(json['createdAt']) ?? 0,
      items: rawItems is List
          ? rawItems
              .whereType<Map<String, dynamic>>()
              .map(DesktopQuestionItem.fromJson)
              .where((item) => item.id.isNotEmpty)
              .toList(growable: false)
          : const <DesktopQuestionItem>[],
    );
  }

  final String questionId;
  final List<DesktopQuestionItem> items;
  final int createdAt;
}

/// M4.23：手机回答一条问题时的选择。
class DesktopQuestionAnswer {
  const DesktopQuestionAnswer({
    required this.id,
    this.selected = const <String>[],
    this.custom = '',
  });

  final String id;
  final List<String> selected;
  final String custom;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'selected': selected,
        if (custom.isNotEmpty) 'custom': custom,
      };
}

/// M3.0：手机附件上传到电脑后的结果。
class DesktopUpload {
  const DesktopUpload({
    required this.name,
    required this.path,
    required this.size,
  });

  factory DesktopUpload.fromJson(Map<String, dynamic> json) {
    return DesktopUpload(
      name: _nonEmpty(json['name']) ?? '附件',
      path: _nonEmpty(json['path']) ?? '',
      size: _asInt(json['size']) ?? 0,
    );
  }

  final String name;

  /// 电脑上的绝对路径。
  final String path;
  final int size;
}

/// M4.66：更新日志里的一条——对应 `docs/UPDATE_NOTES.md` 的一个 `## ` 段。
class UpdateNote {
  const UpdateNote({
    required this.version,
    required this.title,
    required this.body,
    this.date = '',
  });

  factory UpdateNote.fromJson(Map<String, dynamic> json) {
    return UpdateNote(
      version: _nonEmpty(json['version']) ?? '',
      title: _nonEmpty(json['title']) ?? '',
      body: _nonEmpty(json['body']) ?? '',
      date: _nonEmpty(json['date']) ?? '',
    );
  }

  final String version;
  final String title;
  final String body;
  final String date;
}

/// M4.57：「功能 → 接收文件」里的一项——电脑端放进插件 received 目录的文件。
class ReceivedFile {
  const ReceivedFile({required this.name, required this.size, this.updatedAt});

  factory ReceivedFile.fromJson(Map<String, dynamic> json) {
    final raw = json['updatedAt'];
    final millis = raw is num ? raw.toInt() : int.tryParse('${raw ?? ''}');
    return ReceivedFile(
      name: _nonEmpty(json['name']) ?? '',
      size: _asInt(json['size']) ?? 0,
      updatedAt: (millis == null || millis <= 0)
          ? null
          : DateTime.fromMillisecondsSinceEpoch(millis),
    );
  }

  final String name;
  final int size;
  final DateTime? updatedAt;
}

/// M4.0：手机端新建工作区（电脑端在第一个授权根目录下建子目录）的结果。
class DesktopWorkspaceCreated {
  const DesktopWorkspaceCreated({
    required this.name,
    required this.path,
    this.parent = '',
  });

  factory DesktopWorkspaceCreated.fromJson(Map<String, dynamic> json) {
    final path = _nonEmpty(json['path']) ?? '';
    final name = _nonEmpty(json['name']) ??
        (path.isEmpty ? '' : path.replaceAll('\\', '/').split('/').last);
    return DesktopWorkspaceCreated(
      name: name,
      path: path,
      parent: _nonEmpty(json['parent']) ?? '',
    );
  }

  /// 电脑端清理后的目录名（非法字符已替换成 `-`）。
  final String name;

  /// 新建出来的绝对路径。
  final String path;

  /// M4.13：真正落盘的父目录（插件选定的授权根 / 项目根）。
  final String parent;
}

/// M4.10：电脑端（插件）存的会话存档条目。
///
/// DSH 重启后会话可能从列表消失（Host 只认已物化日志），插件的存档会把它留着，
/// 手机端于是还能看到「以前跑过、现在电脑列表里没有」的会话。
class ArchivedSession {
  const ArchivedSession({
    required this.id,
    this.title = '',
    this.workspace = '',
    this.source = '',
    this.createdAt = 0,
    this.lastTime = 0,
    this.messageCount = 0,
    this.eventCount = 0,
    this.archivedAt = '',
  });

  factory ArchivedSession.fromJson(Map<String, dynamic> json) {
    return ArchivedSession(
      id: _nonEmpty(json['id']) ?? '',
      title: _nonEmpty(json['title']) ?? '',
      workspace: _nonEmpty(json['workspace']) ?? '',
      source: _nonEmpty(json['source']) ?? '',
      createdAt: _asInt(json['createdAt']) ?? 0,
      lastTime: _asInt(json['lastTime']) ?? 0,
      messageCount: _asInt(json['messageCount']) ?? 0,
      eventCount: _asInt(json['eventCount']) ?? 0,
      archivedAt: _nonEmpty(json['archivedAt']) ?? '',
    );
  }

  final String id;
  final String title;
  final String workspace;

  /// `live` = 电脑端运行时的存档；`disk` = 从 DSH 磁盘日志恢复的；
  /// 其它值（如 `imported`）来自手机端补传。
  final String source;
  final int createdAt;
  final int lastTime;
  final int messageCount;
  final int eventCount;
  final String archivedAt;

  bool get fromDisk => source == 'disk';
}

/// M2.9.3：一次拉取拿到的桌面会话快照 + 增量事件。
/// M4.24：给存档会话发话时，电脑会先把那条会话从「已存档」里放出来（抬起
/// ArchivedSessionGate），再在**同一条会话**里接着聊，所以 sessionId 不变、
/// 只多一个 `resumed` 标记。`forked` 是 M4.19 的旧字段，留着兼容老电脑。
class DesktopPromptResult {
  const DesktopPromptResult({
    required this.sessionId,
    this.forked = false,
    this.forkedFrom = '',
    this.resumed = false,
  });

  factory DesktopPromptResult.fromJson(
    Map<String, dynamic> json, {
    required String fallbackSessionId,
  }) {
    final id = _nonEmpty(json['sessionId']) ?? fallbackSessionId;
    return DesktopPromptResult(
      sessionId: id,
      forked: json['forked'] == true,
      forkedFrom: _nonEmpty(json['forkedFrom']) ?? fallbackSessionId,
      resumed: json['resumed'] == true,
    );
  }

  /// 消息实际落到的会话（M4.24 起存档会话也还是原来那条）。
  final String sessionId;

  /// M4.19 老行为：电脑把存档会话复制成了一条新会话。
  final bool forked;

  /// fork 之前的会话 id。
  final String forkedFrom;

  /// M4.24：电脑把这条存档会话接回原对话继续了。
  final bool resumed;
}

/// M4.21：一条「排队消息」——电脑端对话里「N 条排队消息」面板中的一行。
///
/// 内容是用户已经发出去、但那一轮还在跑所以暂存在队列里的话。电脑端可以改字、
/// 删除、或者「插话」立刻送进去；手机上现在也要能这么干。
class DesktopQueueItem {
  const DesktopQueueItem({
    required this.id,
    required this.placement,
    required this.text,
  });

  factory DesktopQueueItem.fromJson(Map<String, dynamic> json) {
    return DesktopQueueItem(
      id: _nonEmpty(json['id']) ?? '',
      placement: _nonEmpty(json['placement']) ?? 'queued',
      text: (json['text'] as String? ?? '').trim(),
    );
  }

  final String id;

  /// `queued`（排在这一轮之后）/ `steering`（插话中）/ `context`。
  final String placement;

  final String text;

  /// 「插话中」的那条在电脑上已经进去了，不再给学生改/删的机会。
  bool get pending => placement == 'queued';
}

/// M4.21：一个会话的排队消息快照。
class DesktopQueue {
  const DesktopQueue({
    this.items = const <DesktopQueueItem>[],
    this.running = false,
    this.supported = true,
    this.error = '',
  });

  factory DesktopQueue.fromJson(Map<String, dynamic> json) {
    final raw = json['items'];
    return DesktopQueue(
      items: <DesktopQueueItem>[
        if (raw is List)
          for (final row in raw)
            if (row is Map<String, dynamic>) DesktopQueueItem.fromJson(row),
      ],
      running: json['running'] == true,
      supported: json['supported'] != false,
      error: _nonEmpty(json['error']) ?? '',
    );
  }

  final List<DesktopQueueItem> items;
  final bool running;

  /// 老版本 Harness 读不到队列时为 false，手机据此不显示面板。
  final bool supported;

  final String error;
}

/// M4.31：电脑上正等着手机回答的一条提问（跨会话摘要）。
///
/// 只有标题级别的信息：会话 id、会话标题、问题数、第一条问题的 header/question。
/// 完整选项仍然从 `/sessions/<id>/events` 的 `questions` 里拿——两处各存一份迟早对不上。
class DesktopPendingQuestion {
  const DesktopPendingQuestion({
    required this.sessionId,
    required this.questionId,
    this.count = 0,
    this.header = '',
    this.question = '',
    this.title = '',
    this.createdAt = 0,
  });

  factory DesktopPendingQuestion.fromJson(Map<String, dynamic> json) {
    return DesktopPendingQuestion(
      sessionId: _nonEmpty(json['sessionId']) ?? '',
      questionId: _nonEmpty(json['questionId']) ?? '',
      count: (json['count'] as num?)?.toInt() ?? 0,
      header: _nonEmpty(json['header']) ?? '',
      question: _nonEmpty(json['question']) ?? '',
      title: _nonEmpty(json['title']) ?? '',
      createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
    );
  }

  final String sessionId;
  final String questionId;
  final int count;
  final String header;
  final String question;

  /// 电脑端那条会话的标题；电脑上已经看不到它时为空。
  final String title;
  final int createdAt;
}

/// M4.31：跨会话的「电脑在等你」摘要。
class DesktopPending {
  const DesktopPending({
    this.questions = const <DesktopPendingQuestion>[],
    this.answerable = true,
    this.error = '',
  });

  factory DesktopPending.fromJson(Map<String, dynamic> json) {
    final raw = json['questions'];
    return DesktopPending(
      questions: <DesktopPendingQuestion>[
        if (raw is List)
          for (final row in raw)
            if (row is Map<String, dynamic>) DesktopPendingQuestion.fromJson(row),
      ],
      answerable: json['answerable'] != false,
      error: _nonEmpty(json['error']) ?? '',
    );
  }

  final List<DesktopPendingQuestion> questions;

  /// 插件太旧（501）时为 false，手机据此说明原因而不是反复轮询报错。
  final bool answerable;

  final String error;

  bool get isEmpty => questions.isEmpty;
}

/// M4.25：一个钱包（Host 的 `AccountWallet`）。
class AccountWallet {
  const AccountWallet({required this.currency, required this.balance});

  factory AccountWallet.fromJson(Map<String, dynamic> json) {
    return AccountWallet(
      currency: _nonEmpty(json['currency']) ?? '',
      balance: (json['balance'] as String? ?? json['balance']?.toString() ?? '').trim(),
    );
  }

  /// `CNY` / `USD`。
  final String currency;

  /// Host 给的是字符串（`"12.34"`），原样保留，避免浮点误差。
  final String balance;

  String get symbol {
    final code = currency.trim().toUpperCase();
    if (code == 'CNY' || code == 'RMB') return '¥';
    if (code == 'USD') return r'$';
    return '';
  }

  /// M4.32：Host 给的是定点小数的原始串，`"12.4137841000000000"`、`"0E-16"` 都见过，
  /// 直接显示会挤出十几个小数位。
  String get display => '$symbol${formatMoneyAmount(balance)}';

  /// M4.32：判断这个钱包是不是空的（`"0"`、`"0E-16"`、`""` 都算空）。
  bool get isZero {
    final parsed = _parseMoney(balance);
    return parsed == null ? balance.trim().isEmpty : parsed.abs() < 0.005;
  }
}

/// M4.32：把 Host 的定点小数字符串压成给人看的金额（钱一律两位小数）。
///
/// - `""` → `""`，解析不了的原样返回（比如未来的新格式，别把它吞掉）
/// - `"12.4137841000000000"` → `"12.41"`
/// - `"3.0000000000"` → `"3.00"`
/// - 指数形式也认：`"0E-16"` → `"0.00"`
String formatMoneyAmount(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return '';
  final parsed = _parseMoney(trimmed);
  if (parsed == null) return trimmed;
  final abs = parsed.abs();
  if (abs >= 1e15) return trimmed;
  if (abs < 0.005) return '0.00';
  return parsed.toStringAsFixed(2);
}

double? _parseMoney(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  final direct = double.tryParse(trimmed);
  if (direct != null) return direct;
  // `"0E-16"` 里的 E 大写能解析，但 `"1,234.5"` 这类带千分位的不行，兜底去逗号再试。
  return double.tryParse(trimmed.replaceAll(',', ''));
}

/// M4.25：电脑端 DeepSeek 账户余额（「我的」页显示）。
class AccountBalance {
  const AccountBalance({
    this.supported = true,
    this.signedIn = false,
    this.failed = false,
    this.wallets = const <AccountWallet>[],
    this.bonusWallets = const <AccountWallet>[],
    this.error = '',
  });

  factory AccountBalance.fromJson(Map<String, dynamic> json) {
    List<AccountWallet> walletsOf(Object? raw) => <AccountWallet>[
          if (raw is List)
            for (final row in raw)
              if (row is Map<String, dynamic>) AccountWallet.fromJson(row),
        ];
    return AccountBalance(
      supported: json['supported'] != false,
      signedIn: json['signedIn'] == true,
      failed: json['failed'] == true,
      wallets: walletsOf(json['wallets']),
      bonusWallets: walletsOf(json['bonusWallets']),
      error: _nonEmpty(json['error']) ?? '',
    );
  }

  /// 老插件没有这条路由时为 false。
  final bool supported;

  /// 电脑端没登录 DeepSeek 账号。
  final bool signedIn;

  /// 登录着，但这次查询失败了。
  final bool failed;

  /// 充值钱包。
  final List<AccountWallet> wallets;

  /// 赠送钱包。
  final List<AccountWallet> bonusWallets;

  final String error;

  /// M4.32：优先人民币，其次任何有余额的钱包；全是 0 时退回第一条，
  /// 免得美元钱包的 `0` 把人民币那条挤掉。
  AccountWallet? get primary {
    for (final wallet in wallets) {
      if (wallet.currency.trim().toUpperCase() == 'CNY' && !wallet.isZero) {
        return wallet;
      }
    }
    for (final wallet in wallets) {
      if (!wallet.isZero) return wallet;
    }
    return wallets.isEmpty ? null : wallets.first;
  }

  /// M4.32：赠送钱包同理，但全为 0 时返回 null（界面就不显示这一行）。
  AccountWallet? get primaryBonus {
    for (final wallet in bonusWallets) {
      if (wallet.currency.trim().toUpperCase() == 'CNY' && !wallet.isZero) {
        return wallet;
      }
    }
    for (final wallet in bonusWallets) {
      if (!wallet.isZero) return wallet;
    }
    return null;
  }
}

class DesktopSessionFeed {
  const DesktopSessionFeed({
    required this.sessionId,
    required this.title,
    required this.cwd,
    required this.running,
    required this.lastSeq,
    required this.events,
    this.approvals = const <DesktopApproval>[],
    this.questions = const <DesktopQuestion>[],
  });

  factory DesktopSessionFeed.fromJson(Map<String, dynamic> json) {
    final rawEvents = json['events'];
    final rawApprovals = json['approvals'];
    final rawQuestions = json['questions'];
    return DesktopSessionFeed(
      sessionId: _nonEmpty(json['sessionId']) ?? '',
      title: _nonEmpty(json['title']) ?? '桌面会话',
      cwd: _nonEmpty(json['cwd']) ?? '',
      running: json['running'] == true,
      lastSeq: _asInt(json['lastSeq']) ?? 0,
      events: rawEvents is List
          ? rawEvents
              .whereType<Map<String, dynamic>>()
              .map(DesktopSessionEvent.fromJson)
              .toList(growable: false)
          : const <DesktopSessionEvent>[],
      approvals: rawApprovals is List
          ? rawApprovals
              .whereType<Map<String, dynamic>>()
              .map(DesktopApproval.fromJson)
              .where((item) => item.approvalId.isNotEmpty)
              .toList(growable: false)
          : const <DesktopApproval>[],
      questions: rawQuestions is List
          ? rawQuestions
              .whereType<Map<String, dynamic>>()
              .map(DesktopQuestion.fromJson)
              .where((item) => item.questionId.isNotEmpty && item.items.isNotEmpty)
              .toList(growable: false)
          : const <DesktopQuestion>[],
    );
  }

  final String sessionId;
  final String title;
  final String cwd;
  final bool running;
  final int lastSeq;
  final List<DesktopSessionEvent> events;
  final List<DesktopApproval> approvals;

  /// M4.23：电脑端正等手机回答的问题（「确认需求」卡片）。
  final List<DesktopQuestion> questions;
}

/// M1.1：任务记录（列表与详情共用）。
class TaskRecord {
  const TaskRecord({
    required this.taskId,
    required this.taskName,
    required this.status,
    this.conversationId,
    this.progress = 0,
    this.workspacePath,
    this.result = const <String, dynamic>{},
    this.errorCode,
    this.errorMessage,
    this.createdAt,
    this.startedAt,
    this.finishedAt,
    this.events = const <TaskEventRecord>[],
    this.lastTime,
    this.messageCount = 0,
    this.lastSeq = 0,
  });

  factory TaskRecord.fromJson(Map<String, dynamic> json) {
    final id = json['taskId'] ?? json['id'];
    if (id is! String || id.trim().isEmpty) {
      throw const PairingApiException('任务数据缺少 taskId');
    }
    final rawEvents = json['events'];
    return TaskRecord(
      taskId: id,
      conversationId: _nonEmpty(json['conversationId']),
      taskName: _nonEmpty(json['taskName']) ?? _nonEmpty(json['title']) ?? '',
      status: _nonEmpty(json['status']) ?? 'queued',
      progress: _asInt(json['progress']) ?? 0,
      workspacePath: _nonEmpty(json['workspacePath']),
      result: _asMap(json['result']) ?? const <String, dynamic>{},
      errorCode: _nonEmpty(json['errorCode']),
      errorMessage: _nonEmpty(json['errorMessage']),
      // 兼容只给 `updatedAt` 的行（桌面任务镜像的部分版本如此）。
      createdAt: _parseDate(json['createdAt'] ?? json['updatedAt']),
      startedAt: _parseDate(json['startedAt']),
      finishedAt: _parseDate(json['finishedAt']),
      // M3.6：桌面任务行的「最后活动时刻」（毫秒时间戳）、消息数与最新 seq。
      lastTime: _asTimestampMs(json['lastTime']),
      messageCount: _asInt(json['messageCount']) ?? 0,
      lastSeq: _asInt(json['lastSeq']) ?? 0,
      events: rawEvents is List
          ? rawEvents
              .whereType<Map<String, dynamic>>()
              .map(TaskEventRecord.fromJson)
              .toList()
          : const <TaskEventRecord>[],
    );
  }

  final String taskId;
  final String? conversationId;
  final String taskName;
  final String status;
  final int progress;
  final String? workspacePath;
  final Map<String, dynamic> result;
  final String? errorCode;
  final String? errorMessage;
  final DateTime? createdAt;
  final DateTime? startedAt;
  final DateTime? finishedAt;
  final List<TaskEventRecord> events;

  /// M3.6：桌面任务行的「最后活动时刻」（毫秒时间戳）；无则回退时间戳。
  final int? lastTime;

  /// M3.6：会话消息条数（旧后端为 0）。
  final int messageCount;

  /// M3.6：会话最新事件 seq（旧后端为 0）。
  final int lastSeq;

  TaskStatus get taskStatus => switch (status.trim().toLowerCase()) {
        'queued' || 'pending' || '' => TaskStatus.queued,
        'running' || 'in_progress' => TaskStatus.running,
        'waiting_approval' || 'waitingapproval' || 'waiting' =>
          TaskStatus.waitingApproval,
        'paused' => TaskStatus.paused,
        'completed' || 'succeeded' || 'success' || 'done' =>
          TaskStatus.completed,
        'failed' || 'error' => TaskStatus.failed,
        'cancelled' || 'canceled' => TaskStatus.cancelled,
        _ => TaskStatus.queued,
      };

  /// 结果摘要：优先 `result.summary`，否则把 result 压成一行文本。
  String? get resultSummary {
    final summary = _nonEmpty(result['summary']);
    if (summary != null) return summary;
    if (result.isEmpty) return null;
    final encoded = jsonEncode(result);
    return encoded.length <= 400 ? encoded : '${encoded.substring(0, 400)}…';
  }

  DateTime get updatedAt =>
      finishedAt ?? startedAt ?? createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);

  TaskItem toTaskItem({List<TaskEvent>? timeline}) {
    return TaskItem(
      id: taskId,
      title: taskName.isEmpty ? '未命名任务' : taskName,
      status: taskStatus,
      workspace: (workspacePath ?? '').isEmpty ? '—' : workspacePath!,
      updatedAt: updatedAt,
      progress: (progress.clamp(0, 100)) / 100,
      conversationId: conversationId,
      result: resultSummary,
      errorCode: errorCode ?? errorMessage,
      events: timeline ?? events.map((e) => e.toTaskEvent()).toList(),
      messageCount: messageCount,
      lastTime: lastTime,
    );
  }
}

/// M1.1 历史/任务 REST 客户端（Bearer token 复用 M1 配对 token）。
///
/// 全部方法把网络、超时、HTTP 错误与坏 JSON 映射成 [PairingApiException]，
/// 其 [PairingApiException.message] 可以直接展示在 UI 上。
class HistoryApi {
  HistoryApi({
    AuthorizedHttpSender? sender,
    this.timeout = const Duration(seconds: 10),
  }) : _sender = sender ?? _dartIoSender;

  final AuthorizedHttpSender _sender;
  final Duration timeout;

  /// M4.38：直播首屏要拉一整屏事件（忙会话一百多 KB），10 秒在小水管上不够用。
  ///
  /// 只给「拉桌面会话」这一条放宽：别的接口都是几百字节的小请求，超时就该快，
  /// 免得把真正的地址错误、token 失效一起拖成慢查询。
  static const Duration desktopFeedTimeout = Duration(seconds: 20);

  static const String conversationsPath = '/api/v1/conversations';
  static const String tasksPath = '/api/v1/tasks';
  /// M2.9.2：插件直连的桌面任务只读镜像。
  static const String desktopTasksPath = '/api/v1/desktop/tasks';

  /// 最近会话列表（契约 §3.1）。
  Future<List<ConversationSummary>> conversations(
    String baseUrl, {
    required String token,
    int limit = 50,
  }) async {
    final json = await _get(
      baseUrl,
      conversationsPath,
      token: token,
      query: <String, String>{'limit': '$limit'},
      errorPrefix: '拉取历史会话失败',
    );
    final list = json['conversations'];
    if (list is! List) {
      throw const PairingApiException(
          '拉取历史会话失败：服务器没有返回 conversations 列表');
    }
    return list
        .whereType<Map<String, dynamic>>()
        .map(ConversationSummary.fromJson)
        .toList();
  }

  /// 历史消息（契约 §3.2）；`afterSeq` 用于断线重连后的增量补齐。
  Future<ConversationMessagesPage> messages(
    String baseUrl, {
    required String token,
    required String conversationId,
    int afterSeq = 0,
    int limit = 200,
  }) async {
    final id = conversationId.trim();
    if (id.isEmpty) {
      throw const PairingApiException('会话 id 为空，无法拉取历史消息');
    }
    final path = '$conversationsPath/${Uri.encodeComponent(id)}/messages';
    final json = await _get(
      baseUrl,
      path,
      token: token,
      query: <String, String>{
        'afterSeq': '$afterSeq',
        'limit': '$limit',
      },
      errorPrefix: '拉取历史消息失败',
    );
    return ConversationMessagesPage.fromJson(
      json,
      fallbackConversationId: id,
    );
  }

  /// 会话增量事件（M2.1 契约 §3.1），用于断线/后台恢复后的 seq 补齐。
  Future<ConversationEventsPage> events(
    String baseUrl, {
    required String token,
    required String conversationId,
    int afterSeq = 0,
    int limit = 500,
  }) async {
    final id = conversationId.trim();
    if (id.isEmpty) {
      throw const PairingApiException('会话 id 为空，无法拉取增量事件');
    }
    final path = '$conversationsPath/${Uri.encodeComponent(id)}/events';
    final json = await _get(
      baseUrl,
      path,
      token: token,
      query: <String, String>{
        'afterSeq': '$afterSeq',
        'limit': '$limit',
      },
      errorPrefix: '拉取增量事件失败',
    );
    return ConversationEventsPage.fromJson(json, fallbackConversationId: id);
  }

  /// 任务列表（契约 §3.3），可选状态过滤（如 `running,waiting_approval`）。
  Future<List<TaskRecord>> tasks(
    String baseUrl, {
    required String token,
    int limit = 50,
    List<String>? statuses,
  }) async {
    final query = <String, String>{'limit': '$limit'};
    final filter = (statuses ?? const <String>[])
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (filter.isNotEmpty) query['status'] = filter.join(',');
    final json = await _get(
      baseUrl,
      tasksPath,
      token: token,
      query: query,
      errorPrefix: '拉取任务列表失败',
    );
    final list = json['tasks'];
    if (list is! List) {
      throw const PairingApiException('拉取任务列表失败：服务器没有返回 tasks 列表');
    }
    return list
        .whereType<Map<String, dynamic>>()
        .map(TaskRecord.fromJson)
        .toList();
  }

  /// 任务详情（含 `events` 时间线）。
  Future<TaskRecord> taskDetail(
    String baseUrl, {
    required String token,
    required String taskId,
  }) async {
    final id = taskId.trim();
    if (id.isEmpty) {
      throw const PairingApiException('任务 id 为空，无法拉取任务详情');
    }
    final json = await _get(
      baseUrl,
      '$tasksPath/${Uri.encodeComponent(id)}',
      token: token,
      errorPrefix: '拉取任务详情失败',
    );
    return TaskRecord.fromJson(json);
  }

  /// M2.9.2：插件直连时桌面任务的只读镜像（`GET /api/v1/desktop/tasks`）。
  ///
  /// 桌面 GUI 里发起的会话不经过 relay agent，手机任务页拿不到 WSS 推送，
  /// 所以由插件从 Host 的 sessions 汇一份列表；这里映射成 [TaskRecord]，
  /// 复用任务页现有的卡片与状态筛选。
  Future<List<TaskRecord>> desktopTasks(
    String baseUrl, {
    required String token,
  }) async {
    final json = await _get(
      baseUrl,
      desktopTasksPath,
      token: token,
      errorPrefix: '拉取电脑任务失败',
    );
    final list = json['tasks'];
    if (list is! List) return const <TaskRecord>[];
    return list
        .whereType<Map<String, dynamic>>()
        .map((item) {
          final updatedAt = _parseDate(item['updatedAt']);
          final rawProgress = (item['progress'] as num?)?.toDouble() ?? 1;
          return TaskRecord(
            taskId: _nonEmpty(item['id']) ?? '',
            taskName: _nonEmpty(item['title']) ?? '桌面任务',
            status: _nonEmpty(item['status']) ?? 'completed',
            workspacePath: _nonEmpty(item['workspace']),
            progress: (rawProgress * 100).round(),
            createdAt: updatedAt,
            startedAt: updatedAt,
          );
        })
        .where((record) => record.taskId.isNotEmpty)
        .toList(growable: false);
  }

  /// M2.9.3：桌面会话的直播流（只读）。`afterSeq` 为空时取最后 [limit] 条。
  Future<DesktopSessionFeed> desktopSessionEvents(
    String baseUrl, {
    required String token,
    required String sessionId,
    int? afterSeq,
    int limit = 80,
  }) async {
    final json = await _get(
      baseUrl,
      '/api/v1/desktop/sessions/${Uri.encodeComponent(sessionId)}/events',
      token: token,
      query: <String, String>{
        if (afterSeq != null) 'afterSeq': '$afterSeq',
        'limit': '$limit',
      },
      errorPrefix: '拉取桌面会话失败',
      // M4.38：首屏一整屏事件走隧道要几秒，10 秒太紧。
      timeoutOverride: desktopFeedTimeout,
    );
    return DesktopSessionFeed.fromJson(json);
  }

  /// M4.10：电脑端存档的会话清单（DSH 列表里已经看不到的那些）。
  Future<List<ArchivedSession>> archivedSessions(
    String baseUrl, {
    required String token,
  }) async {
    final json = await _get(
      baseUrl,
      '/api/v1/desktop/archive/sessions',
      token: token,
      errorPrefix: '读取会话存档失败',
    );
    final raw = json['sessions'];
    if (raw is! List) return const <ArchivedSession>[];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(ArchivedSession.fromJson)
        .where((session) => session.id.isNotEmpty)
        .toList(growable: false);
  }

  /// M4.10：读一份会话存档的完整事件（只读直播）。
  Future<DesktopSessionFeed> archivedSession(
    String baseUrl, {
    required String token,
    required String sessionId,
  }) async {
    final json = await _get(
      baseUrl,
      '/api/v1/desktop/archive/sessions/${Uri.encodeComponent(sessionId)}',
      token: token,
      errorPrefix: '读取会话存档失败',
    );
    return DesktopSessionFeed.fromJson(json);
  }

  /// M4.10：把一份会话存档补传到电脑（手机端本地恢复用）。
  Future<void> postArchivedSession(
    String baseUrl, {
    required String token,
    required ArchivedSession session,
    required List<DesktopSessionEvent> events,
  }) async {
    await _post(
      baseUrl,
      '/api/v1/desktop/archive/sessions',
      token: token,
      body: <String, dynamic>{
        'id': session.id,
        'source': session.source,
        'title': session.title,
        'workspace': session.workspace,
        'createdAt': session.createdAt,
        'lastTime': session.lastTime,
        'events': <Map<String, dynamic>>[
          for (final event in events)
            <String, dynamic>{
              'kind': event.kind,
              'time': event.time,
              if (event.text.isNotEmpty) 'text': event.text,
              if (event.reason != null) 'reason': event.reason,
            },
        ],
      },
      errorPrefix: '保存会话存档失败',
    );
  }

  /// M2.9.4：替电脑给桌面会话补一句话（queue 模式，进入当前轮或下一轮）。
  ///
  /// M4.19：存档会话在电脑上会被恢复成一条**新会话**，所以这里把服务端回的
  /// `sessionId` / `forked` 一起交给页面，手机据此跳到新会话继续直播。
  Future<DesktopPromptResult> sendDesktopPrompt(
    String baseUrl, {
    required String token,
    required String sessionId,
    required String text,
  }) async {
    final value = text.trim();
    if (value.isEmpty) {
      throw const PairingApiException('不能发送空指令');
    }
    final json = await _post(
      baseUrl,
      '/api/v1/desktop/sessions/${Uri.encodeComponent(sessionId)}/prompt',
      token: token,
      body: <String, dynamic>{'text': value},
      errorPrefix: '发送桌面指令失败',
    );
    return DesktopPromptResult.fromJson(json, fallbackSessionId: sessionId);
  }

  /// M4.25：读电脑端的 DeepSeek 账户余额（「我的」页那一行）。
  ///
  /// M4.28：这条路由是插件 0.2.29 才有的。旧插件会回 404，而通用错误文案说的是
  /// 「请确认地址指向 M1 后端」——地址其实是对的，只是电脑上跑的还是旧插件，
  /// 照那句提示去改地址只会越走越远。所以这里把 404 单独翻译成「插件太旧」。
  Future<AccountBalance> fetchAccountBalance(
    String baseUrl, {
    required String token,
  }) async {
    try {
      final json = await _get(
        baseUrl,
        '/api/v1/desktop/account/balance',
        token: token,
        errorPrefix: '读取账户余额失败',
      );
      return AccountBalance.fromJson(json);
    } on PairingApiException catch (error) {
      if (error.statusCode == 404) {
        throw PairingApiException(
          '这台电脑上的插件还没有账户余额接口（需要 0.2.29 以上）：'
          '请升级插件后完整退出并重开一次 DSH，再回来刷新',
          code: error.code,
          statusCode: 404,
        );
      }
      rethrow;
    }
  }

  /// M4.21：读一个桌面会话的排队消息（电脑端那排「N 条排队消息」）。
  Future<DesktopQueue> fetchDesktopQueue(
    String baseUrl, {
    required String token,
    required String sessionId,
  }) async {
    final json = await _get(
      baseUrl,
      '/api/v1/desktop/sessions/${Uri.encodeComponent(sessionId)}/queue',
      token: token,
      errorPrefix: '读取排队消息失败',
    );
    return DesktopQueue.fromJson(json);
  }

  /// M4.21：改一条排队消息。
  ///
  /// - [action] `remove` 删除、`steer` 立刻插话送进这一轮、`edit` 改字（要带 [text]）。
  /// 返回改完之后的队列快照，页面直接拿来替换，不用再单独拉一次。
  Future<DesktopQueue> updateDesktopQueue(
    String baseUrl, {
    required String token,
    required String sessionId,
    required String itemId,
    required String action,
    String? text,
  }) async {
    final body = <String, dynamic>{'itemId': itemId, 'action': action};
    if (action == 'edit') {
      final value = (text ?? '').trim();
      if (value.isEmpty) {
        throw const PairingApiException('改过的内容不能为空');
      }
      body['text'] = value;
    }
    final json = await _post(
      baseUrl,
      '/api/v1/desktop/sessions/${Uri.encodeComponent(sessionId)}/queue',
      token: token,
      body: body,
      errorPrefix: '改排队消息失败',
    );
    return DesktopQueue.fromJson(json);
  }

  /// M4.31：跨会话的「电脑在等你选一项」。
  ///
  /// 手机不在那条会话的直播页时，提问仍然被插件接管（只要 App 还连着），
  /// 这个接口让工作区能提前告诉用户「有 1 个问题等着」，点进去再答。
  Future<DesktopPending> fetchDesktopPending(String baseUrl, {required String token}) async {
    try {
      final json = await _get(
        baseUrl,
        '/api/v1/desktop/pending',
        token: token,
        errorPrefix: '读取待回答的提问失败',
      );
      return DesktopPending.fromJson(json);
    } on PairingApiException catch (error) {
      // 501 = 电脑上的插件还没有这个接口（0.2.30 之前）。
      // 404 = 插件更老，连路由都没有（Express 那条 catch-all 回的是 BAD_REQUEST）。
      // 两种都不是「出错」，只是没法提前提醒，交给调用方决定要不要显示。
      if (error.statusCode == 501 || error.statusCode == 404) {
        return DesktopPending(
          answerable: false,
          error: '这台电脑上的插件太旧，手机看不到待回答的提问（需要 0.2.30 以上）',
        );
      }
      rethrow;
    }
  }

  /// M2.9.4：应答桌面会话里等待的授权。
  Future<void> decideDesktopApproval(
    String baseUrl, {
    required String token,
    required String sessionId,
    required String approvalId,
    required bool approve,
  }) async {
    await _post(
      baseUrl,
      '/api/v1/desktop/sessions/${Uri.encodeComponent(sessionId)}'
          '/approvals/${Uri.encodeComponent(approvalId)}',
      token: token,
      body: <String, dynamic>{'decision': approve ? 'approve' : 'reject'},
      errorPrefix: '应答授权失败',
    );
  }

  /// M4.23：回答电脑端「确认需求」卡片里的问题。
  ///
  /// `answers` 为空表示「跳过」——Host 会当作用户什么都没选，让 Agent 继续。
  Future<void> answerDesktopQuestion(
    String baseUrl, {
    required String token,
    required String sessionId,
    required String questionId,
    required List<DesktopQuestionAnswer> answers,
  }) async {
    await _post(
      baseUrl,
      '/api/v1/desktop/sessions/${Uri.encodeComponent(sessionId)}'
          '/questions/${Uri.encodeComponent(questionId)}',
      token: token,
      body: <String, dynamic>{
        'answers': answers.map((answer) => answer.toJson()).toList(growable: false),
      },
      errorPrefix: '回答问题失败',
    );
  }

  /// M3.0：把手机上的照片/文档传到电脑，返回落盘路径（供 prompt 文本引用）。
  Future<DesktopUpload> uploadDesktopFile(
    String baseUrl, {
    required String token,
    required String name,
    required List<int> bytes,
    String? workspace,
  }) async {
    if (bytes.isEmpty) {
      throw const PairingApiException('这个文件是空的，换一个试试');
    }
    final folder = workspace?.trim() ?? '';
    final json = await _post(
      baseUrl,
      '/api/v1/desktop/upload',
      token: token,
      body: <String, dynamic>{
        'name': name,
        'data': base64Encode(bytes),
        // M4.2：插件 0.2.11+ 会按工作区名把附件放进该工作区（会话目录）下的
        // 「手机附件」文件夹，AI 才能在项目里直接打开；旧插件忽略这个字段。
        if (folder.isNotEmpty) 'workspace': folder,
      },
      errorPrefix: '上传附件失败',
    );
    return DesktopUpload.fromJson(json);
  }

  /// M4.8：请电脑把附件「读」成文字（PDF / Word / Excel / 压缩包…）。
  ///
  /// 和上传不同，这条不落工作区：插件写完临时文件读完就删，返回抽出来的
  /// 正文。手机档的云端模型没有文件解析能力，靠它做到「什么都能丢进来」。
  Future<String> readDesktopFile(
    String baseUrl, {
    required String token,
    required String name,
    required List<int> bytes,
  }) async {
    if (bytes.isEmpty) {
      throw const PairingApiException('这个文件是空的，换一个试试');
    }
    final json = await _post(
      baseUrl,
      '/api/v1/desktop/file/read',
      token: token,
      body: <String, dynamic>{
        'name': name,
        'data': base64Encode(bytes),
      },
      errorPrefix: '读取附件失败',
    );
    final text = json['text'];
    if (text is String && text.trim().isNotEmpty) return text;
    throw const PairingApiException('电脑没能读出这个文件的内容');
  }

  /// M4.9：按路径取工作区里某个文件的原始字节（图片 / PDF 预览用）。
  ///
  /// 走 `GET /api/v1/desktop/file/raw?workspace=&path=`，插件会校验工作区必须
  /// 是授权根之一、相对路径不许含 `..`；单文件上限 20 MB。
  Future<List<int>> downloadWorkspaceFile(
    String baseUrl, {
    required String token,
    required String workspacePath,
    required String relativePath,
  }) async {
    final uri = _endpoint(
      baseUrl,
      '/api/v1/desktop/file/raw',
      query: <String, String>{
        'workspace': workspacePath,
        'path': relativePath,
      },
    );
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.getUrl(uri);
      for (final entry in authHeaders(token).entries) {
        request.headers.set(entry.key, entry.value);
      }
      final response = await request.close();
      if (response.statusCode != 200) {
        final body = await response.transform(utf8.decoder).join();
        throw PairingApiException(
          _bodyMessage(body) ?? '下载文件失败：HTTP ${response.statusCode}',
          statusCode: response.statusCode,
        );
      }
      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
      }
      if (bytes.isEmpty) {
        throw const PairingApiException('这个文件是空的');
      }
      return bytes;
    } on PairingApiException {
      rethrow;
    } catch (error) {
      throw PairingApiException('下载文件失败：${PairingApi.describeException(error)}');
    } finally {
      client.close(force: true);
    }
  }

  /// M4.66：手机「功能 → 更新日志」——电脑上 `docs/UPDATE_NOTES.md` 的版本列表。
  Future<List<UpdateNote>> listUpdateNotes(
    String baseUrl, {
    required String token,
  }) async {
    final json = await _get(
      baseUrl,
      '/api/v1/app/notes',
      token: token,
      errorPrefix: '读取更新日志失败',
    );
    final raw = json['notes'];
    if (raw is! List) return const <UpdateNote>[];
    return <UpdateNote>[
      for (final item in raw)
        if (item is Map) UpdateNote.fromJson(item.cast<String, dynamic>()),
    ];
  }

  /// M4.57：手机「功能 → 接收文件」列表（电脑端插件 received 目录）。
  Future<List<ReceivedFile>> listReceivedFiles(
    String baseUrl, {
    required String token,
  }) async {
    final json = await _get(
      baseUrl,
      '/api/v1/received',
      token: token,
      errorPrefix: '读取接收文件失败',
    );
    final raw = json['files'];
    if (raw is! List) return const <ReceivedFile>[];
    return <ReceivedFile>[
      for (final item in raw)
        if (item is Map) ReceivedFile.fromJson(item.cast<String, dynamic>()),
    ];
  }

  /// M4.57：下载一个接收文件。旧的插件没有这个接口（404）。
  Future<List<int>> downloadReceivedFile(
    String baseUrl, {
    required String token,
    required String name,
  }) async {
    final uri = _endpoint(
      baseUrl,
      '/api/v1/received/${Uri.encodeComponent(name)}',
    );
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.getUrl(uri);
      for (final entry in authHeaders(token).entries) {
        request.headers.set(entry.key, entry.value);
      }
      final response = await request.close();
      if (response.statusCode != 200) {
        final body = await response.transform(utf8.decoder).join();
        throw PairingApiException(
          _bodyMessage(body) ?? '下载接收文件失败：HTTP ${response.statusCode}',
          statusCode: response.statusCode,
        );
      }
      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
      }
      if (bytes.isEmpty) {
        throw const PairingApiException('这个文件是空的');
      }
      return bytes;
    } on PairingApiException {
      rethrow;
    } catch (error) {
      throw PairingApiException('下载接收文件失败：${PairingApi.describeException(error)}');
    } finally {
      client.close(force: true);
    }
  }

  /// M4.0：在电脑端第一个授权根目录下新建一个工作区子目录。
  ///
  /// 电脑端会清理非法字符（`\/:*?"<>|` → `-`）；重名时沿用已有目录。
  /// 旧版插件没有这个接口（404），UI 需给出可读提示。
  Future<DesktopWorkspaceCreated> createDesktopWorkspace(
    String baseUrl, {
    required String token,
    required String name,
    String? parentDir,
  }) async {
    final value = name.trim();
    if (value.isEmpty) {
      throw const PairingApiException('请先填写工作区名称');
    }
    final json = await _post(
      baseUrl,
      '/api/v1/desktop/workspaces',
      token: token,
      body: <String, dynamic>{
        'name': value,
        // M4.13：手机端把新项目固定建在「项目根」下，不再依赖授权根顺序。
        if (parentDir != null && parentDir.trim().isNotEmpty)
          'parentDir': parentDir.trim(),
      },
      errorPrefix: '新建工作区失败',
    );
    final created = DesktopWorkspaceCreated.fromJson(json);
    if (created.path.isEmpty) {
      throw const PairingApiException('新建工作区失败：电脑端没有返回目录路径');
    }
    return created;
  }

  /// M3.5：电脑上已安装的插件清单。
  Future<List<PluginInfo>> listPlugins(
    String baseUrl, {
    required String token,
  }) async {
    final json = await _get(
      baseUrl,
      '/api/v1/desktop/plugins',
      token: token,
      errorPrefix: '读取插件列表失败',
    );
    final raw = json['plugins'];
    if (raw is! List) return const <PluginInfo>[];
    return <PluginInfo>[
      for (final item in raw)
        if (item is Map) PluginInfo.fromJson(item.cast<String, dynamic>()),
    ];
  }

  /// M3.5：启用或停用一个插件（电脑端按 HMR 规则重载）。
  Future<void> setPluginEnabled(
    String baseUrl, {
    required String token,
    required String id,
    required bool enabled,
  }) async {
    await _post(
      baseUrl,
      '/api/v1/desktop/plugins/enabled',
      token: token,
      body: <String, dynamic>{'id': id, 'enabled': enabled},
      errorPrefix: '切换插件失败',
    );
  }

  /// M3.6：按「插件包（bundle）」分组的已安装插件。
  ///
  /// 旧版电脑端插件没有这个接口（返回 404），UI 需回退到 [listPlugins]。
  Future<List<PluginBundle>> listPluginBundles(
    String baseUrl, {
    required String token,
  }) async {
    final json = await _get(
      baseUrl,
      '/api/v1/desktop/plugins/bundles',
      token: token,
      errorPrefix: '读取插件包失败',
    );
    final raw = json['bundles'];
    if (raw is! List) return const <PluginBundle>[];
    return <PluginBundle>[
      for (final item in raw)
        if (item is Map) PluginBundle.fromJson(item.cast<String, dynamic>()),
    ];
  }

  /// M4.18：电脑端插件市场目录。
  ///
  /// 以前手机上「插件市场」走的是 `marketSearch`，它只读电脑端「设置 → 插件市场」
  /// 里手动配的第三方索引——一个都没配时永远是空的。这个接口直接把电脑端
  /// `pluginManager.listBundles()` 的目录交给手机，包含官方插件与可安装版本。
  Future<PluginCatalog> listPluginCatalog(
    String baseUrl, {
    required String token,
    String language = 'zh-CN',
  }) async {
    final json = await _get(
      baseUrl,
      '/api/v1/desktop/plugins/catalog?language=${Uri.encodeComponent(language)}',
      token: token,
      errorPrefix: '读取电脑端插件市场失败',
    );
    return PluginCatalog.fromJson(json);
  }

  /// M3.6：启用/停用整个插件包。
  Future<void> setBundleEnabled(
    String baseUrl, {
    required String token,
    required String name,
    required bool enabled,
  }) async {
    await _post(
      baseUrl,
      '/api/v1/desktop/plugins/bundles/enabled',
      token: token,
      body: <String, dynamic>{'name': name, 'enabled': enabled},
      errorPrefix: '切换插件包失败',
    );
  }

  /// M3.6：搜索插件市场（按索引 url 或关键字）。
  Future<MarketSearchResult> marketSearch(
    String baseUrl, {
    required String token,
    String? url,
    String query = '',
  }) async {
    final params = <String, String>{};
    if (url != null && url.trim().isNotEmpty) params['url'] = url.trim();
    if (query.trim().isNotEmpty) params['query'] = query.trim();
    final json = await _get(
      baseUrl,
      '/api/v1/desktop/plugins/market',
      token: token,
      query: params.isEmpty ? null : params,
      errorPrefix: '搜索插件市场失败',
    );
    return MarketSearchResult.fromJson(json);
  }

  /// M4.1：电脑端已安装插件（内置配置 / 实验性 / 其他 分组）。
  Future<PluginGallery> pluginGallery(String baseUrl, {required String token}) async {
    final json = await _get(
      baseUrl,
      '/api/v1/desktop/plugins/gallery',
      token: token,
      errorPrefix: '读取已安装插件失败',
    );
    return PluginGallery.fromJson(json);
  }

  /// M3.6：从市场安装插件；返回体可能带 `pendingBuilds` / `nextStep`。
  Future<Map<String, dynamic>> installPlugin(
    String baseUrl, {
    required String token,
    required String spec,
    List<String>? approvedBuilds,
  }) async {
    final trimmed = spec.trim();
    if (trimmed.isEmpty) {
      throw const PairingApiException('插件名不能为空');
    }
    final body = <String, dynamic>{'spec': trimmed};
    if (approvedBuilds != null && approvedBuilds.isNotEmpty) {
      body['approvedBuilds'] = approvedBuilds;
    }
    return _post(
      baseUrl,
      '/api/v1/desktop/plugins/market/install',
      token: token,
      body: body,
      errorPrefix: '安装插件失败',
    );
  }

  /// M3.6：从电脑端卸载一个插件。
  Future<void> removePlugin(
    String baseUrl, {
    required String token,
    required String name,
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw const PairingApiException('插件名不能为空');
    }
    await _post(
      baseUrl,
      '/api/v1/desktop/plugins/market/remove',
      token: token,
      body: <String, dynamic>{'name': trimmed},
      errorPrefix: '卸载插件失败',
    );
  }

  /// Bearer 请求头（单测可直接断言）。
  static Map<String, String> authHeaders(String token) => <String, String>{
        HttpHeaders.authorizationHeader: 'Bearer ${token.trim()}',
        HttpHeaders.acceptHeader: 'application/json',
      };

  // -------------------------------------------------------------------------
  // 内部
  // -------------------------------------------------------------------------

  Future<Map<String, dynamic>> _get(
    String baseUrl,
    String path, {
    required String token,
    Map<String, String>? query,
    required String errorPrefix,
    Duration? timeoutOverride,
  }) async {
    if (token.trim().isEmpty) {
      throw PairingApiException('$errorPrefix：还没有配对 token，请重新连接');
    }
    final Uri uri;
    try {
      uri = _endpoint(baseUrl, path, query: query);
    } on PairingApiException catch (e) {
      throw PairingApiException('$errorPrefix：${e.message}');
    }
    JsonHttpResponse response;
    try {
      response = await _sender('GET', uri, authHeaders(token), null)
          .timeout(timeoutOverride ?? timeout);
    } catch (e) {
      throw PairingApiException(
        '$errorPrefix：${PairingApi.describeException(e)}',
      );
    }
    return _requireJson(response, errorPrefix: errorPrefix);
  }

  Future<Map<String, dynamic>> _post(
    String baseUrl,
    String path, {
    required String token,
    required Map<String, dynamic> body,
    required String errorPrefix,
  }) async {
    if (token.trim().isEmpty) {
      throw PairingApiException('$errorPrefix：还没有配对 token，请重新连接');
    }
    final Uri uri;
    try {
      uri = _endpoint(baseUrl, path);
    } on PairingApiException catch (e) {
      throw PairingApiException('$errorPrefix：${e.message}');
    }
    JsonHttpResponse response;
    try {
      response = await _sender('POST', uri, authHeaders(token), body).timeout(timeout);
    } catch (e) {
      throw PairingApiException('$errorPrefix：${PairingApi.describeException(e)}');
    }
    return _requireJson(response, errorPrefix: errorPrefix);
  }

  static Uri _endpoint(
    String baseUrl,
    String path, {
    Map<String, String>? query,
  }) {
    final uri = PairingApi.resolveEndpoint(baseUrl, path);
    if (query == null || query.isEmpty) return uri;
    return uri.replace(
      queryParameters: <String, String>{...uri.queryParameters, ...query},
    );
  }

  /// 从错误响应体里抠出可读信息（插件统一回 `{code, message}`）。
  static String? _bodyMessage(String body) {
    try {
      final json = jsonDecode(body);
      if (json is Map<String, dynamic>) {
        return _nonEmpty(json['message']) ?? _nonEmpty(json['error']);
      }
    } catch (_) {
      /* 不是 JSON 就用原文 */
    }
    final trimmed = body.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  Map<String, dynamic> _requireJson(
    JsonHttpResponse response, {
    required String errorPrefix,
  }) {
    final json = response.jsonObject;
    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (json == null) {
        throw PairingApiException('$errorPrefix：服务器返回的内容不是合法 JSON');
      }
      return json;
    }
    // M1.1 出错格式为 `{error:{code,message}}`，同时兼容 M1 的根级 code/message。
    final error = json?['error'];
    final code = (error is Map ? _nonEmpty(error['code']) : null) ??
        _nonEmpty(json?['code']);
    final message = (error is Map ? _nonEmpty(error['message']) : null) ??
        _nonEmpty(json?['message']);
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw PairingApiException(
        '$errorPrefix：认证失败，token 无效或已过期，请重新配对',
        code: code,
        statusCode: response.statusCode,
      );
    }
    throw PairingApiException(
      '$errorPrefix：${PairingApi.messageForHttpError(
        response.statusCode,
        code: code,
        serverMessage: message,
      )}',
      code: code,
      statusCode: response.statusCode,
    );
  }

  static Future<JsonHttpResponse> _dartIoSender(
    String method,
    Uri uri,
    Map<String, String> headers,
    Map<String, dynamic>? body,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      // M4.38：原来是 5 秒。传输中途隧道抽一下、手机切一下基站就会「空转」超过
      // 5 秒，连接被自己掐断，报出来还是超时；给到 20 秒，让上层那个总超时说话。
      ..idleTimeout = const Duration(seconds: 20)
      ..userAgent = 'deepseek-remote-app/0.1';
    try {
      final request = await client.openUrl(method, uri);
      headers.forEach(request.headers.set);
      if (body != null) {
        final encoded = utf8.encode(jsonEncode(body));
        request.headers.contentType = ContentType.json;
        request.headers.contentLength = encoded.length;
        request.add(encoded);
      }
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      return JsonHttpResponse(response.statusCode, text);
    } finally {
      client.close(force: true);
    }
  }
}

// ---------------------------------------------------------------------------
// JSON 宽松解析小工具（后端字段缺失/类型漂移时保持稳定）
// ---------------------------------------------------------------------------

String? _nonEmpty(Object? value) {
  if (value is String && value.trim().isNotEmpty) return value;
  return null;
}

int? _asInt(Object? value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

/// 解析毫秒时间戳：兼容 number 与数字字符串 / ISO 字符串。
int? _asTimestampMs(Object? value) {
  if (value is num) return value.toInt();
  if (value is String) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    final asInt = int.tryParse(trimmed);
    if (asInt != null) return asInt;
    return DateTime.tryParse(trimmed)?.millisecondsSinceEpoch;
  }
  return null;
}

Map<String, dynamic>? _asMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map((k, v) => MapEntry(k.toString(), v));
  }
  return null;
}

DateTime? _parseDate(Object? value) {
  if (value is String) return DateTime.tryParse(value);
  return null;
}

/// M3.5：电脑上的一个已安装插件（对应 Host 的 pluginManager.listPlugins()）。
///
/// 新旧插件返回的形状不同，`fromJson` 做兼容：
/// - 旧版：`{entryId, moduleName, enabled, fiberPhase, readOnlyReason}`；
/// - 新版：`{id, name, moduleName, enabled, phase, patchId, readOnlyReason}`。
class PluginInfo {
  const PluginInfo({
    required this.id,
    required this.name,
    this.enabled,
    required this.phase,
    required this.readOnly,
    this.version,
  });

  final String id;
  final String name;

  /// `null` 表示电脑端未给出明确状态（插件包子项可能为 null，此时不显示开关）。
  final bool? enabled;

  final String phase;
  final bool readOnly;
  final String? version;

  bool get isEnabled => enabled == true;

  factory PluginInfo.fromJson(Map<String, dynamic> json) {
    final rawEnabled = json['enabled'];
    return PluginInfo(
      id: (json['id'] ?? json['entryId'] ?? '').toString(),
      name: (json['name'] ?? json['moduleName'] ?? '').toString(),
      enabled: rawEnabled is bool ? rawEnabled : null,
      phase: (json['phase'] ?? json['fiberPhase'] ?? '').toString(),
      readOnly: json['readOnlyReason'] != null,
      version: json['version']?.toString(),
    );
  }
}

/// M3.6：一个插件包（bundle）——若干子插件 + 一个总开关。
class PluginBundle {
  const PluginBundle({
    required this.name,
    this.version,
    this.description,
    this.enabled = false,
    this.plugins = const <PluginInfo>[],
  });

  factory PluginBundle.fromJson(Map<String, dynamic> json) {
    final rawPlugins = json['plugins'];
    return PluginBundle(
      name: (json['name'] ?? '').toString(),
      version: _nonEmpty(json['version']),
      description: _nonEmpty(json['description']),
      enabled: json['enabled'] == true,
      plugins: <PluginInfo>[
        for (final item in (rawPlugins is List ? rawPlugins : const <Object>[]))
          if (item is Map) PluginInfo.fromJson(item.cast<String, dynamic>()),
      ],
    );
  }

  final String name;
  final String? version;
  final String? description;
  final bool enabled;
  final List<PluginInfo> plugins;

  /// 去掉 `@deepseek-ai/` 作用域，展示更友好。
  String get displayName {
    const prefix = '@deepseek-ai/';
    if (name.startsWith(prefix)) return name.substring(prefix.length);
    return name;
  }
}

/// M3.6：插件市场里的一个条目。
class MarketEntry {
  const MarketEntry({
    required this.name,
    this.title,
    this.version,
    this.description,
    this.author,
    this.tags = const <String>[],
    this.installed = false,
    this.installedVersion,
    this.downloads,
    this.stars,
    this.official = false,
    this.spec,
    this.availability,
    this.removable = false,
    this.enabled = false,
  });

  factory MarketEntry.fromJson(Map<String, dynamic> json) {
    final rawTags = json['tags'];
    return MarketEntry(
      name: (json['name'] ?? '').toString(),
      title: _nonEmpty(json['title']),
      version: _nonEmpty(json['version']),
      description: _nonEmpty(json['description']),
      author: _nonEmpty(json['author']),
      tags: rawTags is List
          ? <String>[
              for (final tag in rawTags)
                if (tag != null && '$tag'.trim().isNotEmpty) '$tag'.trim(),
            ]
          : const <String>[],
      installed: json['installed'] == true,
      installedVersion: _nonEmpty(json['installedVersion']),
      downloads: _asInt(json['downloads']),
      stars: _asInt(json['stars']),
      official: json['official'] == true,
      spec: _nonEmpty(json['spec']),
      availability: _nonEmpty(json['availability']),
      removable: json['removable'] == true,
      enabled: json['enabled'] == true,
    );
  }

  final String name;
  final String? title;
  final String? version;
  final String? description;
  final String? author;
  final List<String> tags;
  final bool installed;
  final String? installedVersion;

  /// M4.1：市场条目可选的下载量与星标（电脑端插件市场卡片上会显示）。
  final int? downloads;
  final int? stars;

  /// M4.18：来自电脑端插件目录（`pluginManager.listBundles()`）的字段。
  /// `spec` 是 `包名@精确版本`，安装时要原样交给电脑端，只给包名会让电脑端
  /// 重新解析一遍版本，装到的东西可能和手机上看到的不一样。
  final bool official;
  final String? spec;
  final String? availability;
  final bool removable;
  final bool enabled;

  String get displayTitle =>
      (title != null && title!.trim().isNotEmpty) ? title!.trim() : name;

  /// `3188.1k` / `746.4k` / `1.2w` 这类紧凑计数，卡片一行放得下。
  String? get downloadsLabel =>
      downloads == null || downloads! <= 0 ? null : _compactCount(downloads!);

  String? get starsLabel =>
      stars == null || stars! <= 0 ? null : _compactCount(stars!);

  static String _compactCount(int value) {
    if (value >= 100000000) {
      return '${(value / 100000000).toStringAsFixed(1)}亿';
    }
    if (value >= 10000) {
      final w = value / 10000;
      return '${w >= 100 ? w.round() : w.toStringAsFixed(1)}万';
    }
    if (value >= 1000) {
      final k = value / 1000;
      return '${k >= 100 ? k.round() : k.toStringAsFixed(1)}k';
    }
    return '$value';
  }
}

/// M3.6：插件市场的一个「索引」来源。
class MarketIndex {
  const MarketIndex({required this.url, this.title, this.description});

  factory MarketIndex.fromJson(Object? raw) {
    if (raw is String) return MarketIndex(url: raw.trim());
    if (raw is Map) {
      final map = raw.cast<String, dynamic>();
      return MarketIndex(
        url: (map['url'] ?? '').toString().trim(),
        title: _nonEmpty(map['title']),
        description: _nonEmpty(map['description']),
      );
    }
    return const MarketIndex(url: '');
  }

  final String url;
  final String? title;
  final String? description;

  String get label {
    final t = title?.trim();
    if (t != null && t.isNotEmpty) return t;
    return url;
  }
}

/// M3.6：一次市场搜索的结果。
class MarketSearchResult {
  const MarketSearchResult({
    this.indexes = const <String>[],
    this.indexDetails = const <MarketIndex>[],
    this.source,
    this.query,
    this.entries = const <MarketEntry>[],
    this.error,
    this.defaultIndex = false,
  });

  factory MarketSearchResult.fromJson(Map<String, dynamic> json) {
    final rawIndexes = json['indexes'];
    final details = <MarketIndex>[
      for (final item in (rawIndexes is List ? rawIndexes : const <Object>[]))
        MarketIndex.fromJson(item),
    ]..removeWhere((index) => index.url.isEmpty);
    final rawEntries = json['entries'];
    return MarketSearchResult(
      indexes: <String>[for (final index in details) index.url],
      indexDetails: details,
      source: _nonEmpty(json['source']),
      query: _nonEmpty(json['query']),
      entries: <MarketEntry>[
        for (final item in (rawEntries is List ? rawEntries : const <Object>[]))
          if (item is Map) MarketEntry.fromJson(item.cast<String, dynamic>()),
      ],
      error: _nonEmpty(json['error']),
      defaultIndex: json['defaultIndex'] == true,
    );
  }

  /// 索引地址列表（旧契约按字符串下发时同样可用）。
  final List<String> indexes;

  /// 索引的完整信息（新版下发的 `{url,title,description}`，UI 下拉用）。
  final List<MarketIndex> indexDetails;

  final String? source;
  final String? query;
  final List<MarketEntry> entries;
  final String? error;

  /// M4.1：电脑端没有配置任何索引源，用的是 DSH 默认索引兜底。
  final bool defaultIndex;
}

/// M4.1：一个已安装插件（电脑端「设置 → 插件」的卡片）。
class PluginGalleryItem {
  const PluginGalleryItem({
    required this.id,
    required this.name,
    this.description = '',
    this.experimental = false,
    this.enabled = true,
    this.version = '',
  });

  factory PluginGalleryItem.fromJson(Map<String, dynamic> json) => PluginGalleryItem(
        id: (json['id'] ?? '').toString(),
        name: (json['name'] ?? '').toString(),
        description: (json['description'] ?? '').toString(),
        experimental: json['experimental'] == true,
        enabled: json['enabled'] != false,
        version: (json['version'] ?? '').toString(),
      );

  final String id;
  final String name;
  final String description;
  final bool experimental;
  final bool enabled;
  final String version;
}

/// M4.1：已安装插件的一个分组（内置插件配置 / 实验性插件 / 其他插件）。
class PluginGalleryGroup {
  const PluginGalleryGroup({
    required this.key,
    required this.title,
    this.plugins = const <PluginGalleryItem>[],
  });

  factory PluginGalleryGroup.fromJson(Map<String, dynamic> json) => PluginGalleryGroup(
        key: (json['key'] ?? json['title'] ?? '').toString(),
        title: (json['title'] ?? json['key'] ?? '').toString(),
        plugins: <PluginGalleryItem>[
          for (final item in ((json['plugins'] is List) ? json['plugins'] as List : const <Object>[]))
            if (item is Map) PluginGalleryItem.fromJson(item.cast<String, dynamic>()),
        ],
      );

  final String key;
  final String title;
  final List<PluginGalleryItem> plugins;
}

/// M4.1：`GET /desktop/plugins/gallery` 的结果。
class PluginGallery {
  const PluginGallery({this.groups = const <PluginGalleryGroup>[]});

  factory PluginGallery.fromJson(Map<String, dynamic> json) => PluginGallery(
        groups: <PluginGalleryGroup>[
          for (final item in ((json['groups'] is List) ? json['groups'] as List : const <Object>[]))
            if (item is Map) PluginGalleryGroup.fromJson(item.cast<String, dynamic>()),
        ],
      );

  final List<PluginGalleryGroup> groups;

  int get total => groups.fold(0, (sum, group) => sum + group.plugins.length);
}

/// M4.18：`GET /desktop/plugins/catalog` 的结果——电脑端插件市场的完整目录。
///
/// 条目复用 [MarketEntry]（名称/标题/版本/说明/是否已装），另外带上官方标记与
/// 安装用的 spec，这样手机上的列表和电脑端「设置 → 插件市场」是同一份数据。
class PluginCatalog {
  const PluginCatalog({
    this.supported = false,
    this.language = '',
    this.entries = const <MarketEntry>[],
    this.error,
  });

  factory PluginCatalog.fromJson(Map<String, dynamic> json) {
    final raw = json['bundles'];
    return PluginCatalog(
      supported: json['supported'] == true,
      language: (json['language'] ?? '').toString(),
      entries: <MarketEntry>[
        for (final item in (raw is List ? raw : const <Object>[]))
          if (item is Map) MarketEntry.fromJson(item.cast<String, dynamic>()),
      ]..removeWhere((entry) => entry.name.trim().isEmpty),
    );
  }

  final bool supported;
  final String language;
  final List<MarketEntry> entries;
  final String? error;

  bool get isEmpty => entries.isEmpty;
}
