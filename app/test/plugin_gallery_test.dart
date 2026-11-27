import 'dart:convert';
import 'dart:io';

import 'package:deepseek_remote_app/data/live_store.dart';
import 'package:deepseek_remote_app/screens/plugin_gallery_screen.dart';
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

class _Recorder {
  final List<_Call> calls = <_Call>[];

  AuthorizedHttpSender handler(JsonHttpResponse Function(_Call call) respond) {
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

/// 假 LiveStore：不联网，只覆写画廊页要用的接口。
class _FakeGalleryStore extends LiveStore {
  _FakeGalleryStore({this.gallery, this.error});

  PluginGallery? gallery;
  Object? error;
  final List<String> toggles = <String>[];

  @override
  Future<PluginGallery> pluginGallery() async {
    final failure = error;
    if (failure != null) {
      error = null;
      throw failure;
    }
    return gallery ?? const PluginGallery();
  }

  @override
  Future<void> setPluginEnabled(String id, bool enabled) async {
    toggles.add('$id:$enabled');
    final current = gallery;
    if (current == null) return;
    gallery = PluginGallery(
      groups: <PluginGalleryGroup>[
        for (final group in current.groups)
          PluginGalleryGroup(
            key: group.key,
            title: group.title,
            plugins: <PluginGalleryItem>[
              for (final plugin in group.plugins)
                if (plugin.id == id)
                  PluginGalleryItem(
                    id: plugin.id,
                    name: plugin.name,
                    description: plugin.description,
                    experimental: plugin.experimental,
                    enabled: enabled,
                    version: plugin.version,
                  )
                else
                  plugin,
            ],
          ),
      ],
    );
  }
}

PluginGallery _sampleGallery() => const PluginGallery(
      groups: <PluginGalleryGroup>[
        PluginGalleryGroup(
          key: 'builtin',
          title: '内置插件配置',
          plugins: <PluginGalleryItem>[
            PluginGalleryItem(
              id: 'subagent',
              name: '子智能体',
              description: '设置子智能体的递归层级、数量和模型。',
            ),
            PluginGalleryItem(
              id: 'web-search',
              name: '网页搜索',
              description: '设置 DeepSeek 的搜索提供方。',
            ),
          ],
        ),
        PluginGalleryGroup(
          key: 'experimental',
          title: '实验性插件',
          plugins: <PluginGalleryItem>[
            PluginGalleryItem(
              id: 'team',
              name: '智能体团队',
              description: '让你对话的智能体把工作分给有名字的队友。',
              experimental: true,
              enabled: false,
            ),
          ],
        ),
      ],
    );

void main() {
  group('已安装插件画廊（M4.1）', () {
    test('PluginGallery.fromJson 解析分组、实验性标记与启用状态', () {
      final gallery = PluginGallery.fromJson(<String, dynamic>{
        'groups': <Map<String, dynamic>>[
          <String, dynamic>{
            'key': 'experimental',
            'title': '实验性插件',
            'plugins': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'team',
                'name': '智能体团队',
                'description': '队友协作',
                'experimental': true,
                'enabled': false,
              },
            ],
          },
        ],
      });
      expect(gallery.total, 1);
      expect(gallery.groups.single.title, '实验性插件');
      final item = gallery.groups.single.plugins.single;
      expect(item.name, '智能体团队');
      expect(item.experimental, isTrue);
      expect(item.enabled, isFalse);
    });

    test('HistoryApi.pluginGallery 走 /desktop/plugins/gallery 并带 Bearer', () async {
      final rec = _Recorder();
      final api = HistoryApi(
        sender: rec.handler((_) => _json(<String, dynamic>{
              'groups': <Map<String, dynamic>>[
                <String, dynamic>{'key': 'builtin', 'title': '内置插件配置', 'plugins': <Object>[]},
              ],
            })),
      );
      final gallery = await api.pluginGallery(_base, token: 'tk');
      expect(gallery.groups.single.title, '内置插件配置');
      expect(rec.last.method, 'GET');
      expect(rec.last.uri.path, '/api/v1/desktop/plugins/gallery');
      expect(rec.last.headers[HttpHeaders.authorizationHeader], 'Bearer tk');
    });

    test('MarketEntry 解析下载量与星标并给出紧凑文案', () {
      final entry = MarketEntry.fromJson(<String, dynamic>{
        'name': 'billion-context',
        'downloads': 3188100,
        'stars': 6900,
      });
      expect(entry.downloadsLabel, '319万');
      expect(entry.starsLabel, '6.9k');
      expect(MarketEntry.fromJson(<String, dynamic>{'name': 'x'}).downloadsLabel,
          isNull);
    });

    test('MarketSearchResult 识别 defaultIndex 兜底', () {
      final result = MarketSearchResult.fromJson(<String, dynamic>{
        'defaultIndex': true,
        'source': 'https://index.example.com/index.json',
        'entries': <Object>[],
      });
      expect(result.defaultIndex, isTrue);
    });

    testWidgets('画廊按分组渲染、标出「实验性」并可切换开关', (WidgetTester tester) async {
      final store = _FakeGalleryStore(gallery: _sampleGallery());
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: PluginGalleryScreen(liveStore: store),
      ));
      await tester.pumpAndSettle();

      expect(find.text('内置插件配置 · 2'), findsOneWidget);
      expect(find.text('实验性插件 · 1'), findsOneWidget);
      expect(find.text('子智能体'), findsOneWidget);
      expect(find.text('实验性'), findsOneWidget);
      expect(find.text('3 个插件 · 开关与电脑端「设置 → 插件」同源，重启 DSH 后完全生效'),
          findsOneWidget);

      final switches = tester.widgetList<Switch>(find.byType(Switch)).toList();
      expect(switches.length, 3);
      await tester.tap(find.byType(Switch).last);
      await tester.pumpAndSettle();
      expect(store.toggles, <String>['team:true']);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      store.dispose();
    });

