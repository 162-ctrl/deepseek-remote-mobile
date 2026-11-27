import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:deepseek_remote_app/services/update_service.dart';

/// 记录请求并可配置响应/异常的内存 HTTP 实现。
class _FakeHttp implements UpdateHttpClient {
  _FakeHttp({
    this.versionBody,
    this.versionStatus = 200,
    this.downloadBytes,
    this.downloadStatus = 200,
    this.throwOnGet = false,
    this.throwOnRead = false,
  });

  String? versionBody;
  int versionStatus;
  List<int>? downloadBytes;
  int downloadStatus;
  bool throwOnGet;
  bool throwOnRead;

  final List<String> requestedUrls = [];
  final List<String?> requestedTokens = [];

  @override
  Future<UpdateHttpResponse> get(String url, {String? token}) async {
    requestedUrls.add(url);
    requestedTokens.add(token);
    if (throwOnGet) throw const SocketException('网络不可达');
    return UpdateHttpResponse(versionStatus, versionBody ?? '');
  }

  @override
  Future<UpdateByteStream> openRead(String url, {String? token}) async {
    requestedUrls.add(url);
    requestedTokens.add(token);
    if (throwOnRead) throw const SocketException('下载中断');
    final bytes = downloadBytes ?? const <int>[];
    return UpdateByteStream(
      statusCode: downloadStatus,
      stream: Stream<List<int>>.fromIterable(<List<int>>[bytes]),
      contentLength: bytes.length,
    );
  }
}

