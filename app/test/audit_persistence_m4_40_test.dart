// M4.40 测试审计 · 角度二：手机本地存档被写坏之后还能不能用
//
// 手机档的对话只存在这台手机的 `cloud_conversations.json` 里——没有云端副本。
// 所以「文件坏一半」「被别的版本写过」「同 id 出现两次」这些情况必须不崩、
// 不静默清空全部历史。这里用真实临时目录写各种坏文件，再 load()。
import 'dart:convert';
import 'dart:io';

import 'package:deepseek_remote_app/services/cloud_conversations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late CloudConversationStore store;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('m4-40-store-');
    store = CloudConversationStore(directory: () async => dir);
    file = File('${dir.path}/${CloudConversationStore.fileName}');
  });

  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  CloudConversation conversation({
    required String id,
    required DateTime updatedAt,
    String title = '',
    List<CloudChatRecord> messages = const <CloudChatRecord>[],
  }) =>
      CloudConversation(
        id: id,
        createdAt: updatedAt.subtract(const Duration(minutes: 5)),
        updatedAt: updatedAt,
        title: title,
        messages: messages,
      );

  group('M4.40 坏存档的容错', () {
    test('文件不存在：空表，且不抛异常', () async {
      expect(file.existsSync(), isFalse);
      expect(await store.load(), isEmpty);
    });

    test('0 字节文件：空表', () async {
      await file.writeAsString('');
      expect(await store.load(), isEmpty);
    });

    test('写到一半的 JSON（截断）：空表，不抛', () async {
      await file.writeAsString('{"version":1,"conversations":[{"id":"a","upda');
      expect(await store.load(), isEmpty);
    });

    test('顶层是数字 / 字符串：空表', () async {
      for (final garbage in <String>['42', '"hello"', 'null']) {
        await file.writeAsString(garbage);
        expect(await store.load(), isEmpty, reason: 'garbage=$garbage');
      }
    });

    test('列表里混进 null 与字符串：跳过坏的，保留好的', () async {
      await file.writeAsString(
        jsonEncode(<String, dynamic>{
          'version': 1,
          'conversations': <Object?>[
            null,
            'not-a-map',
            <String, dynamic>{
              'id': 'good',
              'createdAt': '2026-11-18T09:00:00.000Z',
              'updatedAt': '2026-11-18T10:00:00.000Z',
              'title': '留下来的那条',
              'messages': <Map<String, dynamic>>[
                <String, dynamic>{'role': 'user', 'text': '在吗'},
              ],
            },
          ],
        }),
      );
      final rows = await store.load();
      expect(rows, hasLength(1));
      expect(rows.single.id, 'good');
      expect(rows.single.displayTitle, '留下来的那条');
    });

    test('时间字段坏掉：不抛，且这条不会顶到最前面', () async {
      await file.writeAsString(
        jsonEncode(<String, dynamic>{
          'conversations': <Map<String, dynamic>>[
            <String, dynamic>{'id': 'broken', 'updatedAt': 'yesterday'},
            <String, dynamic>{
              'id': 'fine',
              'createdAt': '2026-11-18T09:00:00.000Z',
              'updatedAt': '2026-11-18T10:00:00.000Z',
            },
          ],
        }),
      );
      final rows = await store.load();
      expect(rows.map((row) => row.id), contains('fine'));
      expect(rows.first.id, 'fine');
    });

    test('消息 role 写错：归一成 user，不丢这条消息', () async {
      await file.writeAsString(
        jsonEncode(<String, dynamic>{
          'conversations': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'c1',
              'createdAt': '2026-11-18T09:00:00.000Z',
              'updatedAt': '2026-11-18T10:00:00.000Z',
              'messages': <Map<String, dynamic>>[
                <String, dynamic>{'role': 'SYSTEM', 'text': '一'},
                <String, dynamic>{'role': '', 'text': '二'},
                <String, dynamic>{'role': 'assistant', 'text': '三'},
              ],
            },
          ],
        }),
      );
      final rows = await store.load();
      expect(rows.single.messages.map((m) => m.role), <String>['user', 'user', 'assistant']);
    });

    test('同 id 出现两次：不崩，仍然读得出来', () async {
      final now = DateTime(2026, 11, 18, 10);
      await file.writeAsString(
        jsonEncode(<String, dynamic>{
          'conversations': <Map<String, dynamic>>[
            conversation(id: 'dup', updatedAt: now).toJson(),
            conversation(id: 'dup', updatedAt: now.subtract(const Duration(hours: 1)))
                .toJson(),
          ],
        }),
      );
      final rows = await store.load();
      expect(rows, isNotEmpty);
      expect(rows.map((row) => row.id).toSet(), <String>{'dup'});
    });
  });

  group('M4.40 存档的容量与往返', () {
    test('超过 80 条只留最近 80 条（按 updatedAt）', () async {
      final base = DateTime(2026, 11, 1, 8);
      final many = List<CloudConversation>.generate(
        120,
        (index) => conversation(
          id: 'c$index',
          updatedAt: base.add(Duration(minutes: index)),
          messages: <CloudChatRecord>[
            CloudChatRecord(role: 'user', text: '第 $index 条'),
          ],
        ),
      );
      await store.save(many);
      final rows = await store.load();
      expect(rows, hasLength(80));
      // 最新的那条（c119）必须在，最老的（c0）被丢掉。
      expect(rows.first.id, 'c119');
      expect(rows.any((row) => row.id == 'c0'), isFalse);
    });

    test('emoji、超长文本、换行、引号往返后一字不差', () async {
      final text = '${'很长的句子。' * 400}\n\n带 emoji 🧪🐶 和引号 "双引号" \'单引号\' \\ 反斜杠';
      await store.save(<CloudConversation>[
        conversation(
          id: 'roundtrip',
          updatedAt: DateTime(2026, 11, 18, 10),
          messages: <CloudChatRecord>[
            CloudChatRecord(role: 'user', text: text),
            const CloudChatRecord(role: 'assistant', text: '', failed: true),
          ],
        ),
      ]);
      final rows = await store.load();
      expect(rows.single.messages.first.text, text);
      expect(rows.single.messages.last.failed, isTrue);
      expect(rows.single.messages.last.text, isEmpty);
    });
  });
}
