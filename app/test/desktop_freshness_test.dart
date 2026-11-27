import 'package:deepseek_remote_app/models.dart';
import 'package:deepseek_remote_app/services/desktop_sort.dart';
import 'package:deepseek_remote_app/services/history_api.dart';
import 'package:flutter_test/flutter_test.dart';

TaskRecord _record({
  required String id,
  int? lastTime,
  int messageCount = 0,
  int lastSeq = 0,
  String? updatedAt,
}) {
  return TaskRecord.fromJson(<String, dynamic>{
    'id': id,
    'title': id,
    'status': 'completed',
    'lastTime': lastTime,
    'messageCount': messageCount,
    'lastSeq': lastSeq,
    if (updatedAt != null) 'updatedAt': updatedAt,
  });
}

TaskItem _item({
  required String id,
  int? lastTime,
  int messageCount = 0,
  DateTime? updatedAt,
}) {
  return TaskItem(
    id: id,
    title: id,
    status: TaskStatus.completed,
    workspace: '—',
    updatedAt: updatedAt ?? DateTime.utc(2026, 11, 1),
    messageCount: messageCount,
    lastTime: lastTime,
  );
}

void main() {
  group('TaskRecord 新鲜度字段（M3.6）', () {
    test('解析 lastTime（毫秒时间戳）、messageCount、lastSeq', () {
      final record = TaskRecord.fromJson(<String, dynamic>{
        'id': 'session-1',
        'title': '示例项目B',
        'workspace': r'D:\work',
        'status': 'running',
        'progress': 0.5,
        'lastTime': 1762746087224,
        'messageCount': 12,
        'lastSeq': 88,
        'updatedAt': '2026-11-10T03:41:27.224Z',
      });

      expect(record.lastTime, 1762746087224);
      expect(record.messageCount, 12);
      expect(record.lastSeq, 88);

      final item = record.toTaskItem();
      expect(item.messageCount, 12);
      expect(item.lastTime, 1762746087224);
      expect(item.title, '示例项目B');
    });

    test('lastTime 兼容数字字符串与 ISO 字符串', () {
      final asString = TaskRecord.fromJson(<String, dynamic>{
        'id': 'a',
        'lastTime': '1762746087224',
      });
      expect(asString.lastTime, 1762746087224);

      final asIso = TaskRecord.fromJson(<String, dynamic>{
        'id': 'b',
        'lastTime': '2026-11-10T03:41:27.224Z',
      });
      expect(
        asIso.lastTime,
        DateTime.parse('2026-11-10T03:41:27.224Z').millisecondsSinceEpoch,
      );
    });

    test('旧接口缺字段时给出安全默认值', () {
      final record = TaskRecord.fromJson(<String, dynamic>{
        'id': 'legacy',
        'title': '旧会话',
      });
      expect(record.lastTime, isNull);
      expect(record.messageCount, 0);
      expect(record.lastSeq, 0);
      final item = record.toTaskItem();
      expect(item.messageCount, 0);
      expect(item.lastTime, isNull);
    });
  });

  group('桌面任务排序（M3.6）', () {
    test('有 lastTime 的在前，按时间戳倒序；没有的回退 updatedAt 倒序', () {
      final older = _record(
        id: 'older',
        lastTime: 1000,
        updatedAt: '2026-11-09T10:00:00.000Z',
      );
      final newer = _record(
        id: 'newer',
        lastTime: 2000,
        updatedAt: '2026-11-09T09:00:00.000Z',
      );
      final noTimeNew = _record(
        id: 'no-time-new',
        updatedAt: '2026-11-10T10:00:00.000Z',
      );
      final noTimeOld = _record(
        id: 'no-time-old',
        updatedAt: '2026-11-08T10:00:00.000Z',
      );

      final sorted = sortDesktopTasks(
        <TaskRecord>[older, noTimeOld, newer, noTimeNew],
      );

      expect(
        sorted.map((task) => task.taskId).toList(),
        <String>['newer', 'older', 'no-time-new', 'no-time-old'],
      );
    });

    test('完全相同的 lastTime / updatedAt 时保持原顺序（稳定）', () {
      final first = _record(
        id: 'first',
        lastTime: 5000,
        updatedAt: '2026-11-10T10:00:00.000Z',
      );
      final second = _record(
        id: 'second',
        lastTime: 5000,
        updatedAt: '2026-11-10T10:00:00.000Z',
      );

      final sorted = sortDesktopTasks(<TaskRecord>[first, second]);
      expect(sorted.map((task) => task.taskId).toList(), <String>[
        'first',
        'second',
      ]);
    });

    test('sortDesktopTaskItems 与 TaskRecord 规则一致', () {
      final a = _item(
        id: 'a',
        lastTime: 100,
        updatedAt: DateTime.utc(2026, 11, 1),
      );
      final b = _item(
        id: 'b',
        lastTime: 300,
        updatedAt: DateTime.utc(2026, 11, 1),
      );
      final c = _item(id: 'c', updatedAt: DateTime.utc(2026, 11, 5));

      final sorted = sortDesktopTaskItems(<TaskItem>[a, c, b]);
      expect(sorted.map((task) => task.id).toList(), <String>['b', 'a', 'c']);
    });

    test('compareLastTime：null/0 视为没有时间戳', () {
      expect(compareLastTime(null, 1), greaterThan(0));
      expect(compareLastTime(1, null), lessThan(0));
      expect(compareLastTime(0, 10), greaterThan(0));
      expect(compareLastTime(10, 10), 0);
      expect(compareLastTime(20, 10), lessThan(0));
    });
  });

  group('formatLastTime（M3.6）', () {
    test('空值显示为空字符串', () {
      expect(formatLastTime(null), '');
      expect(formatLastTime(0), '');
    });

    test('当天时间显示 HH:mm', () {
      final now = DateTime.now();
      final text = formatLastTime(now.millisecondsSinceEpoch);
      expect(text, matches(RegExp(r'^\d{2}:\d{2}$')));
      expect(text, formatTime(now));
    });

    test('跨天时带日期前缀', () {
      final old = DateTime.now().subtract(const Duration(days: 3));
      final text = formatLastTime(old.millisecondsSinceEpoch);
      expect(text, matches(RegExp(r'^\d{2}-\d{2} \d{2}:\d{2}$')));
    });
  });
}
