import 'dart:io';

import 'package:flutter/material.dart';

import '../app_version.dart';
import '../services/update_download_center.dart';
import '../services/update_gateway.dart';
import '../services/update_service.dart';
import '../theme/app_theme.dart';

/// M2.5 A3：「我的 → 关于 → 检查更新」入口。
///
/// 流程：检查版本 → 弹窗说明 → 下载 APK 到应用缓存 → 校验大小 →
/// 调起系统安装器（用户点一次「更新」）。不做静默安装。
///
/// 依赖都可通过构造函数注入，便于 widget 测试不联网、不碰原生通道。
class UpdateCheckTile extends StatefulWidget {
  const UpdateCheckTile({
    super.key,
    required this.serverUrl,
    required this.token,
    required this.connected,
    this.service,
    this.gateway,
    this.downloads,
    this.currentVersionCode = kAppVersionCode,
    this.currentVersionName = kAppVersionName,
  });

  /// 真实链路的后端地址（未连接时为空/默认值，此时只提示去连接）。
  final String serverUrl;

  final String? token;
  final bool connected;
  final UpdateService? service;
  final UpdateGateway? gateway;

  /// M4.29：下载挂在哪个中心上。默认用全局单例，所以关掉弹窗、离开这一页，
  /// 下载都还在走；测试可以塞一个自己的实例，把假服务接进来。
  final UpdateDownloadCenter? downloads;
  final int currentVersionCode;
  final String currentVersionName;

  @override
  State<UpdateCheckTile> createState() => _UpdateCheckTileState();
}

class _UpdateCheckTileState extends State<UpdateCheckTile> {
  late final UpdateService _service;
  late final UpdateGateway _gateway;
  late final UpdateDownloadCenter _center;

