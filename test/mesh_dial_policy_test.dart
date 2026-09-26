import 'dart:typed_data';

import 'package:bluetooth_app/services/mesh_dial_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MeshDialPolicy', () {
    test('uses a held outbound link when the peer scan address is stale', () {
      const local = '20000000-0000-0000-0000-000000000002';
      const peer = '10000000-0000-0000-0000-000000000001';

      expect(
        MeshDialPolicy.urgentCandidates(
          localNodeId: local,
          freshPeerIds: const [],
          heldClientPeerId: peer,
        ),
        [peer],
      );
    });

    test('does not cold-dial a stale peer without a held link', () {
      expect(
        MeshDialPolicy.urgentCandidates(
          localNodeId: '20000000-0000-0000-0000-000000000002',
          freshPeerIds: const [],
        ),
        isEmpty,
      );
    });

    test('uses capability-aware election for urgent candidates', () {
      expect(
        MeshDialPolicy.urgentCandidates(
          localNodeId: '10000000-local',
          freshPeerIds: const ['20000000-remote'],
          shouldInitiatePeer: (_) => false,
        ),
        isEmpty,
      );
      expect(
        MeshDialPolicy.urgentCandidates(
          localNodeId: '10000000-local',
          freshPeerIds: const ['20000000-remote'],
          heldClientPeerId: '20000000-remote',
          shouldInitiatePeer: (_) => false,
        ),
        ['20000000-remote'],
      );
    });

    test('parses the optional FFE0 dial-capability trailer', () {
      final legacyPayload = Uint8List(12);
      final nonExtendedPayload = Uint8List(14)
        ..[12] = MeshDialPolicy.meshDialCapabilityMarker
        ..[13] = 1;
      final extendedPayload = Uint8List(14)
        ..[12] = MeshDialPolicy.meshDialCapabilityMarker
        ..[13] = 3;
      final unknownPayload = Uint8List(14)
        ..[12] = MeshDialPolicy.meshDialCapabilityMarker
        ..[13] = 0;

      expect(
        MeshDialPolicy.extendedConnectableFromMeshPayload(legacyPayload),
        isNull,
      );
      expect(
        MeshDialPolicy.extendedConnectableFromMeshPayload(nonExtendedPayload),
        isFalse,
      );
      expect(
        MeshDialPolicy.extendedConnectableFromMeshPayload(extendedPayload),
        isTrue,
      );
      expect(
        MeshDialPolicy.extendedConnectableFromMeshPayload(unknownPayload),
        isNull,
      );
    });

    test('retries a held-link address after a newer scan sees it again', () {
      final beforeAttempt = DateTime.utc(2026, 9, 26, 12);
      final afterAttempt = beforeAttempt.add(const Duration(milliseconds: 80));

      expect(
        MeshDialPolicy.freshHeldLinkRetryTarget(
          failedMac: '41:96:E0:B9:8B:59',
          scannedMac: '41:96:E0:B9:8B:59',
          scanSeenAtBeforeAttempt: beforeAttempt,
          scanSeenAt: afterAttempt,
        ),
        '41:96:E0:B9:8B:59',
      );
    });

    test(
      'does not retry a held-link address without a newer scan sighting',
      () {
        final seenAt = DateTime.utc(2026, 9, 26, 12);

        expect(
          MeshDialPolicy.freshHeldLinkRetryTarget(
            failedMac: '41:96:E0:B9:8B:59',
            scannedMac: '41:96:E0:B9:8B:59',
            scanSeenAtBeforeAttempt: seenAt,
            scanSeenAt: seenAt,
          ),
          isNull,
        );
        expect(
          MeshDialPolicy.freshHeldLinkRetryTarget(
            failedMac: '41:96:E0:B9:8B:59',
            scannedMac: '41:96:E0:B9:8B:59',
            scanSeenAtBeforeAttempt: null,
            scanSeenAt: seenAt,
          ),
          isNull,
        );
      },
    );

    test('accepts a different address only after a newer scan sighting', () {
      final beforeAttempt = DateTime.utc(2026, 9, 26, 12);
      final afterAttempt = beforeAttempt.add(const Duration(milliseconds: 80));

      expect(
        MeshDialPolicy.freshHeldLinkRetryTarget(
          failedMac: '41:96:E0:B9:8B:59',
          scannedMac: '50:E5:1D:9B:D4:0E',
          scanSeenAtBeforeAttempt: beforeAttempt,
          scanSeenAt: afterAttempt,
        ),
        '50:E5:1D:9B:D4:0E',
      );
    });

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

    test(
      'lets the extended-connectable peer initiate regardless of node-ID order',
      () {
        const android9 = '10000000-0000-0000-0000-000000000001';
        const android15 = '20000000-0000-0000-0000-000000000002';

        expect(
          MeshDialPolicy.shouldInitiate(
            localNodeId: android9,
            remoteNodeId: android15,
            localExtendedConnectable: false,
            remoteExtendedConnectable: true,
          ),
          isFalse,
        );
        expect(
          MeshDialPolicy.shouldInitiate(
            localNodeId: android15,
            remoteNodeId: android9,
            localExtendedConnectable: true,
            remoteExtendedConnectable: false,
          ),
          isTrue,
        );
      },
    );

    test(
      'falls back to node-ID election for equal or unknown capabilities',
      () {
        const alpha = '10000000-0000-0000-0000-000000000001';
        const beta = '20000000-0000-0000-0000-000000000002';

        expect(
          MeshDialPolicy.shouldInitiate(
            localNodeId: alpha,
            remoteNodeId: beta,
            localExtendedConnectable: false,
            remoteExtendedConnectable: false,
          ),
          isTrue,
        );
        expect(
          MeshDialPolicy.shouldInitiate(
            localNodeId: beta,
            remoteNodeId: alpha,
            localExtendedConnectable: true,
          ),
          isFalse,
        );
        expect(
          MeshDialPolicy.shouldInitiate(
            localNodeId: alpha,
            remoteNodeId: beta,
            remoteExtendedConnectable: true,
          ),
          isFalse,
        );
      },
    );

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

    test('partial advertisement hashes elect one side symmetrically', () {
      expect(
        MeshDialPolicy.shouldInitiateFromPartialHash(
          localHashFragment: 7,
          remoteHashFragment: 9,
        ),
        isTrue,
      );
      expect(
        MeshDialPolicy.shouldInitiateFromPartialHash(
          localHashFragment: 9,
          remoteHashFragment: 7,
        ),
        isFalse,
      );
    });

    test('does not elect either side from equal or missing partial hashes', () {
      expect(
        MeshDialPolicy.shouldInitiateFromPartialHash(
          localHashFragment: 7,
          remoteHashFragment: 7,
        ),
        isFalse,
      );
      expect(
        MeshDialPolicy.shouldInitiateFromPartialHash(
          localHashFragment: null,
          remoteHashFragment: 7,
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
