import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../providers/database_provider.dart';
import '../providers/identity_provider.dart';
import 'mesh_crypto.dart';

/// Stores the X25519 seed outside the synced database.
class MeshKeyStore {
  MeshKeyStore({SharedPreferences? preferences, MeshIdentity? identity})
    : _preferences = preferences,
      _identity = identity;

  static const seedKey = 'mesh_x25519_seed_v1';

  final SharedPreferences? _preferences;
  MeshIdentity? _identity;

  Future<MeshIdentity> loadOrCreate() async {
    final cached = _identity;
    if (cached != null) return cached;

    final prefs = _preferences ?? await SharedPreferences.getInstance();
    final existing = prefs.getString(seedKey);
    if (existing != null && existing.isNotEmpty) {
      final identity = await MeshIdentity.fromSeed(base64Decode(existing));
      _identity = identity;
      return identity;
    }

    final created = await MeshIdentity.generate();
    await prefs.setString(seedKey, base64Encode(created.seed));
    _identity = created;
    return created;
  }
}

final meshKeyStoreProvider = Provider<MeshKeyStore>((ref) => MeshKeyStore());

/// Publishes this phone's public key into the synced profile table.
final publishMeshIdentityProvider = FutureProvider<void>((ref) async {
  try {
    final identity = await ref.watch(meshKeyStoreProvider).loadOrCreate();
    final nodeId = await ref.watch(myNodeIdProvider.future);
    final database = await ref.watch(databaseProvider.future);
    await database.setLocalPublicKey(nodeId, identity.publicKeyBase64);
  } catch (error, stackTrace) {
    debugPrint('mesh identity publish failed: $error\n$stackTrace');
  }
});
