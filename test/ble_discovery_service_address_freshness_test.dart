import 'package:bluetooth_app/services/ble_discovery_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const peerId = 'peer-node';
  final now = DateTime.utc(2026, 9, 25, 20);

  setUp(() {
    BleDiscoveryService.nodeIdToMac.clear();
    BleDiscoveryService.nodeIdMacSeenAt.clear();
    BleDiscoveryService.peerBusyStateByNodeId.clear();
    BleDiscoveryService.peerBusySeenAtByNodeId.clear();
    BleDiscoveryService.lastGoodDialMac.clear();
    BleDiscoveryService.macToNodeId.clear();
    BleDiscoveryService.hashToNodeId.clear();
    BleDiscoveryService.hashOwners.clear();
    BleDiscoveryService.latestHashByNodeId.clear();
    BleDiscoveryService.peerObservedHash.clear();
    BleDiscoveryService.nodeIdPrefixToNodeId.clear();
  });

  tearDown(() {
    BleDiscoveryService.nodeIdToMac.clear();
    BleDiscoveryService.nodeIdMacSeenAt.clear();
    BleDiscoveryService.peerBusyStateByNodeId.clear();
    BleDiscoveryService.peerBusySeenAtByNodeId.clear();
    BleDiscoveryService.lastGoodDialMac.clear();
    BleDiscoveryService.macToNodeId.clear();
    BleDiscoveryService.hashToNodeId.clear();
    BleDiscoveryService.hashOwners.clear();
    BleDiscoveryService.latestHashByNodeId.clear();
    BleDiscoveryService.peerObservedHash.clear();
    BleDiscoveryService.nodeIdPrefixToNodeId.clear();
  });

  test('saved peer prefixes restore advertisement identity after restart', () {
    BleDiscoveryService.seedKnownPeerPrefixes(const [
      '45914ddc-86d7-4e39-9bb3-838a2a842219',
      '69ce9ce8-9196-46dd-a838-e84ddecb39f4',
      '336e55dc-3aec-4f57-b2a6-ad37cec17d13',
    ], localNodeId: '336e55dc-3aec-4f57-b2a6-ad37cec17d13');

    expect(
      BleDiscoveryService.nodeIdPrefixToNodeId['4591'],
      '45914ddc-86d7-4e39-9bb3-838a2a842219',
    );
    expect(
      BleDiscoveryService.nodeIdPrefixToNodeId['69ce'],
      '69ce9ce8-9196-46dd-a838-e84ddecb39f4',
    );
    expect(BleDiscoveryService.nodeIdPrefixToNodeId['336e'], isNull);
  });

  test('ambiguous saved prefixes do not create a false peer route', () {
    BleDiscoveryService.seedKnownPeerPrefixes(const [
      '4591-first-peer',
      '4591-second-peer',
    ], localNodeId: 'local-node');

    expect(BleDiscoveryService.nodeIdPrefixToNodeId['4591'], isNull);
  });

  test('new message stays ahead of bucket repair in capped offers', () {
    final prioritized = BleDiscoveryService.prioritizeNewestMessages(
      {
        'messages': [
          {'msg_id': 'old-gap'},
          {'msg_id': 'new-message'},
        ],
      },
      {
        'messages': [
          {'msg_id': 'new-message'},
        ],
      },
    );

    expect(
      BleDiscoveryService.truncateChangesetForBle(
        prioritized,
        maxRowsPerTable: 1,
      )['messages'],
      [
        {'msg_id': 'new-message'},
      ],
    );
    expect((prioritized['messages'] as List).length, 2);
  });

  test(
    'only the latest scan address is dialable inside the freshness window',
    () {
      BleDiscoveryService.nodeIdToMac[peerId] = 'fresh-rpa';
      BleDiscoveryService.nodeIdMacSeenAt[peerId] = now;
      BleDiscoveryService.lastGoodDialMac[peerId] = 'old-rpa';
      BleDiscoveryService.macToNodeId['old-rpa'] = peerId;
      BleDiscoveryService.macToNodeId['fresh-rpa'] = peerId;

      expect(
        BleDiscoveryService.preferredDialMac(peerId, now: now),
        'fresh-rpa',
      );
      expect(
        BleDiscoveryService.preferredDialMac(
          peerId,
          now: now.add(BleDiscoveryService.dialMacFreshnessWindow),
        ),
        'fresh-rpa',
      );
      expect(
        BleDiscoveryService.preferredDialMac(
          peerId,
          now: now.add(
            BleDiscoveryService.dialMacFreshnessWindow +
                const Duration(milliseconds: 1),
          ),
        ),
        isNull,
      );
    },
  );

  test('successful dial address without a scan timestamp is not dialable', () {
    BleDiscoveryService.rememberSuccessfulDial(peerId, 'cached-rpa');

    expect(
      BleDiscoveryService.candidateDialMacs(peerId),
      contains('cached-rpa'),
    );
    expect(BleDiscoveryService.preferredDialMac(peerId, now: now), isNull);
  });

  test('converged peers do not share a hash-based address route', () {
    const otherPeerId = 'other-peer';
    const sharedHash = 42;
    BleDiscoveryService.bindPeerIdentity(
      nodeId: peerId,
      mac: 'peer-a-address',
      hash: sharedHash,
    );
    BleDiscoveryService.bindPeerIdentity(
      nodeId: otherPeerId,
      mac: 'peer-b-address',
      hash: sharedHash,
    );

    expect(BleDiscoveryService.hashToNodeId.containsKey(sharedHash), isFalse);
    expect(
      BleDiscoveryService.candidateDialMacs(peerId),
      isNot(contains('peer-b-address')),
    );
    expect(
      BleDiscoveryService.candidateDialMacs(otherPeerId),
      isNot(contains('peer-a-address')),
    );

    BleDiscoveryService.rememberPeerHash(otherPeerId, sharedHash + 1);
    expect(BleDiscoveryService.hashToNodeId[sharedHash], peerId);
    expect(BleDiscoveryService.hashToNodeId[sharedHash + 1], otherPeerId);
  });

  test('a MAC remapped to another peer is no longer a dial target', () {
    BleDiscoveryService.nodeIdToMac[peerId] = 'reused-address';
    BleDiscoveryService.nodeIdMacSeenAt[peerId] = now;
    BleDiscoveryService.macToNodeId['reused-address'] = 'other-peer';
    BleDiscoveryService.lastGoodDialMac[peerId] = 'reused-address';

    expect(BleDiscoveryService.preferredDialMac(peerId, now: now), isNull);
    expect(
      BleDiscoveryService.candidateDialMacs(peerId),
      isNot(contains('reused-address')),
    );
  });

  test('recent busy advertisement suppresses cold dial until it expires', () {
    BleDiscoveryService.rememberPeerBusy(peerId, true, seenAt: now);

    expect(BleDiscoveryService.isPeerRecentlyBusy(peerId, now: now), isTrue);
    expect(
      BleDiscoveryService.isPeerRecentlyBusy(
        peerId,
        now: now.add(BleDiscoveryService.peerBusyFreshnessWindow),
      ),
      isTrue,
    );
    expect(
      BleDiscoveryService.isPeerRecentlyBusy(
        peerId,
        now: now.add(
          BleDiscoveryService.peerBusyFreshnessWindow +
              const Duration(milliseconds: 1),
        ),
      ),
      isFalse,
    );
  });

  test('newer available advertisement clears busy and stale scan does not', () {
    BleDiscoveryService.rememberPeerBusy(peerId, true, seenAt: now);
    BleDiscoveryService.rememberPeerBusy(
      peerId,
      false,
      seenAt: now.add(const Duration(milliseconds: 100)),
    );
    BleDiscoveryService.rememberPeerBusy(peerId, true, seenAt: now);

    expect(
      BleDiscoveryService.isPeerRecentlyBusy(
        peerId,
        now: now.add(const Duration(milliseconds: 150)),
      ),
      isFalse,
    );
  });

  test('retry requires a newly observed scan address', () {
    BleDiscoveryService.nodeIdToMac[peerId] = 'new-rpa';
    BleDiscoveryService.nodeIdMacSeenAt[peerId] = now;

    expect(
      BleDiscoveryService.freshAlternateDialMac(peerId, 'failed-rpa', now: now),
      'new-rpa',
    );
    expect(
      BleDiscoveryService.freshAlternateDialMac(peerId, 'new-rpa', now: now),
      isNull,
    );
    expect(
      BleDiscoveryService.freshAlternateDialMac(
        peerId,
        'failed-rpa',
        now: now.add(
          BleDiscoveryService.dialMacFreshnessWindow +
              const Duration(milliseconds: 1),
        ),
      ),
      isNull,
    );
  });

  test(
    'GATT-observed addresses bind identity without claiming scan freshness',
    () {
      BleDiscoveryService.rememberObservedPeerMac(peerId, 'inbound-rpa');

      expect(BleDiscoveryService.macToNodeId['inbound-rpa'], peerId);
      expect(BleDiscoveryService.nodeIdMacSeenAt.containsKey(peerId), isFalse);
      expect(BleDiscoveryService.preferredDialMac(peerId, now: now), isNull);
    },
  );
}
