import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../services/url_opener.dart';
import '../theme/app_theme.dart';

/// M4.67：App 内嵌的官方充值页。
///
/// 电脑端 DSH 的「充值」其实也是把 `platform.deepseek.com` 的网页嵌进自己的窗口
/// （`dsh-client-ui-settings-account` 里 `showPage(openPlatformPage, 'top-up')`），
/// 所以手机这边做同一件事：用 WebView 打开官方页，登录一次之后就能在 App 里付款。
///
/// 付款仍然发生在官方域名里，App 只提供窗口，不接触卡号、验证码和支付凭据；
/// 遇到 `alipays://` / `weixin://` 这类协议时交给系统，能装客户端的就用客户端付。
class RechargeWebScreen extends StatefulWidget {
  const RechargeWebScreen({
    super.key,
    required this.url,
    this.urlOpener,
    this.webViewBuilder,
  });

  /// 官方充值页地址（`kBalanceRechargeUrl`）。
  final String url;

  /// 把 `alipays://` 之类的协议交给系统应用；测试里注入假实现。
  final UrlOpener? urlOpener;

  /// 测试用：Widget 测试里没有原生 WebView，注入一个占位组件代替。
  final Widget Function(BuildContext context, String url)? webViewBuilder;

  @override
  State<RechargeWebScreen> createState() => _RechargeWebScreenState();
}

class _RechargeWebScreenState extends State<RechargeWebScreen> {
  WebViewController? _controller;
  late final UrlOpener _urlOpener = widget.urlOpener ?? MethodChannelUrlOpener();
  int _progress = 0;
  bool _loading = true;
  String? _error;
  final String _title = '官方充值页';

  @override
  void initState() {
    super.initState();
    if (widget.webViewBuilder == null) {
      _controller = _buildController();
    }
  }

  WebViewController _buildController() {
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFFFFFFF))
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (value) {
            if (!mounted) return;
            setState(() => _progress = value);
          },
          onPageStarted: (url) {
            if (!mounted) return;
            setState(() {
              _loading = true;
              _error = null;
            });
          },
          onPageFinished: (url) {
            if (!mounted) return;
            setState(() => _loading = false);
          },
          onWebResourceError: (error) {
            // 只是子资源失败时不整页报错，避免支付页被一条广告脚本打断。
            if (!error.isForMainFrame.orTrue) return;
            if (!mounted) return;
            setState(() {
              _loading = false;
              _error = '官方页面打不开：${error.description}（${error.errorCode}）';
            });
          },
          onNavigationRequest: (request) {
            final url = request.url;
            if (url.startsWith('http://') || url.startsWith('https://')) {
              return NavigationDecision.navigate;
            }
            _openExternalScheme(url);
            return NavigationDecision.prevent;
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.url));
    return controller;
  }

  Future<void> _openExternalScheme(String url) async {
    // 支付宝 / 微信客户端协议：WebView 自己处理不了，交给系统应用。
    await _urlOpener.open(url);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        Navigator.of(context).pop(true);
      },
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: palette.bg,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          toolbarHeight: 64,
          titleSpacing: 0,
          leading: IconButton(
            tooltip: '回到充值页',
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.arrow_back_rounded, size: 20),
          ),
          title: Text(
            _title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: palette.text,
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
          actions: [
            IconButton(
              tooltip: '刷新',
              onPressed: () => _controller?.reload(),
              icon: const Icon(Icons.refresh_rounded, size: 20),
            ),
          ],
        ),
        body: Column(
          children: [
            if (_loading && _progress < 100)
              SizedBox(
                height: 2,
                child: LinearProgressIndicator(
                  // 一律用确定值：不确定进度条会一直转，页面没法「稳定」下来。
                  value: (_progress / 100).clamp(0.04, 1.0),
                  minHeight: 2,
                  backgroundColor: palette.lineSoft,
                  color: palette.accent,
                ),
              ),
            Expanded(child: _buildBody(palette)),
            _FooterBar(palette: palette, onDone: () => Navigator.of(context).pop(true)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(AppPalette palette) {
    final builder = widget.webViewBuilder;
    if (builder != null) {
      return builder(context, widget.url);
    }
    final error = _error;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.wifi_off_rounded, size: 34, color: palette.text3),
              const SizedBox(height: 10),
              Text(
                error,
                textAlign: TextAlign.center,
                style: TextStyle(color: palette.text2, fontSize: 12.5, height: 1.6),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () => _controller?.reload(),
                icon: const Icon(Icons.refresh_rounded, size: 17),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    final controller = _controller;
    if (controller == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.4));
    }
    return WebViewWidget(controller: controller);
  }
}

class _FooterBar extends StatelessWidget {
  const _FooterBar({required this.palette, required this.onDone});

  final AppPalette palette;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(AppSpace.page, 8, AppSpace.page, 10),
      decoration: BoxDecoration(
        color: palette.bg,
        border: Border(top: BorderSide(color: palette.lineSoft)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '登录和付款都在 DeepSeek 官方页面完成，App 不接触支付信息。',
            textAlign: TextAlign.center,
            style: TextStyle(color: palette.text3, fontSize: 11, height: 1.45),
          ),
          const SizedBox(height: 8),
          FilledButton(onPressed: onDone, child: const Text('我已完成，回去刷新')),
        ],
      ),
    );
  }
}

extension _BoolOrTrue on bool? {
  bool get orTrue => this ?? true;
}
