import 'package:sqlite_crdt/sqlite_crdt.dart';

/// Helpers for paging inbound BLE catch-up without newest-N holes.
class MeshCatchup {
  static const int pageRows = 25;

  static int rowCount(Map<String, dynamic> changeset) {
    var n = 0;
    for (final v in changeset.values) {
      if (v is List) n += v.length;
    }
    return n;
  }

  /// Oldest-HLC first so crediting the page is a contiguous prefix per node.
  static Map<String, dynamic> takeOldest(
    Map<String, dynamic> delta, {
    int maxRows = pageRows,
  }) {
    final ranked = <({String table, dynamic row, String hlc})>[];
    for (final entry in delta.entries) {
      final rows = entry.value;
      if (rows is! List) continue;
      for (final row in rows) {
        final hlc = row is Map ? (row['hlc']?.toString() ?? '') : '';
        ranked.add((table: entry.key, row: row, hlc: hlc));
      }
    }
    ranked.sort((a, b) => a.hlc.compareTo(b.hlc));
    final take = ranked.length < maxRows ? ranked.length : maxRows;
    final out = <String, List<dynamic>>{};
    for (var i = 0; i < take; i++) {
      out.putIfAbsent(ranked[i].table, () => []).add(ranked[i].row);
    }
    return out;
  }

  /// Advance [prior] by the max HLC we actually shipped per author node.
  static Map<String, String> mergeVectorFromChangeset(
    Map<String, String> prior,
    Map<String, dynamic> changeset,
  ) {
    final next = Map<String, String>.from(prior);
    for (final rows in changeset.values) {
      if (rows is! List) continue;
      for (final row in rows) {
        if (row is! Map) continue;
        final hlc = row['hlc']?.toString();
        if (hlc == null || hlc.isEmpty) continue;
        var nid = row['node_id']?.toString();
        if (nid == null || nid.isEmpty) {
          try {
            nid = Hlc.parse(hlc).nodeId;
          } catch (_) {
            continue;
          }
        }
        final prev = next[nid];
        if (prev == null || hlc.compareTo(prev) > 0) {
          next[nid] = hlc;
        }
      }
    }
    return next;
  }
}
