import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/chat_message.dart';

/// Local record of which outbound messages have reached a peer.
///
/// A message is sent once it is stored. It is delivered when a later mesh sync
/// with a peer completes, because that sync exchanges every row the peer is
/// missing.
class MessageDeliveryTracker extends ChangeNotifier {
  final List<String> _localIds = <String>[];
  final Map<String, Set<String>> _deliveredTo = <String, Set<String>>{};
  SharedPreferences? _preferences;

  static const _prefsKey = 'message_delivery_v1';
  static const _maxTracked = 400;

  Future<void> restore([SharedPreferences? preferences]) async {
    try {
      final prefs = preferences ?? await SharedPreferences.getInstance();
      _preferences = prefs;
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final local = decoded['local'];
      if (local is List) {
        for (final id in local) {
          final text = id?.toString() ?? '';
          if (text.isNotEmpty && !_localIds.contains(text)) {
            _localIds.add(text);
          }
        }
      }
      final delivered = decoded['delivered'];
      if (delivered is Map) {
        for (final entry in delivered.entries) {
          final peers = entry.value;
          if (peers is! List) continue;
          _deliveredTo[entry.key.toString()] = peers
              .map((peer) => peer.toString())
              .where((peer) => peer.isNotEmpty)
              .toSet();
        }
      }
      notifyListeners();
    } catch (error, stackTrace) {
      debugPrint('message delivery restore failed: $error\n$stackTrace');
    }
  }

  void noteLocalSend(String messageId) {
    if (messageId.isEmpty) return;
    observeStored(messageId);
    notifyListeners();
    _persist();
  }

  void observeStored(String messageId) {
    if (messageId.isEmpty || _localIds.contains(messageId)) return;
    _localIds.add(messageId);
    _trim();
  }

  void notePeerSync(String peerId) {
    if (peerId.isEmpty || _localIds.isEmpty) return;
    var changed = false;
    for (final messageId in _localIds) {
      changed = _deliveredTo.putIfAbsent(messageId, () => <String>{}).add(peerId) ||
          changed;
    }
    if (!changed) return;
    notifyListeners();
    _persist();
  }

  MessageDeliveryState stateFor(String messageId) {
    final peers = _deliveredTo[messageId];
    if (peers != null && peers.isNotEmpty) return MessageDeliveryState.delivered;
    if (_localIds.contains(messageId)) return MessageDeliveryState.sent;
    return MessageDeliveryState.none;
  }

  int peerCount(String messageId) => _deliveredTo[messageId]?.length ?? 0;

  void debugReset() {
    _localIds.clear();
    _deliveredTo.clear();
    notifyListeners();
  }

  void _trim() {
    if (_localIds.length <= _maxTracked) return;
    final removed = _localIds.sublist(0, _localIds.length - _maxTracked);
    _localIds.removeRange(0, _localIds.length - _maxTracked);
    for (final id in removed) {
      _deliveredTo.remove(id);
    }
  }

  void _persist() {
    final prefs = _preferences;
    if (prefs == null) return;
    final payload = jsonEncode({
      'local': _localIds,
      'delivered': {
        for (final entry in _deliveredTo.entries)
          entry.key: entry.value.toList()..sort(),
      },
    });
    prefs.setString(_prefsKey, payload);
  }
}

final messageDeliveryTracker = MessageDeliveryTracker();
