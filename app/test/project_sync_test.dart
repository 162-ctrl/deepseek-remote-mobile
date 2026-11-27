import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:deepseek_remote_app/data/live_store.dart';
import 'package:deepseek_remote_app/services/pairing_api.dart';
import 'package:deepseek_remote_app/services/relay_client.dart';
import 'package:deepseek_remote_app/services/workspace_models.dart';

/// M2.6：项目同步（workspace.list / file.read 请求-响应）单测。
///
/// 全部使用注入的假 WebSocket，不依赖真实后端。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('M2.6 工作区请求-响应', () {
    test('listDirectory 发出 workspace.list 并解析目录条目', () async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      await harness.connect();
      harness.sendDeviceStatus();

      final future = harness.store.listDirectory(
        workspacePath: _Harness.root,
        relativePath: '',
      );
      await pumpEventQueue();

      final frame = harness.socket.lastFrameOfType('workspace.list');
      expect(frame, isNotNull);
      final payload = frame!['payload'] as Map<String, dynamic>;
      expect(payload['workspacePath'], _Harness.root);
      expect(payload['relativePath'], '');
      final requestId = payload['requestId'] as String;
      expect(requestId.startsWith('req_'), isTrue);

      harness.socket.serverSend({
        'v': 1,
        'type': 'workspace.list.result',
        'ts': _now(),
        'payload': {
          'requestId': requestId,
          'ok': true,
          'workspacePath': _Harness.root,
          'relativePath': '',
          'entries': [
            {
              'name': 'app',
              'path': 'app',
              'isDir': true,
              'size': 0,
              'modifiedAt': '2026-11-04T00:00:00.000Z',
            },
            {
              'name': 'README.md',
              'path': 'README.md',
              'isDir': false,
              'size': 2048,
              'modifiedAt': '2026-11-03T00:00:00.000Z',
            },
          ],
          'truncated': false,
          'ignoredCount': 2,
        },
      });

      final listing = await future;
      expect(listing.entries.length, 2);
      expect(listing.entries.first.name, 'app');
      expect(listing.entries.first.isDir, isTrue);
      expect(listing.entries.last.isDir, isFalse);
      expect(listing.entries.last.size, 2048);
      expect(listing.entries.last.modifiedAt, isNotNull);
      expect(listing.truncated, isFalse);
      expect(listing.ignoredCount, 2);
    });

    test('并发请求按 requestId 各自配对', () async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      await harness.connect();
      harness.sendDeviceStatus();

      final first = harness.store.listDirectory(
        workspacePath: _Harness.root,
        relativePath: 'app',
      );
      final second = harness.store.listDirectory(
        workspacePath: _Harness.root,
        relativePath: 'docs',
      );
      await pumpEventQueue();

      final frames = harness.socket.framesOfType('workspace.list');
      expect(frames.length, 2);
      final firstId = (frames[0]['payload'] as Map)['requestId'] as String;
      final secondId = (frames[1]['payload'] as Map)['requestId'] as String;
      expect(firstId, isNot(secondId));

      // 先回第二个，再回第一个。
      harness.socket.serverSend(
        _listResult(requestId: secondId, relativePath: 'docs', names: ['a.md']),
      );
      harness.socket.serverSend(
        _listResult(requestId: firstId, relativePath: 'app', names: ['main.dart']),
      );

      final firstListing = await first;
      final secondListing = await second;
      expect(firstListing.relativePath, 'app');
      expect(firstListing.entries.single.name, 'main.dart');
      expect(secondListing.relativePath, 'docs');
      expect(secondListing.entries.single.name, 'a.md');
      expect(harness.store.pendingWorkspaceRequestCount, 0);
    });

    test('未知 requestId 的结果被丢弃且不进消息流', () async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      await harness.connect();
      harness.sendDeviceStatus();
      final before = harness.store.messages.length;

      harness.socket.serverSend(
        _listResult(requestId: 'req_unknown_1', relativePath: '', names: ['x']),
      );
      await pumpEventQueue();

      expect(harness.store.messages.length, before);
      expect(harness.store.pendingWorkspaceRequestCount, 0);
    });

    test('DIR_NOT_FOUND 映射为可展示异常', () async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      await harness.connect();
      harness.sendDeviceStatus();

      final future = harness.store.listDirectory(workspacePath: _Harness.root);
      await pumpEventQueue();
      final requestId = harness.socket.lastRequestIdOf('workspace.list');
      harness.socket.serverSend({
        'v': 1,
        'type': 'workspace.list.result',
        'ts': _now(),
        'payload': {
          'requestId': requestId,
          'ok': false,
          'code': 'DIR_NOT_FOUND',
          'message': 'no such dir',
        },
      });

      await expectLater(
        future,
        throwsA(
          isA<WorkspaceRequestException>()
              .having((e) => e.code, 'code', 'DIR_NOT_FOUND')
              .having((e) => e.friendlyMessage, 'message', '目录不存在或已被移动'),
        ),
      );
    });

    test('PATH_NOT_ALLOWED / BINARY_FILE 中文提示', () {
      expect(
        workspaceErrorLabel('PATH_NOT_ALLOWED'),
        '不在授权范围内，无法访问该路径',
      );
      expect(workspaceErrorLabel('BINARY_FILE'), '二进制文件不支持预览或编辑');
      expect(
        workspaceErrorLabel('TOO_LARGE'),
        '内容过大（预览上限 1 MiB，写入上限 512 KiB）',
      );
      const exception = WorkspaceRequestException('BINARY_FILE');
      expect(exception.friendlyMessage, '二进制文件不支持预览或编辑');
    });

    test('未连接时 listDirectory 抛 OFFLINE', () async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      await expectLater(
        harness.store.listDirectory(workspacePath: _Harness.root),
        throwsA(
          isA<WorkspaceRequestException>()
              .having((e) => e.code, 'code', 'OFFLINE'),
        ),
      );
      expect(harness.sockets, isEmpty);
    });

    test('readWorkspaceFile 解析内容 / 大小 / sha256 / truncated', () async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      await harness.connect();
      harness.sendDeviceStatus();

      final future = harness.store.readWorkspaceFile(
        workspacePath: _Harness.root,
        relativePath: 'app/pubspec.yaml',
      );
      await pumpEventQueue();
      final requestId = harness.socket.lastRequestIdOf('file.read');
      harness.socket.serverSend({
        'v': 1,
        'type': 'file.read.result',
        'ts': _now(),
        'payload': {
          'requestId': requestId,
          'ok': true,
          'relativePath': 'app/pubspec.yaml',
          'content': 'name: deepseek_remote_app\n',
          'size': 27,
          'sha256': '0123456789abcdef0123456789abcdef',
          'truncated': true,
          'binary': false,
          'modifiedAt': '2026-11-04T00:00:00.000Z',
        },
      });

      final content = await future;
      expect(content.content, startsWith('name: deepseek_remote_app'));
      expect(content.size, 27);
      expect(content.sha256Short, '01234567');
      expect(content.truncated, isTrue);
      expect(content.binary, isFalse);
    });

    test('file.read 失败 TOO_LARGE 映射异常', () async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      await harness.connect();
      harness.sendDeviceStatus();

      final future = harness.store.readWorkspaceFile(
        workspacePath: _Harness.root,
        relativePath: 'huge.log',
      );
      await pumpEventQueue();
      final requestId = harness.socket.lastRequestIdOf('file.read');
      harness.socket.serverSend({
        'v': 1,
        'type': 'file.read.result',
        'ts': _now(),
        'payload': {
          'requestId': requestId,
          'ok': false,
          'code': 'TOO_LARGE',
          'message': 'file too large',
        },
      });

      await expectLater(
        future,
        throwsA(
          isA<WorkspaceRequestException>()
              .having(
                (e) => e.friendlyMessage,
                'message',
                '内容过大（预览上限 1 MiB，写入上限 512 KiB）',
              ),
        ),
      );
    });

    test('请求超时抛 TIMEOUT 并清理 pending 表', () async {
      final harness = _Harness(timeout: const Duration(milliseconds: 80));
      addTearDown(harness.dispose);
      await harness.connect();
      harness.sendDeviceStatus();

      await expectLater(
        harness.store.listDirectory(workspacePath: _Harness.root),
        throwsA(
          isA<WorkspaceRequestException>().having((e) => e.code, 'code', 'TIMEOUT'),
        ),
      );
      expect(harness.store.pendingWorkspaceRequestCount, 0);
    });

    test('device.status 更新 workspaceRoots 与能力位', () async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      await harness.connect();
      harness.sendDeviceStatus(
        roots: ['D:\\work\\proj', 'D:\\work\\other'],
        canList: true,
      );
      await pumpEventQueue();
      expect(harness.store.workspaceRoots, ['D:\\work\\proj', 'D:\\work\\other']);
      expect(harness.store.canListWorkspace, isTrue);
      expect(harness.store.canReadWorkspaceFiles, isTrue);
      expect(harness.store.canWriteWorkspaceFiles, isTrue);

      harness.sendDeviceStatus(
        roots: const [],
        canList: false,
        canRead: false,
        canWrite: false,
      );
      await pumpEventQueue();
      expect(harness.store.workspaceRoots, isEmpty);
      expect(harness.store.canListWorkspace, isFalse);
      expect(harness.store.canReadWorkspaceFiles, isFalse);
      expect(harness.store.canWriteWorkspaceFiles, isFalse);
    });

    test('setPendingWorkspace 后 conversation.create 带 workspacePath，创建后清空', () async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      await harness.connect();
      harness.sendDeviceStatus();

      harness.store.setPendingWorkspace(_Harness.root);
      expect(harness.store.pendingWorkspacePath, _Harness.root);

      harness.store.sendPrompt('看一下这个项目');
      await pumpEventQueue();
      final creates = harness.socket.framesOfType('conversation.create');
      expect(creates, isNotEmpty);
      final payload = creates.last['payload'] as Map<String, dynamic>;
      expect(payload['workspacePath'], _Harness.root);

      harness.socket.serverSend({
        'v': 1,
        'type': 'conversation.created',
        'ts': _now(),
        'payload': {
          'conversationId': 'conv-1',
          'sessionId': 'session-1',
          'workspacePath': _Harness.root,
          'title': '手机发起的会话',
        },
      });
      await pumpEventQueue();

      expect(harness.store.pendingWorkspacePath, isNull);
      expect(harness.store.conversationId, 'conv-1');
      final promptSend = harness.socket.lastFrameOfType('prompt.send');
      expect(promptSend, isNotNull);
      expect((promptSend!['payload'] as Map)['text'], '看一下这个项目');
    });

    test('workspace 结果不写入消息流（按 requestId 配对而非 session.update）', () async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      await harness.connect();
      harness.sendDeviceStatus();
      final before = harness.store.messages.length;

      final future = harness.store.listDirectory(workspacePath: _Harness.root);
      await pumpEventQueue();
      final requestId = harness.socket.lastRequestIdOf('workspace.list');
      harness.socket.serverSend(
        _listResult(requestId: requestId, relativePath: '', names: ['one']),
      );
      await future;
      await pumpEventQueue();

      expect(harness.store.messages.length, before);
    });

    test('writeWorkspaceFile 发出 file.write 并解析结果', () async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      await harness.connect();
      harness.sendDeviceStatus();

      final future = harness.store.writeWorkspaceFile(
        workspacePath: _Harness.root,
        relativePath: 'notes/today.md',
        content: 'hello\n',
        baseSha256: 'abc123',
        force: true,
      );
      await pumpEventQueue();
      final frame = harness.socket.lastFrameOfType('file.write');
      expect(frame, isNotNull);
      final payload = frame!['payload'] as Map<String, dynamic>;
      expect(payload['workspacePath'], _Harness.root);
      expect(payload['relativePath'], 'notes/today.md');
      expect(payload['content'], 'hello\n');
      expect(payload['baseSha256'], 'abc123');
      expect(payload['force'], isTrue);
      final requestId = payload['requestId'] as String;

      harness.socket.serverSend({
        'v': 1,
        'type': 'file.write.result',
        'ts': _now(),
        'payload': {
          'requestId': requestId,
          'ok': true,
          'workspacePath': _Harness.root,
          'relativePath': 'notes/today.md',
          'size': 6,
          'sha256': 'deadbeefdeadbeefdeadbeefdeadbeef',
          'created': false,
          'modifiedAt': '2026-11-05T00:00:00.000Z',
        },
      });

      final result = await future;
      expect(result.relativePath, 'notes/today.md');
      expect(result.size, 6);
      expect(result.sha256Short, 'deadbeef');
      expect(result.created, isFalse);
      expect(harness.store.pendingWorkspaceRequestCount, 0);
    });

    test('新建文件不携带 baseSha256 与 force', () async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      await harness.connect();
      harness.sendDeviceStatus();

      final future = harness.store.writeWorkspaceFile(
        workspacePath: _Harness.root,
        relativePath: 'new.md',
        content: 'x',
      );
      await pumpEventQueue();
      final payload = harness.socket.lastFrameOfType('file.write')!['payload']
          as Map<String, dynamic>;
      expect(payload.containsKey('baseSha256'), isFalse);
      expect(payload.containsKey('force'), isFalse);

      harness.socket.serverSend({
        'v': 1,
        'type': 'file.write.result',
        'ts': _now(),
        'payload': {
          'requestId': payload['requestId'],
          'ok': true,
          'workspacePath': _Harness.root,
          'relativePath': 'new.md',
          'size': 1,
          'sha256': '0123456789abcdef0123456789abcdef',
          'created': true,
          'modifiedAt': '2026-11-05T00:00:00.000Z',
        },
      });
      final result = await future;
      expect(result.created, isTrue);
    });

    test('file.write 冲突映射为 CONFLICT 中文提示', () async {
      final harness = _Harness();
      addTearDown(harness.dispose);
      await harness.connect();
      harness.sendDeviceStatus();

      final future = harness.store.writeWorkspaceFile(
        workspacePath: _Harness.root,
        relativePath: 'notes/today.md',
        content: 'new',
        baseSha256: 'stale',
      );
      await pumpEventQueue();
      final requestId = harness.socket.lastRequestIdOf('file.write');
      harness.socket.serverSend({
        'v': 1,
        'type': 'file.write.result',
        'ts': _now(),
        'payload': {
          'requestId': requestId,
          'ok': false,
          'code': 'CONFLICT',
          'message': 'file changed on disk',
        },
      });

      await expectLater(
        future,
        throwsA(
          isA<WorkspaceRequestException>()
              .having((e) => e.code, 'code', 'CONFLICT')
              .having(
                (e) => e.friendlyMessage,
                'message',
                '文件已在电脑上被改动，请重新加载后再保存',
              ),
        ),
      );
      expect(harness.store.pendingWorkspaceRequestCount, 0);
    });
  });
}

