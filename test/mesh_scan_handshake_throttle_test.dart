import 'package:bluetooth_app/services/mesh_dial_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MeshScanHandshakeThrottle', () {
    test('limits repeated scan handshakes for one peer', () {
      final throttle = MeshScanHandshakeThrottle(
        window: const Duration(seconds: 1),
      );
      final start = DateTime(2026, 9, 25);

      expect(throttle.shouldThrottle('peer-a', now: start), isFalse);
      expect(
        throttle.shouldThrottle(
          'peer-a',
          now: start.add(const Duration(milliseconds: 999)),
        ),
        isTrue,
      );
      expect(
        throttle.shouldThrottle(
          'peer-a',
          now: start.add(const Duration(seconds: 1)),
        ),
        isFalse,
      );
    });

    test('keeps separate peers independent and clear resets the gate', () {
      final throttle = MeshScanHandshakeThrottle(
        window: const Duration(seconds: 1),
      );
      final start = DateTime(2026, 9, 25);

      expect(throttle.shouldThrottle('peer-a', now: start), isFalse);
      expect(
        throttle.shouldThrottle(
          'peer-b',
          now: start.add(const Duration(milliseconds: 1)),
        ),
        isFalse,
      );

      throttle.clear();

      expect(
        throttle.shouldThrottle(
          'peer-a',
          now: start.add(const Duration(milliseconds: 2)),
        ),
        isFalse,
      );
    });
  });
}
