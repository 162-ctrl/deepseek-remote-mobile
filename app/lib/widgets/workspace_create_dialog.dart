import 'package:flutter/material.dart';

import '../data/live_store.dart';
import '../services/history_api.dart';
import '../services/pairing_api.dart';
import '../theme/app_theme.dart';

/// M4.0：弹「新建工作区」对话框；成功返回新建出来的目录，取消返回 null。
///
/// M4.13：新项目固定建在「项目根」下（[kDefaultProjectParent]，本机是
/// `D:\Projects\项目`），不再碰运气落到授权根的第一个。电脑端会校验这个父目录
/// 是不是授权根下的目录；旧版插件不认 `parentDir` 时会退回第一个授权根。
///
/// 电脑端会把非法字符 `\/:*?"<>|` 换成 `-`；旧版电脑端没有这个接口时给出
/// 「升级电脑端插件」的提示而不是原始错误码。
Future<DesktopWorkspaceCreated?> showWorkspaceCreateDialog(
  BuildContext context, {
  required LiveStore liveStore,
}) {
  return showDialog<DesktopWorkspaceCreated>(
    context: context,
    builder: (_) => _WorkspaceCreateDialog(liveStore: liveStore),
  );
}

/// M4.13：手机端新建项目的默认父目录（与插件里的 `DEFAULT_PROJECT_PARENT` 一致）。
const String kDefaultProjectParent = r'D:\Projects\项目';

/// 电脑端清理规则的前置预览：只做展示，真正清理交给电脑端。
String previewWorkspaceFolderName(String input) {
  return input.trim().replaceAll(RegExp(r'[\\/:*?"<>|]+'), '-');
}

class _WorkspaceCreateDialog extends StatefulWidget {
  const _WorkspaceCreateDialog({required this.liveStore});

  final LiveStore liveStore;

  @override
  State<_WorkspaceCreateDialog> createState() => _WorkspaceCreateDialogState();
}

class _WorkspaceCreateDialogState extends State<_WorkspaceCreateDialog> {
  final TextEditingController _controller = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
  }

  void _onChanged() => setState(() {});

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    super.dispose();
  }

  String get _preview => previewWorkspaceFolderName(_controller.text);

  /// M4.15：新项目**永远**建在 [kDefaultProjectParent] 下。
  ///
  /// M4.13 曾用「授权根里有没有这个目录」来决定 `parentDir`，可电脑端返回的
  /// 授权根是**项目本身**（`…\项目\deepseek手机端`、`…\项目\示例项目D`），
  /// `…\项目` 从来不在里面 —— 于是每次都判成「没授权」，退回第一个授权根，
  /// 用户看到「将建在：D:\Projects\课程\上册\计算方法实验」。插件侧
  /// `resolveParentDir()` 本来就允许「显式指定且目录真实存在」，直接指名即可。
  String get _targetParent =>
      kDefaultProjectParent.endsWith(r'\')
          ? kDefaultProjectParent.substring(0, kDefaultProjectParent.length - 1)
          : kDefaultProjectParent;

  Future<void> _submit() async {
    final name = _controller.text.trim();
    if (name.isEmpty || _submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final created = await widget.liveStore.createDesktopWorkspace(
        name,
        parentDir: _targetParent,
      );
      if (!mounted) return;
      Navigator.of(context).pop(created);
    } on PairingApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = _friendlyMessage(error);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = '新建工作区失败：$error';
      });
    }
  }

  String _friendlyMessage(PairingApiException error) {
    if (error.statusCode == 404) {
      return '电脑端插件版本过低，还不能新建工作区；升级插件后重试。';
    }
    return error.message;
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final canSubmit = _preview.isNotEmpty && !_submitting;
    return AlertDialog(
      backgroundColor: palette.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      title: Text(
        '新建项目',
        style: TextStyle(color: palette.text, fontSize: 18, fontWeight: FontWeight.w700),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            enabled: !_submitting,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
            decoration: const InputDecoration(
              labelText: '项目名称',
              hintText: '例如 新项目',
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '将建在：$_targetParent\\$_preview',
            style: TextStyle(color: palette.text3, fontSize: 11.5, height: 1.5),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(
              _error!,
              style: TextStyle(color: palette.danger, fontSize: 12, height: 1.4),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: canSubmit ? _submit : null,
          child: _submitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('创建'),
        ),
      ],
    );
  }
}
