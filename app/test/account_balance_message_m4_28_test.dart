// M4.28：余额接口 404 要翻译成「插件太旧」，而不是误导人去改地址。
//
// 现场：手机上「我的 → 账户余额」显示「读取账户余额失败：请求格式不正确：请确认地址
// 指向 M1 后端（not found）」。地址其实是对的——电脑上跑的还是插件 0.2.28，没有
// `/desktop/account/balance` 这条路由（HMR 卡住，0.2.29 没加载上）。通用 404 文案会
// 把人往改地址的方向带，所以这里单独翻译。
import 'dart:convert';

import 'package:deepseek_remote_app/services/history_api.dart';
import 'package:deepseek_remote_app/services/pairing_api.dart';
import 'package:flutter_test/flutter_test.dart';

const String _base = 'http://127.0.0.1:8787';

void main() {
  group('账户余额接口的错误文案（M4.28）', () {
    test('旧插件回 404 时，提示的是插件太旧而不是地址不对', () async {
      final api = HistoryApi(
        sender: (
          String method,
          Uri uri,
          Map<String, String> headers,
          Map<String, dynamic>? body,
        ) async =>
            JsonHttpResponse(
          404,
          jsonEncode(<String, dynamic>{
            'code': 'BAD_REQUEST',
            'message': 'not found',
          }),
        ),
      );

      try {
        await api.fetchAccountBalance(_base, token: 'tok-123');
        fail('应该抛出 PairingApiException');
      } on PairingApiException catch (error) {
        expect(error.statusCode, 404);
        expect(error.message, contains('插件还没有账户余额接口'));
        expect(error.message, contains('0.2.29'));
        expect(error.message, isNot(contains('请确认地址指向')));
      }
    });

    test('正常响应照旧解析钱包', () async {
      final api = HistoryApi(
        sender: (
          String method,
          Uri uri,
          Map<String, String> headers,
          Map<String, dynamic>? body,
        ) async =>
            JsonHttpResponse(
          200,
          jsonEncode(<String, dynamic>{
            'supported': true,
            'signedIn': true,
            'wallets': <dynamic>[
              <String, dynamic>{'currency': 'CNY', 'balance': '12.34'},
            ],
            'bonusWallets': <dynamic>[],
          }),
        ),
      );

      final balance = await api.fetchAccountBalance(_base, token: 'tok-123');
      expect(balance.supported, isTrue);
      expect(balance.primary?.balance, '12.34');
    });
  });
}
