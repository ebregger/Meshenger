import 'dart:convert';
import 'dart:typed_data';

/// One live row as the deep index remembers it.
class DeepIndexEntry {
  const DeepIndexEntry({
    required this.table,
    required this.id,
    required this.hlc,
    required this.fingerprint,
  });

  final String table;

  /// Id used for fingerprints and repair; empty for rows that only count
  /// towards the hash (such as image chunks).
  final String id;
  final String hlc;
  final int fingerprint;
}

/// Whole-history digest that is updated one row at a time.
///
/// Rebuilding the digest from every row made each rebuild cost as much as the
/// history is long. This keeps the contribution of every live row, so a write
/// only has to remove the row's old contribution and add its new one. Both the
/// hash and the bucket fingerprints are order independent for that reason: the
/// hash is the sum of a 64-bit hash of every live row's HLC, and each bucket is
/// the XOR of its rows' fingerprints.
class DeepIndex {
  DeepIndex({required this.bucketCount, required this.fingerprint})
    : _buckets = List<int>.filled(bucketCount, 0);

  final int bucketCount;
  final int Function(String id) fingerprint;

  final Map<String, DeepIndexEntry> _entries = {};
  final List<int> _buckets;
  int _hash = 0;

  /// Highest `modified` value already applied, per table. Rows changed at or
  /// after it are what the next incremental pass has to read.
  final Map<String, String> modifiedMark = {};

  /// Whether the first full pass has been applied.
  bool seeded = false;

  int get length => _entries.length;
  int get hash => _hash;

  static int _hlcHash(String hlc) {
    // FNV-1a 64-bit. Dart's VM integers wrap at 64 bits, which is the point.
    var hash = -3750763034362895579; // 0xcbf29ce484222325
    for (final b in utf8.encode(hlc)) {
      hash = (hash ^ b) * 0x100000001b3;
    }
    return hash;
  }

  /// Records the current state of one row. Safe to repeat for the same row.
  ///
  /// [key] identifies the row within its table; [id] is what fingerprints are
  /// computed from. A row that is no longer [live] is removed.
  void apply({
    required String table,
    required String key,
    required String id,
    required String hlc,
    required bool live,
  }) {
    final entryKey = '$table\u0000$key';
    final previous = _entries.remove(entryKey);
    if (previous != null) _contribute(previous, -1);
    if (!live || hlc.isEmpty) return;
    final entry = DeepIndexEntry(
      table: table,
      id: id,
      hlc: hlc,
      fingerprint: id.isEmpty ? 0 : fingerprint(id),
    );
    _entries[entryKey] = entry;
    _contribute(entry, 1);
  }

  void _contribute(DeepIndexEntry entry, int sign) {
    _hash += sign * _hlcHash(entry.hlc);
    if (entry.id.isNotEmpty) {
      _buckets[entry.fingerprint % bucketCount] ^= entry.fingerprint;
    }
  }

  /// Forgets everything, so the next pass starts from scratch.
  void clear() {
    _entries.clear();
    _buckets.fillRange(0, bucketCount, 0);
    _hash = 0;
    modifiedMark.clear();
    seeded = false;
  }

  /// Packed little-endian bucket fingerprints, as sent to peers.
  Uint8List packedBuckets() {
    final packed = Uint8List(bucketCount * 4);
    final bd = ByteData.view(packed.buffer);
    for (var i = 0; i < bucketCount; i++) {
      bd.setUint32(i * 4, _buckets[i], Endian.little);
    }
    return packed;
  }

  /// Live rows with an id whose bucket is in [buckets].
  Iterable<DeepIndexEntry> rowsInBuckets(Set<int> buckets) sync* {
    for (final entry in _entries.values) {
      if (entry.id.isEmpty) continue;
      if (buckets.contains(entry.fingerprint % bucketCount)) yield entry;
    }
  }
}
