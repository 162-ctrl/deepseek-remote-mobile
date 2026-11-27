import 'package:flutter/material.dart';

import '../data/live_store.dart';
import '../services/history_api.dart' show AccountBalance, AccountWallet;
import '../services/pairing_api.dart';
import '../services/url_opener.dart';
import '../theme/app_theme.dart';
import 'recharge_web_screen.dart';

/// 手机端「充值」入口页（M4.65 / M4.67）。
///
/// 手机端没有商户号、DeepSeek 也没有开放下单/付款接口，所以这个页面不收款；
/// 它做的是把「看余额 → 去官方充值 → 回来刷新」这三步串起来，并把
/// 「为什么 App 里不能直接付」讲清楚，避免用户以为按钮坏了。
///
/// M4.67 之后，「去充值」只走 App 内嵌的官方页（WebView）：
/// 在手机上登录一次，付款就不用离开 App；不再提供系统浏览器入口。
/// `urlOpener` 只留给 WebView 内部把 `alipays://`、`weixin://` 交给系统应用。
class RechargeScreen extends StatefulWidget {
  const RechargeScreen({
    super.key,
    required this.liveStore,
    required this.rechargeUrl,
    this.urlOpener,
    this.webViewBuilder,
  });

  final LiveStore liveStore;

  /// 官方充值页地址（`profile_screen.dart` 的 `kBalanceRechargeUrl`）。
  final String rechargeUrl;

  /// 打开浏览器；测试里注入假实现。
  final UrlOpener? urlOpener;

  /// 测试用：传给 [RechargeWebScreen]，替掉原生 WebView。
  final Widget Function(BuildContext context, String url)? webViewBuilder;

  @override
  State<RechargeScreen> createState() => _RechargeScreenState();
}

class _RechargeScreenState extends State<RechargeScreen> {
  AccountBalance? _balance;
  bool _loading = false;
  String? _error;
  DateTime? _checkedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (_loading) return;
    if (!widget.liveStore.isConnected) {
      setState(() {
        _balance = null;
        _error = '连接电脑后显示电脑端的 DeepSeek 余额';
        _checkedAt = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final balance = await widget.liveStore.fetchAccountBalance();
      if (!mounted) return;
      setState(() {
        _balance = balance;
        _loading = false;
        _checkedAt = DateTime.now();
      });
    } on PairingApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _loading = false;
        _checkedAt = DateTime.now();
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '读取余额失败：$error';
        _loading = false;
        _checkedAt = DateTime.now();
      });
    }
  }

  /// M4.67：唯一入口——App 内嵌的官方充值页（在手机上登录一次即可付款）。
  Future<void> _openRechargeInApp() async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => RechargeWebScreen(
          url: widget.rechargeUrl,
          urlOpener: widget.urlOpener,
          webViewBuilder: widget.webViewBuilder,
        ),
      ),
    );
    if (!mounted) return;
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: palette.bg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        toolbarHeight: 64,
        titleSpacing: 4,
        title: Text(
          '充值',
          style: TextStyle(
            color: palette.text,
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
        actions: [
          IconButton(
            tooltip: '刷新余额',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded, size: 20),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(AppSpace.page, 4, AppSpace.page, 28),
        children: [
          _BalancePanel(
            palette: palette,
            balance: _balance,
            loading: _loading,
            error: _error,
            checkedAt: _checkedAt,
            onRecharge: _openRechargeInApp,
            onRefresh: _load,
          ),
          const SizedBox(height: 18),
          Text(
            '怎么充值',
            style: TextStyle(
              color: palette.text,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          _StepRow(
            palette: palette,
            index: 1,
            title: '点下面的按钮，在 App 里打开 DeepSeek 官方充值页',
            detail: '页面是 platform.deepseek.com 的官方网页，第一次要在手机上登录同一个账号；登录状态会记住。',
          ),
          _StepRow(
            palette: palette,
            index: 2,
            title: '在网页里付款',
            detail: '支付宝 / 微信支付都行，这一步完全在官方页面完成，App 不接触付款信息。',
          ),
          _StepRow(
            palette: palette,
            index: 3,
            title: '回来点「已充值，刷新余额」',
            detail: '余额是电脑端查回来的，可能要等十几秒才到账；没到账就再刷一次。',
          ),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: _openRechargeInApp,
            icon: const Icon(Icons.open_in_new_rounded, size: 17),
            label: const Text('在 App 内打开充值页'),
          ),
          const SizedBox(height: 2),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh_rounded, size: 15),
              label: const Text('已充值，刷新余额'),
            ),
          ),
          const SizedBox(height: 12),
          _NoteCard(
            palette: palette,
            title: '为什么 App 里不能直接付钱',
            body: '这个手机端连接的是你电脑上的 DSH 插件，不是 DeepSeek 官方客户端；'
                '插件只能代查余额，没有下单、收款、开发票的能力。要真正下单，'
                '只能在官方网页里完成，所以这里把你送到网页，而不是让你以为按钮坏了。',
          ),
          const SizedBox(height: 10),
          _NoteCard(
            palette: palette,
            title: '充值没到账怎么办',
            body: '先等十几秒再刷新；还不显示，就在官方网页的「充值记录」里看订单状态。'
                '余额读不出来时，页面顶部会写清楚原因（没连电脑 / 电脑没登录 / 插件太旧）。',
          ),
          const SizedBox(height: 10),
          _NoteCard(
            palette: palette,
            title: '赠送额度与发票',
            body: '赠送钱包的额度由官方活动发放，App 里只读不写；发票、订单、支付方式都在官方网页的账户页里。',
          ),
        ],
      ),
    );
  }
}

