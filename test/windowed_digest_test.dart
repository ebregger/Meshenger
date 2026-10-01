import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_crdt/sqlite_crdt.dart';

import 'package:bluetooth_app/models/generated/mesh_data.pb.dart';
import 'package:bluetooth_app/services/database_service.dart';

/// Window of 5 rows keeps the scenarios small; production uses 1000.
const _window = 5;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DatabaseService alice;
  late DatabaseService bob;

  setUp(() async {
    alice = DatabaseService.forTesting(
      await SqliteCrdt.openInMemory(),
      windowRows: _window,
    );
    bob = DatabaseService.forTesting(
      await SqliteCrdt.openInMemory(),
      windowRows: _window,
    );
    await alice.init();
    await bob.init();
  });

  tearDown(() async {
    await alice.dispose();
    await bob.dispose();
  });

  /// Real ids are random UUIDs, so their sort order says nothing about age.
  String scrambledId(int n) =>
      'm${(((n + 1) * 2654435761) % 4294967296).toRadixString(16)}';

  Future<void> say(DatabaseService db, int n, {bool scrambled = false}) async {
    await db.upsertTextMessage(
      TextMessage(
        msgId: scrambled ? scrambledId(n) : 'm${n.toString().padLeft(3, '0')}',
        originNodeId: 'alice',
        textContent: 'message $n',
        timestamp: Int64(DateTime.now().millisecondsSinceEpoch),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 3));
  }

  /// Bob only has alice's newest few rows, like a phone that just connected.
  Future<void> bobGetsNewest(int rows) async {
    final newest = await alice.getNewestRowsChangeset(maxRows: rows);
    await bob.mergeSyncChangeset(Map<String, dynamic>.from(newest));
  }

  test('the everyday hash only covers the newest rows', () async {
    for (var i = 0; i < 20; i++) {
      await say(alice, i);
    }
    await bobGetsNewest(8);

    expect(await bob.getDatabaseHash(), await alice.getDatabaseHash());
    expect(
      (await bob.computeDeepDigest())!.hash,
      isNot((await alice.computeDeepDigest())!.hash),
    );
  });

  test('a new message changes the window hash immediately', () async {
    for (var i = 0; i < 10; i++) {
      await say(alice, i);
    }
    final before = await alice.getDatabaseHash();
    await say(alice, 99);
    expect(await alice.getDatabaseHash(), isNot(before));
  });

  test('recent-window gap fill never reaches past the window', () async {
    for (var i = 0; i < 20; i++) {
      await say(alice, i);
    }
    // Bob has nothing, so every bucket differs.
    final rows = await alice.getRowsForMismatchedBuckets(
      List<int>.filled(DatabaseService.fingerprintBucketCount, 0),
    );
    final ids = [
      for (final row in (rows['messages'] as List? ?? const []))
        (row as Map)['msg_id'] as String,
    ];
    expect(ids, isNotEmpty);
    expect(ids.length, lessThanOrEqualTo(_window));
    for (final id in ids) {
      expect(
        id.compareTo('m015'),
        greaterThanOrEqualTo(0),
        reason: '$id is older than the window',
      );
    }
  });

  test('deep catch-up fills old history once the windows match', () async {
    for (var i = 0; i < 40; i++) {
      await say(alice, i);
    }
    await bobGetsNewest(8);
    expect(await bob.getDatabaseHash(), await alice.getDatabaseHash());

    var rounds = 0;
    while (rounds < 20) {
      final aliceDeep = (await alice.computeDeepDigest())!;
      final bobDeep = (await bob.computeDeepDigest())!;
      if (aliceDeep.hash == bobDeep.hash) break;
      final rows = await alice.getRowsForDeepMismatch(
        DatabaseService.decodeDeepBuckets(bobDeep.buckets),
        maxRows: 10,
      );
      expect(rows, isNotEmpty, reason: 'mismatch must always yield rows');
      await bob.mergeSyncChangeset(Map<String, dynamic>.from(rows));
      rounds++;
    }

    expect(
      (await bob.computeDeepDigest())!.hash,
      (await alice.computeDeepDigest())!.hash,
    );
    expect(rounds, greaterThan(1), reason: 'catch-up is paged, not one shot');
    final all = await bob.getNewestRowsChangeset(maxRows: 100);
    expect((all['messages'] as List).length, 40);
  });

  group('a large gap inside the window', () {
    late DatabaseService source;
    late DatabaseService lagging;

    setUp(() async {
      source = DatabaseService.forTesting(
        await SqliteCrdt.openInMemory(),
        windowRows: 100,
      );
      lagging = DatabaseService.forTesting(
        await SqliteCrdt.openInMemory(),
        windowRows: 100,
      );
      await source.init();
      await lagging.init();
      for (var i = 0; i < 110; i++) {
        await say(source, i, scrambled: true);
      }
      // The lagging phone has the newest 80 rows: its frontier is current, so
      // the version vector sees nothing missing, but the 30 oldest rows are
      // absent (20 of them inside the source's window).
      final newest = await source.getNewestRowsChangeset(maxRows: 80);
      await lagging.mergeSyncChangeset(Map<String, dynamic>.from(newest));
    });

    tearDown(() async {
      await source.dispose();
      await lagging.dispose();
    });

    Future<void> run({
      required Future<Map<String, dynamic>> Function() page,
      required Future<bool> Function() converged,
      required int maxRounds,
      required int expectedMissing,
      required double slack,
      bool noRepeats = true,
    }) async {
      final sent = <String>[];
      var rounds = 0;
      while (!await converged() && rounds < maxRounds) {
        final rows = await page();
        expect(rows, isNotEmpty, reason: 'a mismatch must yield rows');
        final ids = [
          for (final row in (rows['messages'] as List? ?? const []))
            (row as Map)['msg_id'] as String,
        ];
        sent.addAll(ids);
        await lagging.mergeSyncChangeset(Map<String, dynamic>.from(rows));
        rounds++;
      }
      expect(await converged(), isTrue, reason: 'did not converge');
      if (noRepeats) {
        expect(
          sent.length,
          sent.toSet().length,
          reason: 'the same row was sent more than once',
        );
      }
      expect(
        sent.length,
        lessThanOrEqualTo((expectedMissing * slack).ceil()),
        reason: 'sent ${sent.length} rows to fix $expectedMissing missing',
      );
    }

    test('whole-history fingerprints fix it without repeats', () async {
      await run(
        page: () async {
          final digest = (await lagging.computeDeepDigest())!;
          return source.getRowsForDeepMismatch(
            DatabaseService.decodeDeepBuckets(digest.buckets),
            maxRows: 8,
            peerKey: 'lagging',
          );
        },
        converged: () async =>
            (await lagging.computeDeepDigest())!.hash ==
            (await source.computeDeepDigest())!.hash,
        maxRounds: 10,
        expectedMissing: 30,
        slack: 1.2,
      );
    });

    test('window fingerprints keep moving instead of stalling', () async {
      await run(
        page: () async => source.getRowsForMismatchedBuckets(
          DatabaseService.decodeBucketFingerprints(
            await lagging.getBucketFingerprintBlob(),
          ),
          maxRows: 8,
          peerKey: 'lagging',
        ),
        converged: () async =>
            await lagging.getDatabaseHash() == await source.getDatabaseHash(),
        maxRounds: 12,
        expectedMissing: 20,
        slack: 2,
        // Only 32 coarse buckets: where several rows are missing from one,
        // the whole bucket is sent. It still has to converge promptly.
        noRepeats: false,
      );
    });
  });

  test('the deep digest rebuilds itself once writes pause', () async {
    var ready = 0;
    alice.onDeepDigestReady = () => ready++;
    await say(alice, 1);
    expect(alice.freshDeepDigest, isNull);
    await say(alice, 2);
    await Future<void>.delayed(DatabaseService.deepDigestSettle * 2);
    expect(ready, greaterThan(0));
    expect(alice.freshDeepDigest, isNotNull);

    // A merge (not just a local write) must queue the next rebuild too.
    final before = ready;
    await bob.upsertTextMessage(
      TextMessage(
        msgId: 'x1',
        originNodeId: 'bob',
        textContent: 'hi',
        timestamp: Int64(DateTime.now().millisecondsSinceEpoch),
      ),
    );
    final theirs = await bob.getNewestRowsChangeset(maxRows: 5);
    await alice.mergeSyncChangeset(Map<String, dynamic>.from(theirs));
    await Future<void>.delayed(DatabaseService.deepDigestSettle * 2);
    expect(ready, greaterThan(before));
  });

  test('a stale deep digest is never waited on', () async {
    await say(alice, 1);
    await alice.computeDeepDigest();
    expect(alice.freshDeepDigest, isNotNull);
    await say(alice, 2);
    expect(alice.freshDeepDigest, isNull);
    await alice.computeDeepDigest();
    expect(alice.freshDeepDigest, isNotNull);
  });
}
