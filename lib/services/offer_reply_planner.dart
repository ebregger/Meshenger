import 'ble_discovery_service.dart';

typedef RowFetch = Future<Map<String, dynamic>> Function();

/// What the peer's fingerprint blob lets us do.
enum PeerFingerprints {
  /// A well-formed bucket blob arrived.
  usable,

  /// No blob at all (an older peer); only the hash comparison is available.
  missing,

  /// A blob arrived but could not be read.
  unusable,
}

/// The rows chosen for the reply to an offer, and how they were chosen.
class OfferReplyPlan {
  const OfferReplyPlan({
    required this.delta,
    required this.source,
    required this.fingerprintsComplete,
  });

  final Map<String, dynamic> delta;
  final OfferReplySource source;

  /// False when [delta] is a partial page, so the peer's view of our
  /// fingerprints cannot be treated as the whole story yet.
  final bool fingerprintsComplete;

  bool get isRepair => source != OfferReplySource.versionVector;

  /// Rows allowed in the reply: repair pages are larger because they are
  /// the only thing in the reply.
  int get rowCap =>
      isRepair ? BleDiscoveryService.repairPageRows : normalRowCap;

  static const int normalRowCap = 25;
}

enum OfferReplySource {
  /// Rows newer than the peer's version vector.
  versionVector,

  /// Rows from mismatched whole-history buckets.
  deepBuckets,

  /// Rows from mismatched recent-window buckets.
  windowBuckets,

  /// Slice picked from a hash mismatch alone.
  hashRepair,
}

/// Decides which rows answer an offer. The database lookups are passed in so
/// the decision order can be tested without a database or Bluetooth.
class OfferReplyPlanner {
  OfferReplyPlanner._();

  /// Deltas sent to each peer, to spot ones that never change anything.
  static final StalledDeltaTracker stalledDeltas = StalledDeltaTracker();

  /// Order of preference: the version-vector delta (last, if it is
  /// [deltaStalled]), then whole-history buckets, then window buckets, then a
  /// bare hash repair. Repairs are only tried when the delta is empty, since
  /// otherwise the peer is still missing newer rows and those go first.
  static Future<OfferReplyPlan> plan({
    required Map<String, dynamic> delta,
    bool deltaStalled = false,
    required bool deepBucketsMismatch,
    required PeerFingerprints fingerprints,
    required bool windowHashesDiffer,
    required RowFetch deepRows,
    required RowFetch windowRows,
    required RowFetch hashRepairRows,
    required RowFetch newestRows,
  }) async {
    // A stalled delta is one the peer keeps receiving without it changing
    // anything. It must not starve the repairs that can find what is really
    // missing, so they run first and the delta is only a fallback.
    var rows = deltaStalled ? <String, dynamic>{} : delta;
    var source = OfferReplySource.versionVector;
    var complete = true;

    if (rows.isEmpty && deepBucketsMismatch) {
      final found = await deepRows();
      if (found.isNotEmpty) {
        rows = found;
        source = OfferReplySource.deepBuckets;
        complete = false;
      }
    }

    if (rows.isEmpty && windowHashesDiffer) {
      switch (fingerprints) {
        case PeerFingerprints.usable:
          final found = await windowRows();
          if (found.isNotEmpty) {
            rows = found;
            source = OfferReplySource.windowBuckets;
            complete = countRows(found) < BleDiscoveryService.repairPageRows;
          }
        case PeerFingerprints.missing:
          final found = await hashRepairRows();
          if (found.isNotEmpty) {
            rows = found;
            source = OfferReplySource.hashRepair;
          }
          complete = false;
        case PeerFingerprints.unusable:
          break;
      }
    }

    if (rows.isEmpty && deltaStalled) rows = delta;

    // A repair reply only happens when the peer's frontier already covers
    // our newest rows, so repeating them would waste a slice of every page.
    if (source == OfferReplySource.versionVector) {
      rows = BleDiscoveryService.prioritizeNewestMessages(
        rows,
        await newestRows(),
      );
    }
    return OfferReplyPlan(
      delta: rows,
      source: source,
      fingerprintsComplete: complete,
    );
  }

  /// Rows received as a gap fill are old news to everyone else, so they are
  /// not relayed on as live messages.
  static bool shouldRelay({
    required Map<dynamic, dynamic> envelope,
    required bool hasNewerMessages,
  }) => envelope[BleDiscoveryService.repairFlagKey] != true && hasNewerMessages;

  static int countRows(Map<String, dynamic> changeset) => changeset.values
      .whereType<List>()
      .fold<int>(0, (total, rows) => total + rows.length);
}

/// Notices a version-vector delta that keeps going out unchanged.
///
/// Rows the peer already holds can still sort after its remembered version
/// vector, for example tombstones or rows from a node whose clock ran ahead.
/// Sending them again achieves nothing, yet because they are always first in
/// line they used to crowd out the gap-fill pages for good.
class StalledDeltaTracker {
  StalledDeltaTracker({this.threshold = 3});

  /// Identical deltas in a row after which the delta counts as stalled.
  final int threshold;

  final Map<String, _Sent> _sent = {};

  /// Records that [signature] is about to go to [peerId] and says whether it
  /// has now gone out [threshold] times running with nothing else in between.
  bool record(String peerId, int signature) {
    final previous = _sent[peerId];
    if (previous != null && previous.signature == signature) {
      previous.count++;
      return previous.count >= threshold;
    }
    _sent[peerId] = _Sent(signature);
    return false;
  }

  /// Forgets a peer, for example once its history matches ours.
  void forget(String peerId) => _sent.remove(peerId);

  void clear() => _sent.clear();
}

class _Sent {
  _Sent(this.signature);
  final int signature;
  int count = 1;
}
