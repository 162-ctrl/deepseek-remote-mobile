import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:deepseek_remote_app/services/cloud_chat.dart';

void main() {
  test('CloudChatConfig 默认值可直接用 DeepSeek', () {
    const config = CloudChatConfig();
    expect(config.baseUrl, 'https://api.deepseek.com/v1');
    expect(config.model, 'deepseek-chat');
    expect(config.isReady, isFalse);
  });

  test('CloudChatConfig 往返 JSON 保留字段', () {
    const config = CloudChatConfig(
      baseUrl: 'https://api.moonshot.cn/v1',
      apiKey: 'sk-test',
      model: 'kimi-k2',
    );
    final restored = CloudChatConfig.fromJson(config.toJson());
    expect(restored.baseUrl, config.baseUrl);
    expect(restored.apiKey, 'sk-test');
    expect(restored.model, 'kimi-k2');
    expect(restored.isReady, isTrue);
  });

  test('CloudChatStore 保存、读取、清除', () async {
    final dir = await Directory.systemTemp.createTemp('cloud-chat-test');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final store = CloudChatStore(
      directory: () async => dir,
      secrets: InMemorySecretStore(),
    );

    expect(await store.load(), isNull);

    await store.save(const CloudChatConfig(
      baseUrl: 'https://api.deepseek.com/v1',
      apiKey: 'sk-abc',
      model: 'deepseek-chat',
    ));
    final loaded = await store.load();
    expect(loaded?.apiKey, 'sk-abc');

    await store.clear();
    expect(await store.load(), isNull);
  });

  test('空 Key 的存档读出来当作未配置', () async {
    final dir = await Directory.systemTemp.createTemp('cloud-chat-empty');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final store = CloudChatStore(
      directory: () async => dir,
      secrets: InMemorySecretStore(),
    );
    await store.save(const CloudChatConfig(baseUrl: 'https://api.deepseek.com/v1'));
    expect(await store.load(), isNull);
  });
}
