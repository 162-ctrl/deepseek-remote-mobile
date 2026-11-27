// M4.40 测试审计 · 角度一：接口出错时的「说法」与降级
//
// 目的不是证明它现在是对的，而是把「服务器各种坏法」都喂一遍，看手机端是
// 给出人能看懂的一句话，还是把 FormatException / type cast 之类的内部错误
// 直接甩到界面上。发现的问题都记在 docs/research/M4_40_TEST_AUDIT.md。
import 'dart:async';
import 'dart:convert';

import 'package:deepseek_remote_app/services/history_api.dart';
import 'package:deepseek_remote_app/services/pairing_api.dart';
import 'package:flutter_test/flutter_test.dart';

const String _base = 'https://relay.example.com';

AuthorizedHttpSender _reply(int status, String body) =>
    (String method, Uri uri, Map<String, String> headers,
            Map<String, dynamic>? payload) async =>
        JsonHttpResponse(status, body);

void main() {
  group('M4.40 接口坏掉时的说法', () {
    test('500 + HTML 错误页：只给一句人话，不漏 HTML', () async {
      final api = HistoryApi(
        sender: _reply(500, '<html><body><h1>502 Bad Gateway</h1></body></html>'),
      );
      Object? caught;
      try {
        await api.desktopTasks(_base, token: 't');
      } catch (error) {
        caught = error;
      }
      expect(caught, isA<PairingApiException>());
      final message = (caught! as PairingApiException).message;
      expect(message, contains('拉取电脑任务失败'));
      expect(message.toLowerCase(), isNot(contains('<html')));
      expect(message, isNot(contains('FormatException')));
    });

    test('200 但内容不是 JSON：不抛 type cast', () async {
      final api = HistoryApi(sender: _reply(200, 'not json at all'));
      Object? caught;
      try {
        await api.desktopTasks(_base, token: 't');
      } catch (error) {
        caught = error;
      }
      expect(caught, isA<PairingApiException>());
      expect((caught! as PairingApiException).message, contains('不是合法 JSON'));
    });

    test('200 但 tasks 字段是字符串：不炸（返回空表或明确报错都可，不许崩）',
        () async {
      final api = HistoryApi(
        sender: _reply(200, jsonEncode(<String, dynamic>{'tasks': 'oops'})),
      );
      Object? caught;
      List<Object?>? rows;
      try {
        rows = await api.desktopTasks(_base, token: 't');
      } catch (error) {
        caught = error;
      }
      expect(caught, anyOf(isNull, isA<PairingApiException>()));
      if (caught == null) expect(rows, isEmpty);
    });

    test('401：提示重新配对，并带上 statusCode', () async {
      final api = HistoryApi(
        sender: _reply(401, jsonEncode(<String, dynamic>{'code': 'AUTH_FAILED'})),
      );
      Object? caught;
      try {
        await api.desktopTasks(_base, token: 't');
      } catch (error) {
        caught = error;
      }
      final exception = caught! as PairingApiException;
      expect(exception.statusCode, 401);
      expect(exception.message, contains('重新配对'));
    });

    test('请求一直不回来：超时要给出「超时」，而不是永远转圈', () async {
      final api = HistoryApi(
        timeout: const Duration(milliseconds: 30),
        sender: (String method, Uri uri, Map<String, String> headers,
                Map<String, dynamic>? payload) async =>
            Completer<JsonHttpResponse>().future,
      );
      Object? caught;
      try {
        await api.desktopTasks(_base, token: 't');
      } catch (error) {
        caught = error;
      }
      expect(caught, isA<PairingApiException>());
      expect((caught! as PairingApiException).message, contains('超时'));
    });

    test('空 token：不发请求，直接说要先配对', () async {
      var calls = 0;
      final api = HistoryApi(
        sender: (String method, Uri uri, Map<String, String> headers,
            Map<String, dynamic>? payload) async {
          calls += 1;
          return JsonHttpResponse(200, '{}');
        },
      );
      await expectLater(
        () => api.desktopTasks(_base, token: '   '),
        throwsA(
          isA<PairingApiException>().having(
            (e) => e.message,
            'message',
            contains('还没有配对 token'),
          ),
        ),
      );
      expect(calls, 0);
    });

    test('余额接口 404：说的是「插件太旧」，不是「地址不对」（M4.28 回归）',
        () async {
      final api = HistoryApi(
        sender: _reply(
          404,
          jsonEncode(<String, dynamic>{'code': 'BAD_REQUEST', 'message': 'not found'}),
        ),
      );
      Object? caught;
      try {
        await api.fetchAccountBalance(_base, token: 't');
      } catch (error) {
        caught = error;
      }
      final message = (caught! as PairingApiException).message;
      expect(message, contains('插件还没有账户余额接口'));
      expect(message, isNot(contains('请确认地址指向')));
    });

    test('会话事件 404：要把 statusCode 和 code 带出来，便于界面区分', () async {
      final api = HistoryApi(
        sender: _reply(
          404,
          jsonEncode(
            <String, dynamic>{'code': 'SESSION_NOT_FOUND', 'message': 'session not found'},
          ),
        ),
      );
      Object? caught;
      try {
        await api.desktopSessionEvents(_base, token: 't', sessionId: 'session-x');
      } catch (error) {
        caught = error;
      }
      final exception = caught! as PairingApiException;
      expect(exception.statusCode, 404);
      expect(exception.code, 'SESSION_NOT_FOUND');
    });
  });
}
