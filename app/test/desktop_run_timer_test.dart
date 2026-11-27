import 'package:deepseek_remote_app/services/desktop_sort.dart';
import 'package:deepseek_remote_app/services/history_api.dart';
import 'package:flutter_test/flutter_test.dart';

/// M4.3：直播页「已运行」的起点必须和电脑端一致——
/// 起点是会话日志里最新一条 `turn-start` 的时间，而不是手机打开页面的时刻。
void main() {
  DesktopSessionEvent makeEvent({
    required int seq,
    required String kind,
    int time = 0,
    String text = '',
  }) {
    return DesktopSessionEvent(seq: seq, kind: kind, time: time, text: text);
  }

  group('DesktopSessionEvent.time', () {
    test('解析插件下发的 time，缺省为 0', () {
      final withTime = DesktopSessionEvent.fromJson(<String, dynamic>{
        'seq': 7,
        'time': 1762000000000,
        'kind': 'turn-start',
      });
      expect(withTime.time, 1762000000000);
      final without = DesktopSessionEvent.fromJson(<String, dynamic>{
        'seq': 8,
        'kind': 'assistant',
        'text': 'hi',
      });
      expect(without.time, 0);
    });

    test('withText 保留 time', () {
      final merged = makeEvent(seq: 3, kind: 'assistant', time: 1762000000123, text: 'a')
          .withText('ab');
      expect(merged.time, 1762000000123);
      expect(merged.text, 'ab');
    });
  });

  group('resolveRunStart', () {
    final now = DateTime(2026, 11, 13, 20, 0, 0);

    test('取最新一条带时间的 turn-start', () {
      final start = resolveRunStart(
        events: <DesktopSessionEvent>[
          makeEvent(seq: 1, kind: 'turn-start', time: 1762000000000),
          makeEvent(seq: 2, kind: 'assistant', time: 1762000005000),
          makeEvent(seq: 3, kind: 'turn-end', time: 1762000060000),
          makeEvent(seq: 4, kind: 'turn-start', time: 1762000100000),
          makeEvent(seq: 5, kind: 'tool', time: 1762000110000),
        ],
        now: now,
      );
      expect(start, DateTime.fromMillisecondsSinceEpoch(1762000100000));
    });

    test('手机中途打开也能对上电脑的起点（不是 now）', () {
      final start = resolveRunStart(
        events: <DesktopSessionEvent>[
          makeEvent(seq: 11, kind: 'turn-start', time: 1762000500000),
          makeEvent(seq: 12, kind: 'tool', time: 1762000560000),
        ],
        now: now,
      );
      expect(start.isBefore(now), isTrue);
      expect(now.difference(start), greaterThan(const Duration(minutes: 1)));
    });

    test('旧插件不带时间时退回任务行的 lastTime', () {
      final start = resolveRunStart(
        events: <DesktopSessionEvent>[
          makeEvent(seq: 1, kind: 'turn-start'),
          makeEvent(seq: 2, kind: 'assistant', text: 'x'),
        ],
        lastTime: 1762000200000,
        now: now,
      );
      expect(start, DateTime.fromMillisecondsSinceEpoch(1762000200000));
    });

    test('既无时间也无 lastTime 时退回会话 updatedAt', () {
      final updatedAt = DateTime(2026, 11, 13, 19, 30);
      final start = resolveRunStart(
        events: const <DesktopSessionEvent>[],
        updatedAt: updatedAt,
        now: now,
      );
      expect(start, updatedAt);
    });

    test('什么都没有时用 now（显示 0:00 而不是崩溃）', () {
      final start = resolveRunStart(
        events: const <DesktopSessionEvent>[],
        now: now,
      );
      expect(start, now);
    });
  });

  group('formatElapsed', () {
    test('不足一小时是 M:SS', () {
      expect(formatElapsed(Duration.zero), '0:00');
      expect(formatElapsed(const Duration(seconds: 9)), '0:09');
      expect(formatElapsed(const Duration(minutes: 3, seconds: 7)), '3:07');
      expect(formatElapsed(const Duration(minutes: 59, seconds: 59)), '59:59');
    });

    test('超过一小时是 H:MM:SS', () {
      expect(formatElapsed(const Duration(hours: 1, minutes: 2, seconds: 3)),
          '1:02:03');
      expect(formatElapsed(const Duration(hours: 2, seconds: 5)), '2:00:05');
    });

    test('负数当 0 处理（手机时钟回拨）', () {
      expect(formatElapsed(const Duration(seconds: -30)), '0:00');
    });
  });
}
