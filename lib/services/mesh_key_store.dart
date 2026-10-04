import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../providers/database_provider.dart';
import '../providers/identity_provider.dart';
import 'mesh_crypto.dart';

abstract class MeshSeedStorage {
  Future<String?> read();
  Future<void> write(String seed);
}

class ProtectedMeshSeedStorage implements MeshSeedStorage {
  static const _channel = MethodChannel(
    'com.bregger.edison.meshenger/identity',
  );

  @override
  Future<String?> read() => _channel.invokeMethod<String>('read_seed');

  @override
  Future<void> write(String seed) =>
      _channel.invokeMethod<void>('write_seed', {'seed': seed});
}

/// Stores the X25519 seed under an Android Keystore wrapping key.
class MeshKeyStore {
  MeshKeyStore({
    SharedPreferences? preferences,
    MeshIdentity? identity,
    MeshSeedStorage? storage,
  }) : _preferences = preferences,
       _storage = storage ?? ProtectedMeshSeedStorage(),
       _identity = identity;

  static const seedKey = 'mesh_x25519_seed_v1';

  final SharedPreferences? _preferences;
  final MeshSeedStorage _storage;
  MeshIdentity? _identity;
  Future<MeshIdentity>? _loading;

  Future<MeshIdentity> loadOrCreate() {
    final cached = _identity;
    if (cached != null) return Future.value(cached);
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  Future<MeshIdentity> _load() async {
    final prefs = _preferences ?? await SharedPreferences.getInstance();
    final existing = await _storage.read();
    if (existing != null && existing.isNotEmpty) {
      final identity = await _fromEncodedSeed(existing);
      await _removeLegacySeed(prefs);
      _identity = identity;
      return identity;
    }

    final legacy = prefs.getString(seedKey);
    final created = legacy == null
        ? await MeshIdentity.generate()
        : await _fromEncodedSeed(legacy);
    await _storage.write(base64Encode(created.seed));
    // Remove the old plaintext copy only after protected storage succeeds.
    await _removeLegacySeed(prefs);
    _identity = created;
    return created;
  }

  Future<MeshIdentity> _fromEncodedSeed(String encoded) async {
    final seed = base64Decode(encoded);
    if (seed.length != 32) throw const FormatException('Invalid identity seed');
    return MeshIdentity.fromSeed(seed);
  }

  Future<void> _removeLegacySeed(SharedPreferences prefs) async {
    if (prefs.containsKey(seedKey) && !await prefs.remove(seedKey)) {
      throw StateError('Could not remove the old identity copy');
    }
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