String _now() => DateTime.now().toUtc().toIso8601String();

Map<String, dynamic> _listResult({
  required String requestId,
  required String relativePath,
  required List<String> names,
}) {
  return {
    'v': 1,
    'type': 'workspace.list.result',
    'ts': _now(),
    'payload': {
      'requestId': requestId,
      'ok': true,
      'workspacePath': _Harness.root,
      'relativePath': relativePath,
      'entries': [
        for (final name in names)
          {
            'name': name,
            'path': relativePath.isEmpty ? name : '$relativePath/$name',
            'isDir': false,
            'size': 10,
            'modifiedAt': '2026-11-04T00:00:00.000Z',
          },
      ],
      'truncated': false,
      'ignoredCount': 0,
    },
  };
}

Future<PairResult> _pairer(String baseUrl, String code) async {
  return PairResult.fromJson({
    'token': 'tok-1',
    'role': 'app',
    'deviceId': 'device-1',
  });
}

class _Harness {
  _Harness({Duration timeout = const Duration(milliseconds: 100)})
      : _timeout = timeout {
    relayClient = RelayClient(
      connector: (uri) async {
        final socket = _FakeSocket();
        sockets.add(socket);
        return socket;
      },
      initialRetryDelay: const Duration(milliseconds: 20),
      maxRetryDelay: const Duration(milliseconds: 40),
      maxRetries: 2,
    );
    store = LiveStore(
      relayClient: relayClient,
      pairer: _pairer,
      workspaceRequestTimeout: _timeout,
    );
  }

