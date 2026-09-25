import 'package:bluetooth_app/services/mesh_catchup.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, String> _row(String id, String nodeId, String hlc) => {
  'id': id,
  'node_id': nodeId,
  'hlc': hlc,
};

void main() {
  group('MeshCatchup', () {
    test('rowCount counts table rows and ignores envelope metadata', () {
      final changeset = <String, dynamic>{
        'messages': [_row('m1', 'a', '001'), _row('m2', 'b', '002')],
        'users': [_row('u1', 'a', '003')],
        'sender_id': 'peer',
        'vector': {'a': '003'},
      };

      expect(MeshCatchup.rowCount(changeset), 3);
    });

    test('takeOldest chooses one globally ordered page across tables', () {
      final delta = <String, dynamic>{
        'messages': [
          _row('m1', 'a', '001'),
          _row('m4', 'b', '004'),
        ],
        'users': [_row('u2', 'b', '002')],
        'bitmap_chunks': [_row('b3', 'a', '003')],
        'envelope_metadata': {'sender_id': 'ignored'},
      };

      final page = MeshCatchup.takeOldest(delta, maxRows: 3);
      final shipped = [
        for (final rows in page.values.whereType<List>()) ...rows,
      ].cast<Map>();

      expect(MeshCatchup.rowCount(page), 3);
      expect(
        shipped.map((row) => row['id']).toSet(),
        {'m1', 'u2', 'b3'},
      );
      expect(
        shipped.map((row) => row['hlc']).toList()..sort(),
        ['001', '002', '003'],
      );
      expect(page.containsKey('envelope_metadata'), isFalse);
    });

    test('takeOldest returns empty for an empty delta or a zero row limit', () {
      expect(MeshCatchup.takeOldest({}), isEmpty);
      expect(
        MeshCatchup.takeOldest({
          'messages': [_row('m1', 'a', '001')],
        }, maxRows: 0),
        isEmpty,
      );
    });

    test('mergeVectorFromChangeset advances only through rows shipped', () {
      final prior = <String, String>{'a': '002', 'b': '003'};
      final page = <String, dynamic>{
        'messages': [
          _row('a-old', 'a', '001'),
          _row('a-new', 'a', '004'),
          _row('b-old', 'b', '002'),
        ],
        'users': [_row('c-new', 'c', '006')],
      };

      final next = MeshCatchup.mergeVectorFromChangeset(prior, page);

      expect(next, {'a': '004', 'b': '003', 'c': '006'});
      expect(prior, {'a': '002', 'b': '003'});
    });

    test('repeated pages and vector advancement ship every row exactly once', () {
      final full = <String, dynamic>{
        'messages': [
          _row('a1', 'a', '001'),
          _row('a2', 'a', '003'),
          _row('b1', 'b', '002'),
          _row('b2', 'b', '004'),
        ],
        'users': [_row('a3', 'a', '005')],
        'bitmap_chunks': [_row('b3', 'b', '006')],
      };
      final sent = <String>[];
      var vector = <String, String>{};

      for (var turn = 0; turn < 10; turn++) {
        final remaining = <String, dynamic>{};
        for (final entry in full.entries) {
          final rows = (entry.value as List).where((row) {
            final owner = row['node_id'] as String;
            final hlc = row['hlc'] as String;
            final frontier = vector[owner];
            return frontier == null || hlc.compareTo(frontier) > 0;
          }).toList();
          if (rows.isNotEmpty) remaining[entry.key] = rows;
        }
        if (remaining.isEmpty) break;

        final page = MeshCatchup.takeOldest(remaining, maxRows: 2);
        expect(MeshCatchup.rowCount(page), lessThanOrEqualTo(2));
        for (final rows in page.values.whereType<List>()) {
          for (final row in rows) {
            sent.add(row['id'] as String);
          }
        }
        vector = MeshCatchup.mergeVectorFromChangeset(vector, page);
      }

      final expected = [
        for (final rows in full.values.whereType<List>())
          for (final row in rows)
            row['id'] as String,
      ];
      expect(sent.length, expected.length);
      expect(sent.toSet(), expected.toSet());
    });
  });
}
