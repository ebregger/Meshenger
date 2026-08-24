import 'package:bluetooth_app/services/mesh_catchup.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MeshLeasePolicy', () {
    test('keeps a quiet two-node turn short', () {
      final lease = MeshLeasePolicy.calculate(
        meshNodeCount: 2,
        backlogRows: 25,
      );

      expect(lease.maximum, const Duration(seconds: 9));
      expect(lease.idle, const Duration(milliseconds: 3200));
    });

    test('extends a busy turn from write throughput', () {
      final lease = MeshLeasePolicy.calculate(
        meshNodeCount: 3,
        backlogRows: 25,
        messagesPerSecond: 1,
      );

      expect(lease.maximum, const Duration(milliseconds: 11500));
      expect(lease.idle, const Duration(milliseconds: 3833));
    });

    test('caps deep backlog by peer fair share', () {
      final lease = MeshLeasePolicy.calculate(
        meshNodeCount: 3,
        backlogRows: 500,
        messagesPerSecond: 10,
      );

      expect(lease.maximum, const Duration(seconds: 15));
      expect(lease.idle, const Duration(milliseconds: 4500));
    });

    test('shortens turns as the mesh grows', () {
      final lease = MeshLeasePolicy.calculate(
        meshNodeCount: 5,
        backlogRows: 500,
        messagesPerSecond: 10,
      );

      expect(lease.maximum, const Duration(seconds: 9));
      expect(lease.idle, const Duration(milliseconds: 3200));
    });
  });
}
