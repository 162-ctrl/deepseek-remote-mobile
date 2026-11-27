import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// M4.27：手机档（云端直连）的对话记录。
///
/// 以前云端对话只活在 `_CloudChatScreenState._messages` 里：退出页面、切到别的
/// App、或者点一次「新对话」，说过的话就没了；也不能像豆包那样在侧边翻历史。
/// 现在每条对话存进应用私有目录的 `cloud_conversations.json`，按更新时间倒序
/// 列在侧边栏里，随时切回去接着聊。
class CloudChatRecord {
  const CloudChatRecord({
    required this.role,
    required this.text,
    this.failed = false,
  });

  /// `user` / `assistant`。
  final String role;
  final String text;
  final bool failed;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'role': role,
        'text': text,
        if (failed) 'failed': true,
      };

  factory CloudChatRecord.fromJson(Map<String, dynamic> json) {
    final role = (json['role'] as String?)?.trim() ?? '';
    return CloudChatRecord(
      role: role == 'assistant' ? 'assistant' : 'user',
      text: (json['text'] as String?) ?? '',
      failed: json['failed'] == true,
    );
  }
}

/// 一条对话（一串消息 + 标题 + 时间）。
class CloudConversation {
  CloudConversation({
    required this.id,
    required this.createdAt,
    required this.updatedAt,
    this.title = '',
    List<CloudChatRecord>? messages,
  }) : messages = List<CloudChatRecord>.of(messages ?? const <CloudChatRecord>[]);

  final String id;
  final DateTime createdAt;
  DateTime updatedAt;
  String title;
  final List<CloudChatRecord> messages;

  bool get isEmpty => messages.isEmpty;

  /// 侧边栏里显示的名字：没起过名就「新对话」。
  String get displayTitle {
    final trimmed = title.trim();
    if (trimmed.isNotEmpty) return trimmed;
    final first = messages.firstWhere(
      (message) => message.role == 'user' && message.text.trim().isNotEmpty,
      orElse: () => const CloudChatRecord(role: 'user', text: ''),
    );
    final derived = conversationTitle(first.text);
    return derived.isEmpty ? '新对话' : derived;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'title': title,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'messages': messages.map((message) => message.toJson()).toList(),
      };

  factory CloudConversation.fromJson(Map<String, dynamic> json) {
    final rawMessages = json['messages'];
    final messages = <CloudChatRecord>[];
    if (rawMessages is List) {
      for (final item in rawMessages) {
        if (item is Map<String, dynamic>) {
          messages.add(CloudChatRecord.fromJson(item));
        } else if (item is Map) {
          messages.add(
            CloudChatRecord.fromJson(Map<String, dynamic>.from(item)),
          );
        }
      }
    }
    final created = DateTime.tryParse('${json['createdAt'] ?? ''}');
    final updated = DateTime.tryParse('${json['updatedAt'] ?? ''}');
    // M4.40 审计抓到：时间戳坏了以前退回 DateTime.now()，于是一条写着
    // updatedAt:'yesterday' 的坏记录会排到「最近」的最前面，把真正最新的
    // 那条挤下去。坏记录现在退回 1970（沉底），顺序稳定可预期。
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);
    return CloudConversation(
      id: (json['id'] as String?)?.trim().isNotEmpty == true
          ? (json['id'] as String).trim()
          : DateTime.now().microsecondsSinceEpoch.toString(),
      createdAt: created ?? updated ?? epoch,
      updatedAt: updated ?? created ?? epoch,
      title: (json['title'] as String?) ?? '',
      messages: messages,
    );
  }
}

/// 把第一句用户消息压成侧边栏标题：单行、去多余空白、超长截断。
String conversationTitle(String raw, {int max = 18}) {
  final flat = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (flat.isEmpty) return '';
  if (flat.length <= max) return flat;
  return '${flat.substring(0, max)}…';
}

/// 对话记录的读写：一个 JSON 文件，坏了就当空库，绝不让首页打不开。
class CloudConversationStore {
  CloudConversationStore({
    Future<Directory> Function()? directory,
    this.maxConversations = 80,
  }) : _directory = directory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directory;

  /// 最多保留多少条（按更新时间留新的），避免文件无限长。
  final int maxConversations;

  static const String fileName = 'cloud_conversations.json';

  Future<File> file() async {
    final dir = await _directory();
    return File('${dir.path}${Platform.pathSeparator}$fileName');
  }

  Future<List<CloudConversation>> load() async {
    try {
      final target = await file();
      if (!await target.exists()) return <CloudConversation>[];
      final text = await target.readAsString();
      if (text.trim().isEmpty) return <CloudConversation>[];
      final decoded = jsonDecode(text);
      final raw = decoded is Map ? decoded['conversations'] : decoded;
      if (raw is! List) return <CloudConversation>[];
      final items = <CloudConversation>[];
      for (final item in raw) {
        if (item is Map<String, dynamic>) {
          items.add(CloudConversation.fromJson(item));
        } else if (item is Map) {
          items.add(CloudConversation.fromJson(Map<String, dynamic>.from(item)));
        }
      }
      items.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return items;
    } catch (_) {
      return <CloudConversation>[];
    }
  }

  Future<void> save(List<CloudConversation> conversations) async {
    final target = await file();
    await target.parent.create(recursive: true);
    final sorted = List<CloudConversation>.of(conversations)
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final kept = sorted.take(maxConversations).toList();
    final payload = <String, dynamic>{
      'version': 1,
      'conversations': kept.map((item) => item.toJson()).toList(),
    };
    await target.writeAsString(jsonEncode(payload));
  }
}
