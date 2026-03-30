import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class IdentityService {
  IdentityService({
    SharedPreferences? preferences,
    Uuid? uuid,
  })  : _preferences = preferences,
        _uuid = uuid ?? const Uuid();

  static const String _myNodeIdKey = 'my_node_id';

  final SharedPreferences? _preferences;
  final Uuid _uuid;

  Future<String> getOrCreateMyNodeId() async {
    final prefs = _preferences ?? await SharedPreferences.getInstance();

    final existing = prefs.getString(_myNodeIdKey);
    if (existing != null && existing.trim().isNotEmpty) {
      return existing;
    }

    final created = _uuid.v4();
    await prefs.setString(_myNodeIdKey, created);
    return created;
  }
}

