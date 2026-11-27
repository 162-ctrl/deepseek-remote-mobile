import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'network_url_policy.dart';
import 'pairing_api.dart';

/// M2.5 A1：应用内在线更新（检查 → 下载 → 交给系统安装器）。
///
/// 设计要点：
/// - 只使用 `dart:io`（零新增 pub 依赖）；
/// - HTTP 抽象成 [UpdateHttpClient]，单测注入 Fake，不联网；
/// - 所有失败都以「返回 null / 抛 [UpdateException]」收敛，UI 只需提示不崩溃。

/// 服务端 `GET /api/v1/app/version` 返回的更新信息。
class AppUpdateInfo {
  const AppUpdateInfo({
    required this.versionCode,
    required this.versionName,
    required this.size,
    this.sha256,
    this.notes = '',
    this.downloadPath = UpdateService.defaultDownloadPath,
  });

  /// 服务端版本号（唯一比较依据）。
  final int versionCode;
  final String versionName;

  /// APK 字节数。
  final int size;
  final String? sha256;

  /// 更新说明（可空）。
  final String notes;

  /// APK 下载路径（服务端返回的 `url`，如 `/api/v1/app/apk`）。
  final String downloadPath;

  double get sizeMb => size / (1024 * 1024);

  factory AppUpdateInfo.fromJson(Map<String, dynamic> json) {
    final rawVersionCode = json['versionCode'];
    final versionCode = rawVersionCode is num
        ? rawVersionCode.toInt()
        : int.tryParse('$rawVersionCode') ?? 0;
    final rawSize = json['size'];
    final size = rawSize is num ? rawSize.toInt() : int.tryParse('$rawSize') ?? 0;
    final url = json['url'];
    return AppUpdateInfo(
      versionCode: versionCode,
      versionName: (json['versionName'] as String?)?.trim().isNotEmpty == true
          ? (json['versionName'] as String).trim()
          : '未知版本',
      size: size < 0 ? 0 : size,
      sha256: (json['sha256'] as String?)?.trim().isNotEmpty == true
          ? (json['sha256'] as String).trim()
          : null,
      notes: (json['notes'] as String?)?.trim() ?? '',
      downloadPath: url is String && url.trim().isNotEmpty
          ? url.trim()
          : UpdateService.defaultDownloadPath,
    );
  }
}

/// 更新流程中的可预期错误（消息直接展示给用户）。
class UpdateException implements Exception {
  const UpdateException(this.message);

  final String message;

  @override
  String toString() => 'UpdateException: $message';
}

/// M4.29：用户点了「取消下载」。
///
/// 单独一个类型是因为它跟失败不是一回事：取消不该弹「更新失败」，
/// 也不该把半截文件留在缓存里。
class UpdateCancelled extends UpdateException {
  const UpdateCancelled() : super('已取消下载');
}

/// M4.29：下载取消令牌。
///
/// 下载是一层层 `await for` 推着走的，取消只能靠「每帧查一次标记」——
/// 一帧最长 [UpdateService.progressInterval]（30 ms），所以点了取消最多
/// 三十毫秒就会停，并把 `.part` 文件删掉。
class UpdateCancelToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() {
    _cancelled = true;
  }
}

/// 轻量 HTTP 响应（JSON 检查用）。
class UpdateHttpResponse {
  const UpdateHttpResponse(this.statusCode, this.body);

  final int statusCode;
  final String body;
}

/// APK 下载的流式响应。
class UpdateByteStream {
  const UpdateByteStream({
    required this.statusCode,
    required this.stream,
    this.contentLength,
  });

  final int statusCode;
  final Stream<List<int>> stream;
  final int? contentLength;
}

/// 可注入的 HTTP 抽象（M2.5 A1：便于纯单测）。
abstract class UpdateHttpClient {
  Future<UpdateHttpResponse> get(String url, {String? token});

  Future<UpdateByteStream> openRead(String url, {String? token});
}

