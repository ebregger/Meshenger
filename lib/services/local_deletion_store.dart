import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Remembers, on this phone only, which chats the user deleted and how far.
///
/// The marks map a conversation id (empty for the shared room) to a clock
/// value: messages written before it were deleted on this phone. They are
/// deliberately kept out of the synced database so no other phone can create,
/// change or clear them.
abstract class LocalDeletionStore {
  Future<Map<String, String>> read();

  Future<void> write(Map<String, String> marks);
}

class MemoryLocalDeletionStore implements LocalDeletionStore {
  Map<String, String> _marks = {};

  @override
  Future<Map<String, String>> read() async => Map.of(_marks);

  @override
  Future<void> write(Map<String, String> marks) async {
    _marks = Map.of(marks);
  }
}

class PreferencesLocalDeletionStore implements LocalDeletionStore {
  PreferencesLocalDeletionStore({SharedPreferences? preferences})
    : _preferences = preferences;

  static const String _key = 'local_deletion_marks_v1';

  final SharedPreferences? _preferences;

  Future<SharedPreferences> _prefs() async =>
      _preferences ?? await SharedPreferences.getInstance();

  @override
  Future<Map<String, String>> read() async {
    final raw = (await _prefs()).getString(_key);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return {
        for (final entry in decoded.entries)
          entry.key.toString(): entry.value.toString(),
      };
    } catch (_) {
      return {};
    }
  }

  @override
  Future<void> write(Map<String, String> marks) async {
    await (await _prefs()).setString(_key, jsonEncode(marks));
  }
}
