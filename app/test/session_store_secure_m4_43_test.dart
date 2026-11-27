// 指令第 3 条验收：token 不再明文落在 session.json 里。
//
// 三个层面各钉一条：
//   1. 保存后盘上的 json 里没有 token，vault 里有；
//   2. 老版本留下的明文 token 会被搬进 vault 并把 json 重写干净（迁移）；
//   3. 只有 json 没 vault / 只有 vault 没 json 都算未登录；
//   4. clear() 两边一起清。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:deepseek_remote_app/services/session_store.dart';

const String _token = 'ff778fad55d6c224e5282d32663e8d836169c5a53b774382';

Future<Directory> _tempDir() async {
  final dir = await Directory.systemTemp.createTemp('dsh-session-');
  addTearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });
  return dir;
}

void main() {
  test('保存后 json 里没有 token，token 在 vault 里', () async {
    final dir = await _tempDir();
    final vault = InMemoryTokenVault();
    final store = SessionStore(vault: vault, directory: () async => dir);

    await store.save(const SavedSession(
      serverUrl: 'https://<公网隧道>.trycloudflare.com',
      token: _token,
      deviceId: 'dev_7',
      savedAt: 1234,
    ));

    final raw = await File('${dir.path}${Platform.pathSeparator}session.json').readAsString();
    expect(raw.contains(_token), isFalse, reason: '明文 token 不能出现在 $raw');
    expect(raw.contains('serverUrl'), isTrue);

    final meta = jsonDecode(raw) as Map<String, dynamic>;
    expect(meta['deviceId'], 'dev_7');
    expect(meta['savedAt'], 1234);
    expect(vault.value, _token);
  });

  test('老版本的明文 token 迁移进 vault，json 被重写干净', () async {
    final dir = await _tempDir();
    final file = File('${dir.path}${Platform.pathSeparator}session.json');
    await file.writeAsString(jsonEncode({
      'serverUrl': 'http://192.168.1.x:8787',
      'token': _token,
      'savedAt': 99,
    }));

    final vault = InMemoryTokenVault();
    final store = SessionStore(vault: vault, directory: () async => dir);
    final loaded = await store.load();

    expect(loaded?.token, _token, reason: '迁移后当次就要能直接用');
    expect(loaded?.serverUrl, 'http://192.168.1.x:8787');
    expect(vault.value, _token, reason: 'token 应已搬进 vault');
    expect(await file.readAsString().then((s) => s.contains(_token)), isFalse);
    expect(jsonDecode(await file.readAsString())['savedAt'], 99, reason: '其余字段要保住');
  });

  test('只有 json 或只有 vault 都算未登录', () async {
    final dir = await _tempDir();
    final file = File('${dir.path}${Platform.pathSeparator}session.json');
    await file.writeAsString(jsonEncode({'serverUrl': 'https://a.b', 'savedAt': 1}));
    expect(
      await SessionStore(vault: InMemoryTokenVault(), directory: () async => dir).load(),
      isNull,
    );

    await file.delete();
    expect(
      await SessionStore(vault: InMemoryTokenVault(_token), directory: () async => dir).load(),
      isNull,
    );
  });

  test('clear() 同时清掉 vault 与文件', () async {
    final dir = await _tempDir();
    final vault = InMemoryTokenVault();
    final store = SessionStore(vault: vault, directory: () async => dir);
    await store.save(const SavedSession(serverUrl: 'https://a.b', token: _token));

    await store.clear();

    expect(vault.value, isNull);
    expect(vault.clears, greaterThan(0));
    expect(
      await File('${dir.path}${Platform.pathSeparator}session.json').exists(),
      isFalse,
    );
    expect(await store.load(), isNull);
  });
}
