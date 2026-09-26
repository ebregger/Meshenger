import 'package:bluetooth_app/services/ble_discovery_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const peerId = 'peer-node';
  final now = DateTime.utc(2026, 9, 25, 20);

  setUp(() {
    BleDiscoveryService.nodeIdToMac.clear();
    BleDiscoveryService.nodeIdMacSeenAt.clear();
    BleDiscoveryService.lastGoodDialMac.clear();
    BleDiscoveryService.macToNodeId.clear();
    BleDiscoveryService.hashToMac.clear();
    BleDiscoveryService.hashToNodeId.clear();
  });

  tearDown(() {
    BleDiscoveryService.nodeIdToMac.clear();
    BleDiscoveryService.nodeIdMacSeenAt.clear();
    BleDiscoveryService.lastGoodDialMac.clear();
    BleDiscoveryService.macToNodeId.clear();
    BleDiscoveryService.hashToMac.clear();
    BleDiscoveryService.hashToNodeId.clear();
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
