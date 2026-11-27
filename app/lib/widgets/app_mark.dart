import 'package:flutter/material.dart';

/// M2.9：Kimi 风格的品牌标记——蓝色渐变圆 + 两只白眼睛。
///
/// 用在对话页空态中央和侧边抽屉头部；纯绘制，不依赖图片资源。
class AppMark extends StatelessWidget {
  const AppMark({super.key, this.size = 54, this.withShadow = true});

  final double size;
  final bool withShadow;

  @override
  Widget build(BuildContext context) {
    final eyeWidth = size * 0.115;
    final eyeHeight = eyeWidth * 1.7;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[Color(0xFF7F9DFF), Color(0xFF3A59FF)],
        ),
        boxShadow: withShadow
            ? const <BoxShadow>[
                BoxShadow(
                  color: Color(0x334C5CFF),
                  blurRadius: 26,
                  offset: Offset(0, 12),
                ),
              ]
            : null,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          _Eye(width: eyeWidth, height: eyeHeight),
          SizedBox(width: size * 0.135),
          _Eye(width: eyeWidth, height: eyeHeight),
        ],
      ),
    );
  }
}

class _Eye extends StatelessWidget {
  const _Eye({required this.width, required this.height});

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(width),
      ),
    );
  }
}
