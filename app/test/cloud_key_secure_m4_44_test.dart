// M4.44 API Key 不再明文落盘：Key 进安全存储，JSON 只留地址与模型名。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:deepseek_remote_app/services/cloud_chat.dart';

void main() {
  late Directory dir;
  late InMemorySecretStore secrets;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('cloud-chat-secure-');
    secrets = InMemorySecretStore();
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  CloudChatStore store() =>
      CloudChatStore(directory: () async => dir, secrets: secrets);

  File configFile() =>
      File('${dir.path}${Platform.pathSeparator}cloud_chat.json');

  group('M4.44 云端 Key 安全存储', () {
    test('保存后 JSON 里没有 apiKey，Key 在安全存储里', () async {
      final config = const CloudChatConfig(
        baseUrl: 'https://api.deepseek.com/v1',
        apiKey: 'sk-secret-123',
        model: 'deepseek-chat',
      );
      await store().save(config);

      final raw = await configFile().readAsString();
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      expect(decoded.containsKey('apiKey'), isFalse, reason: '磁盘上不能有明文 Key');
      expect(raw.contains('sk-secret-123'), isFalse);
      expect(decoded['baseUrl'], 'https://api.deepseek.com/v1');
      expect(decoded['model'], 'deepseek-chat');
      expect(secrets.values[CloudChatStore.apiKeySlot], 'sk-secret-123');

      final loaded = await store().load();
      expect(loaded?.apiKey, 'sk-secret-123');
      expect(loaded?.isReady, isTrue);
    });

    test('老文件里的明文 Key 会自动迁移并重写', () async {
      await configFile().writeAsString(jsonEncode(<String, dynamic>{
        'baseUrl': 'https://api.moonshot.cn/v1',
        'apiKey': 'sk-legacy-777',
        'model': 'kimi-k2',
      }));

      final loaded = await store().load();

      expect(loaded?.apiKey, 'sk-legacy-777');
      expect(secrets.values[CloudChatStore.apiKeySlot], 'sk-legacy-777');
      final after = await configFile().readAsString();
      expect(after.contains('sk-legacy-777'), isFalse, reason: '迁移后要重写掉明文');
      final decoded = jsonDecode(after) as Map<String, dynamic>;
      expect(decoded.containsKey('apiKey'), isFalse);
      expect(decoded['model'], 'kimi-k2');
    });

    test('只丢了 JSON 或只丢了 Key 都算没配置', () async {
      // 只有 JSON，没有 Key
      await configFile().writeAsString(jsonEncode(<String, dynamic>{
        'baseUrl': 'https://api.deepseek.com/v1',
        'model': 'deepseek-chat',
      }));
      expect(await store().load(), isNull);

      // 只有 Key，没有 JSON
      await configFile().delete();
      secrets.values[CloudChatStore.apiKeySlot] = 'sk-only';
      expect(await store().load(), isNull);
    });

    test('clear 同时清掉文件与 Key', () async {
      await store().save(const CloudChatConfig(apiKey: 'sk-x'));
      await store().clear();

      expect(await configFile().exists(), isFalse);
      expect(secrets.values.containsKey(CloudChatStore.apiKeySlot), isFalse);
      expect(await store().load(), isNull);
    });
  });
}
