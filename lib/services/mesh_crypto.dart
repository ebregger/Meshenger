import 'dart:collection';
import 'dart:convert';
import 'dart:isolate';
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
    return SimplePublicKey(base64Decode(encoded), type: KeyPairType.x25519);
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

  /// One seal per member, including the sender, so each person can open the
  /// copy addressed to them. Returns null when any member key is missing.
  static Future<String?> sealForMembers({
    required String plaintext,
    required MeshIdentity sender,
    required String senderNodeId,
    required List<String> memberIds,
    required Map<String, String> publicKeys,
    required String conversationId,
  }) async {
    if (!memberIds.contains(senderNodeId)) return null;
    final envelopes = <String, String>{};
    for (final memberId in memberIds) {
      final key = memberId == senderNodeId
          ? sender.publicKeyBase64
          : publicKeys[memberId];
      if (key == null || key.isEmpty) return null;
      envelopes[memberId] = await seal(
        plaintext: plaintext,
        sender: sender,
        recipientPublicKey: key,
        conversationId: conversationId,
        originNodeId: senderNodeId,
        recipientNodeId: memberId,
      );
    }
    return jsonEncode({'v': 1, 'for': envelopes});
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

  /// Batches at least this large are decrypted on a background isolate so a
  /// long thread opening does not stall the UI. Smaller batches, such as one
  /// live message arriving, are opened in place.
  static const _isolateBatchSize = 6;

  static Future<List<TextMessageWithAuthor>> openForViewer({
    required List<TextMessageWithAuthor> messages,
    required MeshIdentity? identity,
    required Map<String, String> publicKeys,
    required String myNodeId,
  }) async {
    final opened = List<TextMessageWithAuthor?>.filled(messages.length, null);
    final pending = <_PendingOpen>[];
    for (var i = 0; i < messages.length; i++) {
      final message = messages[i];
      if (message.contentEncoding != contentEncoding) {
        opened[i] = message;
        continue;
      }
      if (identity == null) {
        opened[i] = message.copyWith(textContent: _lockedText, locked: true);
        continue;
      }
      final job = _planOpen(
        index: i,
        message: message,
        identity: identity,
        publicKeys: publicKeys,
        myNodeId: myNodeId,
      );
      if (job == null) {
        opened[i] = message.copyWith(textContent: _lockedText, locked: true);
        continue;
      }
      final remembered = _openedCache[job.cacheKey];
      if (remembered != null) {
        opened[i] = message.copyWith(textContent: remembered, locked: false);
        continue;
      }
      pending.add(job);
    }

    if (pending.isNotEmpty) {
      final clear = await _openAll(pending, identity!);
      for (var i = 0; i < pending.length; i++) {
        final job = pending[i];
        final text = clear[i];
        if (text != null) _remember(job.cacheKey, text);
        opened[job.index] = text == null
            ? job.message.copyWith(textContent: _lockedText, locked: true)
            : job.message.copyWith(textContent: text, locked: false);
      }
    }
    return [for (final message in opened) message!];
  }

  /// Works out who a message is sealed between and with which envelope, or
  /// null when this phone cannot open it.
  static _PendingOpen? _planOpen({
    required int index,
    required TextMessageWithAuthor message,
    required MeshIdentity identity,
    required Map<String, String> publicKeys,
    required String myNodeId,
  }) {
    if (ConversationIds.isGroup(message.conversationId)) {
      Object? decoded;
      try {
        decoded = jsonDecode(message.textContent);
      } catch (_) {
        decoded = null;
      }
      final envelopes = decoded is Map ? decoded['for'] : null;
      final mine = envelopes is Map ? envelopes[myNodeId] : null;
      final remoteKey = message.originNodeId == myNodeId
          ? identity.publicKeyBase64
          : publicKeys[message.originNodeId];
      if (mine is! String ||
          mine.isEmpty ||
          remoteKey == null ||
          remoteKey.isEmpty) {
        return null;
      }
      return _PendingOpen(
        index: index,
        message: message,
        envelope: mine,
        remotePublicKey: remoteKey,
        recipientNodeId: myNodeId,
        cacheKey: _openedKey(message, myNodeId),
      );
    }
    if (!ConversationIds.isDirect(message.conversationId)) return null;
    final remoteId = message.originNodeId == myNodeId
        ? message.recipientNodeId
        : message.originNodeId;
    final remoteKey = publicKeys[remoteId];
    if (remoteKey == null ||
        remoteKey.isEmpty ||
        (message.originNodeId != myNodeId &&
            message.recipientNodeId != myNodeId)) {
      return null;
    }
    return _PendingOpen(
      index: index,
      message: message,
      envelope: message.textContent,
      remotePublicKey: remoteKey,
      recipientNodeId: message.recipientNodeId,
      cacheKey: _openedKey(message, myNodeId),
    );
  }

  /// Opens every pending message. Keys come from the shared cache (derived
  /// once per pair and direction); the AES-GCM work for a large batch runs on
  /// a background isolate.
  static Future<List<String?>> _openAll(
    List<_PendingOpen> pending,
    MeshIdentity identity,
  ) async {
    final jobs = <_DecryptJob?>[];
    for (final job in pending) {
      try {
        final packed = base64Decode(job.envelope);
        if (packed.length <= _nonceLength + _macLength) {
          jobs.add(null);
          continue;
        }
        final key = await _messageKey(
          local: identity,
          remotePublicKey: MeshIdentity.publicKeyFromBase64(
            job.remotePublicKey,
          ),
          conversationId: job.message.conversationId,
          originNodeId: job.message.originNodeId,
          recipientNodeId: job.recipientNodeId,
        );
        jobs.add(
          _DecryptJob(
            key: await key.extractBytes(),
            packed: packed,
            aad: _associatedData(
              conversationId: job.message.conversationId,
              originNodeId: job.message.originNodeId,
              recipientNodeId: job.recipientNodeId,
            ),
          ),
        );
      } catch (_) {
        jobs.add(null);
      }
    }
    final runnable = [for (final job in jobs) ?job];
    List<String?> results;
    if (runnable.length >= _isolateBatchSize) {
      try {
        results = await Isolate.run(() => _decryptJobs(runnable));
      } catch (_) {
        results = await _decryptJobs(runnable);
      }
    } else {
      results = await _decryptJobs(runnable);
    }
    var next = 0;
    return [for (final job in jobs) job == null ? null : results[next++]];
  }

  /// Derived message keys by pair and direction. The X25519 exchange is the
  /// expensive step (hundreds of milliseconds on a phone), so each key is
  /// worked out once, off the UI isolate, and reused for every message.
  static final Map<String, Future<SecretKey>> _keyCache = {};

  static Future<SecretKey> _messageKey({
    required MeshIdentity local,
    required SimplePublicKey remotePublicKey,
    required String conversationId,
    required String originNodeId,
    required String recipientNodeId,
  }) {
    final info = '$conversationId|$originNodeId|$recipientNodeId';
    final cacheKey =
        '${base64Encode(local.publicKey.bytes)}|'
        '${base64Encode(remotePublicKey.bytes)}|$info';
    final cached = _keyCache[cacheKey];
    if (cached != null) return cached;
    final pending = _deriveKey(local, remotePublicKey, info);
    _keyCache[cacheKey] = pending;
    // Do not keep failures around.
    pending.catchError((Object _) {
      _keyCache.remove(cacheKey);
      return SecretKey(const <int>[]);
    });
    return pending;
  }

  /// X25519 agreement per pair, shared by both directions. This is the slow
  /// step, so it runs once on a background isolate.
  static final Map<String, Future<List<int>>> _sharedCache = {};

  static Future<List<int>> _sharedSecret(
    MeshIdentity local,
    SimplePublicKey remotePublicKey,
  ) {
    final cacheKey =
        '${base64Encode(local.publicKey.bytes)}|'
        '${base64Encode(remotePublicKey.bytes)}';
    final cached = _sharedCache[cacheKey];
    if (cached != null) return cached;
    final seed = List<int>.from(local.seed);
    final remote = List<int>.from(remotePublicKey.bytes);
    Future<List<int>> compute() async {
      try {
        return await Isolate.run(() => _sharedSecretBytes(seed, remote));
      } catch (_) {
        return _sharedSecretBytes(seed, remote);
      }
    }

    final pending = compute();
    _sharedCache[cacheKey] = pending;
    pending.catchError((Object _) {
      _sharedCache.remove(cacheKey);
      return const <int>[];
    });
    return pending;
  }

  static Future<SecretKey> _deriveKey(
    MeshIdentity local,
    SimplePublicKey remotePublicKey,
    String info,
  ) async {
    final shared = await _sharedSecret(local, remotePublicKey);
    // HKDF is cheap; only the agreement above needed the isolate.
    return Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
      secretKey: SecretKey(shared),
      nonce: utf8.encode('meshenger-seal1'),
      info: utf8.encode(info),
    );
  }

  static List<int> _associatedData({
    required String conversationId,
    required String originNodeId,
    required String recipientNodeId,
  }) {
    return utf8.encode('seal1|$conversationId|$originNodeId|$recipientNodeId');
  }

  /// Text already opened, so a list that rebuilds does not decrypt every
  /// message again. Only successes are kept.
  static final LinkedHashMap<String, String> _openedCache = LinkedHashMap();
  static const _openedCacheLimit = 2000;

  static String _openedKey(TextMessageWithAuthor message, String myNodeId) =>
      '$myNodeId|${message.msgId}|${message.textContent.length}|'
      '${message.textContent.hashCode}';

  static void _remember(String key, String clear) {
    _openedCache.remove(key);
    _openedCache[key] = clear;
    while (_openedCache.length > _openedCacheLimit) {
      _openedCache.remove(_openedCache.keys.first);
    }
  }

  static const _lockedText = 'Private message';
  static const _nonceLength = 12;
  static const _macLength = 16;
  static final _exchange = X25519();
  static final _cipher = AesGcm.with256bits();
}