  bool _checking = false;
  bool _progressOpen = false;

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? UpdateService();
    _gateway = widget.gateway ?? MethodChannelUpdateGateway();
    // 传了假 service 就自己建一个中心（测试隔离）；否则挂到全局单例上，
    // 这样这一页被销毁再回来时，下载还在继续。
    _center = widget.downloads ??
        (widget.service == null
            ? UpdateDownloadCenter.instance
            : UpdateDownloadCenter(service: _service));
    _center.addListener(_onCenterChanged);
  }

  @override
  void dispose() {
    // 只摘监听，不取消下载——M4.29 的「后台下载」就是靠这一条成立的。
    _center.removeListener(_onCenterChanged);
    _gateway.dispose();
    super.dispose();
  }

  /// 下载中心的任何变化（进度、取消、失败、下完）都只在这里落地。
  ///
  /// M4.26 的坑也不会再犯：进度弹窗用 `AnimatedBuilder` 直接监听下载中心，
  /// 不再依赖「外层 setState 顺便刷新弹窗」。
  void _onCenterChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _onTap() async {
    if (_checking) return;
    // 下载在后台跑着，点一下是把进度弹窗叫回来，不是重新下一次。
    if (_center.running) {
      _showProgressDialog();
      return;
    }
    // 已经下好了：点这里直接装，不用再下 70 MB。
    final ready = _center.file;
    if (ready != null) {
      await _install(ready);
      return;
    }
    if (!widget.connected || widget.serverUrl.trim().isEmpty) {
      _snack('先连接电脑，再从电脑上的后端检查更新');
      return;
    }
    setState(() => _checking = true);
    final info = await _service.check(
      baseUrl: widget.serverUrl,
      currentVersionCode: widget.currentVersionCode,
      token: widget.token,
    );
    if (!mounted) return;
    setState(() => _checking = false);
    if (info == null) {
      _snack('已是最新版本 v${widget.currentVersionName}');
      return;
    }
    await _showUpdateDialog(info);
  }

  Future<void> _showUpdateDialog(AppUpdateInfo info) async {
    final palette = context.appPalette;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: palette.card,
        title: Text(
          '发现新版本 v${info.versionName}',
          style: TextStyle(
            color: palette.text,
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '当前版本 v${widget.currentVersionName} · 安装包 '
              '${info.sizeMb.toStringAsFixed(1)} MB',
              style: TextStyle(color: palette.text2, fontSize: 12.5),
            ),
            if (info.notes.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                info.notes,
                style: TextStyle(
                  color: palette.text,
                  fontSize: 12.5,
                  height: 1.5,
                ),
              ),
            ],
            const SizedBox(height: 12),
            Text(
              '下载完成后会调起系统安装界面，按提示点一次「更新」即可；'
              'App 数据和配对信息都会保留。',
              style: TextStyle(
                color: palette.text3,
                fontSize: 11.3,
                height: 1.5,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('立即更新'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _downloadAndInstall(info);
    }
  }

  Future<void> _downloadAndInstall(AppUpdateInfo info) async {
    if (_center.running) {
      _showProgressDialog();
      return;
    }
    // 先开下载，再把弹窗挂上去：弹窗只是观察者，关掉它不影响下载。
    final future = _center.start(
      info: info,
      baseUrl: widget.serverUrl,
      token: widget.token,
      cacheDirectory: _gateway.cacheDirectory,
    );
    _showProgressDialog();
    final apk = await future;
    if (!mounted) return;
    _closeProgressDialog();
    if (apk == null) {
      if (_center.cancelled) {
        _snack('已取消下载');
      } else if (_center.error != null) {
        _snack(_center.error!);
      }
      return;
    }
    await _install(apk);
  }

  Future<void> _install(File apk) async {
    try {
      final allowed = await _gateway.canInstallPackages();
      if (!mounted) return;
      if (!allowed) {
        _center.reset();
        await _showInstallPermissionDialog();
        return;
      }
      await _gateway.installApk(apk.path);
      _center.reset();
      _snack('已调起系统安装器，按提示完成更新');
    } on UpdateGatewayException catch (error) {
      _snack(error.message);
    } catch (error) {
      _snack('安装失败：$error');
    }
  }

  /// M4.29：进度弹窗改成「下载中心的观察者」。
  ///
  /// 三个按钮之外没有第四种含义：点「取消下载」才真的停；点「后台继续」、
  /// 点遮罩、按返回键都只是把窗口收起来，下载照跑。所以 [barrierDismissible]
  /// 是 true——收起来不算取消。
  void _showProgressDialog() {
    if (_progressOpen || !mounted) return;
    _progressOpen = true;
    final palette = context.appPalette;
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) {
        return AnimatedBuilder(
          animation: _center,
          builder: (builderContext, _) {
            final info = _center.info;
            final ratio = _center.ratio;
            final receivedMb = _center.received / (1024 * 1024);
            final totalMb = _center.total / (1024 * 1024);
            return AlertDialog(
              backgroundColor: palette.card,
              title: Text(
                '正在下载 v${info?.versionName ?? ''}',
                style: TextStyle(
                  color: palette.text,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                    child: LinearProgressIndicator(
                      value: ratio,
                      minHeight: 6,
                      backgroundColor: palette.lineSoft,
                      color: palette.accent,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    ratio == null
                        ? '下载中…'
                        : '${(ratio * 100).toStringAsFixed(0)}% · '
                            '${receivedMb.toStringAsFixed(1)} / '
                            '${totalMb.toStringAsFixed(1)} MB',
                    style: TextStyle(color: palette.text3, fontSize: 11.5),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '关掉这个窗口不会中断下载：回到「检查更新」点一下还能接着看进度。',
                    style: TextStyle(
                      color: palette.text3,
                      fontSize: 11.3,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    _center.cancel();
                    _dismissProgressDialog(dialogContext);
                  },
                  child: const Text('取消下载'),
                ),
                FilledButton(
                  onPressed: () => _dismissProgressDialog(dialogContext),
                  child: const Text('后台下载'),
                ),
              ],
            );
          },
        );
      },
    ).whenComplete(() {
      // 点遮罩/返回键关窗也走这里：只收窗口，不碰下载。
      _progressOpen = false;
    });
  }

  void _dismissProgressDialog(BuildContext dialogContext) {
    _progressOpen = false;
    Navigator.of(dialogContext).pop();
  }

  void _closeProgressDialog() {
    if (!_progressOpen || !mounted) return;
    _progressOpen = false;
    Navigator.of(context, rootNavigator: true).pop();
  }

  Future<void> _showInstallPermissionDialog() async {
    final palette = context.appPalette;
    final open = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: palette.card,
        title: Text(
          '需要允许安装应用',
          style: TextStyle(
            color: palette.text,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: Text(
          '系统会打开本机的「安装未知应用」设置页，找到 DeepSeek Remote '
          '并允许后，再回来点一次「检查更新」即可。',
          style: TextStyle(
            color: palette.text2,
            fontSize: 12.5,
            height: 1.5,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('去设置'),
          ),
        ],
      ),
    );
    if (open == true) {
      try {
        await _gateway.openInstallSettings();
      } on UpdateGatewayException catch (error) {
        _snack(error.message);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final String subtitle;
    if (_checking) {
      subtitle = '正在检查…';
    } else if (_center.running) {
      final ratio = _center.ratio;
      subtitle = ratio == null
          ? '下载中… · 点开可以看进度或取消'
          : '下载中 ${(ratio * 100).toStringAsFixed(0)}% · 点开可以看进度或取消';
    } else if (_center.file != null) {
      subtitle = '已下载好 v${_center.info?.versionName ?? ''} · 点这里安装';
    } else if (_center.cancelled) {
      subtitle = '已取消下载 · 点一次重新开始';
    } else if (_center.error != null) {
      subtitle = '上次下载失败 · ${_center.error}';
    } else {
      subtitle = '当前版本 v${widget.currentVersionName} · 连接电脑后检查更新';
    }
    return InkWell(
      onTap: _onTap,
      borderRadius: BorderRadius.circular(8),
      child: Row(
        children: [
          Icon(Icons.system_update_alt_rounded, size: 19, color: palette.text2),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '检查更新',
                  style: TextStyle(
                    color: palette.text,
                    fontSize: 13.2,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: palette.text3,
                    fontSize: 11.3,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (_checking || _center.running)
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: palette.accent,
              ),
            )
          else
            Icon(Icons.chevron_right_rounded, size: 18, color: palette.text3),
        ],
      ),
    );
  }
}
