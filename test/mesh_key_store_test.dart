import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:bluetooth_app/services/mesh_crypto.dart';
import 'package:bluetooth_app/services/mesh_key_store.dart';

class _MemoryStorage implements MeshSeedStorage {
  String? seed;
  int writes = 0;
  bool failWrites = false;
  bool failReads = false;
  @override
  Future<String?> read() async {
    if (failReads) throw StateError('storage unavailable');
    return seed;
  }

  @override
  Future<void> write(String value) async {
    if (failWrites) throw StateError('storage unavailable');
    writes++;
    seed = value;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('migration preserves identity and removes the plaintext seed', () async {
    final identity = await MeshIdentity.generate();
    SharedPreferences.setMockInitialValues({
      MeshKeyStore.seedKey: base64Encode(identity.seed),
    });
    final prefs = await SharedPreferences.getInstance();
    final storage = _MemoryStorage();
    final loaded = await MeshKeyStore(
      preferences: prefs,
      storage: storage,
    ).loadOrCreate();
    expect(loaded.publicKeyBase64, identity.publicKeyBase64);
    expect(prefs.containsKey(MeshKeyStore.seedKey), isFalse);
    final restored = await MeshKeyStore(
      preferences: prefs,
      storage: storage,
    ).loadOrCreate();
    expect(restored.publicKeyBase64, identity.publicKeyBase64);
    expect(storage.writes, 1);
  });
  test(
    'a failed migration keeps the legacy seed and does not substitute an identity',
    () async {
      final identity = await MeshIdentity.generate();
      final encoded = base64Encode(identity.seed);
      SharedPreferences.setMockInitialValues({MeshKeyStore.seedKey: encoded});
      final prefs = await SharedPreferences.getInstance();
      final storage = _MemoryStorage()..failWrites = true;
      final store = MeshKeyStore(preferences: prefs, storage: storage);
      await expectLater(store.loadOrCreate(), throwsStateError);
      expect(prefs.getString(MeshKeyStore.seedKey), encoded);
      storage.failWrites = false;
      expect(
        (await store.loadOrCreate()).publicKeyBase64,
        identity.publicKeyBase64,
      );
    },
  );
  test('simultaneous callers create one identity', () async {
    SharedPreferences.setMockInitialValues({});
    final storage = _MemoryStorage();
    final store = MeshKeyStore(storage: storage);
    final identities = await Future.wait([
      store.loadOrCreate(),
      store.loadOrCreate(),
    ]);
    expect(identities.first.publicKeyBase64, identities.last.publicKeyBase64);
    expect(storage.writes, 1);
  });
  test('unreadable protected storage fails closed', () async {
    SharedPreferences.setMockInitialValues({});
    final storage = _MemoryStorage()..failReads = true;
    await expectLater(
      MeshKeyStore(storage: storage).loadOrCreate(),
      throwsStateError,
    );
    expect(storage.writes, 0);
  });
}
