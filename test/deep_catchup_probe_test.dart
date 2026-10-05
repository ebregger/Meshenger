import 'package:bluetooth_app/services/deep_catchup.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(DeepCatchup.reset);
  tearDown(DeepCatchup.reset);

  test('a neighbor arriving after digest completion still gets one probe', () {
    // Digest completion runs before the first scan observes any neighbors.
    expect(DeepCatchup.unprobedNeighbors(const []), isEmpty);

    // Presence refresh sees it later, even without a handshake callback.
    expect(DeepCatchup.unprobedNeighbors(const ['late-peer']), ['late-peer']);
    expect(DeepCatchup.claimProbe('late-peer'), isTrue);
    expect(DeepCatchup.unprobedNeighbors(const ['late-peer']), isEmpty);
    expect(DeepCatchup.claimProbe('late-peer'), isFalse);
  });

  test('waiting for recent sync leaves a neighbor eligible for a probe', () {
    // Presence checks must not claim it while its recent hash differs or our
    // deep digest is still rebuilding. A later ready callback can claim it.
    expect(DeepCatchup.unprobedNeighbors(const ['peer']), ['peer']);
    expect(DeepCatchup.unprobedNeighbors(const ['peer']), ['peer']);
    expect(DeepCatchup.claimProbe('peer'), isTrue);
  });

  test('presence refresh does not spend rounds on a known deep mismatch', () {
    DeepCatchup.remember('known-peer', const PeerDeepDigest(2));
    for (var tick = 0; tick < 100; tick++) {
      expect(DeepCatchup.unprobedNeighbors(const ['known-peer']), isEmpty);
    }
    expect(DeepCatchup.claimProbe('known-peer'), isFalse);
    expect(
      DeepCatchup.claimRound('known-peer', ourHash: 1, theirHash: 2),
      isTrue,
    );
  });

  test('a new mesh session forgets stale digests and initial probes', () {
    expect(DeepCatchup.claimProbe('peer'), isTrue);
    DeepCatchup.remember('peer', const PeerDeepDigest(2));
    for (var round = 0; round < DeepCatchup.maxRoundsPerPair; round++) {
      expect(DeepCatchup.claimRound('peer', ourHash: 1, theirHash: 2), isTrue);
    }
    expect(DeepCatchup.claimRound('peer', ourHash: 1, theirHash: 2), isFalse);

    DeepCatchup.reset();
    expect(DeepCatchup.peer('peer'), isNull);
    expect(DeepCatchup.unprobedNeighbors(const ['peer']), ['peer']);
    expect(DeepCatchup.claimProbe('peer'), isTrue);
    expect(DeepCatchup.claimRound('peer', ourHash: 1, theirHash: 2), isTrue);
  });
}
