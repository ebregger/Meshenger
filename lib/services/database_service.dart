import 'dart:async';
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
import 'local_deletion_store.dart';

class DatabaseService {
  DatabaseService({LocalDeletionStore? deletionStore})
    : _windowRows = recentWindowRows,
      _deletionStore = deletionStore ?? PreferencesLocalDeletionStore();

  DatabaseService.forTesting(
    SqliteCrdt database, {
    LocalDeletionStore? deletionStore,
    int windowRows = recentWindowRows,
  }) : _db = database,
       _windowRows = windowRows,
       _deletionStore = deletionStore ?? MemoryLocalDeletionStore();

  final int _windowRows;

  final LocalDeletionStore _deletionStore;

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
    // Gray-out lookups find a conversation's deletion notices by encoding.
    await _db!.execute('''
      CREATE INDEX IF NOT EXISTS idx_messages_conversation_encoding
      ON messages (conversation_id, content_encoding, hlc)
    ''');
    // The recent-window digest reads the newest live rows of each table.
    for (final table in const ['messages', 'users', 'bitmap_chunks']) {
      await _db!.execute(
        'CREATE INDEX IF NOT EXISTS idx_${table}_live_hlc ON $table (is_deleted, hlc)',
      );
    }
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
    _lastDirtyAt = DateTime.now();
    // Rebuild the whole-history digest as soon as writes pause, instead of on
    // the next handshake that finds it stale. Otherwise every catch-up round
    // starts with a digest one merge out of date and cannot use it.
    if (_onDeepDigestReady != null) scheduleDeepDigest();
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
            'SELECT * FROM messages $where AND NOT ($_isLocalBlank)$orderAndLimit',
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

    return _withoutLocalBlanks(delta);
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

  /// How many of the newest rows the everyday hash and fingerprints cover.
  /// Live sync only ever needs the recent past, so this keeps the work per
  /// handshake constant however long the history grows. Older rows are
  /// reconciled separately through the deep digest.
  static const int recentWindowRows = 1024;

  /// Buckets in the deep digest, which covers the whole history. Enough that a
  /// gap of a hundred rows or so touches only a fraction of the history, yet
  /// the 4 KB digest only travels when the hashes already disagree.
  static const int deepBucketCount = 1024;

  int _windowRevision = -1;
  List<_DigestRow>? _windowCache;

  /// Newest live rows across tables, newest first, capped at
  /// [recentWindowRows]. Cached until the next write or merge.
  Future<List<_DigestRow>> _recentWindow() async {
    final revision = _dbHashRevision;
    final cached = _windowCache;
    if (cached != null && _windowRevision == revision) return cached;
    final rows = <_DigestRow>[];
    Future<void> collect(String table, String idExpression) async {
      final result = await _crdt.query(
        'SELECT $idExpression AS id, hlc FROM $table '
        'WHERE is_deleted = 0 ORDER BY hlc DESC LIMIT ?1',
        [_windowRows],
      );
      for (final row in result) {
        final hlc = row['hlc'];
        final id = row['id']?.toString() ?? '';
        if (hlc is! String || hlc.isEmpty) continue;
        rows.add(_DigestRow(table, id, hlc));
      }
    }

    await collect('messages', 'msg_id');
    await collect('users', 'node_id');
    await collect('bitmap_chunks', "file_id || ':' || chunk_index");
    rows.sort((a, b) {
      final byHlc = b.hlc.compareTo(a.hlc);
      return byHlc != 0 ? byHlc : a.id.compareTo(b.id);
    });
    final window = rows.length > _windowRows
        ? rows.sublist(0, _windowRows)
        : rows;
    if (revision == _dbHashRevision) {
      _windowCache = window;
      _windowRevision = revision;
    }
    return window;
  }

  static Uint8List _packBuckets(List<int> xors) {
    final packed = Uint8List(xors.length * 4);
    final bd = ByteData.view(packed.buffer);
    for (var i = 0; i < xors.length; i++) {
      bd.setUint32(i * 4, xors[i], Endian.little);
    }
    return packed;
  }

