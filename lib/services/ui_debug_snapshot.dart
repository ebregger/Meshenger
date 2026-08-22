import 'package:flutter/foundation.dart' show debugPrint, listEquals;

/// Snapshot of what the chat UI has actually rendered.
///
/// Distinct from DB `/messages`: a row can land in SQLite before Flutter paints it.
/// Stress tests poll `/ui` and watch [revision] to detect UI changes.
class UiDebugSnapshot {
  UiDebugSnapshot._();

  static int revision = 0;
  static int changedAtMs = 0;
  static List<Map<String, String>> messages = const [];

  static final Set<String> _displayedLogged = <String>{};
  static List<String> _lastMsgIds = const [];

  /// Call after a chat frame paints with the list currently bound to the UI.
  static void reportRendered(List<Map<String, String>> rendered) {
    final ids = rendered.map((m) => m['msgId'] ?? '').toList(growable: false);
    if (listEquals(ids, _lastMsgIds)) return;

    _lastMsgIds = ids;
    revision += 1;
    changedAtMs = DateTime.now().millisecondsSinceEpoch;
    messages = List<Map<String, String>>.unmodifiable(
      rendered.map((m) => Map<String, String>.from(m)).toList(growable: false),
    );

    debugPrint(
      '[BENCHMARK] EVENT:UI_CHANGED | REVISION:$revision | COUNT:${messages.length} | TIMESTAMP:$changedAtMs',
    );

    // One DISPLAYED log per msgId for latency metrics (not on every rebuild).
    for (final m in messages) {
      final msgId = m['msgId'];
      if (msgId == null || msgId.isEmpty) continue;
      if (_displayedLogged.contains(msgId)) continue;
      _displayedLogged.add(msgId);
      debugPrint(
        '[BENCHMARK] MSG_ID:$msgId | EVENT:DISPLAYED | TIMESTAMP:$changedAtMs',
      );
    }
  }

  static Map<String, dynamic> toJson() => {
        'revision': revision,
        'changedAtMs': changedAtMs,
        'count': messages.length,
        'messages': messages,
      };
}