  static const String root = r'D:\work\proj';

  final Duration _timeout;
  final List<_FakeSocket> sockets = <_FakeSocket>[];
  late final RelayClient relayClient;
  late final LiveStore store;

  _FakeSocket get socket => sockets.last;

  Future<void> connect() async {
    await store.connect('https://relay.example.com', code: '824613');
    await pumpEventQueue();
  }

  void sendDeviceStatus({
    List<String> roots = const <String>[root],
    bool canList = true,
    bool canRead = true,
    bool canWrite = true,
  }) {
    socket.serverSend({
      'v': 1,
      'type': 'device.status',
      'ts': _now(),
      'payload': {
        'online': true,
        'deviceName': 'DESKTOP-X',
        'agentVersion': '0.2.0',
        'harnessVersion': '0.3.0',
        'capabilities': {
          'workspaceList': canList,
          'fileRead': canRead,
          'fileWrite': canWrite,
        },
        'workspaceRoots': roots,
        'lastSeen': _now(),
      },
    });
  }

  Future<void> dispose() async {
    store.dispose();
    await pumpEventQueue();
  }
}

class _FakeSocket implements RelaySocket {
  final StreamController<String> _controller =
      StreamController<String>.broadcast();
  final List<String> sent = <String>[];
  int? closedCode;

  @override
  Stream<String> get messages => _controller.stream;

  @override
  int? get closeCode => closedCode;

  @override
  String? get closeReason => null;

  @override
  void send(String data) => sent.add(data);

  @override
  Future<void> close([int? code, String? reason]) async {
    closedCode = code;
    await _controller.close();
  }

  void serverSend(Map<String, dynamic> message) {
    _controller.add(jsonEncode(message));
  }

  List<Map<String, dynamic>> get frames => sent
      .map((raw) => jsonDecode(raw) as Map<String, dynamic>)
      .toList(growable: false);

  List<Map<String, dynamic>> framesOfType(String type) =>
      frames.where((frame) => frame['type'] == type).toList(growable: false);

  Map<String, dynamic>? lastFrameOfType(String type) {
    for (final frame in frames.reversed) {
      if (frame['type'] == type) return frame;
    }
    return null;
  }

  String lastRequestIdOf(String type) {
    final frame = lastFrameOfType(type);
    expect(frame, isNotNull, reason: '没有找到 $type 请求帧');
    final payload = frame!['payload'] as Map<String, dynamic>;
    final requestId = payload['requestId'];
    expect(requestId, isA<String>());
    return requestId as String;
  }
}
