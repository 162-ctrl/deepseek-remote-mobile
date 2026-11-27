import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../services/pairing_link.dart';
import '../theme/app_theme.dart';

/// 扫码连接页（M2.7）：对准电脑端 `dsh-plugin-m1` 配网页上的二维码，
/// 扫到「地址 + 匹配码」后自动返回给连接页回填。
///
/// 返回 [PairingLink]；用户取消返回 null。相机不可用/无权限时也允许退回手输。
class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key});

  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> {
  late final MobileScannerController _controller;
  bool _handled = false;
  bool _torchOn = false;
  bool _picking = false;
  String? _hint;
  String? _fatal;

  @override
  void initState() {
    super.initState();
    _controller = MobileScannerController(
      detectionSpeed: DetectionSpeed.noDuplicates,
      facing: CameraFacing.back,
      torchEnabled: false,
      formats: const [BarcodeFormat.qrCode],
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    if (_tryBarcodes(capture.barcodes)) return;
    if (!mounted) return;
    setState(() {
      _hint = _lastScannedText.isEmpty
          ? '没有识别到内容，靠近一点再试一次'
          : '这不是配对二维码：${_short(_lastScannedText)}';
    });
  }

  String _lastScannedText = '';

  /// 从一组条码里找配对链接；找到就消费掉并返回 true。
  bool _tryBarcodes(Iterable<Barcode> barcodes) {
    for (final barcode in barcodes) {
      final raw = barcode.rawValue;
      if (raw == null || raw.trim().isEmpty) continue;
      _lastScannedText = raw;
      final link = PairingLink.tryParse(raw);
      if (link != null) {
        _accept(link);
        return true;
      }
    }
    return false;
  }

  /// 从相册选一张二维码图片来识别（手机相机不好对焦时用）。
  Future<void> _pickFromGallery() async {
    if (_picking || _handled) return;
    setState(() {
      _picking = true;
      _hint = null;
    });
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 2400,
      );
      if (picked == null) {
        if (mounted) setState(() => _picking = false);
        return;
      }
      BarcodeCapture? capture;
      try {
        capture = await _controller.analyzeImage(picked.path);
      } catch (_) {
        capture = null;
      }
      if (!mounted) return;
      if (capture != null && _tryBarcodes(capture.barcodes)) {
        return;
      }
      setState(() {
        _picking = false;
        _hint = '这张图片里没有识别到配对二维码，换一张试试。';
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _picking = false;
          _hint = '打开相册失败：$error';
        });
      }
    }
  }

  String _short(String value) {
    final text = value.trim().replaceAll('\n', ' ');
    return text.length <= 42 ? text : '${text.substring(0, 42)}…';
  }

  Future<void> _accept(PairingLink link) async {
    if (_handled) return;
    _handled = true;
    HapticFeedback.mediumImpact();
    try {
      await _controller.stop();
    } catch (_) {
      // 相机已经停了也不影响返回。
    }
    if (mounted) {
      Navigator.of(context).pop(link);
    }
  }

  Future<void> _toggleTorch() async {
    try {
      await _controller.toggleTorch();
      if (mounted) setState(() => _torchOn = !_torchOn);
    } catch (error) {
      if (mounted) setState(() => _hint = '这台手机没有可用的补光灯');
    }
  }

  Future<void> _restart() async {
    try {
      await _controller.start();
      if (mounted) setState(() => _fatal = null);
    } catch (error) {
      if (mounted) setState(() => _fatal = '相机启动失败：$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (_fatal == null)
            MobileScanner(
              controller: _controller,
              onDetect: _onDetect,
              fit: BoxFit.cover,
              errorBuilder: (context, error) {
                return _cameraError(error);
              },
            )
          else
            _cameraErrorText(_fatal!),
          if (_fatal == null)
            IgnorePointer(
              child: CustomPaint(painter: _ScannerMaskPainter(palette.accent)),
            ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(
                children: [
                  Row(
                    children: [
                      _RoundIconButton(
                        icon: Icons.close_rounded,
                        tooltip: '取消',
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                      const Spacer(),
                      if (_fatal == null)
                        _RoundIconButton(
                          icon: _torchOn
                              ? Icons.flashlight_on_rounded
                              : Icons.flashlight_off_rounded,
                          tooltip: _torchOn ? '关闭补光' : '打开补光',
                          onPressed: _toggleTorch,
                        ),
                    ],
                  ),
                  const Spacer(),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
                    decoration: BoxDecoration(
                      color: palette.card.withValues(alpha: 0.92),
                      borderRadius: BorderRadius.circular(AppRadius.card),
                      border: Border.all(color: palette.line),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '扫描电脑上的二维码',
                          style: TextStyle(
                            color: palette.text,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          _hint ?? '电脑浏览器打开 http://<电脑IP>:8787 ，对着「手机端直连」卡片扫一下，地址和匹配码会自动填好。',
                          style: TextStyle(
                            color: _hint == null ? palette.text2 : palette.warn,
                            fontSize: 12,
                            height: 1.6,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            TextButton(
                              onPressed: () => Navigator.of(context).pop(),
                              style: TextButton.styleFrom(
                                minimumSize: const Size(0, 34),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              child: const Text(
                                '手动输入',
                                style: TextStyle(fontSize: 12),
                              ),
                            ),
                            const SizedBox(width: 2),
                            TextButton.icon(
                              onPressed: _picking ? null : _pickFromGallery,
                              style: TextButton.styleFrom(
                                minimumSize: const Size(0, 34),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              icon: _picking
                                  ? const SizedBox(
                                      width: 13,
                                      height: 13,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 1.8,
                                      ),
                                    )
                                  : const Icon(
                                      Icons.photo_library_outlined,
                                      size: 15,
                                    ),
                              label: const Text(
                                '从相册选择',
                                style: TextStyle(fontSize: 12),
                              ),
                            ),
                            const Spacer(),
                            Text(
                              '二维码里有地址 + 匹配码',
                              style: TextStyle(
                                color: palette.text3,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _cameraError(MobileScannerException error) {
    final text = switch (error.errorCode) {
      MobileScannerErrorCode.permissionDenied =>
        '没有相机权限。到系统设置里允许这台手机使用相机，或者直接手输地址和匹配码。',
      MobileScannerErrorCode.unsupported =>
        '这台设备不支持扫码，请用手输地址和匹配码连接。',
      _ => '相机打不开：${error.errorDetails?.message ?? error.errorCode.name}',
    };
    return _cameraErrorText(text);
  }

  Widget _cameraErrorText(String text) {
    final palette = context.appPalette;
    return Container(
      color: palette.bg,
      padding: const EdgeInsets.all(28),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.no_photography_rounded, size: 34, color: palette.text3),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(color: palette.text2, fontSize: 13, height: 1.7),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('手动输入'),
                ),
                const SizedBox(width: 10),
                OutlinedButton.icon(
                  onPressed: _picking ? null : _pickFromGallery,
                  icon: const Icon(Icons.photo_library_outlined, size: 16),
                  label: const Text('从相册选择'),
                ),
                const SizedBox(width: 10),
                FilledButton(
                  onPressed: _restart,
                  child: const Text('重试'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.black.withValues(alpha: 0.42),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.all(9),
            child: Icon(icon, size: 21, color: Colors.white),
          ),
        ),
      ),
    );
  }
}

/// 取景框：整屏压暗 + 中间挖一个圆角方块 + 四角高亮。
class _ScannerMaskPainter extends CustomPainter {
  const _ScannerMaskPainter(this.accent);

  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.shortestSide * 0.66;
    final hole = Rect.fromCenter(
      center: Offset(size.width / 2, size.height * 0.44),
      width: side,
      height: side,
    );
    final rrect = RRect.fromRectAndRadius(
      hole,
      const Radius.circular(AppRadius.card),
    );

    final dim = Path.combine(
      PathOperation.difference,
      Path()..addRect(Offset.zero & size),
      Path()..addRRect(rrect),
    );
    canvas.drawPath(dim, Paint()..color = Colors.black.withValues(alpha: 0.55));

    final border = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..color = Colors.white.withValues(alpha: 0.28);
    canvas.drawRRect(rrect, border);

    // 四角加粗的 L 形准星。
    final corner = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.4
      ..strokeCap = StrokeCap.round
      ..color = accent;
    const len = 26.0;
    final r = Radius.circular(AppRadius.card - 4);
    final path = Path()
      ..moveTo(hole.left, hole.top + len)
      ..lineTo(hole.left, hole.top + r.y)
      ..arcToPoint(Offset(hole.left + r.x, hole.top), radius: r, clockwise: true)
      ..lineTo(hole.left + len, hole.top)
      ..moveTo(hole.right - len, hole.top)
      ..lineTo(hole.right - r.x, hole.top)
      ..arcToPoint(Offset(hole.right, hole.top + r.y), radius: r, clockwise: true)
      ..lineTo(hole.right, hole.top + len)
      ..moveTo(hole.right, hole.bottom - len)
      ..lineTo(hole.right, hole.bottom - r.y)
      ..arcToPoint(
        Offset(hole.right - r.x, hole.bottom),
        radius: r,
        clockwise: true,
      )
      ..lineTo(hole.right - len, hole.bottom)
      ..moveTo(hole.left + len, hole.bottom)
      ..lineTo(hole.left + r.x, hole.bottom)
      ..arcToPoint(
        Offset(hole.left, hole.bottom - r.y),
        radius: r,
        clockwise: true,
      )
      ..lineTo(hole.left, hole.bottom - len);
    canvas.drawPath(path, corner);
  }

  @override
  bool shouldRepaint(_ScannerMaskPainter oldDelegate) =>
      oldDelegate.accent != accent;
}
