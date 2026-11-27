// M4.65：App 内「充值」页。
//
// 手机端没有商户号、电脑端账户服务也没有下单/付款能力，所以这一页只做
// 「看余额 → 去官方充值 → 回来刷新」的引导；测试盯住三件事：
// 余额读得到、连不上电脑时说清楚、按钮真的把官方页交给浏览器。
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseek_remote_app/data/live_store.dart';
import 'package:deepseek_remote_app/models.dart';
import 'package:deepseek_remote_app/screens/recharge_screen.dart';
import 'package:deepseek_remote_app/services/history_api.dart';
import 'package:deepseek_remote_app/services/pairing_api.dart';
import 'package:deepseek_remote_app/services/url_opener.dart';
import 'package:deepseek_remote_app/theme/app_theme.dart';

const String _rechargeUrl = 'https://platform.deepseek.com/top_up';

class _RechargeStore extends LiveStore {
  _RechargeStore({this.balance, this.error, this.connected = true});

  final AccountBalance? balance;
  final Object? error;
  final bool connected;
  int calls = 0;

  @override
  bool get isConnected => connected;

  @override
  String get deviceName => 'DeepSeek Harness';

  @override
  bool get tasksLoading => false;

  @override
  bool get conversationsLoading => false;

  @override
  UnmodifiableListView<TaskItem> get tasks =>
      UnmodifiableListView<TaskItem>(const <TaskItem>[]);

  @override
  Future<AccountBalance> fetchAccountBalance() async {
    calls += 1;
    final failure = error;
    if (failure != null) throw failure;
    return balance ?? const AccountBalance(signedIn: false);
  }
}

AccountBalance _signedIn() => AccountBalance.fromJson(<String, dynamic>{
      'supported': true,
      'signedIn': true,
      'failed': false,
      'wallets': <Map<String, dynamic>>[
        <String, dynamic>{'currency': 'CNY', 'balance': '36.5000000000'},
      ],
      'bonusWallets': <Map<String, dynamic>>[
        <String, dynamic>{'currency': 'CNY', 'balance': '10.0000000000'},
      ],
      'error': '',
    });

Future<void> _pump(WidgetTester tester, LiveStore store, UrlOpener opener) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: RechargeScreen(
        liveStore: store,
        rechargeUrl: _rechargeUrl,
        urlOpener: opener,
        // Widget 测试里没有原生 WebView，用一段文字代替页面本体。
        webViewBuilder: (context, url) => Center(child: Text('fake-webview:$url')),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('读到余额时显示充值余额与赠送余额，主按钮进 App 内嵌页', (tester) async {
    final store = _RechargeStore(balance: _signedIn());
    final opener = FakeUrlOpener();
    await _pump(tester, store, opener);

    expect(find.text('账户余额'), findsOneWidget);
    expect(find.text('¥36.50'), findsOneWidget);
    expect(find.text('¥10.00'), findsOneWidget);
    expect(find.text('充值余额'), findsOneWidget);
    expect(find.text('赠送余额'), findsOneWidget);
    expect(store.calls, 1);

    await tester.tap(find.text('在 App 内打开充值页'));
    await tester.pumpAndSettle();

    expect(find.text('fake-webview:$_rechargeUrl'), findsOneWidget);
    expect(opener.opened, isEmpty);

    await tester.tap(find.text('我已完成，回去刷新'));
    await tester.pumpAndSettle();

    expect(find.text('账户余额'), findsOneWidget);
    expect(store.calls, 2);
  });

  testWidgets('只保留 App 内入口，不再提供系统浏览器入口', (tester) async {
    final store = _RechargeStore(balance: _signedIn());
    final opener = FakeUrlOpener();
    await _pump(tester, store, opener);

    expect(find.text('在 App 内打开充值页'), findsOneWidget);
    expect(find.text('用系统浏览器打开'), findsNothing);
    expect(opener.opened, isEmpty);
  });

  testWidgets('没连电脑时说清楚，不显示余额', (tester) async {
    final store = _RechargeStore(connected: false);
    final opener = FakeUrlOpener();
    await _pump(tester, store, opener);

    expect(find.textContaining('连接电脑后显示电脑端的 DeepSeek 余额'), findsOneWidget);
    expect(store.calls, 0);
    expect(find.text('¥36.50'), findsNothing);
  });

  testWidgets('读余额失败时把原因显示出来，可以重试', (tester) async {
    final store = _RechargeStore(
      error: const PairingApiException('电脑上还没登录 DeepSeek 账号'),
    );
    final opener = FakeUrlOpener();
    await _pump(tester, store, opener);

    expect(find.textContaining('电脑上还没登录 DeepSeek 账号'), findsOneWidget);

    await tester.tap(find.text('已充值，刷新余额'));
    await tester.pumpAndSettle();

    expect(store.calls, 2);
  });
}
