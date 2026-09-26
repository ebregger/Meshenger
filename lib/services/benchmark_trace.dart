import 'package:flutter/foundation.dart' show debugPrint;

/// Emits message-id-only breadcrumbs for the two-phone stress trace.
///
/// Message text is deliberately excluded; benchmark rows can be correlated by
/// their CRDT msg_id without logging user content.
void traceBenchmarkMessage(
  String messageId,
  String event, {
  Map<String, Object?> fields = const {},
}) {
  if (messageId.isEmpty) return;
  final values = <String>[
    'MSG_ID:$messageId',
    'EVENT:$event',
    'TIMESTAMP:${DateTime.now().millisecondsSinceEpoch}',
    for (final entry in fields.entries)
      if (entry.value != null) '${entry.key}:${entry.value}',
  ];
  debugPrint('[BENCHMARK] ${values.join(' | ')}');
}

List<String> benchmarkMessageIds(Map<String, dynamic> changeset) {
  final rows = changeset['messages'];
  if (rows is! List) return const [];
  return [
    for (final row in rows)
      if (row is Map) (row['msg_id'] ?? row['msgId'])?.toString() ?? '',
  ]..removeWhere((id) => id.isEmpty);
}

void traceBenchmarkMessageRows(
  String event,
  Map<String, dynamic> changeset, {
  Map<String, Object?> fields = const {},
}) {
  for (final messageId in benchmarkMessageIds(changeset)) {
    traceBenchmarkMessage(messageId, event, fields: fields);
  }
}