/// Runs in a background isolate: the X25519 agreement.
Future<List<int>> _sharedSecretBytes(
  List<int> seed,
  List<int> remotePublicKey,
) async {
  final exchange = X25519();
  final keyPair = await exchange.newKeyPairFromSeed(seed);
  final shared = await exchange.sharedSecretKey(
    keyPair: keyPair,
    remotePublicKey: SimplePublicKey(remotePublicKey, type: KeyPairType.x25519),
  );
  return shared.extractBytes();
}

class _PendingOpen {
  const _PendingOpen({
    required this.index,
    required this.message,
    required this.envelope,
    required this.remotePublicKey,
    required this.recipientNodeId,
    required this.cacheKey,
  });

  final int index;
  final TextMessageWithAuthor message;
  final String envelope;
  final String remotePublicKey;
  final String recipientNodeId;
  final String cacheKey;
}

/// Plain data for one decryption, safe to send to another isolate.
class _DecryptJob {
  const _DecryptJob({
    required this.key,
    required this.packed,
    required this.aad,
  });

  final List<int> key;
  final List<int> packed;
  final List<int> aad;
}

/// Decrypts [jobs] in order; null marks a message that failed to open.
Future<List<String?>> _decryptJobs(List<_DecryptJob> jobs) async {
  final cipher = AesGcm.with256bits();
  const nonceLength = 12;
  const macLength = 16;
  final results = <String?>[];
  for (final job in jobs) {
    try {
      final clear = await cipher.decrypt(
        SecretBox(
          job.packed.sublist(nonceLength + macLength),
          nonce: job.packed.sublist(0, nonceLength),
          mac: Mac(job.packed.sublist(nonceLength, nonceLength + macLength)),
        ),
        secretKey: SecretKey(job.key),
        aad: job.aad,
      );
      results.add(utf8.decode(clear));
    } catch (_) {
      results.add(null);
    }
  }
  return results;
}
