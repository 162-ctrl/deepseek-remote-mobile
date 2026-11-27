import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/live_store.dart';
import '../services/pairing_api.dart';
import '../services/network_url_policy.dart';
import '../services/pairing_link.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import 'scanner_screen.dart';

/// 真实连接页（M2.4：服务器地址 + 6 格配对码 + 双按钮 + 状态卡）。
///
/// 连接成功后自动返回上一页；已连接时可直接断开。
class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key, required this.store});

  final LiveStore store;

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  late final TextEditingController _urlController;
  late final TextEditingController _codeController;
  final FocusNode _codeFocus = FocusNode();

  bool _busy = false;
  bool _testing = false;
  bool? _healthOk;
  String? _healthText;

  @override
  void initState() {
    super.initState();
    final store = widget.store;
    final rawUrl = store.serverUrl.trim();
    _urlController = TextEditingController(
      text: rawUrl.isEmpty ? LiveStore.defaultServerUrl : rawUrl,
    );
    _codeController = TextEditingController(text: store.pairingCode);
    _codeController.addListener(_onCodeChanged);
    _urlController.addListener(_onUrlChanged);
  }

  /// M4.44：地址是否允许连、是否需要提示未加密（规则见 NetworkUrlPolicy）。
  NetworkUrlCheck get _urlCheck => NetworkUrlPolicy.inspect(_urlController.text);

  String? get _urlWarning => _urlCheck.warning;

  void _onUrlChanged() {
    if (mounted) setState(() {});
  }

  void _onCodeChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _codeController.removeListener(_onCodeChanged);
    _urlController.removeListener(_onUrlChanged);
    _urlController.dispose();
    _codeController.dispose();
    _codeFocus.dispose();
    super.dispose();
  }

  Future<void> _testHealth() async {
    FocusScope.of(context).unfocus();
    final check = _urlCheck;
    if (!check.allowed) {
      setState(() {
        _testing = false;
        _healthOk = false;
        _healthText = check.error;
      });
      return;
    }
    setState(() {
      _testing = true;
      _healthOk = null;
      _healthText = null;
    });
    try {
      final result = await widget.store.checkHealth(_urlController.text);
      if (!mounted) return;
      setState(() {
        _healthOk = true;
        _healthText =
            '${result.readableLabel} · 版本 ${result.version} · 在线 App ${result.apps} 个';
      });
    } on PairingApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _healthOk = false;
        _healthText = error.message;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _healthOk = false;
        _healthText = PairingApi.describeException(error);
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _connect() async {
    FocusScope.of(context).unfocus();
    // 允许把二维码里那一整串（地址#c=码）粘到地址框：这里顺手把码拆出来。
    final pasted = PairingLink.tryParse(_urlController.text);
    if (pasted != null && pasted.hasCode) {
      _urlController.text = pasted.baseUrl;
      if (_codeController.text.trim() != pasted.pairingCode) {
        _codeController.text = pasted.pairingCode!;
      }
    }
    // M4.44：公网明文一律拒绝，内网明文放行但会提示未加密。
    final check = NetworkUrlPolicy.inspect(_urlController.text);
    if (!check.allowed) {
      setState(() {
        _healthOk = false;
        _healthText = check.error;
      });
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.store.connect(
        _urlController.text,
        code: _codeController.text.trim(),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    if (widget.store.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已连接 ${widget.store.deviceName}，可以使用真实 AI 助手了。')),
      );
      Navigator.of(context).maybePop(true);
    }
  }

  /// M2.7：扫码 → 回填地址与匹配码 → 自动健康检查（有码且在线就直接连）。
  Future<void> _scan() async {
    FocusScope.of(context).unfocus();
    final link = await Navigator.of(context).push<PairingLink>(
      MaterialPageRoute(
        builder: (_) => const ScannerScreen(),
        fullscreenDialog: true,
      ),
    );
    if (!mounted || link == null) return;

    setState(() {
      _urlController.text = link.baseUrl;
      if (link.hasCode) {
        _codeController.text = link.pairingCode!;
      }
      _healthOk = null;
      _healthText = null;
    });

    await _testHealth();
    if (!mounted) return;

    if (_healthOk != true) {
      return;
    }
    if (!link.hasCode) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('地址已填好，这个二维码没带匹配码，请输入电脑上显示的 6 位码。')),
      );
      return;
    }
    if (widget.store.isConnected) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已填入新的地址与匹配码，断开后即可用新配置连接。')));
      return;
    }
    await _connect();
  }

  Future<void> _disconnect() async {    setState(() => _busy = true);
    try {
      await widget.store.disconnect();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    if (!widget.store.isConnected) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已断开与电脑的连接。')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return ListenableBuilder(
      listenable: widget.store,
      builder: (context, _) {
        final store = widget.store;
        final connected = store.isConnected;
        final busy =
            _busy || store.connectionState == LiveConnectionState.connecting;

        return Scaffold(
          appBar: AppBar(
            titleSpacing: 4,
            title: Text(
              '连接电脑',
              style: TextStyle(
                color: palette.text,
                fontSize: 22,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3,
              ),
            ),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpace.page,
              4,
              AppSpace.page,
              28,
            ),
            children: [
              _introCard(connected),
              const SizedBox(height: AppSpace.cardGap),
              _scanCard(connected, busy),
              SectionTitle(
                '服务器',
                trailing: Text(
                  'Cloudflare 隧道或局域网',
                  style: TextStyle(color: palette.text3, fontSize: 11.5),
                ),
              ),
              TextField(
                controller: _urlController,
                enabled: !connected && !_busy,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.next,
                autocorrect: false,
                style: TextStyle(color: palette.text, fontSize: 13.5),
                decoration: const InputDecoration(
                  hintText: '192.168.1.x:8787',
                  helperText: '扫码会自动填这一行；也可手输电脑局域网地址 + 8787 端口，或 cloudflared 给的 https 公网地址',
                  helperMaxLines: 3,
                  prefixIcon: Icon(Icons.public_rounded, size: 19),
                ),
              ),
              // M4.44：明文连接要明说，不能静默降级。
              if (_urlWarning != null) ...[
                const SizedBox(height: 6),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.lock_open_rounded, size: 14, color: palette.warn),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _urlWarning!,
                        style: TextStyle(color: palette.warn, fontSize: 11.5),
                      ),
                    ),
                  ],
                ),
              ],
              SectionTitle(
                '配对码',
                trailing: Text(
                  '电脑端启动 Agent 后显示',
                  style: TextStyle(color: palette.text3, fontSize: 11.5),
                ),
              ),
              _PairingCodeField(
                controller: _codeController,
                focusNode: _codeFocus,
                enabled: !connected && !_busy,
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: (busy || connected) ? null : _testHealth,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (_testing)
                            const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          else
                            Icon(
                              Icons.network_check_rounded,
                              size: 18,
                              color: palette.text2,
                            ),
                          const SizedBox(width: 8),
                          const Text('测试连接'),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed:
                          busy ? null : (connected ? _disconnect : _connect),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (busy)
                            const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          else
                            Icon(
                              connected
                                  ? Icons.link_off_rounded
                                  : Icons.link_rounded,
                              size: 18,
                            ),
                          const SizedBox(width: 8),
                          Text(connected ? '断开连接' : '连接'),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              if (_healthText != null) ...[
                const SizedBox(height: 16),
                _healthBanner(),
              ],
              const SizedBox(height: 8),
              SectionTitle('连接状态'),
              _statusCard(store),
              const SizedBox(height: 6),
              Text(
                '电脑端装 dsh-plugin-m1 → 扫码或填地址与配对码 → 连接',
                style: TextStyle(color: palette.text3, fontSize: 11),
              ),
            ],
          ),
        );
      },
    );
  }

  /// M2.7：扫码入口卡片。连上以后仍然可以扫，用于切换到另一台电脑/另一个地址。
  Widget _scanCard(bool connected, bool busy) {
    final palette = context.appPalette;
    final enabled = !busy;
    return Opacity(
      opacity: enabled ? 1 : 0.55,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.card),
          onTap: enabled ? _scan : null,
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 15, 12, 15),
            decoration: BoxDecoration(
              color: palette.card,
              borderRadius: BorderRadius.circular(AppRadius.card),
              border: Border.all(
                color: palette.accent.withValues(alpha: 0.35),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: palette.accentSoft,
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Icon(
                    Icons.qr_code_scanner_rounded,
                    color: palette.accent,
                    size: 21,
                  ),
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '扫码连接电脑',
                        style: TextStyle(
                          color: palette.text,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        connected
                            ? '想换一台电脑？扫新二维码会填好新地址与匹配码'
                            : '对准电脑配网页上的二维码，地址和匹配码自动填好',
                        style: TextStyle(
                          color: palette.text2,
                          fontSize: 12,
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  color: palette.text3,
                  size: 20,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _introCard(bool connected) {
    final palette = context.appPalette;
    return Panel(
      padding: const EdgeInsets.all(18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: palette.accentSoft,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              connected ? Icons.computer_rounded : Icons.devices_other_rounded,
              color: palette.accent,
              size: 20,
            ),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  connected ? '已连接真实电脑' : '连接你自己的电脑',
                  style: TextStyle(
                    color: palette.text,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  connected
                      ? 'AI 助手页现在会把指令发到电脑上的 DeepSeek Harness 执行，工具调用与高风险操作会实时弹窗授权。'
                      : '连接后 AI 助手会把指令发到电脑上的 DeepSeek Harness 执行；未连接时各页展示空态。',
                  style: TextStyle(
                    color: palette.text2,
                    fontSize: 12.5,
                    height: 1.6,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _healthBanner() {
    final palette = context.appPalette;
    final ok = _healthOk == true;
    final color = ok ? palette.success : palette.danger;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: ok ? palette.successSoft : palette.dangerSoft,
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            ok
                ? Icons.check_circle_outline_rounded
                : Icons.error_outline_rounded,
            size: 16,
            color: color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _healthText ?? '',
              style: TextStyle(color: color, fontSize: 12, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusCard(LiveStore store) {
    final palette = context.appPalette;
    final stateColor = switch (store.connectionState) {
      LiveConnectionState.connected => palette.success,
      LiveConnectionState.connecting => palette.warn,
      LiveConnectionState.error => palette.danger,
      LiveConnectionState.idle => palette.text3,
    };
    final rows = <Widget>[
      _statusRow(store.connectionLabel, stateColor, dot: true),
      if (store.errorText != null) ...[
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline_rounded, size: 14, color: palette.danger),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                store.errorText!,
                style: TextStyle(
                  color: palette.danger,
                  fontSize: 11.5,
                  height: 1.45,
                ),
              ),
            ),
            if (store.connectionState == LiveConnectionState.error)
              TextButton(
                onPressed: store.retry,
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 26),
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('重试', style: TextStyle(fontSize: 11)),
              ),
          ],
        ),
      ],
      if (store.isConnected) ...[
        Divider(height: 20, color: palette.line),
        InfoRow('电脑名称', store.deviceName),
        InfoRow('Agent 版本', store.agentVersion),
        InfoRow('Harness 版本', store.harnessVersion),
        InfoRow(
          '工作区',
          store.workspacePath?.isNotEmpty == true
              ? store.workspacePath!
              : (store.workspaceRoots.isNotEmpty
                    ? store.workspaceRoots.first
                    : '电脑端未授权工作区'),
        ),
        InfoRow(
          '会话',
          store.conversationId == null || store.conversationId!.isEmpty
              ? '未创建'
              : store.conversationId!,
        ),
        InfoRow('上下文', store.contextLabel ?? '暂无数据'),
        InfoRow('手机端 token', _maskedToken(store.token)),
      ],
    ];
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows),
    );
  }

  String _maskedToken(String? token) {
    if (token == null || token.isEmpty) return '未配对';
    if (token.length <= 8) return '$token…';
    return '${token.substring(0, 8)}…';
  }

  Widget _statusRow(String text, Color color, {bool dot = false}) {
    return Row(
      children: [
        if (dot) ...[
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 7),
        ],
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

}

/// 6 格配对码输入（§4）：当前格 accent 边框 + accentSoft 底。
class _PairingCodeField extends StatelessWidget {
  const _PairingCodeField({
    required this.controller,
    required this.focusNode,
    required this.enabled,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final text = controller.text.trim();
    final activeIndex = text.length >= 6 ? 5 : text.length;
    return Stack(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            for (var i = 0; i < 6; i++)
              GestureDetector(
                onTap: enabled ? () => focusNode.requestFocus() : null,
                child: Container(
                  width: 48,
                  height: 56,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: i == activeIndex && enabled
                        ? palette.accentSoft
                        : palette.card,
                    borderRadius: BorderRadius.circular(AppRadius.code),
                    border: Border.all(
                      color: i == activeIndex && enabled
                          ? palette.accent
                          : palette.line,
                      width: i == activeIndex && enabled ? 1.6 : 1,
                    ),
                  ),
                  child: Text(
                    i < text.length ? text[i] : '',
                    style: TextStyle(
                      color: palette.text,
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
          ],
        ),
        Positioned.fill(
          child: Opacity(
            opacity: 0,
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              enabled: enabled,
              keyboardType: TextInputType.number,
              maxLength: 6,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                counterText: '',
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
              ),
            ),
          ),
        ),
      ],
    );
  }
}


