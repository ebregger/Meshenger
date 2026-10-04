/// Caps how many gap-fill pages we push to a peer on what we last heard from it,
/// and enforces burst limits so streaming catchup does not starve live traffic.
///
/// Gap-fill pushes are chosen from the fingerprints the peer last sent. Each
/// page the peer merges makes those fingerprints more out of date, and a peer
/// whose own request for fresh ones is waiting on the very link we keep busy
/// never gets to send them. Without a cap the pushes can go round the same
/// stale picture indefinitely. After [limit] pages the pushes stop until the
/// peer says something new, which lets the link go quiet so it can.
///
/// [burstLimit] limits consecutive pages in a single streaming burst before
/// yielding so the radio can scan and urgent messages can preempt.
class CatchupPushBudget {
  CatchupPushBudget({this.limit = 20, this.burstLimit = 3});

  /// Pages allowed per peer between two fresh reports from that peer.
  final int limit;

  /// Maximum consecutive pages allowed in a single streaming burst before yielding.
  final int burstLimit;

  final Map<String, int> _used = {};
  final Map<String, int> _consecutiveBurst = {};

  /// Shared by the discovery service and the code that receives peer reports.
  static final CatchupPushBudget shared = CatchupPushBudget();

  /// Takes one page from [peerId]'s budget; false when total budget spent.
  bool tryUse(String peerId) {
    final used = _used[peerId] ?? 0;
    if (used >= limit) return false;
    _used[peerId] = used + 1;
    _consecutiveBurst[peerId] = (_consecutiveBurst[peerId] ?? 0) + 1;
    return true;
  }

  /// Whether [peerId] has reached the consecutive burst limit and needs to yield.
  bool shouldYieldBurst(String peerId) {
    return (_consecutiveBurst[peerId] ?? 0) >= burstLimit;
  }

  /// Resets the consecutive burst counter (e.g. after a yield pause or link turn).
  void resetBurst(String peerId) {
    _consecutiveBurst.remove(peerId);
  }

  /// The peer reported something new, so what we push can be better aimed.
  void refill(String peerId) {
    _used.remove(peerId);
    _consecutiveBurst.remove(peerId);
  }

  int remaining(String peerId) => limit - (_used[peerId] ?? 0);

  int currentBurst(String peerId) => _consecutiveBurst[peerId] ?? 0;

  void clear() {
    _used.clear();
    _consecutiveBurst.clear();
  }
}
