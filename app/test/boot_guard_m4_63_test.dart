import 'package:deepseek_remote_app/services/boot_guard.dart';
import 'package:deepseek_remote_app/services/settings_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('M4.63 启动自愈', () {
    test('前两次没走完不会清存档', () async {
      final gateway = FakeSettingsGateway();
      final now = DateTime(2026, 11, 27, 9, 0);
      final guard = BootGuard(gateway: gateway, now: () => now);

      await guard.markAttempt();
      expect(await guard.shouldReset(), isFalse);
      await guard.markAttempt();
      expect(await guard.shouldReset(), isFalse);
      expect(await guard.attempts(), 2);
      expect(gateway.values[BootGuard.attemptsKey], '2');
    });

    test('连续三次都没走到第一帧就要求清存档', () async {
      final gateway = FakeSettingsGateway();
      final now = DateTime(2026, 11, 27, 9, 0);
      final guard = BootGuard(gateway: gateway, now: () => now);

      for (var i = 0; i < BootGuard.maxAttempts; i++) {
        await guard.markAttempt();
      }

      expect(await guard.attempts(), BootGuard.maxAttempts);
      expect(await guard.shouldReset(), isTrue);

      // 很久以后再启动，不算连续闪退。
      final later = BootGuard(
        gateway: gateway,
        now: () => now.add(const Duration(minutes: 30)),
      );
      expect(await later.shouldReset(), isFalse);
    });

    test('画出第一帧后计数归零', () async {
      final gateway = FakeSettingsGateway();
      final now = DateTime(2026, 11, 27, 9, 0);
      final guard = BootGuard(gateway: gateway, now: () => now);

      await guard.markAttempt();
      await guard.markAttempt();
      await guard.markFirstFrame();

      expect(await guard.attempts(), 0);
      expect(await guard.shouldReset(), isFalse);
      expect(gateway.values[BootGuard.attemptsKey], '0');
    });
  });
}
