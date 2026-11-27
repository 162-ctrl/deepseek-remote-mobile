import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import '../widgets/attachment_bar.dart' show PendingAttachment;

/// M4.8：视觉模型识别不了的非图片文件，改由「本机直读」交给模型看。
///
/// 云端接口只认图片，PDF / Word / Excel / 压缩包这些要读内容就得先抽成
/// 文本。手机端没有解析库，于是把附件临时交给电脑上的 Agent 读一遍
/// （不上传到工作区、不留文件），把抽出来的正文当作上下文发给模型——
/// 对用户来说就是「和正常 AI 一样，什么都能丢进来」。
abstract class CaretakerReader {
  /// 读附件，返回给模型看的正文；读不了返回 null。
  Future<String?> read(PendingAttachment attachment);
}

/// M3.0：首页「云端直连」配置。
///
/// 只要兼容 OpenAI 的 `/chat/completions`（DeepSeek、Kimi、OpenAI 都是），
/// 填地址 + Key + 模型名就能在手机上直接对话，不需要连电脑。
class CloudChatConfig {
  const CloudChatConfig({
    this.baseUrl = 'https://api.deepseek.com/v1',
    this.apiKey = '',
    this.model = 'deepseek-chat',
  });

  factory CloudChatConfig.fromJson(Map<String, dynamic> json) {
    return CloudChatConfig(
      baseUrl: (json['baseUrl'] as String?)?.trim().isNotEmpty == true
          ? (json['baseUrl'] as String).trim()
          : 'https://api.deepseek.com/v1',
      apiKey: (json['apiKey'] as String?)?.trim() ?? '',
      model: (json['model'] as String?)?.trim().isNotEmpty == true
          ? (json['model'] as String).trim()
          : 'deepseek-chat',
    );
  }

  final String baseUrl;
  final String apiKey;
  final String model;

  bool get isReady => apiKey.isNotEmpty && baseUrl.isNotEmpty && model.isNotEmpty;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'model': model,
      };

  /// M4.44：写盘用——**不含密钥**。Key 走 `SecretStore`（系统安全存储）。
  Map<String, dynamic> toMetadataJson() => <String, dynamic>{
        'baseUrl': baseUrl,
        'model': model,
      };

  CloudChatConfig copyWith({String? baseUrl, String? apiKey, String? model}) {
    return CloudChatConfig(
      baseUrl: baseUrl ?? this.baseUrl,
      apiKey: apiKey ?? this.apiKey,
      model: model ?? this.model,
    );
  }
}

/// M4.44：密钥的存放位置。
///
/// 以前 API Key 和 baseUrl/model 一起明文写在 `cloud_chat.json` 里，任何能读
/// 应用私有目录的东西（备份、root、调试导出）都能直接看到 Key。现在 Key 单独
/// 进系统安全存储（Android Keystore / iOS Keychain），JSON 里只留地址和模型名。
abstract class SecretStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> clear(String key);
}

/// 生产实现：系统安全存储。
class SecureSecretStore implements SecretStore {
  SecureSecretStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) async {
    final value = await _storage.read(key: key);
    return (value == null || value.isEmpty) ? null : value;
  }

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> clear(String key) => _storage.delete(key: key);
}

/// 测试用：内存里放一份，记录读写次数。
class InMemorySecretStore implements SecretStore {
  InMemorySecretStore([Map<String, String>? values])
      : values = values ?? <String, String>{};

  final Map<String, String> values;
  int writes = 0;
  int clears = 0;

  @override
  Future<String?> read(String key) async {
    final value = values[key];
    return (value == null || value.isEmpty) ? null : value;
  }

  @override
  Future<void> write(String key, String value) async {
    writes += 1;
    values[key] = value;
  }

  @override
  Future<void> clear(String key) async {
    clears += 1;
    values.remove(key);
  }
}

/// 把配置存到应用私有目录（Key 除外，见 [SecretStore]），重启后还在。
class CloudChatStore {
  CloudChatStore({
    Future<Directory> Function()? directory,
    SecretStore? secrets,
  })  : _directory = directory ?? getApplicationSupportDirectory,
        _secrets = secrets ?? SecureSecretStore();

  /// 安全存储里的槽位名。
  static const String apiKeySlot = 'cloud_chat_api_key';

  final Future<Directory> Function() _directory;
  final SecretStore _secrets;

