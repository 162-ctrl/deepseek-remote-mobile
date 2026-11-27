import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseek_remote_app/data/live_store.dart';
import 'package:deepseek_remote_app/screens/connect_screen.dart';
import 'package:deepseek_remote_app/services/pairing_api.dart';
import 'package:deepseek_remote_app/theme/app_theme.dart';

/// M4.44：连接页在发请求之前就要按 NetworkUrlPolicy 判断，公网明文一律拒绝。
class _RecordingStore extends LiveStore {
  final List<String> healthChecks = <String>[];
  final List<String> connects = <String>[];

  @override
  bool get isConnected => false;

  @override
  String get deviceName => 'DeepSeek Harness';

  @override
  Future<HealthResult> checkHealth(String rawUrl, {PairingApi? api}) async {
    healthChecks.add(rawUrl);
    return const HealthResult(
      status: 'ok',
      version: '0.2.31',
      agentOnline: true,
      apps: 1,
    );
  }

  @override
  Future<void> connect(String rawUrl, {String? code}) async {
    connects.add(rawUrl);
  }
}

Widget _wrap(LiveStore store) {
  return MaterialApp(
    theme: buildAppTheme(Brightness.light),
    home: ConnectScreen(store: store),
  );
}

void main() {
  group('M4.44 连接页的地址策略', () {
    testWidgets('公网 http 点「测试连接」被拒绝，且不发起请求', (tester) async {
      final store = _RecordingStore();
      addTearDown(store.dispose);
      await tester.binding.setSurfaceSize(const Size(420, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(_wrap(store));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'http://public.example.com');
      await tester.pumpAndSettle();

      await tester.tap(find.text('测试连接'));
      await tester.pumpAndSettle();

      expect(find.textContaining('公网地址必须用 https://'), findsWidgets);
      expect(store.healthChecks, isEmpty);
    });

    testWidgets('公网 http 点「连接」被拒绝，且不发起连接', (tester) async {
      final store = _RecordingStore();
      addTearDown(store.dispose);
      await tester.binding.setSurfaceSize(const Size(420, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(_wrap(store));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'http://public.example.com');
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, '连接'));
      await tester.pumpAndSettle();

      expect(find.textContaining('公网地址必须用 https://'), findsWidgets);
      expect(store.connects, isEmpty);
    });

    testWidgets('局域网明文放行，但提示未加密', (tester) async {
      final store = _RecordingStore();
      addTearDown(store.dispose);
      await tester.binding.setSurfaceSize(const Size(420, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(_wrap(store));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'http://192.168.1.x:8787');
      await tester.pumpAndSettle();

      expect(find.textContaining('此连接未加密'), findsOneWidget);
      expect(find.textContaining('公网地址必须用 https://'), findsNothing);

      await tester.tap(find.text('测试连接'));
      await tester.pumpAndSettle();

      // 内网明文只是提示，仍然会去探活。
      expect(store.healthChecks, <String>['http://192.168.1.x:8787']);
    });
  });
}