    testWidgets('搜索框按名称过滤', (WidgetTester tester) async {
      final store = _FakeGalleryStore(gallery: _sampleGallery());
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: PluginGalleryScreen(liveStore: store),
      ));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '网页');
      await tester.pumpAndSettle();
      expect(find.text('网页搜索'), findsOneWidget);
      expect(find.text('子智能体'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      store.dispose();
    });

    testWidgets('404 时提示升级电脑端插件', (WidgetTester tester) async {
      final store = _FakeGalleryStore(
        error: const PairingApiException('not found', statusCode: 404),
      );
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: PluginGalleryScreen(liveStore: store),
      ));
      await tester.pumpAndSettle();
      expect(find.textContaining('版本过低'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      store.dispose();
    });

    testWidgets('插件页「已安装」Tab 顶部有「浏览本地插件」入口', (WidgetTester tester) async {
      final store = _FakeInstalledStore();
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: PluginsScreen(liveStore: store),
      ));
      await tester.pumpAndSettle();
      expect(find.text('浏览本地插件'), findsOneWidget);
      await tester.tap(find.text('浏览本地插件'));
      await tester.pumpAndSettle();
      expect(find.byType(PluginGalleryScreen), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      store.dispose();
    });
  });
}

class _FakeInstalledStore extends LiveStore {
  @override
  Future<List<PluginBundle>> listPluginBundles() async => const <PluginBundle>[
        PluginBundle(
          name: '@deepseek-ai/dsh-base',
          version: '0.2.2-rc.1',
          description: 'DSH 核心',
          enabled: true,
        ),
      ];

  @override
  Future<PluginGallery> pluginGallery() async => _sampleGallery();

  @override
  Future<MarketSearchResult> marketSearch({String? url, String query = ''}) async =>
      const MarketSearchResult();

  @override
  Future<void> setPluginEnabled(String id, bool enabled) async {}

  @override
  Future<void> setBundleEnabled(String name, bool enabled) async {}
}