/// `dart:io HttpClient` 默认实现。
class IoUpdateHttpClient implements UpdateHttpClient {
  IoUpdateHttpClient({Duration timeout = const Duration(seconds: 15)})
      : _timeout = timeout;

  final Duration _timeout;

  Future<HttpClientRequest> _request(String url, {String? token}) async {
    final client = HttpClient()..connectionTimeout = _timeout;
    final request = await client.getUrl(Uri.parse(url)).timeout(_timeout);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (token != null && token.isNotEmpty) {
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $token',
      );
    }
    return request;
  }

  @override
  Future<UpdateHttpResponse> get(String url, {String? token}) async {
    final request = await _request(url, token: token);
    final response = await request.close().timeout(_timeout);
    final body = await response.transform(utf8.decoder).join();
    return UpdateHttpResponse(response.statusCode, body);
  }

  @override
  Future<UpdateByteStream> openRead(String url, {String? token}) async {
    final request = await _request(url, token: token);
    final response = await request.close().timeout(_timeout);
    // M4.5：进度条节流在 UpdateService.download 里做（见 pace），这里保持透传。
    return UpdateByteStream(
      statusCode: response.statusCode,
      stream: response,
      contentLength: response.contentLength >= 0
          ? response.contentLength
          : null,
    );
  }
}

/// M2.5 A1：检查更新 + 下载 APK。
class UpdateService {
  UpdateService({UpdateHttpClient? http}) : _http = http ?? IoUpdateHttpClient();

  final UpdateHttpClient _http;

  static const String versionPath = '/api/v1/app/version';
  static const String defaultDownloadPath = '/api/v1/app/apk';
  static const String fileName = 'app-update.apk';

  /// M4.5：进度帧最小间隔与块大小。
  ///
  /// 插件中继跑在本机回环网络上，70 MB 的 APK 几十毫秒就能推完，`onProgress`
  /// 只来得及回调一两次就跳去调安装器，用户看到的就是「进度条不动」。这里把
  /// 收到的字节流按 [progressChunkSize] 分块、每块之间至少等 [progressInterval]，
  /// 让进度条真的走起来；纯内存里的分块/延时，不改文件内容。
  static const Duration progressInterval = Duration(milliseconds: 30);
  static const int progressChunkSize = 256 * 1024;

  /// 按进度帧切分下载流（供测试直接验证，不联网）。
  Stream<List<int>> pace(Stream<List<int>> source) => _paced(source);

  /// {@template update_service_paced}
  /// 切分规则：把每条网络 chunk 切片攒到 [progressChunkSize] 就发出一帧（超长
  /// chunk 会被切成多帧），两帧之间至少间隔 [progressInterval]；不足一块的尾巴
  /// 原样发出。保证任何下载速度下进度条都能走若干帧，而不是一帧跳完。
  /// {@endtemplate}
  Stream<List<int>> _paced(Stream<List<int>> source) async* {
    final pending = BytesBuilder(copy: false);
    var sinceTick = Stopwatch()..start();
    await for (final chunk in source) {
      var offset = 0;
      while (offset < chunk.length) {
        final room = progressChunkSize - pending.length;
        final take =
            chunk.length - offset < room ? chunk.length - offset : room;
        pending.add(chunk.sublist(offset, offset + take));
        offset += take;
        if (pending.length < progressChunkSize) continue;
        final wait = progressInterval - sinceTick.elapsed;
        if (wait > Duration.zero) await Future<void>.delayed(wait);
        yield pending.takeBytes();
        sinceTick = Stopwatch()..start();
      }
    }
    if (pending.isNotEmpty) {
      final wait = progressInterval - sinceTick.elapsed;
      if (wait > Duration.zero) await Future<void>.delayed(wait);
      yield pending.takeBytes();
    }
  }

