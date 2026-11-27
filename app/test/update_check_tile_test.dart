import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseek_remote_app/services/update_gateway.dart';
import 'package:deepseek_remote_app/services/update_service.dart';
import 'package:deepseek_remote_app/theme/app_theme.dart';
import 'package:deepseek_remote_app/widgets/update_check_tile.dart';

/// 可控的更新服务：check 返回预设结果，download 写一个假文件。
class _FakeUpdateService extends UpdateService {
  _FakeUpdateService({this.info, this.checkError, this.downloadFile});

  AppUpdateInfo? info;
  Object? checkError;
  File? downloadFile;

  int checkCalls = 0;
  int downloadCalls = 0;

  @override
  Future<AppUpdateInfo?> check({
    required String baseUrl,
    required int currentVersionCode,
    String? token,
  }) async {
    checkCalls++;
    if (checkError != null) throw checkError!;
    final found = info;
    if (found == null) return null;
    return found.versionCode > currentVersionCode ? found : null;
  }

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
    onProgress?.call(100, 100);
    final file = downloadFile;
    if (file == null) throw const UpdateException('没有可下载的文件');
    return file;
  }
}

AppUpdateInfo _newerInfo() => const AppUpdateInfo(
      versionCode: 7,
      versionName: '0.1.7-m2.5',
      size: 1024 * 1024,
      notes: '修复若干问题',
    );

/// M4.26：下载过程中分几次上报进度，然后停住等测试放行，最后以错误收尾。
///
/// 之前 `onProgress` 只刷新外层 Tile，`StatefulBuilder` 撑起来的进度弹窗不会重画，
/// 于是弹窗一直停在「0% · 0.0 / 1.0 MB」——这条用例就是盯着那个数字。
/// 用 [finish] 手动放行，避免依赖真实时长（假时钟下容易抖）。
class _StreamingUpdateService extends UpdateService {
  final Completer<void> half = Completer<void>();
  final Completer<void> finish = Completer<void>();
  int downloadCalls = 0;

  @override
  Future<AppUpdateInfo?> check({
    required String baseUrl,
    required int currentVersionCode,
    String? token,
  }) async {
    return _newerInfo();
  }

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
    onProgress?.call(0, info.size);
    await half.future;
    onProgress?.call(info.size ~/ 2, info.size);
    await finish.future;
    throw const UpdateException('测试在这里收尾');
  }
}

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: buildAppTheme(Brightness.light),
    home: Scaffold(body: Padding(padding: const EdgeInsets.all(16), child: child)),
  );
}

void main() {
  testWidgets('未连接时点击提示先去连接，不发起检查', (tester) async {
    final service = _FakeUpdateService(info: _newerInfo());
    await tester.pumpWidget(
      _wrap(
        UpdateCheckTile(
          serverUrl: '',
          token: null,
          connected: false,
          service: service,
          gateway: FakeUpdateGateway(),
        ),
      ),
    );
    expect(find.text('检查更新'), findsOneWidget);
    await tester.tap(find.text('检查更新'));
    await tester.pump();
    expect(find.textContaining('先连接电脑'), findsOneWidget);
    expect(service.checkCalls, 0);
  });

  testWidgets('已连接且存在新版本时弹出更新说明', (tester) async {
    final service = _FakeUpdateService(info: _newerInfo());
    await tester.pumpWidget(
      _wrap(
        UpdateCheckTile(
          serverUrl: 'http://127.0.0.1:8080',
          token: 'tk',
          connected: true,
          service: service,
          gateway: FakeUpdateGateway(),
          currentVersionCode: 6,
          currentVersionName: '0.1.6-m2.5',
        ),
      ),
    );
    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();
    expect(service.checkCalls, 1);
    expect(find.text('发现新版本 v0.1.7-m2.5'), findsOneWidget);
    expect(find.text('立即更新'), findsOneWidget);
    expect(find.textContaining('修复若干问题'), findsOneWidget);
  });

  testWidgets('已是最新版本时提示，不弹更新弹窗', (tester) async {
    final service = _FakeUpdateService();
    await tester.pumpWidget(
      _wrap(
        UpdateCheckTile(
          serverUrl: 'http://127.0.0.1:8080',
          token: 'tk',
          connected: true,
          service: service,
          gateway: FakeUpdateGateway(),
          currentVersionCode: 7,
          currentVersionName: '0.1.7-m2.5',
        ),
      ),
    );
    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已是最新版本'), findsOneWidget);
    expect(find.text('立即更新'), findsNothing);
  });

  // M4.26：用户报「这个进度条都不动」，截图里弹窗停在 0% / 0.0 MB，而外层
  // 「检查更新」那行已经写着「下载中 1%」。根因是弹窗用 StatefulBuilder 包着，
  // onProgress 只调了外层 setState，弹窗的 builder 从不重跑。
  testWidgets('下载进度回调要同时刷新弹窗里的百分比与已下载字节', (tester) async {
    final service = _StreamingUpdateService();
    final gateway = FakeUpdateGateway(cacheDir: Directory.systemTemp.path);
    await tester.pumpWidget(
      _wrap(
        UpdateCheckTile(
          serverUrl: 'http://127.0.0.1:8080',
          token: 'tk',
          connected: true,
          service: service,
          gateway: gateway,
          currentVersionCode: 6,
          currentVersionName: '0.1.6-m2.5',
        ),
      ),
    );

    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('立即更新'));
    // 先让弹窗真的建起来、下载真的开始（首个 onProgress(0) 会被执行）。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('正在下载 v0.1.7-m2.5'), findsOneWidget);
    expect(find.textContaining('0% · 0.0 /'), findsOneWidget);

    // 进度到一半：这一帧必须重画弹窗（病灶就在这里）。
    service.half.complete();
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('50% · 0.5 /'), findsOneWidget);
    expect(find.textContaining('0% · 0.0 /'), findsNothing);

    // 收尾（这一步会抛错并关掉弹窗，顺便验证不会卡在弹窗上）。
    service.finish.complete();
    await tester.pumpAndSettle();
    expect(find.textContaining('正在下载'), findsNothing);
    // M4.29：失败原因除了弹一次 SnackBar，还会留在这一行的副标题上，
    // 所以这里是两处命中（SnackBar + 副标题）。
    expect(find.textContaining('测试在这里收尾'), findsWidgets);
    expect(service.downloadCalls, 1);
  });
}
