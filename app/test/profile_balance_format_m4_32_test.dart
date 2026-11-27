// M4.32：余额卡片上的数字与排版。
//
// 现场出过两个问题：`¥12.443675700000000` 这样的原始定点串直接显示、把左边
// 标题挤成一列单字；赠送余额那行显示成 `$0`（Host 的 bonusWallets 是 USD 0）。
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseek_remote_app/data/live_store.dart';
import 'package:deepseek_remote_app/models.dart';
import 'package:deepseek_remote_app/screens/profile_screen.dart';
import 'package:deepseek_remote_app/services/history_api.dart';
import 'package:deepseek_remote_app/services/url_opener.dart';
import 'package:deepseek_remote_app/theme/app_theme.dart';

class _FakeBalanceStore extends LiveStore {
  _FakeBalanceStore({required this.balance});

  final AccountBalance balance;

  @override
  bool get isConnected => true;

  @override
  String get deviceName => 'DeepSeek Harness';

  @override
  String get agentVersion => '0.1.0-m1';

  @override
  String get harnessVersion => '0.2.30';

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
  Future<AccountBalance> fetchAccountBalance() async => balance;
}

/// 现场那条 `/api/v1/desktop/account/balance` 的原始返回。
Map<String, dynamic> _livePayload(String cny) => <String, dynamic>{
      'supported': true,
      'signedIn': true,
      'failed': false,
      'wallets': <Map<String, dynamic>>[
        <String, dynamic>{'currency': 'USD', 'balance': '0E-16'},
        <String, dynamic>{'currency': 'CNY', 'balance': cny},
      ],
      'bonusWallets': <Map<String, dynamic>>[
        <String, dynamic>{'currency': 'USD', 'balance': '0'},
      ],
      'error': '',
    };

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
  group('M4.32 金额格式化', () {
    test('定点小数字符串压成两位小数', () {
      expect(formatMoneyAmount('12.4137841000000000'), '12.41');
      expect(formatMoneyAmount('12.443675700000000'), '12.44');
      expect(formatMoneyAmount('3.0000000000'), '3.00');
      expect(formatMoneyAmount('12.34'), '12.34');
    });

    test('指数形式与零', () {
      expect(formatMoneyAmount('0E-16'), '0.00');
      expect(formatMoneyAmount('0'), '0.00');
      expect(formatMoneyAmount('0.004'), '0.00');
    });

    test('空串与解析不了的原样返回', () {
      expect(formatMoneyAmount(''), '');
      expect(formatMoneyAmount('   '), '');
      expect(formatMoneyAmount('待补充'), '待补充');
    });

    test('钱包 display 带币种符号', () {
      expect(
        const AccountWallet(currency: 'CNY', balance: '12.4137841000000000')
            .display,
        '¥12.41',
      );
      expect(
        const AccountWallet(currency: 'usd', balance: '0E-16').display,
        r'$0.00',
      );
      // 未知币种不硬塞符号，别把金额变成看不懂的东西。
      expect(
        const AccountWallet(currency: 'JPY', balance: '100').display,
        '100.00',
      );
    });
  });

  group('M4.32 从真实返回里挑钱包', () {
    test('美元 0 不会顶掉人民币那条', () {
      final balance = AccountBalance.fromJson(_livePayload('12.4137841000000000'));
      expect(balance.primary?.currency, 'CNY');
      expect(balance.primary?.display, '¥12.41');
    });

    test('赠送钱包全是 0 时不显示', () {
      final balance = AccountBalance.fromJson(_livePayload('12.41'));
      expect(balance.primaryBonus, isNull);
    });

    test('赠送钱包有钱时仍然优先人民币', () {
      final balance = AccountBalance.fromJson(<String, dynamic>{
        ..._livePayload('12.41'),
        'bonusWallets': <Map<String, dynamic>>[
          <String, dynamic>{'currency': 'USD', 'balance': '0'},
          <String, dynamic>{'currency': 'CNY', 'balance': '3.5000000000'},
        ],
      });
      expect(balance.primaryBonus?.display, '¥3.50');
    });
  });

  group('M4.32 卡片排版', () {
    testWidgets(r'金额显示两位小数，且不再显示 $0 赠送余额', (tester) async {
      final store = _FakeBalanceStore(
        balance: AccountBalance.fromJson(_livePayload('12.443675700000000')),
      );

      await _pumpProfile(tester, store);

      expect(find.text('¥12.44'), findsOneWidget);
      expect(find.textContaining('12.443675700000000'), findsNothing);
      expect(find.text('赠送余额'), findsNothing);
    });

    testWidgets('超长金额也不会把标题挤成一列单字', (tester) async {
      final store = _FakeBalanceStore(
        balance: AccountBalance.fromJson(_livePayload('123456789.987654321')),
      );

      await _pumpProfile(tester, store);

      // 「账户余额」在页面上出现两次：分区标题与卡片标题，后者在后面。
      final title = find.text('账户余额').last;
      expect(title, findsOneWidget);
      // 被挤成一列单字时，宽度只剩一个字、高度却有四行。
      final size = tester.getSize(title);
      expect(size.width, greaterThan(40));
      expect(size.height, lessThan(30));
      expect(find.textContaining('123456789.99'), findsWidgets);
    });
  });

  group('M4.33 去充值', () {
    testWidgets('点「去充值」只进 App 内充值页', (tester) async {
      final opener = FakeUrlOpener();
      final store = _FakeBalanceStore(
        balance: AccountBalance.fromJson(_livePayload('12.41')),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: ProfileScreen(liveStore: store, urlOpener: opener),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('去充值'));
      await tester.pumpAndSettle();

      // M4.65：先看到 App 内的充值页，浏览器还没被拉起。
      // M4.67 之后只保留 App 内入口，不再有「交给浏览器」的次级入口。
      expect(find.text('在 App 内打开充值页'), findsOneWidget);
      expect(find.text('用系统浏览器打开'), findsNothing);
      expect(opener.opened, isEmpty);
      expect(kBalanceRechargeUrl, startsWith('https://platform.deepseek.com'));
    });

    testWidgets('没连接时不出现「去充值」', (tester) async {
      final opener = FakeUrlOpener();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: ProfileScreen(liveStore: _OfflineStore(), urlOpener: opener),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('去充值'), findsNothing);
      expect(opener.opened, isEmpty);
    });
  });
}

class _OfflineStore extends LiveStore {
  @override
  bool get isConnected => false;

  @override
  String get deviceName => 'DeepSeek Harness';

  @override
  String get agentVersion => '0.1.0-m1';

  @override
  String get harnessVersion => '0.2.30';

  @override
  bool get tasksLoading => false;

  @override
  bool get conversationsLoading => false;

  @override
  String? get tasksError => null;

  @override
  bool get usesDesktopTaskMirror => false;

  @override
  List<String> get workspaceRoots => const <String>[];

  @override
  UnmodifiableListView<TaskItem> get tasks =>
      UnmodifiableListView<TaskItem>(const <TaskItem>[]);

  @override
  UnmodifiableListView<ArchivedSession> get archivedSessions =>
      UnmodifiableListView<ArchivedSession>(const <ArchivedSession>[]);
}
