import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// M4.44：授权弹层的三种结果。
///
/// 以前只有 `approved / rejected / expired`，而且「下滑关闭」被当成拒绝——
/// 用户只是想先看一眼、或者手滑，电脑那头就被判死刑了。现在下滑、返回、
/// 超时都只产生 [later]（暂缓，不发送任何决定），真正的拒绝必须点红色按钮。
enum ApprovalDecision { approved, denied, later }

/// 高风险授权 Bottom Sheet（§3.11）：先展示原始参数，再让你决定。
class ApprovalSheet extends StatefulWidget {
  const ApprovalSheet({
    super.key,
    required this.tool,
    required this.command,
    required this.deviceName,
    required this.workspace,
    this.timeout = const Duration(minutes: 10),
  });

  final String tool;
  final String command;
  final String deviceName;
  final String workspace;
  final Duration timeout;

  @override
  State<ApprovalSheet> createState() => _ApprovalSheetState();
}

class _ApprovalSheetState extends State<ApprovalSheet> {
  Duration _remaining = const Duration(minutes: 10);
  Timer? _timer;
  bool _decided = false;

  @override
  void initState() {
    super.initState();
    _remaining = widget.timeout;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _decided) return;
      final next = _remaining - const Duration(seconds: 1);
      if (next.inSeconds <= 0) {
        _decided = true;
        _timer?.cancel();
        setState(() => _remaining = Duration.zero);
        // M4.44：超时只是「收起」，不替用户拒绝；pop 必须在 setState 之外。
        Navigator.of(context).pop(ApprovalDecision.later);
        return;
      }
      setState(() => _remaining = next);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _decide(ApprovalDecision decision) {
    if (_decided) return;
    _decided = true;
    _timer?.cancel();
    Navigator.of(context).pop(decision);
  }

  String get _countdown {
    final m = _remaining.inMinutes;
    final s = _remaining.inSeconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return SafeArea(
      // M4.44：小屏 / 大字号下这张卡会顶满屏幕甚至溢出（内容比屏幕高 38px
      // 就会触发 RenderFlex 断言）。封顶 + 可滚动，正常手机上滚不动、样子不变。
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.92,
        ),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: palette.lineSoft,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Container(
                  height: 22,
                  padding: const EdgeInsets.symmetric(horizontal: 9),
                  decoration: BoxDecoration(
                    color: palette.warnSoft,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.local_fire_department_rounded,
                        size: 13,
                        color: palette.warn,
                      ),
                      const SizedBox(width: 3),
                      Text(
                        '高风险 · 6 级权限',
                        style: TextStyle(
                          color: palette.warn,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                Row(
                  children: [
                    Icon(
                      Icons.timer_outlined,
                      size: 13,
                      color: palette.text3,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '$_countdown 后收起，可稍后再答',
                      style: TextStyle(color: palette.text3, fontSize: 11),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              '有一项操作需要你的授权',
              style: TextStyle(
                color: palette.text,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '${widget.deviceName} 上的 DeepSeek Harness 请求执行以下命令。'
              '允许后只执行这一次；拒绝后任务会停止，不会显示为失败。',
              style: TextStyle(
                color: palette.text2,
                fontSize: 12.5,
                height: 1.6,
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: palette.card,
                borderRadius: BorderRadius.circular(AppRadius.card),
                border: Border.all(color: palette.line),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.terminal_rounded,
                        size: 14,
                        color: palette.accent,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        widget.tool,
                        style: TextStyle(
                          color: palette.text,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        '一次性授权',
                        style: TextStyle(color: palette.text3, fontSize: 10.5),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: palette.codeBg,
                      borderRadius: BorderRadius.circular(AppRadius.code),
                    ),
                    child: Text(
                      widget.command,
                      style: kMono.copyWith(color: palette.codeText),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Icon(
                        Icons.folder_outlined,
                        size: 13,
                        color: palette.text3,
                      ),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          widget.workspace,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: kMono.copyWith(
                            fontSize: 10.5,
                            color: palette.text3,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _decide(ApprovalDecision.denied),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: palette.danger,
                      side: BorderSide(color: palette.line),
                    ),
                    child: const Text('拒绝本次操作'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: FilledButton.icon(
                    onPressed: () => _decide(ApprovalDecision.approved),
                    icon: const Icon(Icons.check_rounded, size: 18),
                    label: const Text('允许一次'),
                  ),
                ),
              ],
            ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