class _BalancePanel extends StatelessWidget {
  const _BalancePanel({
    required this.palette,
    required this.balance,
    required this.loading,
    required this.error,
    required this.checkedAt,
    required this.onRecharge,
    required this.onRefresh,
  });

  final AppPalette palette;
  final AccountBalance? balance;
  final bool loading;
  final String? error;
  final DateTime? checkedAt;
  final VoidCallback onRecharge;
  final VoidCallback onRefresh;

  String _statusText() {
    final error = this.error;
    if (error != null && error.isNotEmpty) return error;
    if (loading) return '正在读取…';
    final value = balance;
    if (value == null) return '还没有读到余额';
    if (!value.supported) return '这台电脑的插件版本太旧，读不到余额';
    if (value.failed) {
      return value.error.isEmpty ? '余额查询失败' : value.error;
    }
    if (!value.signedIn) return '电脑上还没登录 DeepSeek 账号';
    return '电脑端 DeepSeek 账号';
  }

  String _whenText() {
    final when = checkedAt;
    if (when == null) return '';
    final diff = DateTime.now().difference(when);
    if (diff.inSeconds < 30) return '刚刚查过';
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前查过';
    return '${diff.inHours} 小时前查过';
  }

  @override
  Widget build(BuildContext context) {
    final value = balance;
    final rows = <(String, AccountWallet)>[
      if (value != null)
        for (final wallet in value.wallets) ('充值余额', wallet),
      if (value != null)
        for (final wallet in value.bonusWallets) ('赠送余额', wallet),
    ];
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: palette.lineSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.account_balance_wallet_outlined,
                size: 18,
                color: palette.text2,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '账户余额',
                  style: TextStyle(
                    color: palette.text,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (loading)
                SizedBox(
                  width: 15,
                  height: 15,
                  child: CircularProgressIndicator(strokeWidth: 2, color: palette.text3),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (rows.isEmpty)
            Text(
              _statusText(),
              style: TextStyle(color: palette.text3, fontSize: 12, height: 1.5),
            )
          else ...[
            for (final row in rows)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        row.$1,
                        style: TextStyle(color: palette.text3, fontSize: 12),
                      ),
                    ),
                    Text(
                      row.$2.display,
                      style: TextStyle(
                        color: palette.text,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            Text(
              [_statusText(), _whenText()].where((text) => text.isNotEmpty).join(' · '),
              style: TextStyle(color: palette.text3, fontSize: 11, height: 1.5),
            ),
          ],
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: onRecharge,
                  child: const Text('去官方充值'),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: loading ? null : onRefresh,
                child: const Text('刷新'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({
    required this.palette,
    required this.index,
    required this.title,
    required this.detail,
  });

  final AppPalette palette;
  final int index;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 20,
            height: 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: palette.accentSoft,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              '$index',
              style: TextStyle(
                color: palette.accent,
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: palette.text,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  style: TextStyle(color: palette.text3, fontSize: 11.5, height: 1.55),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NoteCard extends StatelessWidget {
  const _NoteCard({required this.palette, required this.title, required this.body});

  final AppPalette palette;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(13, 11, 13, 11),
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: palette.lineSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: palette.text,
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            body,
            style: TextStyle(color: palette.text3, fontSize: 11.5, height: 1.6),
          ),
        ],
      ),
    );
  }
}
