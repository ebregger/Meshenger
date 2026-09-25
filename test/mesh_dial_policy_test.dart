import 'package:bluetooth_app/services/mesh_dial_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MeshDialPolicy', () {
    test(
      'elects exactly one initiator for known peers when hashes diverge',
      () {
        const alpha = '10000000-0000-0000-0000-000000000001';
        const beta = '20000000-0000-0000-0000-000000000002';

        expect(
          MeshDialPolicy.shouldInitiate(
            localNodeId: alpha,
            remoteNodeId: beta,
            localHash: 10,
            remoteHash: 20,
          ),
          isTrue,
        );
        expect(
          MeshDialPolicy.shouldInitiate(
            localNodeId: beta,
            remoteNodeId: alpha,
            localHash: 20,
            remoteHash: 10,
          ),
          isFalse,
        );
      },
    );

    test('uses advertised node prefix before identity is known', () {
      expect(
        MeshDialPolicy.shouldInitiate(
          localNodeId: '10000000-local',
          remoteNodeIdPrefix: '2000',
        ),
        isTrue,
      );
      expect(
        MeshDialPolicy.shouldInitiate(
          localNodeId: '20000000-remote',
          remoteNodeIdPrefix: '1000',
        ),
        isFalse,
      );
    });

    test('uses divergent hashes as the first-contact tie breaker', () {
      expect(
        MeshDialPolicy.shouldInitiate(
          localNodeId: 'same-prefix-local',
          localHash: 7,
          remoteHash: 9,
        ),
        isTrue,
      );
      expect(
        MeshDialPolicy.shouldInitiate(
          localNodeId: 'same-prefix-remote',
          localHash: 9,
          remoteHash: 7,
        ),
        isFalse,
      );
    });

    test('never initiates a link to itself', () {
      const node = '10000000-0000-0000-0000-000000000001';
      expect(
        MeshDialPolicy.shouldInitiate(localNodeId: node, remoteNodeId: node),
        isFalse,
      );
    });
  });
}
