import 'package:bluetooth_app/services/mesh_catchup.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MeshLeasePolicy', () {
    test('2-node mesh provides a generous idle lease for conversational churn', () {
      final lease = MeshLeasePolicy.calculate(
        meshNodeCount: 2,
        backlogRows: 25,
      );

      // In a 2-node mesh, no other nodes exist to be starved, so idle can stay open longer.
      expect(lease.idle.inMilliseconds, greaterThanOrEqualTo(2500));
      expect(lease.idle.inMilliseconds, lessThanOrEqualTo(4500));
      expect(lease.maximum.inMilliseconds, greaterThanOrEqualTo(12000));
    });

    test('3-node mesh enforces quick idle release to prevent third-node starvation', () {
      final lease = MeshLeasePolicy.calculate(
        meshNodeCount: 3,
        backlogRows: 25,
      );

      // In a 3-node mesh, holding an idle link for 4.5s blocks the 3rd node.
      // Idle timeout must be clamped to 1.2s - 2.0s.
      expect(lease.idle.inMilliseconds, greaterThanOrEqualTo(1200));
      expect(lease.idle.inMilliseconds, lessThanOrEqualTo(2000));
      expect(lease.maximum.inMilliseconds, lessThanOrEqualTo(15000));
    });

    test('larger mesh width scales fairness cap inversely with node count', () {
      final lease3 = MeshLeasePolicy.calculate(
        meshNodeCount: 3,
        backlogRows: 100,
      );
      final lease6 = MeshLeasePolicy.calculate(
        meshNodeCount: 6,
        backlogRows: 100,
      );

      // 45000 / 3 = 15000ms; 45000 / 6 = 7500ms
      expect(lease6.maximum.inMilliseconds, lessThan(lease3.maximum.inMilliseconds));
      expect(lease6.idle.inMilliseconds, lessThanOrEqualTo(lease3.idle.inMilliseconds));
    });

    test('recent write load awards throughput bonus up to fairness cap', () {
      final idleLease = MeshLeasePolicy.calculate(
        meshNodeCount: 3,
        backlogRows: 25,
        messagesPerSecond: 0,
      );
      final busyLease = MeshLeasePolicy.calculate(
        meshNodeCount: 3,
        backlogRows: 25,
        messagesPerSecond: 5,
      );

      expect(busyLease.maximum.inMilliseconds, greaterThanOrEqualTo(idleLease.maximum.inMilliseconds));
    });
  });
}