  /// Compact anti-entropy digest of the recent window: XOR of row
  /// fingerprints per bucket. Locates small gaps without shipping every id.
  Future<Uint8List> getBucketFingerprintBlob() async {
    await init();
    final xors = List<int>.filled(fingerprintBucketCount, 0);
    for (final row in await _recentWindow()) {
      if (row.table == 'bitmap_chunks' || row.id.isEmpty) continue;
      final fp = rowFingerprint(row.id);
      xors[fp % fingerprintBucketCount] ^= fp;
    }
    return _packBuckets(xors);
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

  /// Indices of buckets whose local and remote digests differ.
  static Set<int> _differingBuckets(
    List<int> local,
    List<int> remote,
    int bucketCount,
  ) {
    final bad = <int>{};
    for (var i = 0; i < bucketCount; i++) {
      final theirs = i < remote.length ? remote[i] : 0;
      final ours = i < local.length ? local[i] : 0;
      if (ours != theirs) bad.add(i);
    }
    return bad;
  }

  /// Full rows for [ids], keyed like a changeset. Fetches only what is needed
  /// instead of serialising the whole database.
  Future<Map<String, dynamic>> _rowsForIds({
    required Iterable<String> messageIds,
    required Iterable<String> userNodeIds,
  }) async {
    final queries = <String, (String, List<Object?>)>{};
    final messages = messageIds.toList();
    final users = userNodeIds.toSet().toList();
    if (messages.isNotEmpty) {
      final marks = List.filled(messages.length, '?').join(',');
      queries['messages'] = (
        'SELECT * FROM messages WHERE is_deleted = 0 AND msg_id IN ($marks)',
        messages,
      );
    }
    if (users.isNotEmpty) {
      final marks = List.filled(users.length, '?').join(',');
      queries['users'] = (
        'SELECT * FROM users WHERE is_deleted = 0 AND node_id IN ($marks)',
        users,
      );
    }
    if (queries.isEmpty) return {};
    final changeset = await _crdt.getChangeset(customQueries: queries);
    changeset.removeWhere((_, rows) => rows.isEmpty);
    return _withoutLocalBlanks(changeset);
  }

  final Map<String, _RepairCursor> _repairCursors = {};

  /// Orders the rows that sit in buckets the peer disagrees with, putting the
  /// ones it is certainly missing first.
  ///
  /// A bucket's digest is the XOR of its rows' fingerprints. When the peer
  /// lacks exactly one row of a bucket, our digest XOR theirs is precisely that
  /// row's fingerprint, so we can tell which row it is and send only that one.
  /// Buckets where that does not work (the peer lacks several rows, or has
  /// rows we lack) fall back to sending every row in the bucket, after the
  /// certain ones.
  static List<_DigestRow> _likelyMissingFirst(
    Iterable<_DigestRow> inBadBuckets,
    List<int> local,
    List<int> remote,
    int bucketCount,
  ) {
    final byBucket = <int, List<_DigestRow>>{};
    for (final row in inBadBuckets) {
      byBucket
          .putIfAbsent(rowFingerprint(row.id) % bucketCount, () => [])
          .add(row);
    }
    final certain = <_DigestRow>[];
    final possible = <_DigestRow>[];
    byBucket.forEach((bucket, rows) {
      final theirs = bucket < remote.length ? remote[bucket] : 0;
      final ours = bucket < local.length ? local[bucket] : 0;
      final diff = ours ^ theirs;
      final exact = [
        for (final row in rows)
          if (rowFingerprint(row.id) == diff) row,
      ];
      if (exact.length == 1) {
        certain.add(exact.first);
      } else {
        possible.addAll(rows);
      }
    });
    int byId(_DigestRow a, _DigestRow b) => a.id.compareTo(b.id);
    certain.sort(byId);
    possible.sort(byId);
    return [...certain, ...possible];
  }

  /// One page of already-ordered repair candidates, sized to what will
  /// actually be sent.
  ///
  /// Each round the peer recomputes its digest, and rows it has received drop
  /// out of the candidates. While the candidate set keeps shrinking the page
  /// restarts at the front, which holds what is still missing. If a round
  /// achieved nothing, the page moves on instead, so rows the peer cannot
  /// accept never block the ones behind them and nothing is sent twice in a
  /// row.
  List<String> _repairPage(String key, List<String> ordered, int maxRows) {
    if (ordered.isEmpty || maxRows <= 0) return const [];
    if (ordered.length <= maxRows) {
      _repairCursors.remove(key);
      return ordered;
    }
    final previous = _repairCursors[key];
    final offset = previous == null || ordered.length < previous.candidates
        ? 0
        : (previous.offset + maxRows) % ordered.length;
    _repairCursors[key] = _RepairCursor(ordered.length, offset);
    return [
      for (var i = 0; i < maxRows; i++) ordered[(offset + i) % ordered.length],
    ];
  }

  /// Splits an ordered candidate list into message ids and user ids and picks
  /// one page: messages take the budget first, then profiles.
  Map<String, List<String>> _pickRepairRows(
    String key,
    List<_DigestRow> ordered,
    int maxRows,
  ) {
    final messages = [
      for (final row in ordered)
        if (row.table == 'messages') row.id,
    ];
    final users = [
      for (final row in ordered)
        if (row.table == 'users') row.id,
    ];
    final pickedMessages = _repairPage('$key:m', messages, maxRows);
    final pickedUsers = _repairPage(
      '$key:u',
      users,
      maxRows - pickedMessages.length,
    );
    return {'messages': pickedMessages, 'users': pickedUsers};
  }

  /// Recent-window rows in buckets whose XOR digest differs from
  /// [remoteBuckets]. Bounded by [recentWindowRows] however long history is.
  Future<Map<String, dynamic>> getRowsForMismatchedBuckets(
    List<int> remoteBuckets, {
    int maxRows = 150,
    String peerKey = '',
  }) async {
    await init();
    final local = decodeBucketFingerprints(await getBucketFingerprintBlob());
    final bad = _differingBuckets(local, remoteBuckets, fingerprintBucketCount);
    if (bad.isEmpty) return {};
    final candidates = <_DigestRow>[];
    for (final row in await _recentWindow()) {
      if (row.id.isEmpty) continue;
      if (row.table != 'messages' && row.table != 'users') continue;
      if (!bad.contains(rowFingerprint(row.id) % fingerprintBucketCount)) {
        continue;
      }
      candidates.add(row);
    }
    final picked = _pickRepairRows(
      'w:$peerKey',
      _likelyMissingFirst(
        candidates,
        local,
        remoteBuckets,
        fingerprintBucketCount,
      ),
      maxRows,
    );
    return _rowsForIds(
      messageIds: picked['messages']!,
      userNodeIds: picked['users']!,
    );
  }

  DeepDigest? _deepDigest;
  int _deepDigestRevision = -1;
  Future<DeepDigest?>? _deepDigestTask;
  void Function()? _onDeepDigestReady;

  /// Called whenever a fresh [DeepDigest] finishes computing in the background.
  set onDeepDigestReady(void Function()? callback) =>
      _onDeepDigestReady = callback;

  /// Whole-history digest, or null while it is stale.
  ///
  /// Never waits: a stale digest is recomputed in the background so the
  /// handshake stays fast, and [onDeepDigestReady] fires once it is current.
  /// Until then peers just compare their recent windows.
  DeepDigest? get freshDeepDigest {
    final cached = _deepDigest;
    if (cached != null && _deepDigestRevision == _dbHashRevision) return cached;
    scheduleDeepDigest();
    return null;
  }

  DateTime _lastDirtyAt = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _deepTimer;

  /// How long writes must pause before the whole-history digest is rebuilt.
  /// Rebuilding reads every row, so it waits for bursts of traffic to finish
  /// rather than competing with message writes and live syncs.
  static const Duration deepDigestSettle = Duration(seconds: 1);

  /// Rebuilds the deep digest in the background once writes have been quiet
  /// for [deepDigestSettle]. Safe to call repeatedly.
  void scheduleDeepDigest() {
    if (_db == null || _deepTimer != null || _deepDigestTask != null) return;
    final quiet = DateTime.now().difference(_lastDirtyAt);
    final wait = quiet >= deepDigestSettle
        ? Duration.zero
        : deepDigestSettle - quiet;
    _deepTimer = Timer(wait, () {
      _deepTimer = null;
      if (_db == null) return;
      if (DateTime.now().difference(_lastDirtyAt) < deepDigestSettle) {
        scheduleDeepDigest();
        return;
      }
      unawaited(computeDeepDigest());
    });
  }

  /// Recompute (or join the in-flight computation of) the deep digest.
  Future<DeepDigest?> computeDeepDigest() async {
    final cached = _deepDigest;
    if (cached != null && _deepDigestRevision == _dbHashRevision) return cached;
    final inFlight = _deepDigestTask;
    if (inFlight != null) return inFlight;
    final task = _buildDeepDigest();
    _deepDigestTask = task;
    try {
      return await task;
    } finally {
      if (identical(_deepDigestTask, task)) _deepDigestTask = null;
      // A write landed while this was building; queue the next rebuild.
      if (_deepDigestRevision != _dbHashRevision &&
          _onDeepDigestReady != null) {
        scheduleDeepDigest();
      }
    }
  }

  Future<DeepDigest?> _buildDeepDigest() async {
    try {
      await init();
      final revision = _dbHashRevision;
      final timer = Stopwatch()..start();
      final hlcs = <String>[];
      final xors = List<int>.filled(deepBucketCount, 0);
      Future<void> collect(String table, String? idColumn) async {
        final result = await _crdt.query(
          'SELECT ${idColumn ?? "''"} AS id, hlc FROM $table '
          'WHERE is_deleted = 0',
        );
        for (final row in result) {
          final hlc = row['hlc'];
          if (hlc is! String || hlc.isEmpty) continue;
          hlcs.add(hlc);
          final id = row['id']?.toString() ?? '';
          if (id.isEmpty) continue;
          final fp = rowFingerprint(id);
          xors[fp % deepBucketCount] ^= fp;
        }
      }

      await collect('messages', 'msg_id');
      await collect('users', 'node_id');
      await collect('bitmap_chunks', null);
      hlcs.sort();
      final digest = DeepDigest(_fnvHlcs(hlcs), _packBuckets(xors));
      debugPrint(
        '[DB] deep digest built: ${hlcs.length} rows in ${timer.elapsedMilliseconds} ms',
      );
      if (revision != _dbHashRevision) return null;
      _deepDigest = digest;
      _deepDigestRevision = revision;
      _onDeepDigestReady?.call();
      return digest;
    } catch (error) {
      // The database may have been closed mid-computation (shutdown, tests).
      debugPrint('[DB] deep digest skipped: $error');
      return null;
    }
  }

  static List<int> decodeDeepBuckets(List<int> raw) {
    final bd = ByteData.sublistView(Uint8List.fromList(raw));
    final out = List<int>.filled(deepBucketCount, 0);
    final n = raw.length ~/ 4;
    for (var i = 0; i < n && i < deepBucketCount; i++) {
      out[i] = bd.getUint32(i * 4, Endian.little);
    }
    return out;
  }

  /// Rows from the whole history that sit in buckets where the deep digest
  /// disagrees with [remoteBuckets]. This is the slower, older-history catch-up
  /// used after the recent windows already match.
  Future<Map<String, dynamic>> getRowsForDeepMismatch(
    List<int> remoteBuckets, {
    int maxRows = 150,
    String peerKey = '',
  }) async {
    await init();
    final digest = await computeDeepDigest();
    if (digest == null) return {};
    final local = decodeDeepBuckets(digest.buckets);
    final bad = _differingBuckets(local, remoteBuckets, deepBucketCount);
    if (bad.isEmpty) return {};
    Future<List<_DigestRow>> rowsInBadBuckets(
      String table,
      String column,
    ) async {
      final result = await _crdt.query(
        'SELECT $column AS id FROM $table WHERE is_deleted = 0',
      );
      return [
        for (final row in result)
          if (row['id'] != null &&
              row['id'].toString().isNotEmpty &&
              bad.contains(
                rowFingerprint(row['id'].toString()) % deepBucketCount,
              ))
            _DigestRow(table, row['id'].toString(), ''),
      ];
    }

    final candidates = [
      ...await rowsInBadBuckets('messages', 'msg_id'),
      ...await rowsInBadBuckets('users', 'node_id'),
    ];
    final picked = _pickRepairRows(
      'd:$peerKey',
      _likelyMissingFirst(candidates, local, remoteBuckets, deepBucketCount),
      maxRows,
    );
    return _rowsForIds(
      messageIds: picked['messages']!,
      userNodeIds: picked['users']!,
    );
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
              "AND COALESCE(text_content, '') != '' "
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
    final fullChangeset = _withoutLocalBlanks(await _crdt.getChangeset());
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
    _deepTimer?.cancel();
    _deepTimer = null;
    _onDeepDigestReady = null;
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

  /// FNV-1a 64-bit over [hlcs], which must already be sorted ascending.
  ///
  /// Uses Int64 from the fixnum package to avoid Dart's 53-bit JS integer limit.
  static int _fnvHlcs(List<String> hlcs) {
    var hash = Int64.parseHex('cbf29ce484222325');
    const fnvPrime64 = 0x00000100000001B3;
    for (final h in hlcs) {
      for (final b in utf8.encode(h)) {
        hash = hash ^ Int64(b & 0xFF);
        hash = hash * Int64(fnvPrime64);
      }
      // Delimiter to avoid accidental concatenation ambiguity.
      hash = hash ^ Int64(0x00);
      hash = hash * Int64(fnvPrime64);
    }
    return hash.toInt();
  }

  Future<int> _computeDatabaseHash(int revision) async {
    // Only the newest [recentWindowRows] rows count, so this stays cheap as
    // history grows. Deterministic order: sorted ascending.
    final window = await _recentWindow();
    final hlcs = [for (final row in window) row.hlc]..sort();
    final out = _fnvHlcs(hlcs);
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
          "SELECT * FROM messages WHERE is_deleted = 0 AND COALESCE(text_content, '') != ''",
          <Object?>[],
        ),
        'users': ('SELECT * FROM users WHERE is_deleted = 0', <Object?>[]),
      };
      final changeset = await _crdt.getChangeset(customQueries: customQueries);
      return _withoutLocalBlanks(Map<String, dynamic>.from(changeset));
    }

