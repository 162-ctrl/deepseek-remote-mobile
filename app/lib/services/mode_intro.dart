import 'settings_gateway.dart';

/// M4.48：档位说明只提示一次。
///
/// 第二阶段第 ⑨ 条把「手机 / 电脑」改成「本机对话 / 远程电脑」——名字换了，
/// 但两个档位的能力差别（要不要 API Key、能不能读写电脑文件、能不能执行
/// 任务）第一次用的人还是不知道。所以第一次切换时在输入框上面挂一条说明，
/// 点「知道了」或关掉就记住，之后不再打扰。
/// M4.48：说明横幅的文案。页面与测试共用同一份，改名时只改这里。
abstract final class ModeIntroCopy {
  static const String title = '两种对话，能力不一样';

  /// 本机对话：用自己的 Key、只碰手机本地文件。
  static const String local =
      '本机对话：用自己的 API Key 直连云端，不经过电脑，只能处理手机里的文件。';

  /// 远程电脑：连着电脑才能读写工作区 / 跑任务，危险操作要授权。
  static const String remote =
      '远程电脑：连上电脑后能读写工作区、跑任务；危险操作会先问你。';

  static const String dismiss = '知道了';
}

class ModeIntroPrefs {
  ModeIntroPrefs({SettingsGateway? gateway}) : _gateway = gateway;

  /// 已经看过的构造方式（测试或「从不提示」场景）。
  ModeIntroPrefs.seen({SettingsGateway? gateway})
      : _gateway = gateway,
        _seen = true;

  static const String key = 'mode_intro_seen_v1';

  final SettingsGateway? _gateway;
  bool _seen = false;

  bool get seen => _seen;

  Future<void> load() async {
    final value = await _gateway?.getString(key);
    _seen = value == '1';
  }

  Future<void> markSeen() async {
    if (_seen) return;
    _seen = true;
    await _gateway?.setString(key, '1');
  }
}
