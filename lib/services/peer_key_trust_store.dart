import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/conversation.dart';
import '../models/text_message_with_author.dart';

class PeerKeyChangedException implements Exception {
  const PeerKeyChangedException();

  @override
  String toString() =>
      'An encryption key changed. Open Verify keys and compare fingerprints before sending.';
}

/// Pins the first key used for each peer. A changed mesh profile never silently
/// replaces that key; a person must compare and confirm the new fingerprint.
class PeerKeyTrustStore extends ChangeNotifier {
  PeerKeyTrustStore({SharedPreferences? preferences})
    : _preferences = preferences;

  static const _prefsKey = 'peer_key_trust_v1';
  SharedPreferences? _preferences;
  Future<void>? _loading;
  Future<void> _pendingWrite = Future<void>.value();
  final Map<String, String> _pinned = {};
  final Set<String> _verified = {};

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    final prefs = _preferences ??= await SharedPreferences.getInstance();
    final encoded = prefs.getString(_prefsKey);
    if (encoded == null) return;
    final decoded = jsonDecode(encoded) as Map<String, dynamic>;
    for (final entry in (decoded['keys'] as Map).entries) {
      final key = entry.value as String;
      validateKey(key);
      _pinned[entry.key as String] = key;
    }
    _verified.addAll((decoded['verified'] as List).cast<String>());
  }

  String? pinnedKey(String nodeId) => _pinned[nodeId];
  bool isVerified(String nodeId, String currentKey) =>
      _verified.contains(nodeId) && _pinned[nodeId] == currentKey;

  Future<String> keyForSending(String nodeId, String currentKey) async {
    await observe(nodeId, currentKey);
    if (_pinned[nodeId] != currentKey) throw const PeerKeyChangedException();
    return currentKey;
  }

  Future<void> observe(String nodeId, String currentKey) async {
    validateKey(currentKey);
    if (nodeId.isEmpty) throw const FormatException('Missing peer identity');
    await load();
    await _saveKey(nodeId, currentKey, confirm: false);
  }

  /// Called only after the user compares the displayed fingerprint with the
  /// peer's own phone. This also acknowledges a deliberate key change.
  Future<void> confirmKey(String nodeId, String currentKey) async {
    validateKey(currentKey);
    if (nodeId.isEmpty) throw const FormatException('Missing peer identity');
    await load();
    await _saveKey(nodeId, currentKey, confirm: true);
    notifyListeners();
  }

  Future<void> _saveKey(String nodeId, String key, {required bool confirm}) {
    final write = _pendingWrite.then((_) async {
      if (!confirm && _pinned.containsKey(nodeId)) return;
      final previous = _pinned[nodeId];
      final wasVerified = _verified.contains(nodeId);
      _pinned[nodeId] = key;
      if (confirm) _verified.add(nodeId);
      try {
        await _persist();
      } catch (_) {
        if (previous == null) {
          _pinned.remove(nodeId);
        } else {
          _pinned[nodeId] = previous;
        }
        if (!wasVerified) _verified.remove(nodeId);
        rethrow;
      }
    });
    _pendingWrite = write.catchError((Object _) {});
    return write;
  }

  Future<Map<String, String>> keysForViewing(
    List<TextMessageWithAuthor> messages,
    String myNodeId,
    Map<String, String> currentKeys,
  ) async {
    final peers = <String>{};
    for (final message in messages) {
      if (!ConversationIds.isPrivate(message.conversationId)) continue;
      final peer = message.originNodeId == myNodeId
          ? message.recipientNodeId
          : message.originNodeId;
      if (peer.isNotEmpty && peer != myNodeId) peers.add(peer);
    }
    final trusted = Map<String, String>.from(currentKeys);
    if (peers.isEmpty) return trusted;
    await load();
    for (final peer in peers) {
      final current = currentKeys[peer];
      if (current != null) await observe(peer, current);
      final pinned = _pinned[peer];
      if (pinned != null) trusted[peer] = pinned;
    }
    return trusted;
  }

  Future<void> _persist() async {
    final saved = await _preferences!.setString(
      _prefsKey,
      jsonEncode({'keys': _pinned, 'verified': _verified.toList()..sort()}),
    );
    if (!saved) throw StateError('Could not save trusted encryption keys');
  }

  static void validateKey(String encoded) {
    final key = base64Decode(encoded);
    if (key.length != 32 || key.every((byte) => byte == 0)) {
      throw const FormatException('Invalid encryption key');
    }
  }

  static Future<String> fingerprint(String encoded) async {
    validateKey(encoded);
    final digest = await Sha256().hash(base64Decode(encoded));
    final hex = digest.bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return [
      for (var i = 0; i < hex.length; i += 4) hex.substring(i, i + 4),
    ].join(' ');
  }
}

final peerKeyTrustStoreProvider = ChangeNotifierProvider<PeerKeyTrustStore>(
  (ref) => PeerKeyTrustStore(),
);
