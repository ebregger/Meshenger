import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_crdt/sqlite_crdt.dart';

import 'package:bluetooth_app/models/generated/mesh_data.pb.dart';
import 'package:bluetooth_app/services/database_service.dart';

void main() {
  late SqliteCrdt sqlite;
  late DatabaseService database;

  setUp(() async {
    sqlite = await SqliteCrdt.openInMemory();
    database = DatabaseService.forTesting(sqlite);
    await database.init();
  });

  tearDown(() async {
    await database.dispose();
  });

  test('version vector advances over message tombstones', () async {
    final localNodeId = database.localNodeId;
    await database.upsertTextMessage(
      TextMessage(
        msgId: 'frontier-test-message',
        originNodeId: localNodeId,
        textContent: 'sync frontier test',
        timestamp: Int64(1),
      ),
    );
    final beforeDelete = await database.getVersionVector();

    expect(await database.clearTextMessages(), 1);
    final afterDelete = await database.getVersionVector();

    expect(afterDelete[localNodeId], isNotNull);
    expect(
      afterDelete[localNodeId]!.compareTo(beforeDelete[localNodeId]!),
      greaterThan(0),
    );
  });

  test('stress clear gives each message tombstone a distinct HLC', () async {
    final localNodeId = database.localNodeId;
    for (var i = 0; i < 5; i++) {
      await database.upsertTextMessage(
        TextMessage(
          msgId: 'clear-frontier-$i',
          originNodeId: localNodeId,
          textContent: 'clear frontier test',
          timestamp: Int64(i),
        ),
      );
    }

    expect(await database.clearTextMessages(), 5);
    final rows = await sqlite.query(
      'SELECT hlc FROM messages WHERE is_deleted = 1',
    );
    expect(rows.map((row) => row['hlc']).toSet(), hasLength(5));
  });

  test(
    'delta sends a newer tombstone once, then honors its frontier',
    () async {
      final localNodeId = database.localNodeId;
      await database.upsertTextMessage(
        TextMessage(
          msgId: 'frontier-test-message',
          originNodeId: localNodeId,
          textContent: 'sync frontier test',
          timestamp: Int64(1),
        ),
      );
      final beforeDelete = await database.getVersionVector();
      await database.clearTextMessages();

      final tombstoneDelta = await database.getDeltaChangeset(beforeDelete);
      final rows = tombstoneDelta['messages'] as List;
      expect(rows, hasLength(1));
      expect(rows.single['msg_id'], 'frontier-test-message');
      expect((rows.single['is_deleted'] as num).toInt(), 1);

      final afterDelete = await database.getVersionVector();
      expect(await database.getDeltaChangeset(afterDelete), isEmpty);
    },
  );

  test('bounded delta query reads one lookahead row per table', () async {
    final localNodeId = database.localNodeId;
    for (var i = 0; i < 40; i++) {
      await database.upsertTextMessage(
        TextMessage(
          msgId: 'bounded-delta-$i',
          originNodeId: localNodeId,
          textContent: 'bounded delta test',
          timestamp: Int64(i),
        ),
      );
    }

    final delta = await database.getDeltaChangeset(const {}, maxRows: 5);

    expect((delta['messages'] as List), hasLength(6));
  });

  test('remote message relay detection ignores rows already merged', () async {
    await database.upsertTextMessage(
      TextMessage(
        msgId: 'relay-existing-message',
        originNodeId: database.localNodeId,
        textContent: 'relay detection test',
        timestamp: Int64(1),
      ),
    );
    final rows = await sqlite.query(
      'SELECT hlc FROM messages WHERE msg_id = ?1',
      ['relay-existing-message'],
    );
    final existingHlc = rows.single['hlc'].toString();

    expect(
      await database.hasNewerIncomingMessages({
        'messages': [
          {'msg_id': 'relay-existing-message', 'hlc': existingHlc},
        ],
      }),
      isFalse,
    );
    expect(
      await database.hasNewerIncomingMessages({
        'messages': [
          {'msg_id': 'relay-new-message', 'hlc': existingHlc},
        ],
      }),
      isTrue,
    );
    expect(
      await database.hasNewerIncomingMessages({
        'messages': [
          {
            'msg_id': 'relay-existing-message',
            'hlc': sqlite.canonicalTime.increment().toString(),
          },
        ],
      }),
      isTrue,
    );
  });
}
