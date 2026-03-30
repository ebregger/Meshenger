import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite_crdt/sqlite_crdt.dart';

import '../models/generated/mesh_data.pb.dart';
import 'database_mappers.dart';

class DatabaseService {
  DatabaseService();

  SqliteCrdt? _db;
  Future<void>? _initTask;

  Future<void> init() => _initTask ??= _initialize();

  Future<void> _initialize() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final dbPath = '${docsDir.path}/mesh_network.db';

    _db = await SqliteCrdt.open(dbPath);

    // sql_crdt appends is_deleted, hlc, node_id, modified — do not declare them here.
    // Use mesh_node_id (not node_id) so we do not duplicate CRDT's node_id column.
    await _db!.execute('''
      CREATE TABLE IF NOT EXISTS users (
        mesh_node_id TEXT PRIMARY KEY,
        display_name TEXT,
        timestamp INTEGER
      )
    ''');

    await _db!.execute('''
      CREATE TABLE IF NOT EXISTS messages (
        msg_id TEXT PRIMARY KEY,
        origin_node_id TEXT,
        text_content TEXT,
        timestamp INTEGER
      )
    ''');

    await _db!.execute('''
      CREATE TABLE IF NOT EXISTS bitmap_chunks (
        file_id TEXT,
        chunk_index INTEGER,
        total_chunks INTEGER,
        chunk_data BLOB,
        PRIMARY KEY (file_id, chunk_index)
      )
    ''');
  }

  SqliteCrdt get _crdt {
    final db = _db;
    if (db == null) {
      throw StateError('DatabaseService not initialized. Call init() first.');
    }
    return db;
  }

  Future<void> dispose() async {
    await _db?.close();
    _db = null;
  }

  /// Returns a CRDT changeset modified strictly after [lastHlc].
  /// If [lastHlc] is null, returns all live rows (`is_deleted = 0`) for a full mesh swap.
  Future<Map<String, dynamic>> getSyncChangeset(String? lastHlc) async {
    await init();
    final countRows = await _crdt.query(
      'SELECT COUNT(*) AS c FROM messages WHERE is_deleted = 0',
    );
    final msgCount = countRows.isEmpty ? 0 : countRows.first['c'];
    debugPrint('📊 DB STATS: Messages table count: $msgCount');

    if (lastHlc == null) {
      // Force a complete, deterministic swap for first-contact.
      // NOTE: do not filter by `modified` for this path — send everything live.
      final customQueries = <String, (String, List<Object?>)>{
        'messages': ('SELECT * FROM messages WHERE is_deleted = 0', <Object?>[]),
        'users': ('SELECT * FROM users WHERE is_deleted = 0', <Object?>[]),
      };
      final changeset = await _crdt.getChangeset(
        customQueries: customQueries,
      );
      return Map<String, dynamic>.from(changeset);
    }

    final modifiedAfter = lastHlc.toHlc;
    final changeset = await _crdt.getChangeset(modifiedAfter: modifiedAfter);
    return Map<String, dynamic>.from(changeset);
  }

  /// Merges a CRDT changeset (from peer sync) into the local store.
  ///
  /// Round-trips through JSON + [_decodeChangeset] so `hlc` / `modified` become
  /// [Hlc] instances — required by [Crdt.validateChangeset].
  Future<void> mergeSyncChangeset(Map<String, dynamic> changeset) async {
    await init();
    final rowsRaw = changeset['messages'];
    if (rowsRaw is List) {
      for (final row in rowsRaw) {
        if (row is! Map) continue;
        final id = row['msg_id'];
        debugPrint("📥 MERGING MSG: $id");
      }
    }
    final hydrated = _decodeChangeset(jsonEncode(changeset));
    debugPrint('💾 ATTEMPTING MERGE...');
    await _crdt.merge(_castChangeset(hydrated));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    debugPrint('✅ MERGE SUCCESSFUL');
  }

  /// Parses mesh sync JSON and restores hybrid logical clocks for CRDT merge.
  Map<String, dynamic> _decodeChangeset(String jsonString) {
    final decoded = jsonDecode(jsonString);
    if (decoded is! Map) {
      throw FormatException('Changeset root must be a JSON object');
    }
    final root = Map<String, dynamic>.from(decoded);
    final out = <String, dynamic>{};

    for (final tableEntry in root.entries) {
      final table = tableEntry.key;
      final rowsRaw = tableEntry.value;
      if (rowsRaw is! List) {
        out[table] = rowsRaw;
        continue;
      }
      final hydratedRows = <Map<String, Object?>>[];
      for (final row in rowsRaw) {
        if (row is! Map) continue;
        final rowMap = Map<String, Object?>.from(
          row.map((k, v) => MapEntry(k.toString(), v as Object?)),
        );
        for (final key in const ['hlc', 'modified']) {
          final v = rowMap[key];
          if (v is String && v.isNotEmpty) {
            rowMap[key] = Hlc.parse(v);
          }
        }
        hydratedRows.add(rowMap);
      }
      out[table] = hydratedRows;
    }
    return out;
  }

  Future<void> upsertNodeProfile(NodeProfile value) async {
    await init();
    await _crdt.execute(
      '''
      INSERT INTO users (mesh_node_id, display_name, timestamp)
      VALUES (?1, ?2, ?3)
      ON CONFLICT(mesh_node_id) DO UPDATE SET
        display_name = excluded.display_name,
        timestamp = excluded.timestamp
      ''',
      [value.nodeId, value.displayName, value.timestamp.toInt()],
    );
  }

  Future<List<NodeProfile>> fetchNodeProfiles() async {
    await init();
    final rows = await _crdt.query(
      'SELECT mesh_node_id, display_name, timestamp FROM users WHERE is_deleted = 0 ORDER BY timestamp DESC',
    );

    return rows
        .map(
          (row) => nodeProfileFromRow(row),
        )
        .toList(growable: false);
  }

  Stream<List<NodeProfile>> watchNodeProfiles() async* {
    await init();
    yield* _crdt
        .watch(
          'SELECT mesh_node_id, display_name, timestamp FROM users WHERE is_deleted = 0 ORDER BY timestamp DESC',
        )
        .map(
          (rows) => rows
              .map((r) => nodeProfileFromRow(r.cast<String, Object?>()))
              .toList(growable: false),
        );
  }

  /// Uses [_crdt.execute] so sql_crdt injects `hlc` / `modified` and advances the clock.
  Future<void> upsertTextMessage(TextMessage value) async {
    await init();
    await _crdt.execute(
      '''
      INSERT INTO messages (msg_id, origin_node_id, text_content, timestamp)
      VALUES (?1, ?2, ?3, ?4)
      ON CONFLICT(msg_id) DO UPDATE SET
        origin_node_id = excluded.origin_node_id,
        text_content = excluded.text_content,
        timestamp = excluded.timestamp
      ''',
      [
        value.msgId,
        value.originNodeId,
        value.textContent,
        value.timestamp.toInt(),
      ],
    );
  }

  Future<List<TextMessage>> fetchTextMessages() async {
    await init();
    final rows = await _crdt.query(
      'SELECT msg_id, origin_node_id, text_content, timestamp FROM messages WHERE is_deleted = 0 ORDER BY timestamp ASC',
    );

    return rows
        .map(
          (row) => textMessageFromRow(row),
        )
        .toList(growable: false);
  }

  /// Emits when the `messages` table changes (watch scope is that table only).
  Stream<List<TextMessage>> watchTextMessages() async* {
    await init();
    const sql =
        'SELECT msg_id, origin_node_id, text_content, timestamp FROM messages WHERE is_deleted = 0 ORDER BY timestamp ASC';
    yield* _crdt.watch(sql).map((rows) {
      final list = rows
          .map((r) => textMessageFromRow(r.cast<String, Object?>()))
          .toList(growable: false);
      debugPrint('📺 STREAM EMITTED: ${list.length} messages');
      return list;
    });
  }

  Future<void> upsertBitmapChunk(BitmapChunk value) async {
    await init();
    await _crdt.execute(
      '''
      INSERT INTO bitmap_chunks (file_id, chunk_index, total_chunks, chunk_data)
      VALUES (?1, ?2, ?3, ?4)
      ON CONFLICT(file_id, chunk_index) DO UPDATE SET
        total_chunks = excluded.total_chunks,
        chunk_data = excluded.chunk_data
      ''',
      [value.fileId, value.chunkIndex, value.totalChunks, value.chunkData],
    );
  }

  Future<List<BitmapChunk>> fetchBitmapChunks(String fileId) async {
    await init();
    final rows = await _crdt.query(
      '''
      SELECT file_id, chunk_index, total_chunks, chunk_data
      FROM bitmap_chunks
      WHERE file_id = ?1 AND is_deleted = 0
      ORDER BY chunk_index ASC
      ''',
      [fileId],
    );

    return rows
        .map(
          (row) => bitmapChunkFromRow(row),
        )
        .toList(growable: false);
  }

  static Map<String, List<Map<String, Object?>>> _castChangeset(
    Map<String, dynamic> changeset,
  ) {
    return changeset.map((table, rows) {
      final list = (rows as List).cast<dynamic>();
      final mapped = list
          .map((r) => (r as Map).cast<String, Object?>())
          .toList(growable: false);
      return MapEntry(table, mapped);
    });
  }
}
