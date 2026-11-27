import 'dart:convert';
import 'dart:io';

import 'package:deepseek_remote_app/data/live_store.dart';
import 'package:deepseek_remote_app/screens/plugins_screen.dart';
import 'package:deepseek_remote_app/services/history_api.dart';
import 'package:deepseek_remote_app/services/pairing_api.dart';
import 'package:deepseek_remote_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const String _base = 'https://relay.example.com';

class _Call {
  _Call(this.method, this.uri, this.headers, this.body);

  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final Map<String, dynamic>? body;
}

/// 注入式 HTTP 记录器：既能断言请求，也能按路径返回不同响应。
class _Recorder {
  final List<_Call> calls = <_Call>[];

  AuthorizedHttpSender handler(
    JsonHttpResponse Function(_Call call) respond,
  ) {
    return (String method, Uri uri, Map<String, String> headers,
        Map<String, dynamic>? body) async {
      final call = _Call(method, uri, headers, body);
      calls.add(call);
      return respond(call);
    };
  }

  _Call get last => calls.last;
}

JsonHttpResponse _json(Object body, {int status = 200}) =>
    JsonHttpResponse(status, jsonEncode(body));

JsonHttpResponse _notFound() => const JsonHttpResponse(
      404,
      '{"code":"BAD_REQUEST","message":"not found"}',
    );

HistoryApi _api(_Recorder rec, JsonHttpResponse Function(_Call call) respond) =>
    HistoryApi(sender: rec.handler(respond));

/// 不联网的假 LiveStore：只覆写插件页要用的几个方法。
///
/// widget 测试里不能走真实 `connect()`——它内部有 `Future.delayed`，在
/// testWidgets 的假时钟下不会自己推进，会导致 `await connect()` 永远挂起。
class _FakePluginStore extends LiveStore {
  final List<String> toggledBundles = <String>[];
  final List<String> toggledPlugins = <String>[];

  @override
  Future<List<PluginBundle>> listPluginBundles() async {
    throw const PairingApiException('旧电脑端不支持插件包接口', statusCode: 404);
  }

  @override
  Future<List<PluginInfo>> listPlugins() async => const <PluginInfo>[
        PluginInfo(
          id: 'm1',
          name: 'dsh-plugin-m1',
          enabled: true,
          phase: 'active',
          readOnly: false,
        ),
        PluginInfo(
          id: 'core',
          name: 'core-runtime',
          enabled: true,
          phase: 'active',
          readOnly: false,
        ),
      ];

  @override
  Future<MarketSearchResult> marketSearch({String? url, String query = ''}) async {
    throw const PairingApiException('旧电脑端不支持插件市场', statusCode: 404);
  }

  /// M4.18：旧电脑端没有目录接口，手机端要退化成「升级电脑端」的提示。
  @override
  Future<PluginCatalog> pluginCatalog() async {
    throw const PairingApiException('旧电脑端不支持插件目录', statusCode: 404);
  }

  @override
  Future<void> setPluginEnabled(String id, bool enabled) async {
    toggledPlugins.add(id);
  }

  @override
  Future<void> setBundleEnabled(String name, bool enabled) async {
    toggledBundles.add(name);
  }
}

