import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../models/conversation.dart';
import '../models/text_message_with_author.dart';

/// X25519 identity used to seal direct messages.
class MeshIdentity {
  MeshIdentity({
    required this.seed,
    required this.keyPair,
    required this.publicKey,
  });

  final List<int> seed;
  final SimpleKeyPair keyPair;
  final SimplePublicKey publicKey;

  String get publicKeyBase64 => base64Encode(publicKey.bytes);

  static Future<MeshIdentity> generate() async {
    final keyPair = await MeshCrypto._exchange.newKeyPair();
    return MeshIdentity(
      seed: await keyPair.extractPrivateKeyBytes(),
      keyPair: keyPair,
      publicKey: await keyPair.extractPublicKey(),
    );
  }

  static Future<MeshIdentity> fromSeed(List<int> seed) async {
    final keyPair = await MeshCrypto._exchange.newKeyPairFromSeed(seed);
    return MeshIdentity(
      seed: List<int>.from(seed),
      keyPair: keyPair,
      publicKey: await keyPair.extractPublicKey(),
    );
  }

  static SimplePublicKey publicKeyFromBase64(String encoded) {
    return SimplePublicKey(
      base64Decode(encoded),
      type: KeyPairType.x25519,
    );
  }
}

/// Seals direct-message text so mesh relays can store it without reading it.
///
/// The shared room stays plaintext. A direct message is encrypted with
/// AES-GCM under a key derived from the two participants' X25519 keys, so
/// either participant can open it and other phones cannot.
class MeshCrypto {
  const MeshCrypto._();

  static const contentEncoding = 'seal1';

  static Future<String> seal({
    required String plaintext,
    required MeshIdentity sender,
    required String recipientPublicKey,
    required String conversationId,
    required String originNodeId,
    required String recipientNodeId,
  }) async {
    final key = await _messageKey(
      local: sender,
      remotePublicKey: MeshIdentity.publicKeyFromBase64(recipientPublicKey),
      conversationId: conversationId,
      originNodeId: originNodeId,
      recipientNodeId: recipientNodeId,
    );
    final box = await _cipher.encrypt(
      utf8.encode(plaintext),
      secretKey: key,
      aad: _associatedData(
        conversationId: conversationId,
        originNodeId: originNodeId,
        recipientNodeId: recipientNodeId,
      ),
    );
    final packed = Uint8List(
      box.nonce.length + box.mac.bytes.length + box.cipherText.length,
    );
    packed.setAll(0, box.nonce);
    packed.setAll(box.nonce.length, box.mac.bytes);
    packed.setAll(box.nonce.length + box.mac.bytes.length, box.cipherText);
    return base64Encode(packed);
  }

  static Future<String?> open({
    required String envelope,
    required MeshIdentity local,
    required String remotePublicKey,
    required String conversationId,
    required String originNodeId,
    required String recipientNodeId,
  }) async {
    try {
      final packed = base64Decode(envelope);
      if (packed.length <= _nonceLength + _macLength) return null;
      final nonce = packed.sublist(0, _nonceLength);
      final mac = packed.sublist(_nonceLength, _nonceLength + _macLength);
      final cipherText = packed.sublist(_nonceLength + _macLength);
      final key = await _messageKey(
        local: local,
        remotePublicKey: MeshIdentity.publicKeyFromBase64(remotePublicKey),
        conversationId: conversationId,
        originNodeId: originNodeId,
        recipientNodeId: recipientNodeId,
      );
      final clear = await _cipher.decrypt(
        SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
        secretKey: key,
        aad: _associatedData(
          conversationId: conversationId,
          originNodeId: originNodeId,
          recipientNodeId: recipientNodeId,
        ),
      );
      return utf8.decode(clear);
    } catch (_) {
      return null;
    }
  }

  static Future<List<TextMessageWithAuthor>> openForViewer({
    required List<TextMessageWithAuthor> messages,
    required MeshIdentity? identity,
    required Map<String, String> publicKeys,
    required String myNodeId,
  }) async {
    final opened = <TextMessageWithAuthor>[];
    for (final message in messages) {
      if (message.contentEncoding != contentEncoding) {
        opened.add(message);
        continue;
      }
      if (!ConversationIds.isDirect(message.conversationId)) {
        opened.add(message.copyWith(textContent: _lockedText, locked: true));
        continue;
      }
      final remoteId = message.originNodeId == myNodeId
          ? message.recipientNodeId
          : message.originNodeId;
      final remoteKey = publicKeys[remoteId];
      if (identity == null ||
          remoteKey == null ||
          remoteKey.isEmpty ||
          (message.originNodeId != myNodeId &&
              message.recipientNodeId != myNodeId)) {
        opened.add(message.copyWith(textContent: _lockedText, locked: true));
        continue;
      }
      final clear = await open(
        envelope: message.textContent,
        local: identity,
        remotePublicKey: remoteKey,
        conversationId: message.conversationId,
        originNodeId: message.originNodeId,
        recipientNodeId: message.recipientNodeId,
      );
      opened.add(
        clear == null
            ? message.copyWith(textContent: _lockedText, locked: true)
            : message.copyWith(textContent: clear, locked: false),
      );
    }
    return opened;
  }

  static Future<SecretKey> _messageKey({
    required MeshIdentity local,
    required SimplePublicKey remotePublicKey,
    required String conversationId,
    required String originNodeId,
    required String recipientNodeId,
  }) async {
    final shared = await _exchange.sharedSecretKey(
      keyPair: local.keyPair,
      remotePublicKey: remotePublicKey,
    );
    return _kdf.deriveKey(
      secretKey: shared,
      nonce: utf8.encode('meshenger-seal1'),
      info: utf8.encode('$conversationId|$originNodeId|$recipientNodeId'),
    );
  }

  static List<int> _associatedData({
    required String conversationId,
    required String originNodeId,
    required String recipientNodeId,
  }) {
    return utf8.encode('seal1|$conversationId|$originNodeId|$recipientNodeId');
  }

  static const _lockedText = 'Private message';
  static const _nonceLength = 12;
  static const _macLength = 16;
  static final _exchange = X25519();
  static final _cipher = AesGcm.with256bits();
  static final _kdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
}
