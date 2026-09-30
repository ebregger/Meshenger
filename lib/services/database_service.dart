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

  DatabaseService.forTesting(SqliteCrdt database) : _db = database;

  SqliteCrdt? _db;
  Future<void>? _initTask;

  // Stage 2: DB hash is expensive; cache it and invalidate on known writes/merges.
  int? _cachedDbHashU32;
  bool _dbHashDirty = true;
  int _dbHashRevision = 0;
  Future<int>? _dbHashTask;

  // Urgent offers request the version vector after every local message write.
  // Keep a snapshot and advance its local frontier from the exact HLC assigned
  // to local writes; remote merges and deletes invalidate the snapshot.
  Map<String, String>? _cachedVersionVector;
  int _versionVectorRevision = 0;
  String? _localWriteFrontierHlc;

  Future<void> init() => _initTask ??= _initialize();

  Future<void> _initialize() async {
    if (_db == null) {
      final docsDir = await getApplicationDocumentsDirectory();
      final dbPath = '${docsDir.path}/mesh_network.db';
      _db = await SqliteCrdt.open(dbPath);
    }

    // sql_crdt appends is_deleted, hlc, node_id, modified — do not declare them here.
    // Use mesh_node_id (not node_id) so we do not duplicate CRDT's node_id column.
    await _db!.execute('''
      CREATE TABLE IF NOT EXISTS users (
        mesh_node_id TEXT PRIMARY KEY,
        display_name TEXT,
        timestamp INTEGER,
        public_key TEXT
      )
    ''');

    await _db!.execute('''
      CREATE TABLE IF NOT EXISTS messages (
        msg_id TEXT PRIMARY KEY,
        origin_node_id TEXT,
        text_content TEXT,
        timestamp INTEGER,
        conversation_id TEXT,
        recipient_node_id TEXT,
        content_encoding TEXT
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

    // Urgent live-row reads filter deleted records before sorting the newest
    // messages and profiles.
    await _db!.execute('''
      CREATE INDEX IF NOT EXISTS idx_messages_live_node_hlc
      ON messages (is_deleted, node_id, hlc)
    ''');
    await _db!.execute('''
      CREATE INDEX IF NOT EXISTS idx_users_live_node_hlc
      ON users (is_deleted, node_id, hlc)
    ''');
    await _db!.execute('''
      CREATE INDEX IF NOT EXISTS idx_bitmap_chunks_live_node_hlc
      ON bitmap_chunks (is_deleted, node_id, hlc)
    ''');
    // Delta queries use a per-node HLC frontier and must include tombstones.
    // This index keeps those queries bounded as deleted chat rows accumulate.
    await _db!.execute('''
      CREATE INDEX IF NOT EXISTS idx_messages_node_hlc
      ON messages (node_id, hlc)
    ''');
    await _db!.execute('''
      CREATE INDEX IF NOT EXISTS idx_users_node_hlc
      ON users (node_id, hlc)
    ''');
    await _db!.execute('''
      CREATE INDEX IF NOT EXISTS idx_bitmap_chunks_node_hlc
      ON bitmap_chunks (node_id, hlc)
    ''');

    await _ensureColumn(
      'ALTER TABLE users ADD COLUMN public_key TEXT NOT NULL DEFAULT \'\'',
    );
    await _ensureColumn(
      'ALTER TABLE messages ADD COLUMN conversation_id TEXT NOT NULL DEFAULT \'\'',
    );
    await _ensureColumn(
      'ALTER TABLE messages ADD COLUMN recipient_node_id TEXT NOT NULL DEFAULT \'\'',
    );
    await _ensureColumn(
      'ALTER TABLE messages ADD COLUMN content_encoding TEXT NOT NULL DEFAULT \'plain\'',
    );
  }

  Future<void> _ensureColumn(String sql) async {
    try {
      await _crdt.execute(sql);
    } catch (error) {
      final message = error.toString().toLowerCase();
      if (message.contains('duplicate column')) return;
      rethrow;
    }
  }

  SqliteCrdt get _crdt {
    final db = _db;
    if (db == null) {
      throw StateError('DatabaseService not initialized. Call init() first.');
    }
    return db;
  }

  void _invalidateVersionVectorCache() {
    _versionVectorRevision++;
    _cachedVersionVector = null;
  }

  void _markDatabaseHashDirty() {
    _dbHashRevision++;
    _dbHashDirty = true;
  }

  void _recordLocalWriteHlc(String hlc) {
    _markDatabaseHashDirty();
    final previousFrontier = _localWriteFrontierHlc;
    if (previousFrontier == null || hlc.compareTo(previousFrontier) > 0) {
      _localWriteFrontierHlc = hlc;
    }

    final vector = _cachedVersionVector;
    final nodeId = _crdt.nodeId;
    if (vector != null) {
      final previous = vector[nodeId];
      if (previous == null || hlc.compareTo(previous) > 0) {
        vector[nodeId] = hlc;
      }
    }
  }

  void _overlayLocalWriteFrontier(Map<String, String> vector) {
    final hlc = _localWriteFrontierHlc;
    if (hlc == null) return;
    final nodeId = _crdt.nodeId;
    final previous = vector[nodeId];
    if (previous == null || hlc.compareTo(previous) > 0) {
      vector[nodeId] = hlc;
    }
  }

  /// Underlying sql_crdt node id (canonical HLC identity).
  String get localNodeId => _crdt.nodeId;

  /// Global max HLC per logical node across mesh CRDT tables, including
  /// tombstones. Excluding tombstones makes every deleted row look perpetually
  /// newer than a peer's frontier, so catch-up resends the same delete pages.
  Future<Map<String, String>> getVersionVector() async {
    await init();
    final cached = _cachedVersionVector;
    if (cached != null) return Map<String, String>.from(cached);

    final revision = _versionVectorRevision;
    final result = await _crdt.query('''
      SELECT node_id, MAX(hlc) AS max_hlc
      FROM (
        SELECT node_id, hlc FROM messages
        UNION ALL
        SELECT node_id, hlc FROM users
        UNION ALL
        SELECT node_id, hlc FROM bitmap_chunks
      )
      WHERE node_id IS NOT NULL AND node_id != ''
      GROUP BY node_id
    ''');
    final vector = <String, String>{
      for (final row in result)
        if (row['node_id'] != null && row['max_hlc'] != null)
          row['node_id']! as String: row['max_hlc']! as String,
    };
    // Local writes can proceed while the query is queued. Their exact HLC is
    // tracked separately, so fold the latest local frontier into this result
    // rather than discarding the snapshot on every continuously arriving send.
    _overlayLocalWriteFrontier(vector);
    // A remote merge may finish while the query is queued. Avoid caching a
    // snapshot that predates that change; a later call will reload it.
    if (revision == _versionVectorRevision) {
      _cachedVersionVector = vector;
    }
    return Map<String, String>.from(vector);
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
    String? id = actualNodeId is String
        ? actualNodeId
        : actualNodeId?.toString();
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
    Map<String, dynamic> remoteVector, {
    int? maxRows,
  }) async {
    await init();
    final remote = _normalizeRemoteVector(remoteVector);
    final local = await getVersionVector();
    // Callers that immediately page or truncate a delta should avoid reading
    // and sorting the entire tombstone history just to keep the first rows.
    // Read one extra row per table so they can tell whether more data remains.
    final queryLimit = maxRows == null ? null : (maxRows < 0 ? 0 : maxRows) + 1;
    Map<String, dynamic> fullChangeset;
    if (local.isEmpty && queryLimit == null) {
      fullChangeset = await _crdt.getChangeset();
    } else {
      // Ask SQLite for rows beyond the peer's frontier instead of loading the
      // whole CRDT into Dart and filtering it. Tombstone-heavy databases can
      // contain thousands of old rows, while each live delta is usually tiny.
      final clauses = <String>[
        'node_id IS NULL',
        "node_id = ''",
        'hlc IS NULL',
        "hlc = ''",
      ];
      final args = <Object?>[];
      var parameter = 1;
      for (final entry in local.entries) {
        final remoteMax = remote[entry.key];
        if (remoteMax != null && entry.value.compareTo(remoteMax) <= 0) {
          continue;
        }
        if (remoteMax == null) {
          clauses.add('node_id = ?$parameter');
          args.add(entry.key);
          parameter++;
        } else {
          clauses.add('(node_id = ?$parameter AND hlc > ?${parameter + 1})');
          args
            ..add(entry.key)
            ..add(remoteMax);
          parameter += 2;
        }
      }
      final where = 'WHERE (${clauses.join(' OR ')})';
      final orderAndLimit = queryLimit == null
          ? ''
          : ' ORDER BY hlc ASC, msg_id ASC LIMIT ?$parameter';
      final userOrderAndLimit = queryLimit == null
          ? ''
          : ' ORDER BY hlc ASC, mesh_node_id ASC LIMIT ?$parameter';
      final bitmapOrderAndLimit = queryLimit == null
          ? ''
          : ' ORDER BY hlc ASC, file_id ASC, chunk_index ASC LIMIT ?$parameter';
      final queryArgs = <Object?>[...args, ?queryLimit];
      fullChangeset = await _crdt.getChangeset(
        customQueries: {
          'messages': (
            'SELECT * FROM messages $where$orderAndLimit',
            queryArgs,
          ),
          'users': ('SELECT * FROM users $where$userOrderAndLimit', queryArgs),
          'bitmap_chunks': (
            'SELECT * FROM bitmap_chunks $where$bitmapOrderAndLimit',
            queryArgs,
          ),
        },
      );
    }
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

  static int rowFingerprint(String id) {
    // FNV-1a 32-bit — used for bucketed gap fill that version vectors miss.
    var hash = 0x811c9dc5;
    for (final b in utf8.encode(id)) {
      hash ^= b & 0xff;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash;
  }

  /// Number of XOR buckets in [getBucketFingerprintBlob] (128 bytes on wire).
  static const int fingerprintBucketCount = 32;

  /// Compact anti-entropy digest: XOR of row fingerprints per bucket.
  /// Locates small gaps without shipping every id (full lists balloon GATT).
  Future<Uint8List> getBucketFingerprintBlob() async {
    await init();
    final xors = List<int>.filled(fingerprintBucketCount, 0);
    final msgRows = await _crdt.query(
      'SELECT msg_id FROM messages WHERE is_deleted = 0',
    );
    for (final row in msgRows) {
      final id = row['msg_id']?.toString();
      if (id == null || id.isEmpty) continue;
      final fp = rowFingerprint(id);
      xors[fp % fingerprintBucketCount] ^= fp;
    }
    final userRows = await _crdt.query(
      'SELECT node_id FROM users WHERE is_deleted = 0',
    );
    for (final row in userRows) {
      final id = row['node_id']?.toString();
      if (id == null || id.isEmpty) continue;
      final fp = rowFingerprint(id);
      xors[fp % fingerprintBucketCount] ^= fp;
    }
    final packed = Uint8List(fingerprintBucketCount * 4);
    final bd = ByteData.view(packed.buffer);
    for (var i = 0; i < fingerprintBucketCount; i++) {
      bd.setUint32(i * 4, xors[i], Endian.little);
    }
    return packed;
  }

  static List<int> decodeBucketFingerprints(List<int> raw) {
    final bd = ByteData.sublistView(Uint8List.fromList(raw));
    final out = List<int>.filled(fingerprintBucketCount, 0);
    final n = raw.length ~/ 4;
    for (var i = 0; i < n && i < fingerprintBucketCount; i++) {
      out[i] = bd.getUint32(i * 4, Endian.little);
    }
    return out;
  }

  /// Rows in buckets whose XOR digest differs from [remoteBuckets].
  Future<Map<String, dynamic>> getRowsForMismatchedBuckets(
    List<int> remoteBuckets, {
    int maxRows = 150,
  }) async {
    await init();
    final localBlob = await getBucketFingerprintBlob();
    final local = decodeBucketFingerprints(localBlob);
    final bad = <int>{};
    for (var i = 0; i < fingerprintBucketCount; i++) {
      final remote = i < remoteBuckets.length ? remoteBuckets[i] : 0;
      if (local[i] != remote) bad.add(i);
    }
    if (bad.isEmpty) return {};

    final fullChangeset = await _crdt.getChangeset();
    final out = <String, dynamic>{};
    var budget = maxRows;
    // Rotate through mismatched-bucket rows — newest-first starved stranded IDs
    // once newer traffic filled the same buckets (Red stuck ~30 behind).
    final epoch = DateTime.now().millisecondsSinceEpoch ~/ 3000;
    for (final entry in fullChangeset.entries) {
      if (budget <= 0) break;
      final candidates = <dynamic>[];
      for (final r in entry.value as List) {
        final id = _rowStableId(r);
        if (id.isEmpty) continue;
        final fp = rowFingerprint(id);
        if (bad.contains(fp % fingerprintBucketCount)) {
          candidates.add(r);
        }
      }
      if (candidates.isEmpty) continue;
      candidates.sort((a, b) => _rowStableId(a).compareTo(_rowStableId(b)));
      final start = (epoch * maxRows) % candidates.length;
      final slice = <dynamic>[];
      final take = candidates.length < budget ? candidates.length : budget;
      for (var i = 0; i < take; i++) {
        slice.add(candidates[(start + i) % candidates.length]);
      }
      out[entry.key] = slice;
      budget -= take;
    }
    return out;
  }

  /// Newest live rows across tables — safe bootstrap when peer frontier is unknown.
  /// Prefers `messages` so urgent push-on-write spends the row budget on chat, not profiles.
  Future<Map<String, dynamic>> getNewestRowsChangeset({
    int maxRows = 40,
  }) async {
    await init();
    final limit = maxRows < 0 ? 0 : maxRows;
    // Read only rows that can fit in the outgoing page. Fetching and sorting
    // every CRDT row in Dart made each urgent push slower as chat history grew.
    // Keep one bounded query per table because message rows retain priority
    // over profile and bitmap rows when the shared budget is applied below.
    final fullChangeset = await _crdt.getChangeset(
      customQueries: {
        'messages': (
          'SELECT * FROM messages WHERE is_deleted = 0 '
              'ORDER BY hlc DESC LIMIT ?1',
          [limit],
        ),
        'users': (
          'SELECT * FROM users WHERE is_deleted = 0 '
              'ORDER BY hlc DESC LIMIT ?1',
          [limit],
        ),
        'bitmap_chunks': (
          'SELECT * FROM bitmap_chunks WHERE is_deleted = 0 '
              'ORDER BY hlc DESC LIMIT ?1',
          [limit],
        ),
      },
    );
    final out = <String, dynamic>{};
    var budget = maxRows;
    final keys = fullChangeset.keys.toList()
      ..sort((a, b) {
        int rank(String k) => k == 'messages' ? 0 : (k == 'users' ? 2 : 1);
        return rank(a).compareTo(rank(b));
      });
    for (final key in keys) {
      if (budget <= 0) break;
      final rows = List<dynamic>.from(fullChangeset[key] as List);
      rows.sort((a, b) {
        final ha = a is Map ? (a['hlc']?.toString() ?? '') : '';
        final hb = b is Map ? (b['hlc']?.toString() ?? '') : '';
        return hb.compareTo(ha);
      });
      final take = rows.length < budget ? rows.length : budget;
      if (take > 0) {
        out[key] = rows.sublist(0, take);
        budget -= take;
      }
    }
    return out;
  }

  /// When FNV hashes differ but the version-vector delta is empty, older rows were
  /// skipped (later HLCs from the same node already merged). Prefer
  /// [getRowsForMismatchedBuckets]; this is a slow rotating fallback.
  Future<Map<String, dynamic>> getHashRepairChangeset({
    int maxRows = 120,
    String? peerKey,
  }) async {
    await init();
    final fullChangeset = await _crdt.getChangeset();
    final out = <String, dynamic>{};
    const bucketCount = 8;
    final epoch = DateTime.now().millisecondsSinceEpoch ~/ 2000;
    final salt = peerKey?.hashCode.abs() ?? 0;
    final bucket = (epoch + salt) % bucketCount;
    fullChangeset.forEach((table, records) {
      final rows = List<dynamic>.from(records as List);
      if (rows.isEmpty) return;
      final inBucket = rows.where((r) {
        final id = _rowStableId(r);
        if (id.isEmpty) return true;
        return id.hashCode.abs() % bucketCount == bucket;
      }).toList();
      inBucket.sort((a, b) => _rowStableId(a).compareTo(_rowStableId(b)));
      if (inBucket.isEmpty) return;
      final start = ((epoch ~/ bucketCount) * maxRows) % inBucket.length;
      final slice = <dynamic>[];
      final take = maxRows < inBucket.length ? maxRows : inBucket.length;
      for (var i = 0; i < take; i++) {
        slice.add(inBucket[(start + i) % inBucket.length]);
      }
      out[table] = slice;
    });
    return out;
  }

  static String _rowStableId(dynamic row) {
    if (row is! Map) return '';
    final id = row['msg_id'] ?? row['msgId'] ?? row['id'] ?? row['node_id'];
    return id?.toString() ?? '';
  }

  Future<void> dispose() async {
    await _db?.close();
    _db = null;
  }

  /// FNV-1a 64-bit hash of all live HLC values — the "fingerprint" of this node's database state.
  ///
  /// 64-bit gives ~5 billion unique combinations before the Birthday Paradox reaches 50%,
  /// versus ~77,000 for the old 32-bit hash. Two nodes with different data will almost
  /// never produce the same token, preventing them from permanently ignoring each other.
  Future<int> getDatabaseHash() async {
    await init();
    if (!_dbHashDirty && _cachedDbHashU32 != null) {
      return _cachedDbHashU32!;
    }
    final inFlight = _dbHashTask;
    if (inFlight != null) return inFlight;

    final revision = _dbHashRevision;
    final task = _computeDatabaseHash(revision);
    _dbHashTask = task;
    try {
      return await task;
    } finally {
      if (identical(_dbHashTask, task)) _dbHashTask = null;
    }
  }

  Future<int> _computeDatabaseHash(int revision) async {
    final result = await _crdt.query('''
      SELECT hlc FROM messages WHERE is_deleted = 0
      UNION ALL
      SELECT hlc FROM users WHERE is_deleted = 0
      UNION ALL
      SELECT hlc FROM bitmap_chunks WHERE is_deleted = 0
    ''');

    // FNV-1a 64-bit: offset basis and prime from the FNV spec.
    // Using Int64 from the fixnum package to avoid Dart's 53-bit JS integer limit.
    var hash = Int64.parseHex('cbf29ce484222325');
    const fnvPrime64 = 0x00000100000001B3;

    // Deterministic order: stable across query implementations.
    final hlcs = <String>[];
    for (final row in result) {
      final hlcString = row['hlc'];
      if (hlcString is! String || hlcString.isEmpty) continue;
      hlcs.add(hlcString);
    }
    hlcs.sort();

    for (final h in hlcs) {
      final bytes = utf8.encode(h);
      for (final b in bytes) {
        hash = hash ^ Int64(b & 0xFF);
        hash = hash * Int64(fnvPrime64);
      }
      // Delimiter to avoid accidental concatenation ambiguity.
      hash = hash ^ Int64(0x00);
      hash = hash * Int64(fnvPrime64);
    }

    final out = hash.toInt();
    // A write or merge may have been queued while the query was running. Keep
    // the computed value for current callers, but leave the cache dirty so the
    // next request refreshes it. This also prevents duplicate concurrent scans.
    if (revision == _dbHashRevision) {
      _cachedDbHashU32 = out;
      _dbHashDirty = false;
    }
    return out;
  }

  /// 8-byte big-endian representation of [getDatabaseHash].
  ///
  /// The full 64-bit hash is advertised over BLE. Receivers compare these 8 bytes
  /// against their own local hash to decide whether to initiate a sync.
  Future<Uint8List> getDatabaseHashBytes() async {
    final hashInt = await getDatabaseHash();
    final bytes = Uint8List(8);
    final bd = ByteData.view(bytes.buffer);
    // Write as two 32-bit big-endian words since ByteData has no setUint64.
    bd.setUint32(0, (hashInt >> 32) & 0xFFFFFFFF, Endian.big);
    bd.setUint32(4, hashInt & 0xFFFFFFFF, Endian.big);
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
        'messages': (
          'SELECT * FROM messages WHERE is_deleted = 0',
          <Object?>[],
        ),
        'users': ('SELECT * FROM users WHERE is_deleted = 0', <Object?>[]),
      };
      final changeset = await _crdt.getChangeset(customQueries: customQueries);
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
  Future<void> mergeSyncChangeset(
    Map<String, dynamic> changeset, {
    void Function(String stage, int elapsedUs)? onStage,
  }) async {
    await init();
    _markDatabaseHashDirty();
    _invalidateVersionVectorCache();

    final decodeTimer = Stopwatch()..start();
    final hydrated = _decodeChangeset(jsonEncode(changeset));
    onStage?.call('decode', decodeTimer.elapsedMicroseconds);

    final mergeTimer = Stopwatch()..start();
    await _crdt.merge(_castChangeset(hydrated));
    onStage?.call('crdt_merge', mergeTimer.elapsedMicroseconds);

    // Invalidate again after the mutation so a read queued behind the early
    // invalidation cannot cache a snapshot from just before the merge.
    _markDatabaseHashDirty();
    _invalidateVersionVectorCache();

    final settleTimer = Stopwatch()..start();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    onStage?.call('settle_delay', settleTimer.elapsedMicroseconds);
  }

  /// Whether [changeset] contains a message row that is newer than the local
  /// copy (or is not present locally). Call before merging so the mesh can
  /// relay newly received chat without re-forwarding every anti-entropy reply.
  Future<bool> hasNewerIncomingMessages(Map<String, dynamic> changeset) async {
    await init();
    final rawRows = changeset['messages'];
    if (rawRows is! List || rawRows.isEmpty) return false;

    final incomingById = <String, String?>{};
    for (final rawRow in rawRows) {
      if (rawRow is! Map) continue;
      final id = (rawRow['msg_id'] ?? rawRow['msgId'])?.toString();
      if (id == null || id.isEmpty) continue;
      incomingById[id] = rawRow['hlc']?.toString();
    }
    if (incomingById.isEmpty) return false;

    final ids = incomingById.keys.toList(growable: false);
    final placeholders = List<String>.generate(
      ids.length,
      (index) => '?${index + 1}',
    ).join(', ');
    final existingRows = await _crdt.query(
      'SELECT msg_id, hlc FROM messages WHERE msg_id IN ($placeholders)',
      ids,
    );
    final existingById = <String, String>{
      for (final row in existingRows)
        if (row['msg_id'] != null && row['hlc'] != null)
          row['msg_id']!.toString(): row['hlc']!.toString(),
    };

    for (final entry in incomingById.entries) {
      final existingHlc = existingById[entry.key];
      if (existingHlc == null) return true;
      final incomingHlc = entry.value;
      if (incomingHlc != null && incomingHlc.compareTo(existingHlc) > 0) {
        return true;
      }
    }
    return false;
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
    _markDatabaseHashDirty();
    final writeHlc = _crdt.canonicalTime.increment().toString();
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
    _recordLocalWriteHlc(writeHlc);
  }

  Future<List<NodeProfile>> fetchNodeProfiles() async {
    await init();
    final rows = await _crdt.query(
      'SELECT mesh_node_id, display_name, timestamp FROM users WHERE is_deleted = 0 ORDER BY timestamp DESC',
    );

    return rows.map((row) => nodeProfileFromRow(row)).toList(growable: false);
  }

  Stream<List<NodeProfile>> watchNodeProfiles() async* {
    await init();
    yield* _crdt
        .watch(
          'SELECT mesh_node_id, display_name, timestamp FROM users WHERE is_deleted = 0 ORDER BY timestamp DESC',
        )
        .map((rows) {
          return rows
              .map((r) => nodeProfileFromRow(r.cast<String, Object?>()))
              .toList(growable: false);
        });
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
  /// An empty [name] clears the custom label so peers fall back to the default
  /// mesh identity (truncated node id).
  ///
  /// This uses [IdentityService] so the user key matches `messages.origin_node_id`.
  Future<void> setLocalDisplayName(String name) async {
    await init();
    final trimmed = name.trim();

    final nodeId = await IdentityService().getOrCreateMyNodeId();
    _markDatabaseHashDirty();
    final writeHlc = _crdt.canonicalTime.increment().toString();
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
    _recordLocalWriteHlc(writeHlc);
  }

  /// Publishes this install's X25519 public key. The private seed never enters
  /// the CRDT. An unchanged key does not write a new row.
  Future<void> setLocalPublicKey(String nodeId, String publicKey) async {
    await init();
    final trimmedKey = publicKey.trim();
    final trimmedNodeId = nodeId.trim();
    if (trimmedNodeId.isEmpty || trimmedKey.isEmpty) return;
    if (await fetchPublicKey(trimmedNodeId) == trimmedKey) return;

    _markDatabaseHashDirty();
    final writeHlc = _crdt.canonicalTime.increment().toString();
    await _crdt.execute(
      '''
      INSERT INTO users (mesh_node_id, display_name, timestamp, public_key)
      VALUES (?1, '', ?2, ?3)
      ON CONFLICT(mesh_node_id) DO UPDATE SET
        public_key = excluded.public_key
      ''',
      [trimmedNodeId, DateTime.now().millisecondsSinceEpoch, trimmedKey],
    );
    _recordLocalWriteHlc(writeHlc);
  }

  Future<String?> fetchPublicKey(String nodeId) async {
    await init();
    final rows = await _crdt.query(
      '''
      SELECT public_key FROM users
      WHERE is_deleted = 0 AND mesh_node_id = ?1
      LIMIT 1
      ''',
      [nodeId],
    );
    if (rows.isEmpty) return null;
    final value = rows.first['public_key']?.toString() ?? '';
    return value.isEmpty ? null : value;
  }

  Future<Map<String, String>> fetchPublicKeys() async {
    await init();
    final rows = await _crdt.query(
      '''
      SELECT mesh_node_id, public_key FROM users
      WHERE is_deleted = 0 AND public_key IS NOT NULL AND public_key != ''
      ''',
    );
    return {
      for (final row in rows)
        if ((row['mesh_node_id']?.toString() ?? '').isNotEmpty)
          row['mesh_node_id'].toString(): row['public_key'].toString(),
    };
  }

  /// Uses [_crdt.execute] so sql_crdt injects `hlc` / `modified` and advances the clock.
  Future<void> upsertTextMessage(
    TextMessage value, {
    String conversationId = '',
    String recipientNodeId = '',
    String contentEncoding = 'plain',
  }) async {
    await init();
    _markDatabaseHashDirty();
    final writeHlc = _crdt.canonicalTime.increment().toString();
    await _crdt.execute(
      '''
      INSERT INTO messages (
        msg_id,
        origin_node_id,
        text_content,
        timestamp,
        conversation_id,
        recipient_node_id,
        content_encoding
      )
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
      ON CONFLICT(msg_id) DO UPDATE SET
        origin_node_id = excluded.origin_node_id,
        text_content = excluded.text_content,
        timestamp = excluded.timestamp,
        conversation_id = excluded.conversation_id,
        recipient_node_id = excluded.recipient_node_id,
        content_encoding = excluded.content_encoding
      ''',
      [
        value.msgId,
        value.originNodeId,
        value.textContent,
        value.timestamp.toInt(),
        conversationId,
        recipientNodeId,
        contentEncoding,
      ],
    );
    _recordLocalWriteHlc(writeHlc);
  }

  /// Tombstones live chat rows. Each delete gets its own HLC so catch-up pages
  /// do not treat one bulk delete as a single frontier.
  ///
  /// [conversationId] limits the delete to one thread. [olderThanTimestampMs]
  /// keeps newer rows. [participantNodeId] skips sealed relays this phone is
  /// only forwarding.
  Future<int> deleteTextMessages({
    String? conversationId,
    int? olderThanTimestampMs,
    String? participantNodeId,
  }) async {
    await init();
    _markDatabaseHashDirty();
    _invalidateVersionVectorCache();
    final liveRows = await _crdt.query(
      '''
      SELECT msg_id, timestamp, conversation_id, origin_node_id, recipient_node_id
      FROM messages
      WHERE is_deleted = 0
      ORDER BY msg_id ASC
      ''',
    );
    final messageIds = <String>[];
    for (final row in liveRows) {
      final messageId = row['msg_id']?.toString() ?? '';
      if (messageId.isEmpty) continue;
      final rowConversation = row['conversation_id']?.toString() ?? '';
      if (conversationId != null && rowConversation != conversationId) {
        continue;
      }
      if (olderThanTimestampMs != null) {
        final timestamp = _timestampMillis(row['timestamp']);
        if (timestamp >= olderThanTimestampMs) continue;
      }
      if (participantNodeId != null && rowConversation.isNotEmpty) {
        final origin = row['origin_node_id']?.toString() ?? '';
        final recipient = row['recipient_node_id']?.toString() ?? '';
        if (origin != participantNodeId && recipient != participantNodeId) {
          continue;
        }
      }
      messageIds.add(messageId);
    }
    for (final messageId in messageIds) {
      await _crdt.execute('DELETE FROM messages WHERE msg_id = ?1', [
        messageId,
      ]);
    }
    _markDatabaseHashDirty();
    _invalidateVersionVectorCache();
    return messageIds.length;
  }

  /// Stress-test reset: drop chat rows only; keep [users] display names.
  Future<int> clearTextMessages() async {
    final removed = await deleteTextMessages();
    await _crdt.execute('DELETE FROM bitmap_chunks');
    _markDatabaseHashDirty();
    _invalidateVersionVectorCache();
    return removed;
  }

  static int _timestampMillis(Object? value) {
    if (value is int) return value;
    if (value is Int64) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  Future<List<TextMessage>> fetchTextMessages() async {
    await init();
    final rows = await _crdt.query(
      'SELECT msg_id, origin_node_id, text_content, timestamp FROM messages WHERE is_deleted = 0 ORDER BY timestamp ASC',
    );

    return rows.map((row) => textMessageFromRow(row)).toList(growable: false);
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
      return list;
    });
  }

  /// Same as [watchTextMessages], but joins `messages` + `users` to include
  /// the author's display name.
  ///
  /// [conversationId] is empty for the shared room. Direct threads are limited
  /// to rows where [viewerNodeId] is a participant.
  Stream<List<TextMessageWithAuthor>> watchTextMessagesWithAuthors({
    String conversationId = '',
    String viewerNodeId = '',
  }) async* {
    await init();
    const sql = '''
      SELECT
        m.msg_id,
        m.origin_node_id,
        m.text_content,
        m.timestamp,
        COALESCE(m.conversation_id, '') AS conversation_id,
        COALESCE(m.recipient_node_id, '') AS recipient_node_id,
        COALESCE(NULLIF(m.content_encoding, ''), 'plain') AS content_encoding,
        COALESCE(NULLIF(TRIM(u.display_name), ''), SUBSTR(m.origin_node_id, 1, 8)) AS author_name
      FROM messages m
      LEFT JOIN users u ON m.origin_node_id = u.mesh_node_id
      WHERE m.is_deleted = 0
        AND COALESCE(m.conversation_id, '') = ?1
        AND (
          ?1 = ''
          OR m.origin_node_id = ?2
          OR m.recipient_node_id = ?2
        )
      ORDER BY m.timestamp ASC
    ''';
    yield* _crdt.watch(sql, () => [conversationId, viewerNodeId]).map((rows) {
      return rows
          .map((r) {
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
              conversationId: r['conversation_id']?.toString() ?? '',
              recipientNodeId: r['recipient_node_id']?.toString() ?? '',
              contentEncoding: r['content_encoding']?.toString() ?? 'plain',
            );
          })
          .toList(growable: false);
    });
  }

  Stream<List<String>> watchDirectConversationIds(String viewerNodeId) async* {
    await init();
    const sql = '''
      SELECT DISTINCT conversation_id
      FROM messages
      WHERE is_deleted = 0
        AND COALESCE(conversation_id, '') != ''
        AND (origin_node_id = ?1 OR recipient_node_id = ?1)
      ORDER BY conversation_id ASC
    ''';
    yield* _crdt.watch(sql, () => [viewerNodeId]).map((rows) {
      return rows
          .map((row) => row['conversation_id']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toList(growable: false);
    });
  }

  Future<void> upsertBitmapChunk(BitmapChunk value) async {
    await init();
    _markDatabaseHashDirty();
    final writeHlc = _crdt.canonicalTime.increment().toString();
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
    _recordLocalWriteHlc(writeHlc);
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

    return rows.map((row) => bitmapChunkFromRow(row)).toList(growable: false);
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
