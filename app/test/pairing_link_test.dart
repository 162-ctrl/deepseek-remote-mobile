import 'package:deepseek_remote_app/services/pairing_link.dart';
import 'package:flutter_test/flutter_test.dart';

/// M2.7：二维码/粘贴文本 → 地址 + 匹配码 的解析规则。
///
/// 这些字符串就是 `dsh-plugin-m1` 配网页真实生成的二维码内容，
/// 以及用户从聊天软件转发过来时可能出现的几种变体。
void main() {
  group('PairingLink.tryParse · 正常形态', () {
    test('局域网：地址 + fragment 里的匹配码', () {
      final link = PairingLink.tryParse('http://192.168.1.x:8787#c=000000');
      expect(link, isNotNull);
      expect(link!.baseUrl, 'http://192.168.1.x:8787');
      expect(link.pairingCode, '000000');
      expect(link.hasCode, isTrue);
    });

    test('公网：cloudflared 的 https 地址 + 匹配码', () {
      final link = PairingLink.tryParse(
        'https://<公网隧道>.trycloudflare.com#c=000000',
      );
      expect(link, isNotNull);
      expect(
        link!.baseUrl,
        'https://<公网隧道>.trycloudflare.com',
      );
      expect(link.pairingCode, '000000');
    });

    test('缺协议：局域网补 http，不给公网域名补 http', () {
      expect(
        PairingLink.tryParse('192.168.1.x:8787#c=123456')!.baseUrl,
        'http://192.168.1.x:8787',
      );
      expect(
        PairingLink.tryParse('abc-xyz.trycloudflare.com#c=123456')!.baseUrl,
        'https://<公网隧道>.trycloudflare.com',
      );
      expect(
        PairingLink.tryParse('localhost:8787#c=123456')!.baseUrl,
        'http://localhost:8787',
      );
    });

    test('query 形式与自定义 scheme 都认', () {
      final query = PairingLink.tryParse('http://10.0.0.8:8787/?code=456789');
      expect(query, isNotNull);
      expect(query!.baseUrl, 'http://10.0.0.8:8787');
      expect(query.pairingCode, '456789');

      final deep = PairingLink.tryParse('dshremote://192.168.1.5:8787#c=998877');
      expect(deep, isNotNull);
      expect(deep!.baseUrl, 'http://192.168.1.5:8787');
      expect(deep.pairingCode, '998877');
    });

    test('只扫到地址（没带码）也能解析，交给界面让用户手输', () {
      final link = PairingLink.tryParse('http://192.168.1.x:8787');
      expect(link, isNotNull);
      expect(link!.baseUrl, 'http://192.168.1.x:8787');
      expect(link.pairingCode, isNull);
      expect(link.hasCode, isFalse);
    });

    test('保留原始文本，便于界面回显', () {
      const raw = 'http://192.168.1.x:8787#c=000000';
      expect(PairingLink.tryParse(raw)!.raw, raw);
    });

    test('误粘贴的 /ws 尾巴会被 normalizeBaseUrl 去掉', () {
      expect(
        PairingLink.tryParse('192.168.1.x:8787/ws#c=123456')!.baseUrl,
        'http://192.168.1.x:8787',
      );
    });
  });

  group('PairingLink.tryParse · 拒绝无效内容', () {
    test('空串 / 空白', () {
      expect(PairingLink.tryParse(''), isNull);
      expect(PairingLink.tryParse('   '), isNull);
    });

    test('只扫到一串数字或一句普通文本', () {
      expect(PairingLink.tryParse('000000'), isNull);
      expect(PairingLink.tryParse('这不是二维码'), isNull);
      expect(PairingLink.tryParse('https://www.bilibili.com'), isNotNull);
    });

    test('不认识的 scheme 直接拒绝', () {
      expect(PairingLink.tryParse('weixin://dl/business?t=abc'), isNull);
      expect(PairingLink.tryParse('mailto:a@b.com'), isNull);
    });

    test('码不是 4–8 位数字时不采纳，但地址仍然可用', () {
      final link = PairingLink.tryParse('http://192.168.1.x:8787#c=abc');
      expect(link, isNotNull);
      expect(link!.pairingCode, isNull);
    });
  });
}
