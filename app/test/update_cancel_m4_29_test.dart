// M4.29：下载卡片上的「取消下载」与「后台下载」。
//
// 现场：下载 70 MB 的更新包时，那张卡片只有一个进度条，既不能停，也不能先收起来
// 去做别的事。现在：
//   - 「取消下载」真的会停（下载循环每帧查一次取消标记），并把半截 .part 删掉；
//   - 「后台下载」只是把卡片收起来，下载挂在 UpdateDownloadCenter 上继续走，
//     回到「检查更新」点一下还能接着看进度、下完直接装。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseek_remote_app/services/update_download_center.dart';
import 'package:deepseek_remote_app/services/update_gateway.dart';
import 'package:deepseek_remote_app/services/update_service.dart';
import 'package:deepseek_remote_app/theme/app_theme.dart';
import 'package:deepseek_remote_app/widgets/update_check_tile.dart';

const String _base = 'http://127.0.0.1:8787';

AppUpdateInfo _info({int size = 1024 * 1024}) => AppUpdateInfo(
      versionCode: 9,
      versionName: '0.4.29-m4.29',
      size: size,
    );

/// 只提供一条下载流：不分片、不联网。
class _FakeHttpClient implements UpdateHttpClient {
  _FakeHttpClient(this.chunks, this.contentLength);

  final List<List<int>> chunks;
  final int contentLength;
  int openReadCalls = 0;

  @override
  Future<UpdateHttpResponse> get(String url, {String? token}) async =>
      const UpdateHttpResponse(200, '{}');

  @override
  Future<UpdateByteStream> openRead(String url, {String? token}) async {
    openReadCalls++;
    return UpdateByteStream(
      statusCode: 200,
      stream: Stream<List<int>>.fromIterable(chunks),
      contentLength: contentLength,
    );
  }
}

/// 可控的下载服务：进度到一半就停住，等测试放行；取消时按真服务的语义抛错。
class _ControlledUpdateService extends UpdateService {
  _ControlledUpdateService({this.apk});

  final File? apk;
  final Completer<void> gate = Completer<void>();
  int downloadCalls = 0;
  UpdateCancelToken? seenCancel;

  @override
  Future<AppUpdateInfo?> check({
    required String baseUrl,
    required int currentVersionCode,
    String? token,
  }) async =>
      _info();

  @override
  Future<File> download(
    AppUpdateInfo info, {
    required String baseUrl,
    required Directory targetDir,
    void Function(int received, int total)? onProgress,
    String? token,
    UpdateCancelToken? cancel,
  }) async {
    downloadCalls++;
    seenCancel = cancel;
    onProgress?.call(0, info.size);
    await gate.future;
    if (cancel?.isCancelled ?? false) {
      throw const UpdateCancelled();
    }
    onProgress?.call(info.size, info.size);
    final ready = apk;
    if (ready == null) throw const UpdateException('没有可下载的文件');
    return ready;
  }
}

Widget _wrap(Widget child) => MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: Scaffold(
        body: Padding(padding: const EdgeInsets.all(16), child: child),
      ),
    );