void main() {
  group('插件包 bundles（M3.6）', () {
    test('解析 bundle 名称、版本、描述与子插件（enabled 可为 null）', () async {
      final rec = _Recorder();
      final api = _api(
        rec,
        (_) => _json(<String, dynamic>{
          'bundles': <Map<String, dynamic>>[
            <String, dynamic>{
              'name': '@deepseek-ai/dsh-plugin-m1',
              'version': '0.4.0',
              'description': 'HTTP + WSS 中继',
              'enabled': true,
              'installed': true,
              'removable': true,
              'plugins': <Map<String, dynamic>>[
                <String, dynamic>{
                  'id': 'relay',
                  'name': 'M1 中继',
                  'enabled': true,
                },
                <String, dynamic>{
                  'id': 'lab',
                  'name': '实验插件',
                  'enabled': null,
                },
              ],
            },
            <String, dynamic>{'name': 'dsh-plugin-notes'},
          ],
        }),
      );

      final bundles = await api.listPluginBundles(_base, token: 'tok-123');

      expect(rec.last.method, 'GET');
      expect(rec.last.uri.path, '/api/v1/desktop/plugins/bundles');
      expect(rec.last.headers[HttpHeaders.authorizationHeader],
          'Bearer tok-123');
      expect(bundles, hasLength(2));
      expect(bundles.first.name, '@deepseek-ai/dsh-plugin-m1');
      expect(bundles.first.displayName, 'dsh-plugin-m1');
      expect(bundles.first.version, '0.4.0');
      expect(bundles.first.description, 'HTTP + WSS 中继');
      expect(bundles.first.enabled, isTrue);
      expect(bundles.first.plugins, hasLength(2));
      expect(bundles.first.plugins.first.name, 'M1 中继');
      expect(bundles.first.plugins.first.isEnabled, isTrue);
      // enabled == null 表示未知：UI 不显示开关，也不当作已启用。
      expect(bundles.first.plugins.last.enabled, isNull);
      expect(bundles.first.plugins.last.isEnabled, isFalse);
      expect(bundles.last.enabled, isFalse);
    });

    test('旧版电脑端 404 时抛 statusCode=404，供 UI 回退到 listPlugins', () async {
      final rec = _Recorder();
      final api = _api(rec, (_) => _notFound());

      await expectLater(
        api.listPluginBundles(_base, token: 'tok-123'),
        throwsA(
          isA<PairingApiException>().having(
            (e) => e.statusCode,
            'statusCode',
            404,
          ),
        ),
      );
    });

    test('设置 bundle 开关：POST 名称与 enabled', () async {
      final rec = _Recorder();
      final api = _api(rec, (_) => _json(<String, dynamic>{'ok': true}));

      await api.setBundleEnabled(
        _base,
        token: 'tok-123',
        name: 'dsh-plugin-m1',
        enabled: false,
      );

      expect(rec.last.method, 'POST');
      expect(rec.last.uri.path, '/api/v1/desktop/plugins/bundles/enabled');
      expect(rec.last.body, <String, dynamic>{
        'name': 'dsh-plugin-m1',
        'enabled': false,
      });
    });
  });

  group('插件市场搜索（M3.6）', () {
    test('解析索引、条目标题/作者/tags/已安装版本', () async {
      final rec = _Recorder();
      final api = _api(
        rec,
        (_) => _json(<String, dynamic>{
          'indexes': <Object>[
            <String, dynamic>{
              'url': 'https://market.example.com/index.json',
              'title': '官方索引',
              'description': '稳定版插件',
            },
            'https://mirror.example.com/index.json',
          ],
          'source': 'official',
          'query': 'relay',
          'entries': <Map<String, dynamic>>[
            <String, dynamic>{
              'name': '@deepseek-ai/dsh-plugin-m1',
              'title': 'M1 中继',
              'version': '0.4.0',
              'description': '把手机接到电脑',
              'author': 'DeepSeek',
              'tags': <String>['远程', 'relay'],
              'installed': true,
              'installedVersion': '0.3.9',
            },
            <String, dynamic>{'name': 'dsh-plugin-empty'},
          ],
        }),
      );

      final result = await api.marketSearch(
        _base,
        token: 'tok-123',
        url: 'https://market.example.com/index.json',
        query: ' relay ',
      );

      expect(rec.last.uri.path, '/api/v1/desktop/plugins/market');
      expect(rec.last.uri.queryParameters['url'],
          'https://market.example.com/index.json');
      expect(rec.last.uri.queryParameters['query'], 'relay');
      expect(result.indexes, hasLength(2));
      expect(result.indexDetails.first.label, '官方索引');
      expect(result.indexDetails.last.url,
          'https://mirror.example.com/index.json');
      expect(result.source, 'official');
      expect(result.query, 'relay');
      expect(result.entries, hasLength(2));
      final entry = result.entries.first;
      expect(entry.displayTitle, 'M1 中继');
      expect(entry.version, '0.4.0');
      expect(entry.author, 'DeepSeek');
      expect(entry.tags, <String>['远程', 'relay']);
      expect(entry.installed, isTrue);
      expect(entry.installedVersion, '0.3.9');
      expect(result.entries.last.displayTitle, 'dsh-plugin-empty');
      expect(result.entries.last.installed, isFalse);
    });

    test('不带 url/query 时不附加查询参数', () async {
      final rec = _Recorder();
      final api = _api(rec, (_) => _json(<String, dynamic>{'entries': []}));

      await api.marketSearch(_base, token: 'tok-123');

      expect(rec.last.uri.path, '/api/v1/desktop/plugins/market');
      expect(rec.last.uri.queryParameters, isEmpty);
    });
  });

  group('安装 / 卸载（M3.6）', () {
    test('安装返回 pendingBuilds 与 nextStep，二次确认后带上 approvedBuilds', () async {
      final rec = _Recorder();
      final api = _api(
        rec,
        (call) => _json(<String, dynamic>{
          'ok': true,
          'pendingBuilds': <String>['esbuild', '@scope/native'],
          'nextStep': '确认后会执行构建脚本',
          'approvedBuilds': call.body?['approvedBuilds'],
        }),
      );

      final first = await api.installPlugin(
        _base,
        token: 'tok-123',
        spec: '@deepseek-ai/dsh-plugin-m1',
      );
      expect(rec.last.method, 'POST');
      expect(rec.last.uri.path, '/api/v1/desktop/plugins/market/install');
      expect(rec.last.body, <String, dynamic>{
        'spec': '@deepseek-ai/dsh-plugin-m1',
      });
      expect(first['ok'], isTrue);
      final pending = (first['pendingBuilds'] as List).cast<String>();
      expect(pending, <String>['esbuild', '@scope/native']);
      expect(first['nextStep'], '确认后会执行构建脚本');

      final second = await api.installPlugin(
        _base,
        token: 'tok-123',
        spec: '@deepseek-ai/dsh-plugin-m1',
        approvedBuilds: pending,
      );
      expect(rec.last.body, <String, dynamic>{
        'spec': '@deepseek-ai/dsh-plugin-m1',
        'approvedBuilds': <String>['esbuild', '@scope/native'],
      });
      expect(second['approvedBuilds'], <String>['esbuild', '@scope/native']);
    });

    test('卸载：POST 插件名', () async {
      final rec = _Recorder();
      final api = _api(rec, (_) => _json(<String, dynamic>{'ok': true}));

      await api.removePlugin(
        _base,
        token: 'tok-123',
        name: '@deepseek-ai/dsh-plugin-m1',
      );

      expect(rec.last.method, 'POST');
      expect(rec.last.uri.path, '/api/v1/desktop/plugins/market/remove');
      expect(rec.last.body, <String, dynamic>{
        'name': '@deepseek-ai/dsh-plugin-m1',
      });
      expect(rec.last.headers[HttpHeaders.authorizationHeader],
          'Bearer tok-123');
    });
  });

  group('插件页降级（旧版电脑端）', () {
    testWidgets('bundles 404 回退插件列表并过滤系统模块；市场 404 提示升级', (tester) async {
      final store = _FakePluginStore();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: PluginsScreen(liveStore: store),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('当前电脑插件版本较旧'), findsOneWidget);
      expect(find.text('dsh-plugin-m1'), findsOneWidget);
      expect(find.text('core-runtime'), findsNothing);
      expect(find.text('系统内置（1）'), findsOneWidget);

      await tester.tap(find.text('插件市场'));
      await tester.pumpAndSettle();
      // M4.18：市场主来源改成电脑端插件目录；读不到目录时给出可重试的提示，
      // 而不是像旧版那样只说「输入关键字搜索」（那台电脑可能一个索引都没配）。
      expect(
        find.textContaining('旧电脑端不支持插件目录'),
        findsOneWidget,
      );
      expect(find.text('读取目录'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      store.dispose();
    });
  });
}