    final modifiedAfter = lastHlc.toHlc;
    final changeset = await _crdt.getChangeset(modifiedAfter: modifiedAfter);
    return _withoutLocalBlanks(Map<String, dynamic>.from(changeset));
  }

  /// Merges a CRDT changeset (from peer sync) into the local store.
  ///
  /// Round-trips through JSON + [_decodeChangeset] so `hlc` / `modified` become
  /// [Hlc] instances — required by [Crdt.validateChangeset].
  Future<void> mergeSyncChangeset(
    Map<String, dynamic> incoming, {
    void Function(String stage, int elapsedUs)? onStage,
  }) async {
    await init();
    // Re-sent rows we already hold change nothing, so they must not throw away
    // the cached hashes and digests that sync depends on.
    final alreadyKnown = await _changesetIsAlreadyKnown(incoming);
    if (!alreadyKnown) {
      _markDatabaseHashDirty();
      _invalidateVersionVectorCache();
    }

    // A blank live message is a copy some phone deleted for itself. Never take
    // it over a real message: the real text can come from anyone who has it.
    final changeset = _withoutLocalBlanks(incoming);

    final decodeTimer = Stopwatch()..start();
    final hydrated = _decodeChangeset(jsonEncode(changeset));
    onStage?.call('decode', decodeTimer.elapsedMicroseconds);

    final mergeTimer = Stopwatch()..start();
    await _crdt.merge(_castChangeset(hydrated));
    onStage?.call('crdt_merge', mergeTimer.elapsedMicroseconds);
    await _scrubMergedDeletedRows(changeset['messages']);

    // Invalidate again after the mutation so a read queued behind the early
    // invalidation cannot cache a snapshot from just before the merge.
    if (!alreadyKnown) {
      _markDatabaseHashDirty();
      _invalidateVersionVectorCache();
    }

    final settleTimer = Stopwatch()..start();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    onStage?.call('settle_delay', settleTimer.elapsedMicroseconds);
  }

  /// True only when every row in [changeset] is a message or profile that the
  /// local copy already holds at the same or a newer clock. Anything else,
  /// including any unfamiliar table, counts as new.
  Future<bool> _changesetIsAlreadyKnown(Map<String, dynamic> changeset) async {
    Future<bool> known(String table, String idColumn) async {
      final rows = changeset[table];
      if (rows is! List || rows.isEmpty) return true;
      final incoming = <String, String>{};
      for (final row in rows) {
        if (row is! Map) return false;
        final id = row[idColumn]?.toString() ?? '';
        final hlc = row['hlc']?.toString() ?? '';
        if (id.isEmpty || hlc.isEmpty) return false;
        incoming[id] = hlc;
      }
      final ids = incoming.keys.toList(growable: false);
      for (var start = 0; start < ids.length; start += 300) {
        final chunk = ids.sublist(
          start,
          start + 300 > ids.length ? ids.length : start + 300,
        );
        final marks = List.filled(chunk.length, '?').join(',');
        final existing = await _crdt.query(
          'SELECT $idColumn AS id, hlc FROM $table WHERE $idColumn IN ($marks)',
          chunk,
        );
        final local = <String, String>{
          for (final row in existing)
            if (row['id'] != null && row['hlc'] != null)
              row['id'].toString(): row['hlc'].toString(),
        };
        for (final id in chunk) {
          final mine = local[id];
          if (mine == null || incoming[id]!.compareTo(mine) > 0) return false;
        }
      }
      return true;
    }

    for (final entry in changeset.entries) {
      final rows = entry.value;
      if (rows is List &&
          rows.isNotEmpty &&
          entry.key != 'messages' &&
          entry.key != 'users') {
        return false;
      }
    }
    return await known('messages', 'msg_id') &&
        await known('users', 'mesh_node_id');
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
    final rows = await _crdt.query('''
      SELECT mesh_node_id, public_key FROM users
      WHERE is_deleted = 0 AND public_key IS NOT NULL AND public_key != ''
      ''');
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

  /// Notice row that says "this author deleted the chat up to here". Other
  /// members of a one-to-one chat show their older copies grayed out.
  static const String retireEncoding = 'retire1';

  /// A live message with no text is one this phone blanked on the user's
  /// request. Such rows are never sent to, or accepted from, other phones:
  /// deleting here must not hide or remove anything anywhere else, and a phone
  /// with an incomplete picture must still be able to take the real messages
  /// from whoever has them.
  static const String _isLocalBlank =
      "is_deleted = 0 AND COALESCE(text_content, '') = ''";

  /// Conversation id -> clock value before which this phone deleted messages.
  /// Kept in a local store, never in the synced database, so nothing another
  /// phone sends can create or move a mark.
  Map<String, String>? _localDeletions;

  Future<Map<String, String>> _loadLocalDeletions() async =>
      _localDeletions ??= await _deletionStore.read();

  Future<void> _markLocalDeletion(String conversationId, String hlc) async {
    final marks = await _loadLocalDeletions();
    final known = marks[conversationId];
    if (known != null && known.compareTo(hlc) >= 0) return;
    marks[conversationId] = hlc;
    await _deletionStore.write(marks);
  }

  /// Drops blank live message rows from an outgoing changeset.
  Map<String, dynamic> _withoutLocalBlanks(Map<String, dynamic> changeset) {
    final rows = changeset['messages'];
    if (rows is! List) return changeset;
    final kept = rows.where((row) => !_isBlankLiveRow(row)).toList();
    if (kept.length == rows.length) return changeset;
    final out = Map<String, dynamic>.from(changeset);
    if (kept.isEmpty) {
      out.remove('messages');
    } else {
      out['messages'] = kept;
    }
    return out;
  }

  static bool _isBlankLiveRow(Object? row) {
    if (row is! Map) return false;
    final deleted = row['is_deleted'];
    final isDeleted = deleted == true || deleted == 1 || deleted == '1';
    if (isDeleted) return false;
    return (row['text_content']?.toString() ?? '').isEmpty;
  }

  /// Blanks message text on this phone only. The row (id, hlc, metadata) stays
  /// so sync hashes and version vectors keep matching the other phones, and
  /// nothing is tombstoned, so the blanking never travels.
  Future<int> _blankMessageText(Iterable<String> messageIds) async {
    final ids = messageIds.toList(growable: false);
    if (ids.isEmpty) return 0;
    const chunkSize = 300;
    for (var start = 0; start < ids.length; start += chunkSize) {
      final chunk = ids.sublist(
        start,
        start + chunkSize > ids.length ? ids.length : start + chunkSize,
      );
      final placeholders = List<String>.generate(
        chunk.length,
        (index) => '?${index + 1}',
      ).join(', ');
      // `query` runs the statement as written: no new hlc, no tombstone.
      await _crdt.query(
        "UPDATE messages SET text_content = '' WHERE msg_id IN ($placeholders)",
        chunk,
      );
    }
    _crdt.onDatasetChanged(const ['messages'], _crdt.canonicalTime);
    return ids.length;
  }

  /// Blanks readable messages on this phone only (retention, clearing the
  /// shared room). Other phones keep their copies and nothing is broadcast.
  ///
  /// [participantNodeId] skips sealed relays this phone is only forwarding.
  /// [beforeHlc] limits the scrub to rows written before that clock value.
  Future<int> scrubTextMessages({
    String? conversationId,
    int? olderThanTimestampMs,
    String? participantNodeId,
    String? beforeHlc,
  }) async {
    await init();
    final liveRows = await _crdt.query('''
      SELECT msg_id, timestamp, conversation_id, origin_node_id, recipient_node_id, hlc
      FROM messages
      WHERE is_deleted = 0
        AND text_content != ''
        AND COALESCE(content_encoding, '') <> 'retire1'
      ''');
    final messageIds = <String>[];
    for (final row in liveRows) {
      final messageId = row['msg_id']?.toString() ?? '';
      if (messageId.isEmpty) continue;
      final rowConversation = row['conversation_id']?.toString() ?? '';
      if (conversationId != null && rowConversation != conversationId) {
        continue;
      }
      if (beforeHlc != null &&
          row['hlc'].toString().compareTo(beforeHlc) >= 0) {
        continue;
      }
      if (olderThanTimestampMs != null) {
        final timestamp = _timestampMillis(row['timestamp']);
        if (timestamp >= olderThanTimestampMs) continue;
      }
      if (participantNodeId != null && rowConversation.isNotEmpty) {
        final origin = row['origin_node_id']?.toString() ?? '';
        final recipient = row['recipient_node_id']?.toString() ?? '';
        final member =
            origin == participantNodeId ||
            recipient == participantNodeId ||
            rowConversation.contains(participantNodeId);
        if (!member) continue;
      }
      messageIds.add(messageId);
    }
    return _blankMessageText(messageIds);
  }

  /// Deletes a private or group chat from this phone only.
  ///
  /// Messages are blanked here and nothing is tombstoned, so no other phone
  /// loses anything. A local mark makes later-arriving copies of the old
  /// messages blank on arrival too. With [grayOutForOthers] a notice row is
  /// also written; the other person's phone then shows its older copies grayed
  /// out and keeps them until that person decides otherwise.
  ///
  /// Returns the notice's message id when one was written.
  Future<String?> deleteConversationLocally({
    required String conversationId,
    required String myNodeId,
    required bool grayOutForOthers,
  }) async {
    await init();
    if (conversationId.isEmpty) return null;

    final latestRetireHlc = await _latestRetireHlc(conversationId);
    final unseen = await _crdt.query(
      '''
      SELECT COUNT(*) AS c FROM messages
      WHERE is_deleted = 0
        AND conversation_id = ?1
        AND text_content != ''
        AND COALESCE(content_encoding, '') <> 'retire1'
        AND (?2 IS NULL OR hlc > ?2)
      ''',
      [conversationId, latestRetireHlc],
    );
    final hasNewMessages = (unseen.first['c'] as num? ?? 0) > 0;

    String? noticeId;
    String? scrubBefore = latestRetireHlc;
    if (hasNewMessages && grayOutForOthers) {
      noticeId = 'del-${DateTime.now().microsecondsSinceEpoch}-$myNodeId';
      await upsertTextMessage(
        TextMessage(
          msgId: noticeId,
          originNodeId: myNodeId,
          textContent: '{"v":1}',
          timestamp: Int64(DateTime.now().millisecondsSinceEpoch),
        ),
        conversationId: conversationId,
        contentEncoding: retireEncoding,
      );
      final written = await _crdt.query(
        'SELECT hlc FROM messages WHERE msg_id = ?1',
        [noticeId],
      );
      scrubBefore = written.first['hlc'].toString();
    } else if (hasNewMessages) {
      // Nothing is sent. Cover everything this phone has right now.
      scrubBefore = _crdt.canonicalTime.increment().toString();
    }
    if (scrubBefore == null) return null;

    await _markLocalDeletion(conversationId, scrubBefore);
    await scrubTextMessages(
      conversationId: conversationId,
      beforeHlc: scrubBefore,
    );
    return noticeId;
  }

  /// Clears the shared room on this phone only.
  Future<int> clearRoomLocally() async {
    await init();
    final mark = _crdt.canonicalTime.increment().toString();
    await _markLocalDeletion('', mark);
    return scrubTextMessages(conversationId: '', beforeHlc: mark);
  }

  /// Newest deletion notice written by a member of [conversationId], or null.
  /// Notices from anyone else are ignored.
  Future<String?> _latestRetireHlc(String conversationId) async {
    final rows = await _crdt.query(
      '''
      SELECT MAX(hlc) AS hlc FROM messages
      WHERE is_deleted = 0
        AND conversation_id = ?1
        AND content_encoding = 'retire1'
        AND origin_node_id != ''
        AND instr(conversation_id, origin_node_id) > 0
      ''',
      [conversationId],
    );
    return rows.isEmpty ? null : rows.first['hlc']?.toString();
  }

  /// Blanks messages that are grayed out because [conversationId] was deleted
  /// by the other person. Runs only when the user asks for it.
  Future<int> deleteRetiredMessagesLocally(String conversationId) async {
    await init();
    final hlc = await _latestRetireHlc(conversationId);
    if (hlc == null) return 0;
    await _markLocalDeletion(conversationId, hlc);
    return scrubTextMessages(conversationId: conversationId, beforeHlc: hlc);
  }

  /// Blanks freshly merged copies of messages this phone already deleted.
  Future<void> _scrubMergedDeletedRows(Object? rawRows) async {
    if (rawRows is! List || rawRows.isEmpty) return;
    final deletions = await _loadLocalDeletions();
    if (deletions.isEmpty) return;
    final idsByConversation = <String, List<String>>{};
    for (final raw in rawRows) {
      if (raw is! Map) continue;
      final conversation = raw['conversation_id']?.toString() ?? '';
      if (!deletions.containsKey(conversation)) continue;
      final id = raw['msg_id']?.toString() ?? '';
      if (id.isEmpty) continue;
      idsByConversation.putIfAbsent(conversation, () => []).add(id);
    }
    for (final entry in idsByConversation.entries) {
      final limit = deletions[entry.key]!;
      final rows = await _crdt.query('''
        SELECT msg_id, hlc FROM messages
        WHERE text_content != ''
          AND COALESCE(content_encoding, '') <> 'retire1'
          AND msg_id IN (${List<String>.generate(entry.value.length, (i) => '?${i + 1}').join(', ')})
        ''', entry.value);
      final stale = [
        for (final row in rows)
          if (row['hlc'].toString().compareTo(limit) < 0)
            row['msg_id'].toString(),
      ];
      await _blankMessageText(stale);
    }
  }

  /// Tombstones live chat rows and syncs the removal to every peer. Only the
  /// stress-test reset uses this; user-facing deletes are local-only.
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
    final liveRows = await _crdt.query('''
      SELECT msg_id, timestamp, conversation_id, origin_node_id, recipient_node_id
      FROM messages
      WHERE is_deleted = 0
      ORDER BY msg_id ASC
      ''');
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
        final member =
            origin == participantNodeId ||
            recipient == participantNodeId ||
            rowConversation.contains(participantNodeId);
        if (!member) continue;
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
  /// [conversationId] is empty for the shared room. Private and group threads
  /// are limited to rows whose id contains [viewerNodeId].
  ///
  /// [limit] keeps only the newest N messages (null means all), so a long
  /// thread opens on a small page. [limitUpdates] raises or lowers it while
  /// the stream is live, which re-runs the query once per change.
  Stream<List<TextMessageWithAuthor>> watchTextMessagesWithAuthors({
    String conversationId = '',
    String viewerNodeId = '',
    int? limit,
    Stream<int?>? limitUpdates,
  }) {
    final controller = StreamController<List<TextMessageWithAuthor>>();
    StreamSubscription<List<TextMessageWithAuthor>>? rows;
    StreamSubscription<int?>? updates;
    var current = limit;

    Future<void> listenToRows() async {
      await rows?.cancel();
      try {
        await init();
      } catch (error, stack) {
        controller.addError(error, stack);
        return;
      }
      if (controller.isClosed) return;
      rows = _watchThread(
        conversationId,
        viewerNodeId,
        () => current,
      ).listen(controller.add, onError: controller.addError);
    }

    controller.onListen = () {
      unawaited(listenToRows());
      updates = limitUpdates?.listen((next) {
        if (next == current) return;
        current = next;
        unawaited(listenToRows());
      });
    };
    controller.onCancel = () async {
      await updates?.cancel();
      await rows?.cancel();
      await controller.close();
    };
    return controller.stream;
  }

  Stream<List<TextMessageWithAuthor>> _watchThread(
    String conversationId,
    String viewerNodeId,
    int? Function() limit,
  ) {
    // A private thread is an exact match on the indexed conversation id; the
    // shared room also has to accept rows written before the column existed.
    final conversationMatch = conversationId.isEmpty
        ? "COALESCE(m.conversation_id, '') = ?1"
        : 'm.conversation_id = ?1';
    // The inner query picks the newest page of messages on their own; authors
    // and gray-out lookups are then only resolved for that page.
    final sql =
        '''
      SELECT
        t.msg_id,
        t.origin_node_id,
        t.text_content,
        t.timestamp,
        t.conversation_id,
        t.recipient_node_id,
        t.content_encoding,
        COALESCE(NULLIF(TRIM(u.display_name), ''), SUBSTR(t.origin_node_id, 1, 8)) AS author_name,
        (
          SELECT n.origin_node_id
          FROM messages n
          WHERE ?1 != ''
            AND n.conversation_id = t.conversation_id
            AND n.content_encoding = 'retire1'
            AND n.is_deleted = 0
            AND n.origin_node_id != ''
            AND instr(n.conversation_id, n.origin_node_id) > 0
            AND n.hlc > t.hlc
          ORDER BY n.hlc DESC
          LIMIT 1
        ) AS retired_by
      FROM (
        SELECT
          m.msg_id,
          m.origin_node_id,
          m.text_content,
          m.timestamp,
          m.hlc,
          COALESCE(m.conversation_id, '') AS conversation_id,
          COALESCE(m.recipient_node_id, '') AS recipient_node_id,
          COALESCE(NULLIF(m.content_encoding, ''), 'plain') AS content_encoding
        FROM messages m
        WHERE m.is_deleted = 0
          AND m.text_content != ''
          AND COALESCE(m.content_encoding, '') <> 'retire1'
          AND $conversationMatch
          AND (
            ?1 = ''
            OR (
              ?2 != ''
              AND instr(COALESCE(m.conversation_id, ''), ?2) > 0
            )
          )
        ORDER BY m.timestamp DESC, m.msg_id DESC
        LIMIT ?3
      ) t
      LEFT JOIN users u ON t.origin_node_id = u.mesh_node_id
      ORDER BY t.timestamp ASC, t.msg_id ASC
    ''';
    return _crdt
        .watch(sql, () => [conversationId, viewerNodeId, limit() ?? -1])
        .map((rows) {
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
                  retiredBy: r['retired_by']?.toString() ?? '',
                );
              })
              .toList(growable: false);
        });
  }

  Stream<List<String>> watchPrivateConversationIds(String viewerNodeId) async* {
    await init();
    const sql = '''
      SELECT DISTINCT conversation_id
      FROM messages
      WHERE is_deleted = 0
        AND text_content != ''
        AND COALESCE(content_encoding, '') <> 'retire1'
        AND COALESCE(conversation_id, '') != ''
        AND ?1 != ''
        AND instr(COALESCE(conversation_id, ''), ?1) > 0
      ORDER BY conversation_id ASC
    ''';
    yield* _crdt.watch(sql, () => [viewerNodeId]).map((rows) {
      return rows
          .map((row) => row['conversation_id']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toList(growable: false);
    });
  }

  /// The newest row of each conversation this viewer can open, newest first.
  /// One row per conversation keeps this small however long the room gets.
  Stream<List<Map<String, Object?>>> watchVisibleConversationRows(
    String viewerNodeId,
  ) async* {
    await init();
    const sql = '''
      SELECT
        msg_id,
        origin_node_id,
        text_content,
        MAX(timestamp) AS timestamp,
        COALESCE(conversation_id, '') AS conversation_id,
        COALESCE(recipient_node_id, '') AS recipient_node_id,
        COALESCE(NULLIF(content_encoding, ''), 'plain') AS content_encoding
      FROM messages
      WHERE is_deleted = 0
        AND text_content != ''
        AND COALESCE(content_encoding, '') <> 'retire1'
        AND (
          COALESCE(conversation_id, '') = ''
          OR (
            ?1 != ''
            AND instr(COALESCE(conversation_id, ''), ?1) > 0
          )
        )
      GROUP BY COALESCE(conversation_id, '')
      ORDER BY timestamp DESC
    ''';
    yield* _crdt.watch(sql, () => [viewerNodeId]);
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

/// One row's identity within the recent window digest.
class _DigestRow {
  const _DigestRow(this.table, this.id, this.hlc);
  final String table;
  final String id;
  final String hlc;
}

/// Where the last repair page for one peer started, and how many candidates
/// there were, so the next page can tell whether the last one achieved anything.
class _RepairCursor {
  const _RepairCursor(this.candidates, this.offset);
  final int candidates;
  final int offset;
}

/// Whole-history summary: a 64-bit hash plus bucketed fingerprints that let a
/// peer locate which old rows differ.
class DeepDigest {
  const DeepDigest(this.hash, this.buckets);
  final int hash;
  final Uint8List buckets;
}
