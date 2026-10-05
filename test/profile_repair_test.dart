import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_crdt/sqlite_crdt.dart';

import 'package:bluetooth_app/models/generated/mesh_data.pb.dart';
import 'package:bluetooth_app/services/database_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DatabaseService sender;
  late DatabaseService receiver;

  setUp(() async {
    sender = DatabaseService.forTesting(await SqliteCrdt.openInMemory());
    receiver = DatabaseService.forTesting(await SqliteCrdt.openInMemory());
    await sender.init();
    await receiver.init();
  });
  tearDown(() async {
    await sender.dispose();
    await receiver.dispose();
  });

  Future<void> profile(String id) => sender.upsertNodeProfile(
    NodeProfile(nodeId: id, displayName: id, timestamp: Int64(1)),
  );

  Future<Map<String, dynamic>> repair(bool deep) async {
    if (deep) {
      final digest = (await receiver.computeDeepDigest())!;
      return sender.getRowsForDeepMismatch(
        DatabaseService.decodeDeepBuckets(digest.buckets),
        maxRows: 1,
        peerKey: 'receiver',
      );
    }
    return sender.getRowsForMismatchedBuckets(
      DatabaseService.decodeBucketFingerprints(
        await receiver.getBucketFingerprintBlob(),
      ),
      maxRows: 1,
      peerKey: 'receiver',
    );
  }

  for (final deep in [false, true]) {
    test(
      '${deep ? 'deep' : 'recent'} repair finds two profiles from one writer',
      () async {
        await profile('peer-a');
        await profile('peer-b');
        // The receiver already knows the writer's latest clock, while both
        // earlier profiles are missing. They must not cancel in the XOR digest.
        await sender.upsertTextMessage(
          TextMessage(
            msgId: 'newest',
            originNodeId: 'writer',
            textContent: 'newest',
            timestamp: Int64(2),
          ),
        );
        await receiver.mergeSyncChangeset(
          await sender.getNewestRowsChangeset(maxRows: 1),
        );
        expect(
          await sender.getDeltaChangeset(await receiver.getVersionVector()),
          isEmpty,
        );
        for (var page = 0; page < 2; page++) {
          final rows = await repair(deep);
          expect(rows['users'], hasLength(1));
          await receiver.mergeSyncChangeset(rows);
        }
        expect(
          (await receiver.fetchNodeProfiles()).map((row) => row.nodeId).toSet(),
          {'peer-a', 'peer-b'},
        );
        expect(
          await receiver.getDatabaseHash(),
          await sender.getDatabaseHash(),
        );
      },
    );
  }

  test(
    'a one-row repair budget cannot expand into every profile from its writer',
    () async {
      for (final id in ['peer-a', 'peer-b', 'peer-c']) {
        await profile(id);
      }
      for (final deep in [false, true]) {
        expect((await repair(deep))['users'], hasLength(1));
      }
    },
  );
}
