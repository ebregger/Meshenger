import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:bluetooth_app/services/mesh_crypto.dart';
import 'package:bluetooth_app/services/peer_key_trust_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'key replacement blocks sends until the new fingerprint is verified',
    () async {
      final original = await MeshIdentity.generate();
      final replacement = await MeshIdentity.generate();
      final trust = PeerKeyTrustStore();
      expect(
        await trust.keyForSending('bob', original.publicKeyBase64),
        original.publicKeyBase64,
      );
      expect(trust.isVerified('bob', original.publicKeyBase64), isFalse);
      await expectLater(
        trust.keyForSending('bob', replacement.publicKeyBase64),
        throwsA(isA<PeerKeyChangedException>()),
      );
      expect(trust.pinnedKey('bob'), original.publicKeyBase64);
      await trust.confirmKey('bob', replacement.publicKeyBase64);
      expect(
        await trust.keyForSending('bob', replacement.publicKeyBase64),
        replacement.publicKeyBase64,
      );
      final restored = PeerKeyTrustStore();
      await restored.load();
      expect(restored.isVerified('bob', replacement.publicKeyBase64), isTrue);
    },
  );
  test(
    'fingerprints use the full key and malformed keys are rejected',
    () async {
      final first = await MeshIdentity.generate();
      final second = await MeshIdentity.generate();
      expect(
        await PeerKeyTrustStore.fingerprint(first.publicKeyBase64),
        isNot(await PeerKeyTrustStore.fingerprint(second.publicKeyBase64)),
      );
      expect(
        (await PeerKeyTrustStore.fingerprint(first.publicKeyBase64)).split(' '),
        hasLength(16),
      );
      await expectLater(
        PeerKeyTrustStore().keyForSending('bob', 'AAAA'),
        throwsFormatException,
      );
    },
  );
}
