// M4.44 / 第 4 条：`NetworkUrlPolicy` 的规则表。
//
// 三条规则各有用例：公网必须加密、明文只许内网、允许未加密时必须给出提示。
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseek_remote_app/services/network_url_policy.dart';

void main() {
  group('分类', () {
    test('回环、私有网段、公网域名各归各位', () {
      expect(NetworkUrlPolicy.classifyHost('localhost'), NetworkHostScope.loopback);
      expect(NetworkUrlPolicy.classifyHost('127.0.0.1'), NetworkHostScope.loopback);
      expect(NetworkUrlPolicy.classifyHost('[::1]'), NetworkHostScope.loopback);

      for (final host in [
        '10.0.0.5',
        '172.16.3.9',
        '172.31.255.1',
        '192.168.1.x',
        '169.254.10.2',
        '192.168.1.10', // Tailscale
        'fd12:3456::1',
        'fe80::1',
      ]) {
        expect(
          NetworkUrlPolicy.classifyHost(host),
          NetworkHostScope.privateNetwork,
          reason: '$host 应算局域网',
        );
      }

      // 172.32 不在 172.16/12 里，不能误判
      expect(NetworkUrlPolicy.classifyHost('172.32.0.1'), NetworkHostScope.publicHost);
      expect(NetworkUrlPolicy.classifyHost('8.8.8.8'), NetworkHostScope.publicHost);
      expect(
        NetworkUrlPolicy.classifyHost('fwd-encoding-packard.trycloudflare.com'),
        NetworkHostScope.publicHost,
      );
    });
  });

  group('公网必须加密', () {
    test('公网 https 放行，公网 http 拒绝', () {
      final secure = NetworkUrlPolicy.inspect('https://<公网隧道>.trycloudflare.com');
      expect(secure.allowed, isTrue);
      expect(secure.secure, isTrue);
      expect(secure.warning, isNull);

      final plain = NetworkUrlPolicy.inspect('http://abc.trycloudflare.com');
      expect(plain.allowed, isFalse);
      expect(plain.error, contains('公网地址必须用 https://'));

      final publicIp = NetworkUrlPolicy.inspect('http://8.8.8.8:8787');
      expect(publicIp.allowed, isFalse);
    });
  });

  group('明文只许内网', () {
    test('局域网/回环 http 放行，但明确提示未加密', () {
      final lan = NetworkUrlPolicy.inspect('http://192.168.1.x:8787');
      expect(lan.allowed, isTrue);
      expect(lan.secure, isFalse);
      expect(lan.scope, NetworkHostScope.privateNetwork);
      expect(lan.warning, contains('未加密'));

      final loopback = NetworkUrlPolicy.inspect('http://127.0.0.1:8787');
      expect(loopback.allowed, isTrue);
      expect(loopback.warning, contains('未加密'));

      final tailscale = NetworkUrlPolicy.inspect('http://192.168.1.10:8787');
      expect(tailscale.allowed, isTrue);
    });

    test('局域网也能用 https（自签场景由系统信任链决定，策略层不拦）', () {
      final check = NetworkUrlPolicy.inspect('https://192.168.1.x:8787');
      expect(check.allowed, isTrue);
      expect(check.secure, isTrue);
      expect(check.warning, isNull);
    });
  });

  group('裸地址与协议', () {
    test('不带协议时按主机类型补：内网 http、公网 https', () {
      final lan = NetworkUrlPolicy.inspect('192.168.1.x:8787');
      expect(lan.allowed, isTrue);
      expect(lan.uri.toString(), 'http://192.168.1.x:8787');

      final pub = NetworkUrlPolicy.inspect('abc.trycloudflare.com');
      expect(pub.allowed, isTrue);
      expect(pub.uri.toString(), startsWith('https://'));

      final local = NetworkUrlPolicy.inspect('localhost:8787');
      expect(local.uri.toString(), 'http://localhost:8787');
    });

    test('ws/wss 只在明确允许时接受', () {
      expect(NetworkUrlPolicy.inspect('wss://abc.trycloudflare.com/ws').allowed, isFalse);
      final relay = NetworkUrlPolicy.inspect('wss://abc.trycloudflare.com/ws', allowWebSocket: true);
      expect(relay.allowed, isTrue);
      expect(relay.secure, isTrue);

      final plainRelay = NetworkUrlPolicy.inspect('ws://192.168.1.5:8787/ws', allowWebSocket: true);
      expect(plainRelay.allowed, isTrue);
      expect(plainRelay.warning, contains('未加密'));

      final badRelay = NetworkUrlPolicy.inspect('ws://abc.trycloudflare.com/ws', allowWebSocket: true);
      expect(badRelay.allowed, isFalse);
    });

    test('空地址、乱七八糟的协议、看不懂的主机都给出人话', () {
      expect(NetworkUrlPolicy.inspect('   ').error, contains('请先填写'));
      expect(NetworkUrlPolicy.inspect('ftp://example.com').error, contains('只支持'));
      // 端口写错时 host 仍然能解析出来，交由连接本身报错
      expect(NetworkUrlPolicy.inspect('https://').allowed, isFalse);
    });
  });
}
