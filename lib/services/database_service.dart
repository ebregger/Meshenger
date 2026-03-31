import 'dart:convert';
import 'dart:typed_data';

import 'package:fixnum/fixnum.dart' show Int64;
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite_crdt/sqlite_crdt.dart';

import '../models/generated/mesh_data.pb.dart';
import '../models/text_message_with_author.dart';
import 'identity_service.dart';
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

  /// Underlying sql_crdt node id (canonical HLC identity).
  String get localNodeId => _crdt.nodeId;

  /// Global max HLC per logical node across mesh CRDT tables (live rows only).
  Future<Map<String, String>> getVersionVector() async {
    await init();
    final result = await _crdt.query('''
      SELECT node_id, MAX(hlc) AS max_hlc
      FROM (
        SELECT node_id, hlc FROM messages WHERE is_deleted = 0
        UNION ALL
        SELECT node_id, hlc FROM users WHERE is_deleted = 0
        UNION ALL
        SELECT node_id, hlc FROM bitmap_chunks WHERE is_deleted = 0
      )
      WHERE node_id IS NOT NULL
      GROUP BY node_id
    ''');
    return {
      for (final row in result)
        if (row['node_id'] != null && row['max_hlc'] != null)
          row['node_id']! as String: row['max_hlc']! as String,
    };
  }

  static Map<String, String> _normalizeRemoteVector(
    Map<String, dynamic> remoteVector,
  ) {
    return {
      for (final e in remoteVector.entries)
        if (e.value != null) e.key.toString(): e.value.toString(),
    };
  }

  static String? _nodeIdForDeltaRow(Map<String, Object?> row, String rHlc) {
    var actualNodeId = row['node_id'];
    String? id =
        actualNodeId is String ? actualNodeId : actualNodeId?.toString();
    if (id != null && id.isEmpty) id = null;
    if (id == null) {
      try {
        id = Hlc.parse(rHlc).nodeId;
      } catch (_) {
        return null;
      }
    }
    return id;
  }

  /// Rows strictly newer than [remoteVector] per node (column or HLC-derived id).
  Future<Map<String, dynamic>> getDeltaChangeset(
    Map<String, dynamic> remoteVector,
  ) async {
    await init();
    final remote = _normalizeRemoteVector(remoteVector);
    final fullChangeset = await _crdt.getChangeset();
    final delta = <String, dynamic>{};

    fullChangeset.forEach((table, records) {
      final filtered = records.where((r) {
        final row = Map<String, Object?>.from(
          (r as Map).map((k, v) => MapEntry(k.toString(), v)),
        );
        final rHlcRaw = row['hlc'];
        if (rHlcRaw == null) return true;

        final rHlc = rHlcRaw is String ? rHlcRaw : rHlcRaw.toString();
        if (rHlc.isEmpty) return true;

        final actualNodeId = _nodeIdForDeltaRow(row, rHlc);
        if (actualNodeId == null) return true;

        final remoteMaxHlc = remote[actualNodeId];
        if (remoteMaxHlc == null) return true;

        return rHlc.compareTo(remoteMaxHlc) > 0;
      }).toList();

      if (filtered.isNotEmpty) delta[table] = filtered;
    });

    return delta;
  }

  Future<void> dispose() async {
    await _db?.close();
    _db = null;
  }

  /// XOR-based "sync token" representing current DB state.
  ///
  /// Uses CRDT HLC values so the token tracks true logical progress.
  Future<int> getDatabaseHash() async {
    await init();
    final result = await _crdt.query('''
      SELECT hlc FROM messages WHERE is_deleted = 0
      UNION ALL
      SELECT hlc FROM users WHERE is_deleted = 0
      UNION ALL
      SELECT hlc FROM bitmap_chunks WHERE is_deleted = 0
    ''');

    // IMPORTANT: Do NOT use Dart's `String.hashCode` here.
    // It is randomized per process and not stable across devices, which breaks
    // hash-based sync skipping and hash routing.
    const fnvOffsetBasis = 0x811C9DC5; // 2166136261
    const fnvPrime = 0x01000193; // 16777619

    // Deterministic order: stable across query implementations.
    final hlcs = <String>[];
    for (final row in result) {
      final hlcString = row['hlc'];
      if (hlcString is! String || hlcString.isEmpty) continue;
      hlcs.add(hlcString);
    }
    hlcs.sort();

    var hash = fnvOffsetBasis;
    for (final h in hlcs) {
      final bytes = utf8.encode(h);
      for (final b in bytes) {
        hash ^= b & 0xFF;
        hash = (hash * fnvPrime) & 0xFFFFFFFF;
      }
      // Delimiter to avoid accidental concatenation ambiguity.
      hash ^= 0x00;
      hash = (hash * fnvPrime) & 0xFFFFFFFF;
    }

    // Normalize into an unsigned 32-bit space.
    return hash & 0xFFFFFFFF;
  }

  /// 4-byte big-endian representation of [getDatabaseHash].
  Future<Uint8List> getDatabaseHashBytes() async {
    final hashInt = await getDatabaseHash();
    final bytes = Uint8List(4);
    final bd = ByteData.view(bytes.buffer);
    bd.setUint32(0, hashInt, Endian.big);
    return bytes;
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

  Future<List<String>> getAllUserIds() async {
    await init();
    final rows = await _crdt.query(
      'SELECT mesh_node_id FROM users WHERE is_deleted = 0',
    );
    return rows
        .map((r) => r['mesh_node_id']?.toString() ?? '')
        .where((s) => s.trim().isNotEmpty)
        .toList(growable: false);
  }

  Future<NodeProfile?> fetchNodeProfile(String nodeId) async {
    await init();
    final rows = await _crdt.query(
      'SELECT mesh_node_id, display_name, timestamp FROM users WHERE is_deleted = 0 AND mesh_node_id = ?1 ORDER BY timestamp DESC',
      [nodeId],
    );
    if (rows.isEmpty) return null;
    return nodeProfileFromRow(rows.first);
  }

  /// Updates the local display name in the CRDT-synced `users` table.
  ///
  /// This uses [IdentityService] so the user key matches `messages.origin_node_id`.
  Future<void> setLocalDisplayName(String name) async {
    await init();
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;

    final nodeId = await IdentityService().getOrCreateMyNodeId();
    await _crdt.execute(
      '''
      INSERT INTO users (mesh_node_id, display_name, timestamp)
      VALUES (?1, ?2, ?3)
      ON CONFLICT(mesh_node_id) DO UPDATE SET
        display_name = excluded.display_name,
        timestamp = excluded.timestamp
      ''',
      [nodeId, trimmed, DateTime.now().millisecondsSinceEpoch],
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

  /// Same as [watchTextMessages], but joins `messages` + `users` to include
  /// the author's display name.
  Stream<List<TextMessageWithAuthor>> watchTextMessagesWithAuthors() async* {
    await init();
    const sql = '''
      SELECT
        m.msg_id,
        m.origin_node_id,
        m.text_content,
        m.timestamp,
        COALESCE(u.display_name, SUBSTR(m.origin_node_id, 1, 8)) AS author_name
      FROM messages m
      LEFT JOIN users u ON m.origin_node_id = u.mesh_node_id
      WHERE m.is_deleted = 0
      ORDER BY m.timestamp ASC
    ''';
    yield* _crdt.watch(sql).map((rows) {
      return rows.map((r) {
        final msgId = r['msg_id']?.toString() ?? '';
        final originNodeId = r['origin_node_id']?.toString() ?? '';
        final textContent = r['text_content']?.toString() ?? '';
        final timestampRaw = r['timestamp'];
        final timestampMs = timestampRaw is Int64
            ? timestampRaw.toInt()
            : int.tryParse(timestampRaw?.toString() ?? '') ?? 0;
        final authorName = r['author_name']?.toString() ?? '';
        final shortId = originNodeId.length <= 8
            ? originNodeId
            : originNodeId.substring(0, 8);
        return TextMessageWithAuthor(
          msgId: msgId,
          originNodeId: originNodeId,
          textContent: textContent,
          timestamp: Int64(timestampMs),
          authorName: authorName.isNotEmpty ? authorName : shortId,
        );
      }).toList(growable: false);
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
