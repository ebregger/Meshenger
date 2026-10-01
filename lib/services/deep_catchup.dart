import 'dart:convert';

import 'database_service.dart';

/// What a peer told us about its whole history. [buckets] stays empty until a
/// mismatch makes the peer send them.
class PeerDeepDigest {
  const PeerDeepDigest(this.hash, [this.buckets = const []]);
  final int hash;
  final List<int> buckets;

  bool get hasBuckets => buckets.isNotEmpty;
}

/// Older-history catch-up that runs after the recent windows already match.
///
/// The everyday hash only covers the newest rows, so two phones whose recent
/// windows agree can still disagree about older history. Each handshake can
/// carry a second, longer digest of everything a phone holds. It is sent only
/// when it is already computed, so it never delays a handshake, and never on
/// the urgent new-message path. Only the 8-byte hash travels every time; the
/// bucket fingerprints (a few KB) are added once the hashes are known to
/// differ. Then the phones trade the old rows that sit in the mismatched
/// buckets, a page at a time.
class DeepCatchup {
  DeepCatchup._();

  static const hashKey = 'deep_hash';
  static const bucketsKey = 'deep_fps';

  /// Rounds allowed while neither digest changes. A round that settles rows
  /// changes our digest, which starts the count afresh, so this only stops
  /// rounds that achieve nothing (for example a row one side is withholding).
  static const int maxRoundsPerPair = 3;

  static final Map<String, PeerDeepDigest> _peers = {};
  static final Map<String, _Progress> _progress = {};

  /// Envelope fields for our deep digest, or empty while it is out of date.
  /// The bucket fingerprints are included only when [withBuckets] is set.
  static Map<String, dynamic> envelopeFields(
    DatabaseService db, {
    bool withBuckets = false,
  }) {
    final digest = db.freshDeepDigest;
    if (digest == null) return const {};
    return {
      hashKey: digest.hash,
      if (withBuckets) bucketsKey: base64Encode(digest.buckets),
    };
  }

  /// Reads the peer's deep digest from an offer or delta envelope.
  static PeerDeepDigest? parse(Map<dynamic, dynamic> root) {
    final hash = root[hashKey];
    if (hash is! int) return null;
    final raw = root[bucketsKey];
    if (raw is! String || raw.isEmpty) return PeerDeepDigest(hash);
    try {
      final bytes = base64Decode(raw);
      if (bytes.length != DatabaseService.deepBucketCount * 4) {
        return PeerDeepDigest(hash);
      }
      return PeerDeepDigest(hash, DatabaseService.decodeDeepBuckets(bytes));
    } catch (_) {
      return PeerDeepDigest(hash);
    }
  }

  static void remember(String peerId, PeerDeepDigest digest) {
    if (peerId.isEmpty) return;
    final previous = _peers[peerId];
    // A hash-only update for a digest we already hold buckets for keeps them.
    if (!digest.hasBuckets &&
        previous != null &&
        previous.hasBuckets &&
        previous.hash == digest.hash) {
      return;
    }
    _peers[peerId] = digest;
  }

  static PeerDeepDigest? peer(String peerId) => _peers[peerId];

  /// True when both sides know their whole-history digest and they differ.
  static bool differs(DeepDigest? ours, PeerDeepDigest? theirs) =>
      ours != null && theirs != null && ours.hash != theirs.hash;

  /// Counts a deep round against the current pair of digests and says whether
  /// it may go ahead. Progress shows up as a change in either digest, which
  /// resets the count.
  static bool claimRound(
    String peerId, {
    required int ourHash,
    required int theirHash,
  }) {
    var state = _progress[peerId];
    if (state == null || state.ours != ourHash || state.theirs != theirHash) {
      state = _Progress(ourHash, theirHash);
      _progress[peerId] = state;
    }
    if (state.rounds >= maxRoundsPerPair) return false;
    state.rounds++;
    return true;
  }

  static void reset() {
    _peers.clear();
    _progress.clear();
  }
}

class _Progress {
  _Progress(this.ours, this.theirs);
  final int ours;
  final int theirs;
  int rounds = 0;
}