void main() {
  group('下载可以取消（M4.29）', () {
    test('取消后抛 UpdateCancelled，并把半截 .part 删掉', () async {
      final dir = await Directory.systemTemp.createTemp('m429-cancel');
      addTearDown(() => dir.delete(recursive: true));
      // 每块 256 KB，正好一帧；第一帧回来就取消，剩下的不再写。
      final chunk = List<int>.filled(256 * 1024, 7);
      final service = UpdateService(
        http: _FakeHttpClient(<List<int>>[chunk, chunk, chunk], 768 * 1024),
      );
      final cancel = UpdateCancelToken();

      await expectLater(
        service.download(
          _info(size: 768 * 1024),
          baseUrl: _base,
          targetDir: dir,
          cancel: cancel,
          onProgress: (received, total) {
            if (received > 0) cancel.cancel();
          },
        ),
        throwsA(isA<UpdateCancelled>()),
      );

      final part = File(
        '${dir.path}${Platform.pathSeparator}updates'
        '${Platform.pathSeparator}${UpdateService.fileName}.part',
      );
      expect(await part.exists(), isFalse);
    });

    test('下载中心把进度转成百分比，下完留好文件', () async {
      final apk = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}m429-ready.apk',
      );
      final service = _ControlledUpdateService(apk: apk);
      final center = UpdateDownloadCenter(service: service);

      final future = center.start(
        info: _info(),
        baseUrl: _base,
        cacheDirectory: () async => Directory.systemTemp.path,
      );
      expect(center.running, isTrue);
      expect(center.ratio, 0);

      service.gate.complete();
      final file = await future;

      expect(file?.path, apk.path);
      expect(center.running, isFalse);
      expect(center.file?.path, apk.path);
      expect(center.ratio, 1);
      expect(center.cancelled, isFalse);
    });

    test('取消下载中心：结果为空且标记取消', () async {
      final service = _ControlledUpdateService();
      final center = UpdateDownloadCenter(service: service);
      final future = center.start(
        info: _info(),
        baseUrl: _base,
        cacheDirectory: () async => Directory.systemTemp.path,
      );
      await Future<void>.delayed(Duration.zero);

      center.cancel();
      expect(center.cancelled, isTrue);
      service.gate.complete();

      expect(await future, isNull);
      expect(center.running, isFalse);
      expect(center.cancelled, isTrue);
      expect(service.seenCancel?.isCancelled, isTrue);
    });
  });

  group('下载卡片上的两个按钮（M4.29）', () {
    testWidgets('点「后台下载」只收起卡片，下载继续并在下完后安装', (tester) async {
      final apk = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}m429-bg.apk',
      );
      final service = _ControlledUpdateService(apk: apk);
      final gateway = FakeUpdateGateway(cacheDir: Directory.systemTemp.path);

      await tester.pumpWidget(
        _wrap(
          UpdateCheckTile(
            serverUrl: _base,
            token: 'tok',
            connected: true,
            service: service,
            gateway: gateway,
          ),
        ),
      );

      await tester.tap(find.text('检查更新'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('立即更新'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // 卡片上有两个按钮。
      expect(find.text('取消下载'), findsOneWidget);
      expect(find.text('后台下载'), findsOneWidget);

      await tester.tap(find.text('后台下载'));
      // 弹窗退出有动画；不能用 pumpAndSettle——这一行的转圈是无限动画，settle 会超时。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // 卡片收起来了，但这一行还写着下载中。
      expect(find.text('正在下载 v0.4.29-m4.29'), findsNothing);
      expect(find.textContaining('下载中'), findsOneWidget);

      // 放行下载：即使卡片早就关了，也应该走完并调起安装器。
      service.gate.complete();
      await tester.pumpAndSettle();

      expect(gateway.installedPaths, <String>[apk.path]);
      expect(service.downloadCalls, 1);
    });

    testWidgets('点「取消下载」会停下来并提示已取消', (tester) async {
      final service = _ControlledUpdateService();
      final gateway = FakeUpdateGateway(cacheDir: Directory.systemTemp.path);

      await tester.pumpWidget(
        _wrap(
          UpdateCheckTile(
            serverUrl: _base,
            token: 'tok',
            connected: true,
            service: service,
            gateway: gateway,
          ),
        ),
      );

      await tester.tap(find.text('检查更新'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('立即更新'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.text('取消下载'));
      // 弹窗退出有动画；不能用 pumpAndSettle——这一行的转圈是无限动画，settle 会超时。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // 弹窗关掉，并且下发取消标记。
      expect(find.text('正在下载 v0.4.29-m4.29'), findsNothing);
      expect(service.seenCancel?.isCancelled, isTrue);

      // 放行被卡住的那次下载，让它按「已取消」收尾。
      service.gate.complete();
      await tester.pumpAndSettle();

      expect(gateway.installedPaths, isEmpty);
      expect(find.textContaining('已取消下载'), findsWidgets);
    });
  });
}
