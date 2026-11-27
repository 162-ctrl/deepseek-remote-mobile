// M4.25：账户余额显示在「我的」页。
//
// 余额只能由电脑端查（Host 的 `deepseekAccount.getBalance()` 只让 Host 消费者
// 拿凭据），手机这边只认插件代理回来的 `{ wallets, bonusWallets, signedIn }`。
// 这里验证四种版面：有余额（¥ + 赠送）、未登录、查询失败、没连接。
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseek_remote_app/data/live_store.dart';
import 'package:deepseek_remote_app/models.dart';
import 'package:deepseek_remote_app/screens/profile_screen.dart';
import 'package:deepseek_remote_app/services/history_api.dart';
import 'package:deepseek_remote_app/services/pairing_api.dart';
import 'package:deepseek_remote_app/theme/app_theme.dart';

class _FakeBalanceStore extends LiveStore {
  _FakeBalanceStore({this.balance, this.error, this.connected = true});

  AccountBalance? balance;
  String? error;
  bool connected;
  int calls = 0;

  @override
  bool get isConnected => connected;

  @override
  String get deviceName => 'DeepSeek Harness';

  @override
  String get agentVersion => '0.1.0-m1';

  @override
  String get harnessVersion => '0.2.29';

  @override
  bool get tasksLoading => false;

  @override
  bool get conversationsLoading => false;

  @override
  String? get tasksError => null;

  @override
  bool get usesDesktopTaskMirror => true;

  @override
  List<String> get workspaceRoots => const <String>[];

  @override
  UnmodifiableListView<TaskItem> get tasks =>
      UnmodifiableListView<TaskItem>(const <TaskItem>[]);

  @override
  UnmodifiableListView<ArchivedSession> get archivedSessions =>
      UnmodifiableListView<ArchivedSession>(const <ArchivedSession>[]);

  @override
  Future<AccountBalance> fetchAccountBalance() async {
    calls += 1;
    final failure = error;
    if (failure != null) throw PairingApiException(failure);
    return balance ?? const AccountBalance();
  }
}

Future<void> _pumpProfile(WidgetTester tester, LiveStore store) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: ProfileScreen(liveStore: store),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('M4.25 有余额时显示 ¥ 金额与赠送余额', (tester) async {
    final store = _FakeBalanceStore(
      balance: const AccountBalance(
        supported: true,
        signedIn: true,
        wallets: <AccountWallet>[
          AccountWallet(currency: 'CNY', balance: '12.34'),
        ],
        bonusWallets: <AccountWallet>[
          AccountWallet(currency: 'CNY', balance: '3.00'),
        ],
      ),
    );

    await _pumpProfile(tester, store);

    expect(find.text('账户余额'), findsWidgets);
    expect(find.text('¥12.34'), findsOneWidget);
    expect(find.text('赠送余额'), findsOneWidget);
    expect(find.text('¥3.00'), findsOneWidget);
    expect(store.calls, 1);
  });

  testWidgets('M4.25 未登录时说清楚是电脑上没登录', (tester) async {
    final store = _FakeBalanceStore(balance: const AccountBalance(supported: true));

    await _pumpProfile(tester, store);

    expect(find.text('电脑上还没登录 DeepSeek 账号'), findsOneWidget);
    expect(find.text('赠送余额'), findsNothing);
  });

  testWidgets('M4.25 查询失败时把错误显示出来并能重试', (tester) async {
    final store = _FakeBalanceStore(error: '读取账户余额失败：电脑没响应');

    await _pumpProfile(tester, store);

    expect(find.textContaining('读取账户余额失败'), findsOneWidget);
    expect(store.calls, 1);

    store.error = null;
    store.balance = const AccountBalance(
      supported: true,
      signedIn: true,
      wallets: <AccountWallet>[AccountWallet(currency: 'CNY', balance: '8.00')],
    );
    await tester.tap(find.byTooltip('重新读取'));
    await tester.pumpAndSettle();

    expect(store.calls, 2);
    expect(find.text('¥8.00'), findsOneWidget);
  });

  testWidgets('M4.25 没连接时不请求、只提示先连接', (tester) async {
    final store = _FakeBalanceStore(connected: false);

    await _pumpProfile(tester, store);

    expect(find.text('连接电脑后显示电脑端的 DeepSeek 余额'), findsOneWidget);
    expect(store.calls, 0);
  });
}
