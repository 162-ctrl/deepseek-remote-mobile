import 'settings_gateway.dart';

/// M4.4：通知偏好（存在手机本地 SharedPreferences，走 [SettingsGateway]）。
///
/// 只影响「手机端发不发系统通知」，不影响审批本身的拦截；
/// 用户关掉后电脑端的任务照常运行。
class NotificationPrefs {
  NotificationPrefs({SettingsGateway? gateway, this.defaultEnabled = true})
      : _gateway = gateway;

  static const String taskDoneKey = 'notify_task_done';
  static const String approvalKey = 'notify_approval_action';

  final SettingsGateway? _gateway;

  /// 读不到设置时的默认值（首次使用默认开启）。
  final bool defaultEnabled;

  bool _taskDone = true;
  bool _approvalAction = true;
  bool _loaded = false;

  /// 连上电脑后是否在后台提醒「任务做完 / 失败」。
  bool get taskDone => _taskDone;

  /// 是否发「等待授权」通知（可操作：通知栏直接允许/拒绝）。
  bool get approvalAction => _approvalAction;

  bool get loaded => _loaded;

  /// 从手机本地读取；没有原生实现（测试/桌面）时用默认值。
  Future<void> load() async {
    final gateway = _gateway;
    if (gateway != null) {
      final done = await gateway.getString(taskDoneKey);
      final approval = await gateway.getString(approvalKey);
      _taskDone = done == null ? defaultEnabled : done == '1';
      _approvalAction = approval == null ? defaultEnabled : approval == '1';
    }
    _loaded = true;
  }

  Future<void> setTaskDone(bool value) async {
    _taskDone = value;
    await _gateway?.setString(taskDoneKey, value ? '1' : '0');
  }

  Future<void> setApprovalAction(bool value) async {
    _approvalAction = value;
    await _gateway?.setString(approvalKey, value ? '1' : '0');
  }
}
