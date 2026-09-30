import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How long messages stay in the shared history before they are removed.
class ChatHistoryPreferences {
  ChatHistoryPreferences({SharedPreferences? preferences})
    : _preferences = preferences;

  static const retentionKey = 'chat_retention_days';
  static const options = <int>[0, 1, 7, 30];

  final SharedPreferences? _preferences;

  static String labelFor(int days) {
    switch (days) {
      case 1:
        return '1 day';
      case 7:
        return '7 days';
      case 30:
        return '30 days';
      default:
        return 'Keep forever';
    }
  }

  Future<int> readDays() async {
    try {
      final prefs = _preferences ?? await SharedPreferences.getInstance();
      final stored = prefs.getInt(retentionKey) ?? 0;
      return options.contains(stored) ? stored : 0;
    } catch (error, stackTrace) {
      debugPrint('retention preference unavailable: $error\n$stackTrace');
      return 0;
    }
  }

  Future<void> writeDays(int days) async {
    final stored = options.contains(days) ? days : 0;
    final prefs = _preferences ?? await SharedPreferences.getInstance();
    await prefs.setInt(retentionKey, stored);
  }
}
