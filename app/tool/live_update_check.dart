// 用 App 自己的更新客户端（UpdateService）对着真实插件跑一遍：
//   检查更新 →（有新版本时）下载 APK → 校验字节数。
//
//   dart run tool/live_update_check.dart [baseUrl] [currentVersionCode]
import 'dart:convert';
import 'dart:io';

import 'package:deepseek_remote_app/services/update_service.dart';

/// 直接读一次版本接口，用来区分「确实已是最新」和「接口挂了」。
Future<Map<String, dynamic>?> _fetchVersion(String baseUrl) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final request = await client.getUrl(Uri.parse('$baseUrl/api/v1/app/version'));
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != 200) return null;
    return jsonDecode(body) as Map<String, dynamic>;
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

Future<void> main(List<String> args) async {
  final baseUrl = args.isNotEmpty ? args[0] : 'http://127.0.0.1:8787';
  final current = args.length > 1 ? int.parse(args[1]) : 9;
  var failed = 0;
  void check(String name, bool ok, [String detail = '']) {
    stdout.writeln('${ok ? 'PASS' : 'FAIL'} $name${detail.isEmpty ? '' : ' — $detail'}');
    if (!ok) failed += 1;
  }

  final server = await _fetchVersion(baseUrl);
  check('版本接口可达', server != null, server == null ? '拿不到 JSON' : 'HTTP 200');
  if (server == null) {
    stdout.writeln('\nUPDATE CHECK FAIL ($failed)');
    exitCode = 1;
    return;
  }
  final serverCode = server['versionCode'] as int;
  check('服务器版本号是数字', serverCode > 0, 'code=$serverCode name=${server['versionName']}');

  final service = UpdateService();
  final info = await service.check(baseUrl: baseUrl, currentVersionCode: current);
  if (serverCode <= current) {
    // 已经是最新版：UpdateService 按约定返回 null，不算失败。
    check('已是最新（current=$current）', info == null, '服务器 code=$serverCode');
    stdout.writeln('\nUPDATE CHECK PASS');
    exitCode = failed == 0 ? 0 : 1;
    return;
  }
  if (info == null) {
    check('检查更新', false, '服务器有 code=$serverCode 但客户端没拿到');
    stdout.writeln('\nUPDATE CHECK FAIL ($failed)');
    exitCode = 1;
    return;
  }
  check('检查更新', info.versionCode == serverCode,
      '${info.versionName} code=${info.versionCode} size=${info.sizeMb.toStringAsFixed(1)}MB');
  check('sha256 存在', (info.sha256 ?? '').length == 64, info.sha256 ?? '(空)');
  check('下载路径是 /api/v1/app/apk', info.downloadPath == '/api/v1/app/apk', info.downloadPath);

  final temp = await Directory.systemTemp.createTemp('dsh-update-');
  var lastPercent = -1;
  final file = await service.download(
    info,
    baseUrl: baseUrl,
    targetDir: temp,
    onProgress: (received, total) {
      if (total <= 0) return;
      final percent = (received * 100 ~/ total);
      if (percent >= lastPercent + 25) {
        lastPercent = percent;
        stdout.writeln('  下载中 $percent%');
      }
    },
  );
  final size = await file.length();
  check('下载完成', size == info.size, '$size / ${info.size} 字节');

  await temp.delete(recursive: true);
  stdout.writeln(failed == 0 ? '\nUPDATE CHECK PASS' : '\nUPDATE CHECK FAIL ($failed)');
  exitCode = failed == 0 ? 0 : 1;
}