String _versionJson({
  required int code,
  String name = '0.1.7-m2.5',
  int size = 1234,
  String notes = '测试更新说明',
}) {
  return jsonEncode(<String, dynamic>{
    'versionCode': code,
    'versionName': name,
    'size': size,
    'sha256': 'a' * 64,
    'notes': notes,
    'url': '/api/v1/app/apk',
    'publishedAt': '2026-11-03T17:16:00+08:00',
  });
}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('m2_5_update_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('check：服务端 versionCode 更大时返回更新信息', () async {
    final http = _FakeHttp(versionBody: _versionJson(code: 7));
    final service = UpdateService(http: http);
    final info = await service.check(
      baseUrl: 'https://demo.example.com',
      currentVersionCode: 6,
      token: 'tk',
    );
    expect(info, isNotNull);
    expect(info!.versionCode, 7);
    expect(info.versionName, '0.1.7-m2.5');
    expect(info.notes, '测试更新说明');
    expect(info.downloadPath, '/api/v1/app/apk');
    expect(
      http.requestedUrls.single,
      'https://demo.example.com/api/v1/app/version',
    );
    expect(http.requestedTokens.single, 'tk');
  });

  test('check：相同或更旧版本返回 null', () async {
    final service = UpdateService(
      http: _FakeHttp(versionBody: _versionJson(code: 6)),
    );
    expect(
      await service.check(baseUrl: 'http://127.0.0.1:8080', currentVersionCode: 6),
      isNull,
    );
    final older = UpdateService(
      http: _FakeHttp(versionBody: _versionJson(code: 5)),
    );
    expect(
      await older.check(baseUrl: 'http://127.0.0.1:8080', currentVersionCode: 6),
      isNull,
    );
  });

  test('check：404（后端未开启更新）返回 null', () async {
    final service = UpdateService(
      http: _FakeHttp(versionBody: 'not found', versionStatus: 404),
    );
    expect(
      await service.check(baseUrl: 'http://127.0.0.1:8080', currentVersionCode: 6),
      isNull,
    );
  });

  test('check：非法 JSON 返回 null 而不抛异常', () async {
    final service = UpdateService(
      http: _FakeHttp(versionBody: '<html>oops</html>'),
    );
    expect(
      await service.check(baseUrl: 'http://127.0.0.1:8080', currentVersionCode: 6),
      isNull,
    );
  });

  test('check：网络异常返回 null', () async {
    final service = UpdateService(http: _FakeHttp(throwOnGet: true));
    expect(
      await service.check(baseUrl: 'http://127.0.0.1:8080', currentVersionCode: 6),
      isNull,
    );
  });

  test('AppUpdateInfo.fromJson：缺省 url/sha256 时回退默认值', () {
    final info = AppUpdateInfo.fromJson(<String, dynamic>{
      'versionCode': '9',
      'size': '2097152',
      'versionName': '  ',
    });
    expect(info.versionCode, 9);
    expect(info.size, 2097152);
    expect(info.versionName, '未知版本');
    expect(info.sha256, isNull);
    expect(info.downloadPath, UpdateService.defaultDownloadPath);
    expect(info.sizeMb, closeTo(2.0, 1e-9));
  });

  test('download：写入 updates/app-update.apk 并回调进度', () async {
    final bytes = List<int>.generate(64, (i) => i);
    final http = _FakeHttp(downloadBytes: bytes);
    final service = UpdateService(http: http);
    final info = AppUpdateInfo(
      versionCode: 7,
      versionName: '0.1.7-m2.5',
      size: bytes.length,
    );
    final received = <int>[];
    final file = await service.download(
      info,
      baseUrl: 'http://127.0.0.1:8080/',
      targetDir: tempDir,
      onProgress: (r, t) => received.add(r),
    );
    expect(file.existsSync(), isTrue);
    expect(file.path, endsWith('updates${Platform.pathSeparator}app-update.apk'));
    expect(file.readAsBytesSync(), bytes);
    expect(received.isNotEmpty, isTrue);
    expect(received.last, bytes.length);
    expect(
      http.requestedUrls.single,
      'http://127.0.0.1:8080/api/v1/app/apk',
    );
    final part = File('${file.path}.part');
    expect(part.existsSync(), isFalse);
  });

  test('download：大小不一致抛 UpdateException 并清理 .part', () async {
    final http = _FakeHttp(downloadBytes: List<int>.filled(10, 1));
    final service = UpdateService(http: http);
    final info = AppUpdateInfo(
      versionCode: 7,
      versionName: '0.1.7-m2.5',
      size: 999,
    );
    await expectLater(
      service.download(info, baseUrl: 'http://127.0.0.1:8080', targetDir: tempDir),
      throwsA(isA<UpdateException>()),
    );
    final updatesDir = Directory('${tempDir.path}/updates');
    if (updatesDir.existsSync()) {
      final leftovers = updatesDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.part'));
      expect(leftovers, isEmpty);
    }
  });

  test('download：HTTP 非 200 抛 UpdateException', () async {
    final service = UpdateService(
      http: _FakeHttp(downloadBytes: const <int>[1], downloadStatus: 500),
    );
    final info = AppUpdateInfo(versionCode: 7, versionName: '0.1.7', size: 1);
    await expectLater(
      service.download(info, baseUrl: 'http://127.0.0.1:8080', targetDir: tempDir),
      throwsA(
        isA<UpdateException>().having(
          (e) => e.message,
          'message',
          contains('HTTP 500'),
        ),
      ),
    );
  });

  test('download：网络中断抛 UpdateException', () async {
    final service = UpdateService(http: _FakeHttp(throwOnRead: true));
    final info = AppUpdateInfo(versionCode: 7, versionName: '0.1.7', size: 10);
    await expectLater(
      service.download(info, baseUrl: 'http://127.0.0.1:8080', targetDir: tempDir),
      throwsA(isA<UpdateException>()),
    );
  });

  test('IoUpdateHttpClient 限速流：大响应按块上报进度而不是一帧跳完', () async {
    // M4.5：本地中继几十毫秒就能把 70 MB 推完，实时进度条只刷一帧就像「不动」。
    // 这里直接验证限速流：1 MiB 的响应至少要分 4 帧送达，且字节完全一致。
    final source = Stream<List<int>>.fromIterable(<List<int>>[
      List<int>.filled(512 * 1024, 1),
      List<int>.filled(512 * 1024, 2),
    ]);
    final service = UpdateService();
    final chunks = <List<int>>[];
    await for (final chunk in service.pace(source)) {
      chunks.add(chunk);
    }
    final joined = chunks.expand((c) => c).toList();
    expect(joined.length, 1024 * 1024);
    expect(joined.first, 1);
    expect(joined.last, 2);
    expect(chunks.length, inInclusiveRange(4, 9));
    expect(
      chunks.every((c) => c.length >= 256 * 1024),
      isTrue,
    );
  });

  test('IoUpdateHttpClient 限速流：小响应保持原样透传', () async {
    final source = Stream<List<int>>.fromIterable(<List<int>>[
      <int>[1, 2, 3],
      <int>[4, 5],
    ]);
    final service = UpdateService();
    final chunks = <List<int>>[];
    await for (final chunk in service.pace(source)) {
      chunks.add(chunk);
    }
    expect(chunks.expand((c) => c).toList(), <int>[1, 2, 3, 4, 5]);
  });

  test('download：重复下载会覆盖旧 APK', () async {
    final first = List<int>.filled(8, 7);
    final service = UpdateService(http: _FakeHttp(downloadBytes: first));
    final info = AppUpdateInfo(versionCode: 7, versionName: '0.1.7', size: 8);
    final firstFile = await service.download(
      info,
      baseUrl: 'http://127.0.0.1:8080',
      targetDir: tempDir,
    );
    final second = List<int>.filled(8, 9);
    final secondService = UpdateService(http: _FakeHttp(downloadBytes: second));
    final secondFile = await secondService.download(
      info,
      baseUrl: 'http://127.0.0.1:8080',
      targetDir: tempDir,
    );
    expect(secondFile.path, firstFile.path);
    expect(secondFile.readAsBytesSync(), second);
  });
}
