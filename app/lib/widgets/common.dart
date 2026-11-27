import 'package:flutter/material.dart';

import '../data/live_store.dart';
import '../models.dart';
import '../theme/app_theme.dart';

class DeviceStatusChip extends StatelessWidget {
  const DeviceStatusChip({super.key, required this.online, this.label});

  final bool online;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final color = online ? palette.success : palette.text3;
    return Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 9),
      decoration: BoxDecoration(
        color: color.withValues(alpha: palette.isDark ? 0.18 : 0.12),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(
            label ?? (online ? '电脑在线' : '电脑离线'),
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class TaskStatusBadge extends StatelessWidget {
  const TaskStatusBadge({super.key, required this.status});

  final TaskStatus status;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final color = switch (status) {
      TaskStatus.queued => palette.text3,
      TaskStatus.running => palette.accent,
      TaskStatus.waitingApproval => palette.warn,
      TaskStatus.paused => palette.warn,
      TaskStatus.completed => palette.success,
      TaskStatus.failed => palette.danger,
      TaskStatus.cancelled => palette.text3,
    };
    return Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 9),
      decoration: BoxDecoration(
        color: color.withValues(alpha: palette.isDark ? 0.18 : 0.12),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(status.icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            status.label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, AppSpace.sectionTop, 2, AppSpace.sectionBottom),
      child: Row(
        children: [
          Text(
            text,
            style: TextStyle(
              color: palette.text,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
            ),
          ),
          const Spacer(),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// 标准卡片（§3.3）：card 底 + 1px line 描边 + 20 圆角 + 极淡阴影。
class Panel extends StatelessWidget {
  const Panel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpace.card),
    this.color,
    this.borderColor,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? palette.card,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: borderColor ?? palette.line),
        boxShadow: palette.cardShadow,
      ),
      child: child,
    );
  }
}

class InfoRow extends StatelessWidget {
  const InfoRow(this.label, this.value, {super.key, this.valueColor});

  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 84,
            child: Text(
              label,
              style: TextStyle(color: palette.text3, fontSize: 12.5),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: valueColor ?? palette.text,
                fontSize: 12.5,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class MonoText extends StatelessWidget {
  const MonoText(this.text, {super.key, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: kMono.copyWith(color: color ?? context.appPalette.text2),
    );
  }
}

class EmptyHint extends StatelessWidget {
  const EmptyHint({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 20),
      child: Column(
        children: [
          Icon(icon, size: 40, color: palette.text3),
          const SizedBox(height: 12),
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(color: palette.text3, fontSize: 12.5, height: 1.5),
          ),
        ],
      ),
    );
  }
}

/// 简化版「滑动停止」：拖动滑块到右侧触发。
class SlideToStop extends StatefulWidget {
  const SlideToStop({super.key, required this.onStop, this.enabled = true});

  final VoidCallback onStop;
  final bool enabled;

  @override
  State<SlideToStop> createState() => _SlideToStopState();
}

class _SlideToStopState extends State<SlideToStop> {
  double _drag = 0;

