import 'dart:convert';

import 'package:deepseek_remote_app/data/live_store.dart';
import 'package:deepseek_remote_app/screens/assistant_screen.dart';
import 'package:deepseek_remote_app/services/history_api.dart';
import 'package:deepseek_remote_app/services/pairing_api.dart';
import 'package:deepseek_remote_app/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Call {
  _Call(this.method, this.uri, this.body);

  final String method;
  final Uri uri;
  final Map<String, dynamic>? body;
}

class _Recorder {
  final List<_Call> calls = <_Call>[];

  AuthorizedHttpSender sender(JsonHttpResponse Function(_Call call) respond) {
    return (String method, Uri uri, Map<String, String> headers,
        Map<String, dynamic>? body) async {
      final call = _Call(method, uri, body);
      calls.add(call);
      return respond(call);
    };
  }
}

JsonHttpResponse _json(Object body, {int status = 200}) =>
    JsonHttpResponse(status, jsonEncode(body));

/// 记录手机端把附件传到了哪个工作区。
class _FakeUploadStore extends LiveStore {
  final List<String?> uploadedWorkspaces = <String?>[];
  final List<String> sentPrompts = <String>[];

  @override
  bool get isConnected => true;

  @override
  String get deviceName => 'DeepSeek Harness';

  @override
  String? get pendingWorkspacePath => 'D:\\work\\项目';

  @override
  Future<DesktopUpload> uploadDesktopFile({
    required String name,
    required List<int> bytes,
    String? workspace,
  }) async {
    uploadedWorkspaces.add(workspace);
    return DesktopUpload(
      name: name,
      path: 'D:\\work\\$workspace\\手机附件\\$name',
      size: bytes.length,
    );
  }

  @override
  void sendPrompt(String text) {
    sentPrompts.add(text);
  }
}

void main() {
  group('HistoryApi 附件上传带工作区（M4.2）', () {
    test('workspace 会写进请求体（去掉首尾空格）', () async {
      final recorder = _Recorder();
      final api = HistoryApi(
        sender: recorder.sender((call) => _json(<String, dynamic>{
              'ok': true,
              'name': call.body?['name'],
              'path': 'C:\\work\\项目\\手机附件\\a.txt',
              'size': 1,
            })),
      );
      final uploaded = await api.uploadDesktopFile(
        'http://127.0.0.1:8787',
        token: 'tk',
        name: 'a.txt',
        bytes: const <int>[1],
        workspace: '  项目  ',
      );
      expect(uploaded.name, 'a.txt');
      expect(recorder.calls.single.method, 'POST');
      expect(recorder.calls.single.uri.path, '/api/v1/desktop/upload');
      expect(recorder.calls.single.body?['workspace'], '项目');
    });

    test('没有工作区时不带 workspace 字段（兼容旧插件）', () async {
      final recorder = _Recorder();
      final api = HistoryApi(
        sender: recorder.sender((call) =>
            _json(<String, dynamic>{'ok': true, 'path': 'C:\\x\\a.txt'})),
      );
      await api.uploadDesktopFile(
        'http://127.0.0.1:8787',
        token: 'tk',
        name: 'a.txt',
        bytes: const <int>[1],
      );
      expect(recorder.calls.single.body!.containsKey('workspace'), isFalse);
    });
  });

  group('AI 助手页（M4.2）', () {
    testWidgets('电脑档：附件按钮常驻可见（手机档是云端对话）', (tester) async {
      final store = _FakeUploadStore();
      await tester.binding.setSurfaceSize(const Size(420, 900));
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: AssistantScreen(liveStore: store),
      ));
      await tester.pump();

      // M4.6：默认停在本机对话档（云端直连），点「远程电脑」切到和电脑对话。
      expect(find.text('本机对话'), findsOneWidget);
      expect(find.text('远程电脑'), findsOneWidget);
      await tester.tap(find.text('远程电脑'));
      await tester.pump();

      // 附件入口常驻：拍照 / 相册 / 文件（快捷胶囊行里，不需要先点「+」）。
      expect(find.text('拍照'), findsWidgets);
      expect(find.text('相册'), findsWidgets);
      expect(find.text('文件'), findsWidgets);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      store.dispose();
      await tester.binding.setSurfaceSize(null);
    });

    testWidgets('发送附件会带上当前工作区名（电脑端据此落盘）', (tester) async {
      final store = _FakeUploadStore();
      await tester.binding.setSurfaceSize(const Size(420, 900));
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: AssistantScreen(liveStore: store),
      ));
      await tester.pump();

      await tester.tap(find.text('远程电脑'));
      await tester.pump();

      final state = tester.state(find.byType(AssistantScreen));
      // 直接调用页面私有的上传+发送逻辑不需要碰私有类型：通过附件按钮注入不了
      // 沙盒文件，这里用 State 的动态调用触发同一条路径。
      await (state as dynamic).attachForTest(
        name: 'note.txt',
        bytes: const <int>[65, 66, 67],
      );
      await tester.pump();
      expect(find.text('note.txt'), findsOneWidget);

      await (state as dynamic).sendForTest('看看这个文件');
      await tester.pump();

      expect(store.uploadedWorkspaces, <String?>['项目']);
      expect(store.sentPrompts, hasLength(1));
      expect(store.sentPrompts.single, contains('看看这个文件'));
      expect(store.sentPrompts.single, contains('D:\\work\\项目\\手机附件\\note.txt'));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      store.dispose();
      await tester.binding.setSurfaceSize(null);
    });
  });
}
