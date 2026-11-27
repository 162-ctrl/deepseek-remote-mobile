// M4.13：工作区「按项目分组」的纯函数测试。
import 'package:flutter_test/flutter_test.dart';
import 'package:deepseek_remote_app/services/project_groups.dart';

void main() {
  group('路径拆分', () {
    test('projectNameOf 取末段名，忽略末尾分隔符', () {
      expect(projectNameOf(r'<项目根>'), 'deepseek手机端');
      expect(projectNameOf(r'<项目根>\'), 'deepseek手机端');
      expect(projectNameOf('D:/用户/项目/示例项目B'), '示例项目B');
      expect(projectNameOf(r'D:\Projects\项目'), '项目');
      expect(projectNameOf(''), '');
    });

    test('parentPathOf 给父目录，盘符根当没有父目录', () {
      expect(parentPathOf(r'D:\Projects\示例项目C'), r'D:\Projects\项目');
      expect(parentPathOf(r'D:\Projects\'), r'D:\Projects');
      // 盘符根（`D:\项目`）的父目录当成「没有」。
      expect(parentPathOf(r'D:\项目'), '');
      expect(parentPathOf('D:'), '');
      expect(parentPathOf(''), '');
    });
  });

  group('groupWorkspacesByProject', () {
    test('每个路径一个组，会话挂到各自组里', () {
      final groups = groupWorkspacesByProject<String>(
        paths: [r'D:\p\A', r'D:\p\B'],
        itemsOf: (path) => switch (path) {
          r'D:\p\A' => ['a1', 'a2'],
          r'D:\p\B' => ['b1'],
          _ => const <String>[],
        },
        maxOf: (item) => switch (item) {
          'a1' => 100,
          'a2' => 300,
          'b1' => 200,
          _ => 0,
        },
      );
      expect(groups.length, 2);
      final a = groups.firstWhere((g) => g.name == 'A');
      expect(a.parent, r'D:\p');
      // 组内按最后活动时间从新到旧。
      expect(a.items, ['a2', 'a1']);
      expect(a.isEmpty, isFalse);
    });

    test('授权了但没有会话的目录也占一个空组', () {
      final groups = groupWorkspacesByProject<String>(
        paths: [r'D:\p\A'],
        extraRoots: [r'D:\p\空闲'],
        itemsOf: (path) => path == r'D:\p\A' ? ['x'] : const <String>[],
        maxOf: (_) => 10,
      );
      expect(groups.length, 2);
      final idle = groups.firstWhere((g) => g.name == '空闲');
      expect(idle.isEmpty, isTrue);
      // 有会话的组排在空组前面。
      expect(groups.first.name, 'A');
    });

    test('相同路径只出现一次（去重、斜杠方向不敏感）', () {
      final groups = groupWorkspacesByProject<String>(
        paths: [r'D:\p\A', r'D:\p\A\'],
        itemsOf: (_) => const <String>[],
        maxOf: (_) => 0,
      );
      expect(groups.length, 1);
    });

    test('组间按最新活动时间从新到旧', () {
      final groups = groupWorkspacesByProject<String>(
        paths: [r'D:\p\旧', r'D:\p\新'],
        itemsOf: (path) => path.endsWith('旧') ? ['o'] : ['n'],
        maxOf: (item) => item == 'o' ? 1 : 99,
      );
      expect(groups.map((g) => g.name).toList(), ['新', '旧']);
    });

    test('空路径被忽略', () {
      final groups = groupWorkspacesByProject<String>(
        paths: ['', '  ', r'D:\p\A'],
        itemsOf: (_) => const <String>[],
        maxOf: (_) => 0,
      );
      expect(groups.length, 1);
    });
  });
}
