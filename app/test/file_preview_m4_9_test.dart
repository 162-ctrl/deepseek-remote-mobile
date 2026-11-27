import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deepseek_remote_app/data/live_store.dart';
import 'package:deepseek_remote_app/screens/file_viewer_screen.dart';
import 'package:deepseek_remote_app/services/file_opener.dart';
import 'package:deepseek_remote_app/services/pairing_api.dart';
import 'package:deepseek_remote_app/services/workspace_models.dart';
import 'package:deepseek_remote_app/theme/app_theme.dart';

/// M4.9：工作区里的图片 / PDF / Office 不再直接报「无法预览」。
void main() {
  group('previewKindOf 按扩展名选预览方式', () {
    test('图片走 App 内预览', () {
      expect(previewKindOf('a.png'), FilePreviewKind.image);
      expect(previewKindOf('A.JPG'), FilePreviewKind.image);
      expect(previewKindOf('x/y/photo.webp'), FilePreviewKind.image);
      expect(previewKindOf('截图.heic'), FilePreviewKind.image);
    });

    test('PDF 与 Office 走系统应用', () {
      expect(previewKindOf('report.pdf'), FilePreviewKind.pdf);
      expect(previewKindOf('074_报告.docx'), FilePreviewKind.office);
      expect(previewKindOf('data.xlsx'), FilePreviewKind.office);
      expect(previewKindOf('slides.pptx'), FilePreviewKind.office);
      expect(previewKindOf('导出.csv'), FilePreviewKind.office);
    });

    test('文本与无扩展名走文本预览', () {
      expect(previewKindOf('README.md'), FilePreviewKind.text);
      expect(previewKindOf('main.dart'), FilePreviewKind.text);
      expect(previewKindOf('LICENSE'), FilePreviewKind.text);
    });
  });

  group('FileViewerScreen（M4.9）', () {
    testWidgets('图片：下载字节后在 App 内显示，可交给系统应用', (tester) async {
      final store = _FakeStore(bytes: <int>[137, 80, 78, 71]);
      final opener = FakeFileOpener();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: FileViewerScreen(
            liveStore: store,
            workspacePath: r'D:\work',
            relativePath: 'shot.png',
            fileName: 'shot.png',
            fileOpener: opener,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(store.downloaded, 1);
      expect(store.readCalls, 0, reason: '图片不该走文本读取');
      expect(find.byType(Image), findsOneWidget);
      expect(find.textContaining('双指可放大'), findsOneWidget);

      await tester.tap(find.byTooltip('用其他应用打开'));
      await tester.pumpAndSettle();
      expect(opener.openCalls, 1);
      expect(opener.last?.fileName, 'shot.png');
      expect(opener.last?.mimeType, 'image/png');
    });

    testWidgets('PDF：提示用其他应用打开，点击后调用系统应用', (tester) async {
      final store = _FakeStore(bytes: <int>[37, 80, 68, 70]);
      final opener = FakeFileOpener();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: FileViewerScreen(
            liveStore: store,
            workspacePath: r'D:\work',
            relativePath: '实验四/074_报告.pdf',
            fileName: '074_报告.pdf',
            fileOpener: opener,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(store.downloaded, 1);
      // 标题 + 按钮文案都是「用其他应用打开」，所以这里数 2 个。
      expect(find.text('用其他应用打开'), findsNWidgets(2));
      expect(find.byType(FilledButton), findsOneWidget);
      expect(find.textContaining('已下载到手机'), findsOneWidget);
      expect(find.textContaining('WPS'), findsOneWidget);

      await tester.tap(find.byType(FilledButton).first);
      await tester.pumpAndSettle();
      expect(opener.last?.fileName, '074_报告.pdf');
      expect(opener.last?.mimeType, 'application/pdf');
    });

    testWidgets('文本接口说二进制时，自动改成下载原始字节', (tester) async {
      final store = _FakeStore(bytes: <int>[1, 2, 3], binary: true);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: FileViewerScreen(
            liveStore: store,
            workspacePath: r'D:\work',
            relativePath: 'noext',
            fileOpener: FakeFileOpener(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(store.readCalls, 1);
      expect(store.downloaded, 1);
      expect(find.text('无法预览这个文件'), findsNothing);
      expect(find.text('这个文件不是文本'), findsOneWidget);
    });

    testWidgets('插件过旧（404）给出可读提示', (tester) async {
      final store = _FakeStore(
        downloadError: const PairingApiException('not found', statusCode: 404),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: FileViewerScreen(
            liveStore: store,
            workspacePath: r'D:\work',
            relativePath: 'a.pdf',
            fileOpener: FakeFileOpener(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('无法预览这个文件'), findsOneWidget);
      expect(find.textContaining('插件版本过低'), findsOneWidget);
    });

    testWidgets('普通文本仍走原来的文本预览', (tester) async {
      final store = _FakeStore(text: 'hello\nworld');
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: FileViewerScreen(
            liveStore: store,
            workspacePath: r'D:\work',
            relativePath: 'README.md',
            fileOpener: FakeFileOpener(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(store.readCalls, 1);
      expect(store.downloaded, 0);
      expect(find.textContaining('hello'), findsOneWidget);
    });
  });
}

class _FakeStore extends LiveStore {
  _FakeStore({
    this.bytes = const <int>[],
    this.text = '',
    this.binary = false,
    this.downloadError,
  });

  final List<int> bytes;
  final String text;
  final bool binary;
  final Object? downloadError;

  int readCalls = 0;
  int downloaded = 0;

  @override
  bool get isConnected => true;

  @override
  bool get canWriteWorkspaceFiles => false;

  @override
  Future<WorkspaceFileContent> readWorkspaceFile({
    required String workspacePath,
    required String relativePath,
    int? maxBytes,
  }) async {
    readCalls += 1;
    if (binary) {
      return WorkspaceFileContent(
        relativePath: relativePath,
        content: '',
        size: bytes.length,
        sha256: '',
        truncated: false,
        binary: true,
      );
    }
    return WorkspaceFileContent(
      relativePath: relativePath,
      content: text,
      size: text.length,
      sha256: 'a' * 8,
      truncated: false,
      binary: false,
    );
  }

  @override
  Future<List<int>> downloadWorkspaceFile({
    required String workspacePath,
    required String relativePath,
  }) async {
    downloaded += 1;
    final error = downloadError;
    if (error != null) throw error;
    return Uint8List.fromList(bytes);
  }
}
