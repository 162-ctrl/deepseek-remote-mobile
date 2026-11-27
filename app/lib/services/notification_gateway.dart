import 'dart:async';

import 'package:flutter/services.dart';

/// M4.4：通知栏里直接做出的审批决定。
class ApprovalDecisionResult {
  const ApprovalDecisionResult({required this.approvalId, required this.approved});

  final String approvalId;
  final bool approved;
}

/// 通知/前台服务的 Dart 侧抽象。
///
/// 真实实现走 Kotlin 原生桥（零 pub 依赖），单测注入 [FakeNotificationGateway]，
/// 因此通知时机、点击回传等逻辑可以完全不碰平台 channel 地测试。
abstract class NotificationGateway {
  /// 用户点击审批通知回传的 approvalId（热启动路径；冷启动用
  /// [getInitialApprovalId]）。
  Stream<String> get approvalTaps;

  /// M4.4：用户在通知栏直接点「允许 / 拒绝」后回传的决定。
  Stream<ApprovalDecisionResult> get approvalDecisions;

  /// 注册 channel 回调（应在 App 启动时调用一次）。
  Future<void> init();

  /// 冷启动时通知点击携带的 approvalId；没有则返回 null。
  Future<String?> getInitialApprovalId();

  /// 发审批通知（channel `approval_alerts`，tag = approvalId）。
  Future<void> showApproval({
    required String approvalId,
    required String title,
    required String body,
  });

  /// 取消审批通知（审批被解决/超时/断开连接）。
  Future<void> cancelApproval(String approvalId);

  /// 发「已断开与电脑的连接」高优先级通知（被动断开/急停）。
  Future<void> showDisconnected({String? reason});

  /// 清除断开提示通知。
  Future<void> clearDisconnected();

  /// M4.4：发「任务已完成 / 失败 / 取消」通知（channel `task_updates`，
  /// tag = sessionKey）。点击默认打开 App 的「工作区」页。
  Future<void> showTaskUpdate({
    required String sessionKey,
    required String title,
    required String body,
    String status = 'completed',
    String? sessionId,
  });

  /// M4.4：发「等待授权」高优先级通知（channel `approval_alerts`，
  /// tag = notificationId，带「允许 / 拒绝」两个动作按钮）。
  Future<void> showApprovalAction({
    required String notificationId,
    required String approvalId,
    required String title,
    required String body,
  });

  /// M4.4：撤掉任意一条任务类通知（tag 与 id 相同）。
  Future<void> cancelTaskUpdate(String notificationId);

  /// 启动前台服务保活（通知内容「已连接 <deviceName> · DeepSeek Remote」）。
  Future<void> startForegroundService(String deviceName);

  /// 停止前台服务。
  Future<void> stopForegroundService();

  /// Android 13+ 请求 POST_NOTIFICATIONS 运行时权限；拒绝返回 false（降级）。
  Future<bool> requestPermission();

  Future<void> dispose();
}

/// 走 `MethodChannel('deepseek_remote/notifications')` 的 Android 实现。
///
/// 所有调用都静默降级：非 Android 平台 / 测试环境（MissingPluginException）
/// 或原生异常都不会影响连接主流程。
class MethodChannelNotificationGateway implements NotificationGateway {
  MethodChannelNotificationGateway({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  static const String channelName = 'deepseek_remote/notifications';
  static const String approvalTitle = '有一项操作需要授权';

  final MethodChannel _channel;
  final StreamController<String> _taps = StreamController<String>.broadcast();
  final StreamController<ApprovalDecisionResult> _decisions =
      StreamController<ApprovalDecisionResult>.broadcast();
  bool _initialized = false;

  @override
  Stream<String> get approvalTaps => _taps.stream;

  @override
  Stream<ApprovalDecisionResult> get approvalDecisions => _decisions.stream;

  @override
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler((MethodCall call) async {
      final args = call.arguments;
      if (call.method == 'onApprovalTapped') {
        final id = call.arguments;
        if (id is String && id.isNotEmpty && !_taps.isClosed) {
          _taps.add(id);
        }
      } else if (call.method == 'onApprovalDecision' && args is Map) {
        final id = args['approvalId'];
        final approved = args['approved'];
        if (id is String && id.isNotEmpty && approved is bool && !_decisions.isClosed) {
          _decisions.add(ApprovalDecisionResult(approvalId: id, approved: approved));
        }
      }
      return null;
    });
  }

  @override
  Future<String?> getInitialApprovalId() async {
    final id = await _invoke<String>('getInitialApprovalId');
    if (id == null || id.isEmpty) return null;
    return id;
  }

  @override
  Future<void> showApproval({
    required String approvalId,
    required String title,
    required String body,
  }) async {
    await _invoke<bool>('showApproval', <String, Object?>{
      'approvalId': approvalId,
      'title': title,
      'body': body,
    });
  }

  @override
  Future<void> cancelApproval(String approvalId) async {
    await _invoke<bool>('cancelApproval', <String, Object?>{
      'approvalId': approvalId,
    });
  }

  @override
  Future<void> showDisconnected({String? reason}) async {
    await _invoke<bool>('showDisconnected', <String, Object?>{
      'reason': reason ?? '',
    });
  }

  @override
  Future<void> clearDisconnected() async {
    await _invoke<bool>('clearDisconnected');
  }

  @override
  Future<void> showTaskUpdate({
    required String sessionKey,
    required String title,
    required String body,
    String status = 'completed',
    String? sessionId,
  }) async {
    await _invoke<bool>('showTaskUpdate', <String, Object?>{
      'key': sessionKey,
      'title': title,
      'body': body,
      'status': status,
      'sessionId': sessionId ?? '',
    });
  }

  @override
  Future<void> showApprovalAction({
    required String notificationId,
    required String approvalId,
    required String title,
    required String body,
  }) async {
    await _invoke<bool>('showApprovalAction', <String, Object?>{
      'id': notificationId,
      'approvalId': approvalId,
      'title': title,
      'body': body,
    });
  }

  @override
  Future<void> cancelTaskUpdate(String notificationId) async {
    await _invoke<bool>('cancelTaskUpdate', <String, Object?>{
      'id': notificationId,
    });
  }

  @override
  Future<void> startForegroundService(String deviceName) async {
    await _invoke<bool>('startForegroundService', <String, Object?>{
      'deviceName': deviceName,
    });
  }

  @override
  Future<void> stopForegroundService() async {
    await _invoke<bool>('stopForegroundService');
  }

  @override
  Future<bool> requestPermission() async {
    final granted = await _invoke<bool>('requestPermission');
    return granted ?? false;
  }

  @override
  Future<void> dispose() async {
    if (!_taps.isClosed) await _taps.close();
    if (!_decisions.isClosed) await _decisions.close();
  }

  Future<T?> _invoke<T>(String method, [Object? arguments]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    } catch (_) {
      return null;
    }
  }
}