  Future<File> _file() async {
    final dir = await _directory();
    return File('${dir.path}${Platform.pathSeparator}cloud_chat.json');
  }

  Future<CloudChatConfig?> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return null;
      final text = await file.readAsString();
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) return null;
      final legacyKey = (decoded['apiKey'] as String?)?.trim() ?? '';
      var apiKey = await _secrets.read(apiKeySlot) ?? '';
      var migrated = false;
      if (apiKey.isEmpty && legacyKey.isNotEmpty) {
        // M4.44：老文件里的明文 Key，搬到安全存储并重写不含 Key 的文件。
        await _secrets.write(apiKeySlot, legacyKey);
        apiKey = legacyKey;
        migrated = true;
      }
      final config = CloudChatConfig.fromJson(<String, dynamic>{
        ...decoded,
        'apiKey': apiKey,
      });
      if (migrated) {
        await file.writeAsString(jsonEncode(config.toMetadataJson()));
      }
      return config.isReady ? config : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> save(CloudChatConfig config) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    // Key 进安全存储；JSON 只写地址与模型名。
    await _secrets.write(apiKeySlot, config.apiKey);
    await file.writeAsString(jsonEncode(config.toMetadataJson()));
  }

  Future<void> clear() async {
    try {
      final file = await _file();
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 清不掉也不影响使用。
    }
    await _secrets.clear(apiKeySlot);
  }
}

/// 一条云端消息（只在本机保存，不落库）。
class CloudMessage {
  CloudMessage.user(this.text, {this.attachments = const <PendingAttachment>[]})
      : role = 'user',
        streaming = false,
        failed = false;

  CloudMessage.assistant(this.text)
      : role = 'assistant',
        streaming = false,
        failed = false,
        attachments = const <PendingAttachment>[];

  CloudMessage.assistantStreaming()
      : role = 'assistant',
        text = '',
        streaming = true,
        failed = false,
        attachments = const <PendingAttachment>[];

  final String role;
  String text;
  bool streaming;
  bool failed;

  /// M4.7：随这条消息一起发出去的附件（图片走视觉输入，文本文件内联）。
  final List<PendingAttachment> attachments;

  /// 组装成 OpenAI 兼容的 `content`。
  ///
  /// 没有附件时保持纯字符串（所有兼容接口都认）；有图片时用
  /// `[{type:text},{type:image_url}]` 的多段结构（OpenAI / Kimi / 豆包等
  /// 视觉接口的通用写法）。
  Future<Object> buildContent({CaretakerReader? caretaker}) =>
      buildUserContent(text, attachments, caretaker: caretaker);

  /// 纯函数，方便单测：把文字与附件拼成请求里的 content。
  ///
  /// [caretaker] 是 M4.8 的兜底：非图片、非纯文本的附件（PDF、Word、
  /// Excel、压缩包…）交给电脑读一遍，读出来的正文内联进 prompt。
  static Future<Object> buildUserContent(
    String text,
    List<PendingAttachment> attachments, {
    CaretakerReader? caretaker,
  }) async {
    if (attachments.isEmpty) return text;
    final parts = <Map<String, dynamic>>[];
    final images = <PendingAttachment>[];
    final buffer = StringBuffer(text.trim());
    var inline = 0;
    for (final attachment in attachments) {
      final mime = attachment.mediaType;
      if (mime != null) {
        images.add(attachment);
        continue;
      }
      var note = _inlineText(attachment);
      if (note == null && caretaker != null) {
        try {
          final read = await caretaker.read(attachment);
          if (read != null && read.trim().isNotEmpty) note = read;
        } catch (_) {
          note = null;
        }
      }
      if (note == null) {
        buffer.write('\n（已附带文件：${attachment.name}，'
            '${attachment.sizeLabel}，格式不支持在手机上预览）');
        continue;
      }
      inline++;
      buffer.write('\n\n【附件 ${attachment.name}】\n$note');
    }
    parts.add(<String, dynamic>{
      'type': 'text',
      'text': buffer.toString().trim(),
    });
    for (final image in images) {
      parts.add(<String, dynamic>{
        'type': 'image_url',
        'image_url': <String, dynamic>{
          'url': 'data:${image.mediaType};base64,${base64Encode(image.bytes)}',
        },
      });
    }
    // 只有附件没有文字、且附件都是图片时，正文留一句占位，避免空格子。
    if (inline == 0 && images.length == attachments.length) {
      if (text.trim().isEmpty) {
        parts[0]['text'] = '看看这张图。';
      }
    }
    return parts;
  }