  /// 检查更新：仅当 `versionCode > currentVersionCode` 时返回信息；
  /// 其它情况（相同/更旧/404/网络错误/JSON 异常）统一返回 null，不抛异常。
  Future<AppUpdateInfo?> check({
    required String baseUrl,
    required int currentVersionCode,
    String? token,
  }) async {
    try {
      final base = PairingApi.normalizeBaseUrl(baseUrl);
      // M4.44：升级包也要走同一条地址策略，公网明文一律不发。
      final check = NetworkUrlPolicy.inspect(base);
      if (!check.allowed) return null;
      final url = PairingApi.resolveEndpoint(base, versionPath).toString();
      final response = await _http.get(url, token: token);
      if (response.statusCode != 200) return null;
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) return null;
      final info = AppUpdateInfo.fromJson(decoded);
      if (info.versionCode <= currentVersionCode) return null;
      return info;
    } catch (_) {
      return null;
    }
  }

  /// 下载 APK 到 `{targetDir}/updates/app-update.apk`：
  /// 先写 `.part`，成功后 rename；按 [AppUpdateInfo.size] 校验完整性。
  ///
  /// M4.29：传了 [cancel] 就能中途停下——每写一帧查一次标记，取消时抛
  /// [UpdateCancelled] 并删掉 `.part`，不留半截文件。
  Future<File> download(
    AppUpdateInfo info, {
    required String baseUrl,
    required Directory targetDir,
    void Function(int received, int total)? onProgress,
    String? token,
    UpdateCancelToken? cancel,
  }) async {
    final base = PairingApi.normalizeBaseUrl(baseUrl);
    // M4.44：公网明文不下载更新包。
    final check = NetworkUrlPolicy.inspect(base);
    if (!check.allowed) {
      throw PairingApiException(check.error ?? '接口地址不被允许', code: 'UNSAFE_URL');
    }
    final updatesDir = Directory(
      '${targetDir.path}${Platform.pathSeparator}updates',
    );
    await updatesDir.create(recursive: true);
    final partFile = File(
      '${updatesDir.path}${Platform.pathSeparator}$fileName.part',
    );
    final targetFile = File(
      '${updatesDir.path}${Platform.pathSeparator}$fileName',
    );
    if (await partFile.exists()) {
      await partFile.delete();
    }
    final path = info.downloadPath.trim().isEmpty
        ? defaultDownloadPath
        : info.downloadPath.trim();
    final url = PairingApi.resolveEndpoint(base, path).toString();

    IOSink? sink;
    var closed = false;
    try {
      final response = await _http.openRead(url, token: token);
      if (response.statusCode != 200) {
        throw UpdateException('下载失败（HTTP ${response.statusCode}）');
      }
      sink = partFile.openWrite();
      var received = 0;
      final total = info.size > 0 ? info.size : (response.contentLength ?? 0);
      await for (final chunk in pace(response.stream)) {
        if (cancel?.isCancelled ?? false) {
          throw const UpdateCancelled();
        }
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      if (cancel?.isCancelled ?? false) {
        throw const UpdateCancelled();
      }
      await sink.flush();
      await sink.close();
      closed = true;
      if (info.size > 0 && received != info.size) {
        await partFile.delete();
        throw UpdateException(
          '下载不完整：$received / ${info.size} 字节，请重试',
        );
      }
      if (await targetFile.exists()) {
        await targetFile.delete();
      }
      return partFile.rename(targetFile.path);
    } on UpdateCancelled {
      // 取消：先把文件句柄关掉再删——Windows 上对着还在写的文件调 delete 会失败，
      // 半截 .part 就留在缓存里了（这里踩过一次）。
      if (!closed && sink != null) {
        try {
          await sink.close();
        } catch (_) {
          // 关不掉也继续尝试删除。
        }
        closed = true;
      }
      try {
        if (await partFile.exists()) {
          await partFile.delete();
        }
      } catch (_) {
        // 清理失败不影响「已取消」这个结论。
      }
      rethrow;
    } on UpdateException {
      rethrow;
    } catch (error) {
      throw UpdateException('下载失败：${PairingApi.describeException(error)}');
    } finally {
      if (!closed && sink != null) {
        try {
          await sink.close();
        } catch (_) {
          // 忽略清理时的二次错误。
        }
      }
    }
  }
}
