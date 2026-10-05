import 'package:bluetooth_app/services/deep_catchup.dart';
import 'package:bluetooth_app/services/database_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_crdt/sqlite_crdt.dart';

void main() {
  setUp(DeepCatchup.reset);
  tearDown(DeepCatchup.reset);

  test(
    'first ordinary offer supplies buckets; converged offers stay small',
    () async {
      final db = DatabaseService.forTesting(await SqliteCrdt.openInMemory());
      addTearDown(db.dispose);
      await db.init();
      final digest = (await db.computeDeepDigest())!;
      final first = DeepCatchup.parse(DeepCatchup.offerFields(db, 'new-peer'))!;
      expect(first.hash, digest.hash);
      expect(first.hasBuckets, isTrue);
      expect(first.buckets.length, DatabaseService.deepBucketCount);
      expect(
        DeepCatchup.parse(DeepCatchup.offerFields(db, null))!.hasBuckets,
        isTrue,
      );

      DeepCatchup.remember('new-peer', PeerDeepDigest(digest.hash));
      expect(
        DeepCatchup.parse(DeepCatchup.offerFields(db, 'new-peer'))!.hasBuckets,
        isFalse,
      );
      DeepCatchup.remember('new-peer', PeerDeepDigest(digest.hash ^ 1));
      expect(
        DeepCatchup.parse(DeepCatchup.offerFields(db, 'new-peer'))!.hasBuckets,
        isTrue,
      );
    },
  );

  test('a neighbor arriving after digest completion still gets one probe', () {
    // Digest completion runs before the first scan observes any neighbors.
    final neighborsAtCompletion = <String>[];
    for (final peer in neighborsAtCompletion) {
      DeepCatchup.claimProbe(peer);
    }

    // Presence refresh sees it later, even without a handshake callback.
    expect(DeepCatchup.claimProbe('late-peer'), isTrue);
    expect(DeepCatchup.claimProbe('late-peer'), isFalse);
  });

  test('a skipped probe remains eligible once the radio is available', () {
    for (var tick = 0; tick < 100; tick++) {
      expect(DeepCatchup.claimProbe('peer', request: () => false), isFalse);
    }
    expect(DeepCatchup.claimProbe('peer', request: () => true), isTrue);
    var duplicateRequests = 0;
    expect(
      DeepCatchup.claimProbe(
        'peer',
        request: () {
          duplicateRequests++;
          return true;
        },
      ),
      isFalse,
    );
    expect(duplicateRequests, 0);
  });

  test('presence refresh does not spend rounds on a known deep mismatch', () {
    DeepCatchup.remember('known-peer', const PeerDeepDigest(2));
    for (var tick = 0; tick < 100; tick++) {
      expect(DeepCatchup.claimProbe('known-peer'), isFalse);
    }
    expect(DeepCatchup.claimProbe('known-peer'), isFalse);
    expect(
      DeepCatchup.claimRound('known-peer', ourHash: 1, theirHash: 2),
      isTrue,
    );
  });

  test('cooldown and stale addresses do not exhaust the deep round budget', () {
    for (var tick = 0; tick < 100; tick++) {
      expect(
        DeepCatchup.claimRound(
          'peer',
          ourHash: 1,
          theirHash: 2,
          request: () => false,
        ),
        isFalse,
      );
    }
    var scheduled = 0;
    bool request() {
      scheduled++;
      return true;
    }

    for (var round = 0; round < DeepCatchup.maxRoundsPerPair; round++) {
      expect(
        DeepCatchup.claimRound(
          'peer',
          ourHash: 1,
          theirHash: 2,
          request: request,
        ),
        isTrue,
      );
    }
    expect(
      DeepCatchup.claimRound(
        'peer',
        ourHash: 1,
        theirHash: 2,
        request: request,
      ),
      isFalse,
    );
    expect(scheduled, DeepCatchup.maxRoundsPerPair);
    // Actual database progress grants a fresh bounded set of requests.
    expect(
      DeepCatchup.claimRound(
        'peer',
        ourHash: 3,
        theirHash: 2,
        request: request,
      ),
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
    expect(DeepCatchup.claimProbe('peer'), isTrue);
    expect(DeepCatchup.claimRound('peer', ourHash: 1, theirHash: 2), isTrue);
  });
}
