import 'dart:async';
import 'dart:io';

import 'package:deepseek_remote_app/services/pairing_api.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('normalizeBaseUrl', () {
    test('补齐 https 并去掉尾部路径', () {
      expect(
        PairingApi.normalizeBaseUrl('abc.trycloudflare.com'),
        'https://<公网隧道>.trycloudflare.com',
      );
      expect(
        PairingApi.normalizeBaseUrl('  https://<公网隧道>.trycloudflare.com/  '),
        'https://<公网隧道>.trycloudflare.com',
      );
      expect(
        PairingApi.normalizeBaseUrl('https://<公网隧道>.trycloudflare.com/api/v1'),
        'https://<公网隧道>.trycloudflare.com',
      );
      expect(
        PairingApi.normalizeBaseUrl('https://<公网隧道>.trycloudflare.com/ws'),
        'https://<公网隧道>.trycloudflare.com',
      );
    });

    test('wss / ws 转为 https / http', () {
      expect(
        PairingApi.normalizeBaseUrl('wss://relay.example.com/ws'),
        'https://relay.example.com',
      );
      expect(
        PairingApi.normalizeBaseUrl('ws://192.168.1.20:8080/'),
        'http://192.168.1.20:8080',
      );
    });

    test('局域网/回环地址补 http（插件直连）', () {
      expect(
        PairingApi.normalizeBaseUrl('192.168.1.x:8787'),
        'http://192.168.1.x:8787',
      );
      expect(
        PairingApi.normalizeBaseUrl('127.0.0.1:8787'),
        'http://127.0.0.1:8787',
      );
      expect(PairingApi.normalizeBaseUrl('10.0.0.5'), 'http://10.0.0.5');
      expect(
        PairingApi.normalizeBaseUrl('172.16.4.9:9000/'),
        'http://172.16.4.9:9000',
      );
      expect(
        PairingApi.normalizeBaseUrl('localhost:8787'),
        'http://localhost:8787',
      );
      // 172.32 不在私有段，仍按公网域名补 https
      expect(PairingApi.normalizeBaseUrl('172.32.0.1'), 'https://172.32.0.1');
    });

    test('空地址抛可读异常', () {
      expect(
        () => PairingApi.normalizeBaseUrl('   '),
        throwsA(
          isA<PairingApiException>().having(
            (e) => e.message,
            'message',
            contains('请先填写电脑端地址'),
          ),
        ),
      );
    });

    test('非法地址抛可读异常', () {
      expect(
        () => PairingApi.normalizeBaseUrl('https://'),
        throwsA(
          isA<PairingApiException>().having(
            (e) => e.message,
            'message',
            contains('服务器地址格式不正确'),
          ),
        ),
      );
    });
  });

  test('resolveEndpoint 拼接 API 路径', () {
    expect(
      PairingApi.resolveEndpoint('https://relay.example.com', '/api/v1/health'),
      Uri.parse('https://relay.example.com/api/v1/health'),
    );
    expect(
      PairingApi.resolveEndpoint('http://192.168.1.20:8080', 'api/v1/auth/pair'),
      Uri.parse('http://192.168.1.20:8080/api/v1/auth/pair'),
    );
  });

  test('PairResult.fromJson 解析 token 与设备', () {
    final result = PairResult.fromJson(<String, dynamic>{
      'token': 'token-123',
      'role': 'app',
      'deviceId': 'device-9',
      'expiresAt': '2026-11-30T00:00:00.000Z',
    });
    expect(result.token, 'token-123');
    expect(result.role, 'app');
    expect(result.deviceId, 'device-9');
    expect(result.expiresAt, isNotNull);
  });

  test('PairResult.fromJson 缺 token 抛异常', () {
    expect(
      () => PairResult.fromJson(<String, dynamic>{'role': 'app'}),
      throwsA(
        isA<PairingApiException>().having(
          (e) => e.message,
          'message',
          contains('没有返回 token'),
        ),
      ),
    );
  });

  test('HealthResult 解析与可读标签', () {
    final healthy = HealthResult.fromJson(<String, dynamic>{
      'status': 'ok',
      'version': '0.1.0-m1',
      'agentOnline': true,
      'apps': 1,
    });
    expect(healthy.healthy, isTrue);
    expect(healthy.version, '0.1.0-m1');
    expect(healthy.agentOnline, isTrue);
    expect(healthy.apps, 1);
    expect(healthy.readableLabel, contains('后端正常'));
    expect(healthy.readableLabel, contains('在线'));

    final degraded = HealthResult.fromJson(<String, dynamic>{
      'status': 'degraded',
      'agentOnline': false,
    });
    expect(degraded.healthy, isFalse);
    expect(degraded.readableLabel, contains('后端状态异常'));
  });

  test('messageForHttpError 映射中文提示', () {
    expect(PairingApi.messageForHttpError(401), contains('配对失败'));
    expect(PairingApi.messageForHttpError(404), contains('接口不存在'));
    expect(PairingApi.messageForHttpError(503), contains('服务器出错'));
    expect(PairingApi.messageForHttpError(418), contains('HTTP 418'));
    expect(
      PairingApi.messageForHttpError(400, code: 'AUTH_FAILED'),
      contains('配对码'),
    );
  });

  test('describeException 映射网络异常', () {
    expect(PairingApi.describeException(TimeoutException('slow')),
        contains('连接超时'));
    expect(
      PairingApi.describeException(const PairingApiException('自定义配对错误')),
      '自定义配对错误',
    );
    expect(
      PairingApi.describeException(SocketException('Connection refused')),
      contains('无法连接服务器'),
    );
    expect(
      PairingApi.describeException(HandshakeException('bad certificate')),
      contains('HTTPS 证书校验失败'),
    );
    expect(
      PairingApi.describeException(const FormatException('bad json')),
      contains('不是合法 JSON'),
    );
  });

  group('PairingApi 注入 HTTP 发送器', () {
    test('pair 发送配对请求并解析结果', () async {
      String? method;
      Uri? uri;
      Map<String, dynamic>? body;
      final api = PairingApi(
        sender: (String m, Uri u, Map<String, dynamic>? b) async {
          method = m;
          uri = u;
          body = b;
          return const JsonHttpResponse(
            200,
            '{"token":"token-123","role":"app","deviceId":"device-9",'
            '"expiresAt":"2026-11-30T00:00:00.000Z"}',
          );
        },
      );

      final result = await api.pair(
        'https://<公网隧道>.trycloudflare.com/',
        pairingCode: ' 824613 ',
        clientName: '测试手机',
      );
      expect(result.token, 'token-123');
      expect(result.deviceId, 'device-9');
      expect(method, 'POST');
      expect(uri!.path, '/api/v1/auth/pair');
      expect(body!['pairingCode'], '824613');
      expect(body!['clientName'], '测试手机');
      expect(body!['role'], 'app');
    });

    test('pair 空配对码直接抛可读异常', () async {
      final api = PairingApi(
        sender: (m, u, b) async => const JsonHttpResponse(200, '{}'),
      );
      expect(
        () => api.pair('https://<公网隧道>.trycloudflare.com', pairingCode: '  '),
        throwsA(
          isA<PairingApiException>().having(
            (e) => e.message,
            'message',
            contains('配对码'),
          ),
        ),
      );
    });

    test('401 映射为配对失败异常', () async {
      final api = PairingApi(
        sender: (m, u, b) async => const JsonHttpResponse(
          401,
          '{"code":"AUTH_FAILED","message":"invalid pairing code"}',
        ),
      );
      try {
        await api.pair('https://<公网隧道>.trycloudflare.com', pairingCode: '000000');
        fail('应当抛出 PairingApiException');
      } on PairingApiException catch (error) {
        expect(error.statusCode, 401);
        expect(error.message, contains('配对失败'));
      }
    });

    test('health 解析后端与 Agent 状态', () async {
      final api = PairingApi(
        sender: (m, u, b) async => const JsonHttpResponse(
          200,
          '{"status":"ok","version":"0.1.0-m1","agentOnline":true,"apps":1}',
        ),
      );
      final health = await api.health('https://<公网隧道>.trycloudflare.com');
      expect(health.healthy, isTrue);
      expect(health.agentOnline, isTrue);
      expect(health.version, '0.1.0-m1');
    });
  });
}
