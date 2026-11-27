// M4.18：手机端「插件市场」与电脑端同步的回归测试。
//
// 背景：手机上的插件市场以前只读电脑端「设置 → 插件市场」里手配的第三方索引，
// 一台没配索引的电脑上永远是空的——可电脑端自己的市场有四十多个可安装的插件包。
// 现在市场的主来源是 `GET /desktop/plugins/catalog`（Host `pluginManager.listBundles()`），
// 这里断言：
//   1. 目录 JSON 解析出官方标记、安装用的 spec、已安装状态；
//   2. 请求打到正确的接口并带上语言参数；
//   3. 市场页真的把目录列出来了，且搜索是在本地过滤目录，不再依赖索引。
import 'dart:convert';

import 'package:deepseek_remote_app/data/live_store.dart';
import 'package:deepseek_remote_app/screens/plugins_screen.dart';
import 'package:deepseek_remote_app/services/history_api.dart';
import 'package:deepseek_remote_app/services/pairing_api.dart';
import 'package:deepseek_remote_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const String _base = 'http://127.0.0.1:8787';

void main() {
  group('插件目录（M4.18）', () {
    test('解析官方标记、安装用的 spec 与已安装状态', () {
      final catalog = PluginCatalog.fromJson(<String, dynamic>{
        'supported': true,
        'language': 'zh-CN',
        'bundles': <dynamic>[
          <String, dynamic>{
            'name': '@deepseek-ai/dsh-demo',
            'title': '示例插件',
            'description': '说明文字',
            'official': true,
            'availability': 'installation',
            'spec': '@deepseek-ai/dsh-demo@0.2.2-rc.1',
            'version': '0.2.2-rc.1',
            'installed': false,
            'removable': false,
            'listedByDefault': true,
          },
          <String, dynamic>{
            'name': 'local-bundle',
            'title': '',
            'official': false,
            'installed': true,
            'removable': true,
          },
          // 没有包名的条目要被剔掉，否则列表里会出现空白卡片。
          <String, dynamic>{'name': ''},
        ],
      });

      expect(catalog.supported, isTrue);
      expect(catalog.entries.length, 2);
      final first = catalog.entries.first;
      expect(first.displayTitle, '示例插件');
      expect(first.official, isTrue);
      expect(first.spec, '@deepseek-ai/dsh-demo@0.2.2-rc.1');
      expect(first.version, '0.2.2-rc.1');
      expect(first.installed, isFalse);
      // 没有标题时退打包名，卡片不会只剩一个版本号。
      expect(catalog.entries[1].displayTitle, 'local-bundle');
      expect(catalog.entries[1].installed, isTrue);
      expect(catalog.entries[1].removable, isTrue);
    });

    test('请求 /desktop/plugins/catalog 并带 language', () async {
      late Uri seen;
      late Map<String, String> headers;
      final api = HistoryApi(
        sender: (
          String method,
          Uri uri,
          Map<String, String> requestHeaders,
          Map<String, dynamic>? body,
        ) async {
          seen = uri;
          headers = requestHeaders;
          return JsonHttpResponse(
            200,
            jsonEncode(<String, dynamic>{
              'supported': true,
              'language': 'zh-CN',
              'bundles': <dynamic>[
                <String, dynamic>{'name': 'a', 'official': true},
              ],
            }),
          );
        },
      );
      final result = await api.listPluginCatalog(
        _base,
        token: 'tok-123',
        language: 'zh-CN',
      );

      expect(seen.path, '/api/v1/desktop/plugins/catalog');
      expect(seen.queryParameters['language'], 'zh-CN');
      expect(headers['authorization'], 'Bearer tok-123');
      expect(result.entries.single.name, 'a');
    });

    testWidgets('市场页列出电脑端目录，并在本地按关键字过滤', (tester) async {
      final store = _FakeCatalogStore();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: PluginsScreen(liveStore: store),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('插件市场'));
      await tester.pumpAndSettle();

      expect(find.text('示例插件'), findsOneWidget);
      expect(find.text('另一个插件'), findsOneWidget);
      expect(find.text('官方'), findsOneWidget);
      expect(find.textContaining('电脑端插件市场'), findsWidgets);

      // 本地过滤：不用再点「搜索」，也不用电脑端配索引。
      await tester.enterText(find.byType(TextField).first, '另一个');
      await tester.pumpAndSettle();
      expect(find.text('示例插件'), findsNothing);
      expect(find.text('另一个插件'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });
}

class _FakeCatalogStore extends LiveStore {
  @override
  Future<List<PluginBundle>> listPluginBundles() async => const <PluginBundle>[];

  @override
  Future<List<PluginInfo>> listPlugins() async => const <PluginInfo>[];

  @override
  Future<MarketSearchResult> marketSearch({String? url, String query = ''}) async =>
      const MarketSearchResult(indexes: <String>[], entries: <MarketEntry>[]);

  @override
  Future<PluginCatalog> pluginCatalog() async => PluginCatalog.fromJson(
        <String, dynamic>{
          'supported': true,
          'language': 'zh-CN',
          'bundles': <dynamic>[
            <String, dynamic>{
              'name': '@deepseek-ai/dsh-demo',
              'title': '示例插件',
              'description': '官方示例',
              'official': true,
              'spec': '@deepseek-ai/dsh-demo@0.2.2-rc.1',
              'version': '0.2.2-rc.1',
            },
            <String, dynamic>{
              'name': 'local-bundle',
              'title': '另一个插件',
              'description': '本地插件',
              'official': false,
              'version': '1.0.0',
            },
          ],
        },
      );
}