  static const double _height = 52;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      final maxDrag = width - _height - 8;
      return Container(
        height: _height,
        decoration: BoxDecoration(
          color: widget.enabled ? palette.dangerSoft : palette.lineSoft,
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.pill),
          child: Stack(
            children: [
              Center(
                child: Text(
                  widget.enabled ? '滑动紧急停止  ⟶' : '设备已停止',
                  style: TextStyle(
                    color: widget.enabled ? palette.danger : palette.text3,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1,
                  ),
                ),
              ),
              AnimatedPositioned(
                duration: const Duration(milliseconds: 120),
                left: 4 + _drag,
                top: 4,
                child: GestureDetector(
                  onHorizontalDragUpdate: widget.enabled
                      ? (details) {
                          setState(() {
                            _drag =
                                (_drag + details.delta.dx).clamp(0.0, maxDrag);
                          });
                        }
                      : null,
                  onHorizontalDragEnd: widget.enabled
                      ? (_) {
                          if (_drag > maxDrag * 0.72) {
                            widget.onStop();
                          }
                          setState(() => _drag = 0);
                        }
                      : null,
                  child: Container(
                    height: _height - 8,
                    width: _height - 8,
                    decoration: BoxDecoration(
                      color: widget.enabled
                          ? palette.danger
                          : palette.text3,
                      shape: BoxShape.circle,
                      boxShadow: widget.enabled
                          ? [
                              BoxShadow(
                                color: palette.danger.withValues(alpha: 0.35),
                                blurRadius: 12,
                              )
                            ]
                          : null,
                    ),
                    child: const Icon(
                      Icons.power_settings_new_rounded,
                      color: Colors.white,
                      size: 22,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    });
  }
}

/// 底部危险操作确认。
Future<bool> confirmDanger(
    BuildContext context, String title, String message) async {
  final palette = context.appPalette;
  final result = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: palette.card,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: palette.danger),
                const SizedBox(width: 8),
                Text(title,
                    style: TextStyle(
                        color: palette.text,
                        fontSize: 16,
                        fontWeight: FontWeight.w700)),
              ],
            ),
            const SizedBox(height: 10),
            Text(message,
                style: TextStyle(
                    color: palette.text2, fontSize: 13, height: 1.5)),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('取消'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    style: FilledButton.styleFrom(
                      backgroundColor: palette.danger,
                    ),
                    child: const Text('确认停止'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
  return result ?? false;
}

/// 真实连接（LiveStore）作用域：连接状态变化时重建依赖它的组件。
class LiveScope extends InheritedNotifier<LiveStore> {
  const LiveScope({
    super.key,
    required LiveStore store,
    required super.child,
  }) : super(notifier: store);

  static LiveStore of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<LiveScope>();
    assert(scope != null, 'LiveScope 未挂载');
    return scope!.notifier!;
  }

  static LiveStore? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LiveScope>()?.notifier;
}

/// M2.9：Kimi 风格的抽屉入口（各页 AppBar 左上角）。
///
/// 未传 [onPressed] 时不渲染，便于测试或嵌入式页面复用。
class DrawerMenuButton extends StatelessWidget {
  const DrawerMenuButton({super.key, this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Padding(
      padding: const EdgeInsets.only(left: 16),
      child: Tooltip(
        message: '打开菜单',
        child: Material(
          color: palette.card,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            side: BorderSide(color: palette.line),
          ),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: SizedBox(
              width: 40,
              height: 40,
              child: Icon(Icons.menu_rounded, size: 20, color: palette.text),
            ),
          ),
        ),
      ),
    );
  }
}

/// M2.9：Kimi 风格的二级页顶栏。
///
/// 白底、无阴影、无分割线；左侧圆形菜单（或自定义 leading），标题 26/w700。
class KimiAppBar extends StatelessWidget implements PreferredSizeWidget {
  const KimiAppBar({
    super.key,
    required this.title,
    this.onOpenMenu,
    this.actions = const <Widget>[],
    this.leading,
    this.automaticallyImplyLeading = false,
  });

  final String title;
  final VoidCallback? onOpenMenu;
  final List<Widget> actions;
  final Widget? leading;
  final bool automaticallyImplyLeading;

  @override
  Size get preferredSize => const Size.fromHeight(64);

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return AppBar(
      backgroundColor: palette.bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      toolbarHeight: 64,
      automaticallyImplyLeading: automaticallyImplyLeading,
      leadingWidth: leading == null ? 64 : 56,
      leading:
          leading ??
          (onOpenMenu == null
              ? null
              : DrawerMenuButton(onPressed: onOpenMenu)),
      titleSpacing: leading == null ? 12 : 0,
      title: Text(
        title,
        style: TextStyle(
          color: palette.text,
          fontSize: 26,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.4,
        ),
      ),
      actions: [...actions, const SizedBox(width: 8)],
    );
  }
}
