// M4.67：App 内嵌的官方充值页（WebView）。
//
// 原生 WebView 没法在 Widget 测试里跑，所以注入一个占位组件，测的是这层外壳：
// 页面确实接到了官方地址、点「我已完成」或按返回都会把 true 交回去，
// 让「充值」页知道要刷新余额。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseek_remote_app/screens/recharge_web_screen.dart';
import 'package:deepseek_remote_app/services/url_opener.dart';
import 'package:deepseek_remote_app/theme/app_theme.dart';

const String _rechargeUrl = 'https://platform.deepseek.com/top_up';

void main() {
  testWidgets('内嵌页加载官方地址，点「我已完成」返回 true', (tester) async {
    bool? popped;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  popped = await Navigator.of(context).push<bool>(
                    MaterialPageRoute<bool>(
                      builder: (_) => RechargeWebScreen(
                        url: _rechargeUrl,
                        webViewBuilder: (context, url) =>
                            Center(child: Text('fake-webview:$url')),
                      ),
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('fake-webview:$_rechargeUrl'), findsOneWidget);
    expect(find.text('官方充值页'), findsOneWidget);

    await tester.tap(find.text('我已完成，回去刷新'));
    await tester.pumpAndSettle();

    expect(popped, isTrue);
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('按返回箭头也把 true 交回去，提醒不要卡在官方页', (tester) async {
    bool? popped;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  popped = await Navigator.of(context).push<bool>(
                    MaterialPageRoute<bool>(
                      builder: (_) => RechargeWebScreen(
                        url: _rechargeUrl,
                        webViewBuilder: (context, url) =>
                            Center(child: Text('fake-webview:$url')),
                      ),
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('回到充值页'));
    await tester.pumpAndSettle();

    expect(popped, isTrue);
  });

  testWidgets('不再提供「用系统浏览器打开」的出口', (tester) async {
    final opener = FakeUrlOpener();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: RechargeWebScreen(
          url: _rechargeUrl,
          urlOpener: opener,
          webViewBuilder: (context, url) => Center(child: Text('fake-webview:$url')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('用系统浏览器打开'), findsNothing);
    expect(find.byTooltip('刷新'), findsOneWidget);
    expect(opener.opened, isEmpty);
  });
}
