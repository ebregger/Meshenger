import 'package:bluetooth_app/models/generated/mesh_data.pb.dart';
import 'package:bluetooth_app/services/ble_discovery_service.dart';
import 'package:bluetooth_app/services/database_service.dart';
import 'package:bluetooth_app/services/mesh_catchup.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_crdt/sqlite_crdt.dart';

void main() {
  test('held-link repair covers gaps beyond a tombstone frontier', () async {
    final sql = await SqliteCrdt.openInMemory();
    final sender = DatabaseService.forTesting(sql);
    final receiver = DatabaseService.forTesting(
      await SqliteCrdt.openInMemory(),
    );
    await sender.init();
    await receiver.init();
    addTearDown(sender.dispose);
    addTearDown(receiver.dispose);
    Future<void> write(String id) => sender.upsertTextMessage(
      TextMessage(
        msgId: id,
        originNodeId: sender.localNodeId,
        textContent: id,
        timestamp: Int64(1),
      ),
    );
    for (var index = 0; index < 1000; index++) {
      await write('old-$index');
    }
    await sender.clearTextMessages();
    await receiver.mergeSyncChangeset(await sender.getDeltaChangeset({}));
    expect(
      (await sql.query(
        'SELECT COUNT(*) AS n FROM messages WHERE is_deleted = 1',
      )).single['n'],
      1000,
    );
    for (var index = 0; index < 160; index++) {
      await write('live-${index.toString().padLeft(3, '0')}');
    }
    final latest = await sender.getNewestRowsChangeset(maxRows: 1);
    await receiver.mergeSyncChangeset(latest);
    // Learning the newest clock is not evidence that all older rows arrived.
    expect(
      await sender.getDeltaChangeset(await receiver.getVersionVector()),
      isEmpty,
    );
    final staleBuckets = DatabaseService.decodeBucketFingerprints(
      await receiver.getBucketFingerprintBlob(),
    );
    final expected = (await sender.fetchTextMessages())
        .map((m) => m.msgId)
        .toSet();
    final legacySeen = <String>{};
    final sent = <String>{};
    for (var round = 0; round < 8; round++) {
      final legacy = await sender.getRowsForMismatchedBuckets(
        staleBuckets,
        maxRows: 80,
        peerKey: 'legacy',
      );
      final oldPage = BleDiscoveryService.truncateChangesetForBle(
        legacy,
        maxRowsPerTable: MeshCatchup.pageRows,
      );
      for (final row in oldPage['messages'] as List? ?? []) {
        legacySeen.add((row as Map)['msg_id'].toString());
      }
      final page = await BleDiscoveryService.inboundRepairPage(
        sender,
        staleBuckets,
        peerId: 'fixed',
      );
      expect(
        MeshCatchup.rowCount(page),
        lessThanOrEqualTo(MeshCatchup.pageRows),
      );
      for (final row in page['messages'] as List? ?? []) {
        expect((row as Map)['is_deleted'], 0);
        sent.add(row['msg_id'].toString());
      }
      await receiver.mergeSyncChangeset(page);
    }
    expect(
      legacySeen.containsAll(expected),
      isFalse,
      reason: 'the original 80-row cursor plus 25-row truncation skips gaps',
    );
    expect(sent, containsAll(expected.difference({'live-159'})));
    expect(
      (await receiver.fetchTextMessages()).map((m) => m.msgId).toSet(),
      expected,
    );
    expect(await receiver.getDatabaseHash(), await sender.getDatabaseHash());
  }, timeout: const Timeout(Duration(minutes: 2)));
}