  /// 文本类附件直接内联，二进制附件给 null（只提示文件名）。
  static String? _inlineText(PendingAttachment attachment) {
    if (!attachment.isText) return null;
    try {
      final decoded = utf8.decode(attachment.bytes, allowMalformed: true);
      // 太长的不塞：留够上下文，提示用户改发片段。
      const max = 20000;
      if (decoded.length > max) {
        return '${decoded.substring(0, max)}\n（内容过长，已截断到前 $max 字）';
      }
      return decoded;
    } catch (_) {
      return null;
    }
  }
}

/// 简单的 OpenAI 兼容客户端，支持流式输出。
class CloudChatClient {
  CloudChatClient({HttpClient? client}) : _client = client ?? HttpClient();

  final HttpClient _client;

  Uri _endpoint(CloudChatConfig config) {
    var base = config.baseUrl.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    if (base.endsWith('/chat/completions')) return Uri.parse(base);
    return Uri.parse('$base/chat/completions');
  }

  /// 发一轮对话，返回完整回复；[onDelta] 每收到一段文本就回调一次。
  Future<String> complete({
    required CloudChatConfig config,
    required List<CloudMessage> history,
    CaretakerReader? caretaker,
    String systemPrompt =
        '你是一个简洁、可靠的中文助手。回答直接给结论，需要时再展开。',
    void Function(String delta)? onDelta,
    CancellationToken? cancel,
  }) async {
    final request = await _client.postUrl(_endpoint(config));
    request.headers
      ..set(HttpHeaders.authorizationHeader, 'Bearer ${config.apiKey}')
      ..set(HttpHeaders.contentTypeHeader, 'application/json')
      ..set(HttpHeaders.acceptHeader, 'text/event-stream');

    // M4.8：用户消息的 content 可能是纯文本，也可能是多段（图片 / 读出来的文件）。
    final messages = <Map<String, dynamic>>[
      <String, dynamic>{'role': 'system', 'content': systemPrompt},
    ];
    for (final message in history) {
      messages.add(<String, dynamic>{
        'role': message.role,
        'content': message.role == 'user'
            ? await message.buildContent(caretaker: caretaker)
            : message.text,
      });
    }
    request.add(utf8.encode(jsonEncode(<String, dynamic>{
      'model': config.model,
      'messages': messages,
      'stream': true,
    })));

    final response = await request.close();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final body = await response.transform(utf8.decoder).join();
      throw CloudChatException(_errorMessage(response.statusCode, body));
    }

    final buffer = StringBuffer();
    final lines = response.transform(utf8.decoder).transform(const LineSplitter());
    await for (final line in lines) {
      if (cancel?.cancelled == true) break;
      if (!line.startsWith('data:')) continue;
      final payload = line.substring(5).trim();
      if (payload == '[DONE]') break;
      if (payload.isEmpty) continue;
      try {
        final decoded = jsonDecode(payload);
        final choices = decoded is Map ? decoded['choices'] : null;
        if (choices is! List || choices.isEmpty) continue;
        final delta = (choices.first as Map)['delta'];
        final content = delta is Map ? delta['content'] : null;
        if (content is String && content.isNotEmpty) {
          buffer.write(content);
          onDelta?.call(content);
        }
      } catch (_) {
        // 单条 SSE 解析失败不影响整体。
      }
    }
    return buffer.toString();
  }

  String _errorMessage(int status, String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final error = decoded['error'];
        if (error is Map && error['message'] is String) {
          return '${error['message']}（HTTP $status）';
        }
        if (decoded['message'] is String) {
          return '${decoded['message']}（HTTP $status）';
        }
      }
    } catch (_) {
      // 落到下面的通用文案。
    }
    if (status == 401) return 'API Key 不对或已过期（HTTP 401）';
    if (status == 404) return '接口地址不对，检查是不是少了 /v1（HTTP 404）';
    if (status == 429) return '请求太频繁或额度用完了（HTTP 429）';
    return '请求失败（HTTP $status）';
  }

  void close() => _client.close(force: true);
}

class CloudChatException implements Exception {
  const CloudChatException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 一个很轻的取消标记（停止生成用）。
class CancellationToken {
  bool cancelled = false;

  void cancel() => cancelled = true;
}
