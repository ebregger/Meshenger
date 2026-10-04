import 'dart:async';

import 'package:bluetooth_app/models/generated/mesh_data.pb.dart';
import 'package:bluetooth_app/services/database_service.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_crdt/sqlite_crdt.dart';

// Keep real SQL and sql_crdt clock publication, withholding just one SQL
// completion so a write and a remote merge overlap deterministically.
class _HeldSql extends DatabaseApi {
  _HeldSql(this.sqlite);
  final SqliteCrdt sqlite;
  Completer<void>? entered;
  Completer<void>? release;
  bool _held = false;
  int overlappingWrites = 0;
  bool rejectNextWrite = false;

  void holdNextWrite() {
    entered = Completer<void>();
    release = Completer<void>();
  }

  @override
  Future<List<Map<String, Object?>>> query(String sql, [List<Object?>? args]) =>
      sqlite.query(sql, args);

  @override
  Future<void> execute(String sql, [List<Object?>? args]) async {
    if (rejectNextWrite) {
      rejectNextWrite = false;
      throw StateError('injected SQL failure');
    }
    if (_held) overlappingWrites++;
    await sqlite.query(sql, args);
    if (entered != null && !entered!.isCompleted) {
      _held = true;
      entered!.complete();
      await release!.future;
      _held = false;
    }
  }

  @override
  Future<void> transaction(Future<void> Function(ReadWriteApi) actions) =>
      actions(this);
}

class _TestCrdt extends SqlCrdt {
  _TestCrdt(this.sql) : super(sql);
  final _HeldSql sql;
  @override
  Future<Iterable<String>> getTables() => sql.sqlite.getTables();
  @override
  Future<Iterable<String>> getTableKeys(String table) =>
      sql.sqlite.getTableKeys(table);
}

TextMessage _message(String id) => TextMessage(
  msgId: id,
  originNodeId: 'test-author',
  textContent: id,
  timestamp: Int64(1),
);

void main() {
  test('a failed mutation does not block queued writes', () async {
    final sqlite = await SqliteCrdt.openInMemory();
    final sql = _HeldSql(sqlite);
    final crdt = _TestCrdt(sql);
    await crdt.init();
    final database = DatabaseService.forTesting(
      crdt,
      closeDatabase: sqlite.close,
    );
    await database.init();
    addTearDown(database.dispose);
    sql.rejectNextWrite = true;
    final failure = expectLater(
      database.upsertTextMessage(_message('rejected')),
      throwsStateError,
    );
    final writes = List.generate(
      20,
      (index) => database.upsertTextMessage(_message('queued-$index')),
    );
    await failure;
    await Future.wait(writes);
    final rows = await crdt.query('SELECT msg_id, hlc FROM messages');
    expect(rows, hasLength(20));
    expect(rows.map((row) => row['hlc']).toSet(), hasLength(20));
    expect(rows.any((row) => row['msg_id'] == 'rejected'), isFalse);
    expect(
      (await database.getVersionVector())[crdt.nodeId],
      (await crdt.query('SELECT MAX(hlc) AS hlc FROM messages')).single['hlc'],
    );
  });

  test(
    'a held local write publishes before a queued write and remote merge',
    () async {
      final sqlite = await SqliteCrdt.openInMemory();
      final sql = _HeldSql(sqlite);
      final crdt = _TestCrdt(sql);
      await crdt.init();
      final database = DatabaseService.forTesting(
        crdt,
        closeDatabase: sqlite.close,
      );
      await database.init();
      addTearDown(database.dispose);
      final remote = await SqliteCrdt.openInMemory();
      final peer = DatabaseService.forTesting(remote);
      await peer.init();
      addTearDown(peer.dispose);
      await peer.upsertTextMessage(_message('remote'));
      final incoming = await peer.getSyncChangeset(null);

      sql.holdNextWrite();
      final first = database.upsertTextMessage(_message('local-first'));
      await sql.entered!.future;
      final second = database.upsertTextMessage(_message('local-second'));
      final merge = database.mergeSyncChangeset(incoming);
      final completion = expectLater(
        Future.wait([first, second, merge]),
        completes,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final overlaps = sql.overlappingWrites;
      sql.release!.complete();
      await completion;

      expect(overlaps, 0);
      expect(
        (await database.fetchTextMessages()).map((row) => row.msgId).toSet(),
        {'local-first', 'local-second', 'remote'},
      );
      final actual = await crdt.query(
        'SELECT node_id, MAX(hlc) AS hlc FROM messages GROUP BY node_id',
      );
      final vector = await database.getVersionVector();
      for (final row in actual) {
        expect(vector[row['node_id']], row['hlc']);
      }
    },
  );
}
