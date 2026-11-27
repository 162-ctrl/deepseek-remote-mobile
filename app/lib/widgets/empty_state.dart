import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// M2.4：未连接时的统一空态。
///
/// 五个 Tab 复用：图标 32 / `text3`、标题 15/600、说明 12.5/`text2`、
/// 主按钮为 accent 胶囊（高 44、左右 24）。垂直位置约屏高 38%。
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    required this.actionLabel,
    required this.onAction,
  });

  final IconData icon;
  final String title;
  final String description;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Align(
      alignment: const Alignment(0, -0.24),
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: palette.lineSoft,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 28, color: palette.text2),
            ),
            const SizedBox(height: 18),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: palette.text,
                fontSize: 18,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.2,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              description,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: palette.text2,
                fontSize: 13,
                height: 1.6,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: onAction,
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 44),
                padding: const EdgeInsets.symmetric(horizontal: 24),
                shape: const StadiumBorder(),
              ),
              child: Text(actionLabel),
            ),
          ],
        ),
      ),
    );
  }
}