/// 单测用假实现：记录每次调用，并允许手动模拟通知点击。
class FakeNotificationGateway implements NotificationGateway {
  FakeNotificationGateway({
    this.initialApprovalId,
    this.permissionResult = true,
    this.throwOnStartService = false,
  });

  final StreamController<String> _taps = StreamController<String>.broadcast();
  final StreamController<ApprovalDecisionResult> _decisions =
      StreamController<ApprovalDecisionResult>.broadcast();

  /// 冷启动时模拟随 intent 带进来的 approvalId。
  String? initialApprovalId;

  /// 权限请求返回值（false = 用户拒绝，连接应照常工作）。
  bool permissionResult;

  /// 模拟 Android 12+ 后台启动前台服务受限。
  bool throwOnStartService;

  bool initCalled = false;
  bool disposed = false;

  final List<String> permissionRequests = <String>[];
  final List<Map<String, String>> approvalShows = <Map<String, String>>[];
  final List<String> canceledApprovals = <String>[];
  final List<String> foregroundStarts = <String>[];
  final List<String> foregroundStops = <String>[];
  final List<String> disconnectedNotices = <String>[];
  int clearedDisconnected = 0;

  /// M4.4：任务完成/失败通知、等待授权通知与撤回记录。
  final List<Map<String, String>> taskUpdates = <Map<String, String>>[];
  final List<Map<String, String>> approvalActionShows = <Map<String, String>>[];
  final List<String> canceledTaskUpdates = <String>[];

  @override
  Stream<String> get approvalTaps => _taps.stream;

  @override
  Stream<ApprovalDecisionResult> get approvalDecisions => _decisions.stream;

  @override
  Future<void> init() async {
    initCalled = true;
  }

  @override
  Future<String?> getInitialApprovalId() async => initialApprovalId;

  @override
  Future<void> showApproval({
    required String approvalId,
    required String title,
    required String body,
  }) async {
    approvalShows.add(<String, String>{
      'approvalId': approvalId,
      'title': title,
      'body': body,
    });
  }

  @override
  Future<void> cancelApproval(String approvalId) async {
    canceledApprovals.add(approvalId);
  }

  @override
  Future<void> showDisconnected({String? reason}) async {
    disconnectedNotices.add(reason ?? '');
  }

  @override
  Future<void> clearDisconnected() async {
    clearedDisconnected += 1;
  }

  @override
  Future<void> showTaskUpdate({
    required String sessionKey,
    required String title,
    required String body,
    String status = 'completed',
    String? sessionId,
  }) async {
    taskUpdates.add(<String, String>{
      'key': sessionKey,
      'title': title,
      'body': body,
      'status': status,
      'sessionId': sessionId ?? '',
    });
  }

  @override
  Future<void> showApprovalAction({
    required String notificationId,
    required String approvalId,
    required String title,
    required String body,
  }) async {
    approvalActionShows.add(<String, String>{
      'id': notificationId,
      'approvalId': approvalId,
      'title': title,
      'body': body,
    });
  }

  @override
  Future<void> cancelTaskUpdate(String notificationId) async {
    canceledTaskUpdates.add(notificationId);
  }

  @override
  Future<void> startForegroundService(String deviceName) async {
    if (throwOnStartService) {
      throw PlatformException(code: 'ForegroundServiceStartNotAllowedException');
    }
    foregroundStarts.add(deviceName);
  }

  @override
  Future<void> stopForegroundService() async {
    foregroundStops.add('stop');
  }

  @override
  Future<bool> requestPermission() async {
    permissionRequests.add('request');
    return permissionResult;
  }

  /// 模拟用户点击审批通知（热启动路径）。
  void emitTap(String approvalId) {
    if (!_taps.isClosed) _taps.add(approvalId);
    // 让监听者有机会在本轮事件循环内处理。
  }

  /// M4.4：模拟用户在通知栏直接点「允许 / 拒绝」。
  void emitDecision(String approvalId, {required bool approved}) {
    if (!_decisions.isClosed) {
      _decisions.add(
        ApprovalDecisionResult(approvalId: approvalId, approved: approved),
      );
    }
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    if (!_taps.isClosed) await _taps.close();
    if (!_decisions.isClosed) await _decisions.close();
  }
}
