import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_crdt/sqlite_crdt.dart';

import 'package:bluetooth_app/models/generated/mesh_data.pb.dart';
import 'package:bluetooth_app/services/database_service.dart';
import 'package:bluetooth_app/services/deep_index.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DeepIndex', () {
    DeepIndex fresh() => DeepIndex(
      bucketCount: DatabaseService.deepBucketCount,
      fingerprint: DatabaseService.rowFingerprint,
    );

    void put(DeepIndex index, String id, String hlc, {bool live = true}) =>
        index.apply(table: 'messages', key: id, id: id, hlc: hlc, live: live);

    test('does not depend on the order rows arrive in', () {
      final a = fresh();
      final b = fresh();
      for (var i = 0; i < 50; i++) {
        put(a, 'm$i', 'hlc$i');
      }
      for (var i = 49; i >= 0; i--) {
        put(b, 'm$i', 'hlc$i');
      }

      expect(a.hash, b.hash);
      expect(a.packedBuckets(), b.packedBuckets());
    });

    test('applying the same row twice changes nothing', () {
      final index = fresh();
      put(index, 'm1', 'hlc1');
      final hash = index.hash;
      final buckets = Uint8List.fromList(index.packedBuckets());

      put(index, 'm1', 'hlc1');

      expect(index.hash, hash);
      expect(index.packedBuckets(), buckets);
      expect(index.length, 1);
    });

    test('a row that is removed leaves the digest as if it never was', () {
      final index = fresh();
      put(index, 'm1', 'hlc1');
      final before = index.hash;
      final bucketsBefore = Uint8List.fromList(index.packedBuckets());

      put(index, 'm2', 'hlc2');
      expect(index.hash, isNot(before));
      put(index, 'm2', 'hlc2', live: false);

      expect(index.hash, before);
      expect(index.packedBuckets(), bucketsBefore);
    });

    test('a changed row swaps its old contribution for the new one', () {
      final changed = fresh();
      put(changed, 'm1', 'hlc1');
      put(changed, 'm1', 'hlc9');
      final direct = fresh();
      put(direct, 'm1', 'hlc9');

      expect(changed.hash, direct.hash);
      expect(changed.packedBuckets(), direct.packedBuckets());
    });

    test('rows without an id count towards the hash but not the buckets', () {
      final index = fresh();
      final empty = Uint8List.fromList(index.packedBuckets());
      index.apply(
        table: 'bitmap_chunks',
        key: 'f:0',
        id: '',
        hlc: 'hlc1',
        live: true,
      );

      expect(index.hash, isNot(0));
      expect(index.packedBuckets(), empty);
      expect(index.rowsInBuckets({for (var i = 0; i < 1024; i++) i}), isEmpty);
    });
  });

  group('incremental deep digest', () {
    late DatabaseService db;
    late DatabaseService peer;

    setUp(() async {
      db = DatabaseService.forTesting(await SqliteCrdt.openInMemory());
      peer = DatabaseService.forTesting(await SqliteCrdt.openInMemory());
      await db.init();
      await peer.init();
    });

    tearDown(() async {
      await db.dispose();
      await peer.dispose();
    });

    Future<void> say(
      DatabaseService target,
      String id, {
      String conversation = '',
    }) async {
      await target.upsertTextMessage(
        TextMessage(
          msgId: id,
          originNodeId: 'alice',
          textContent: 'text $id',
          timestamp: Int64(DateTime.now().millisecondsSinceEpoch),
        ),
        conversationId: conversation,
      );
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }

    /// The incremental digest must match one built from scratch.
    Future<void> expectExact(String step) async {
      final incremental = (await db.computeDeepDigest())!;
      final scratch = await db.deepDigestFromScratch();
      expect(incremental.hash, scratch.hash, reason: 'hash after $step');
      expect(
        incremental.buckets,
        scratch.buckets,
        reason: 'buckets after $step',
      );
    }

    test('stays exact through writes, merges, deletes and profiles', () async {
      await expectExact('start');

      for (var i = 0; i < 12; i++) {
        await say(db, 'm$i');
      }
      await expectExact('local messages');

      await db.upsertNodeProfile(NodeProfile(nodeId: 'ava', displayName: 'A'));
      await db.upsertNodeProfile(NodeProfile(nodeId: 'ava', displayName: 'B'));
      await expectExact('profile rewrite');

      for (var i = 0; i < 8; i++) {
        await say(peer, 'p$i');
      }
      final theirs = await peer.getNewestRowsChangeset(maxRows: 20);
      await db.mergeSyncChangeset(Map<String, dynamic>.from(theirs));
      await expectExact('merged rows');

      await say(db, 'priv1', conversation: 'a:b');
      await say(db, 'priv2', conversation: 'a:b');
      await db.deleteTextMessages(conversationId: 'a:b');
      await expectExact('conversation delete');

      await db.deleteTextMessages(olderThanTimestampMs: 1 << 62);
      await expectExact('room cleared');

      await say(db, 'after');
      await expectExact('write after clear');
    });

    test('merging old rows below the frontier is picked up', () async {
      for (var i = 0; i < 6; i++) {
        await say(peer, 'old$i');
      }
      final old = await peer.getNewestRowsChangeset(maxRows: 20);
      for (var i = 0; i < 6; i++) {
        await say(db, 'new$i');
      }
      expect((await db.computeDeepDigest())!.hash, isNotNull);

      // These rows carry hlcs far older than everything the phone holds.
      await db.mergeSyncChangeset(Map<String, dynamic>.from(old));
      await expectExact('old rows merged late');
    });

    test('a pass only reads what changed since the last one', () async {
      for (var i = 0; i < 30; i++) {
        await say(db, 'm$i');
      }
      await db.computeDeepDigest();
      final logged = <String>[];
      final original = debugPrint;
      debugPrint = (message, {wrapWidth}) => logged.add(message ?? '');
      addTearDown(() => debugPrint = original);

      await say(db, 'one more');
      await db.computeDeepDigest();

      final line = logged.firstWhere((l) => l.contains('deep digest updated'));
      final read = int.parse(RegExp(r'read (\d+)').firstMatch(line)!.group(1)!);
      expect(read, lessThan(5), reason: line);
      await expectExact('after incremental pass');
    });
  });
}
