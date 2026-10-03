/// Caps how many gap-fill pages we push to a peer on what we last heard from it.
///
/// Gap-fill pushes are chosen from the fingerprints the peer last sent. Each
/// page the peer merges makes those fingerprints more out of date, and a peer
/// whose own request for fresh ones is waiting on the very link we keep busy
/// never gets to send them. Without a cap the pushes can go round the same
/// stale picture indefinitely. After [limit] pages the pushes stop until the
/// peer says something new, which lets the link go quiet so it can.
class CatchupPushBudget {
  CatchupPushBudget({this.limit = 20});

  /// Pages allowed per peer between two fresh reports from that peer.
  final int limit;

  final Map<String, int> _used = {};

  /// Shared by the discovery service and the code that receives peer reports.
  static final CatchupPushBudget shared = CatchupPushBudget();

  /// Takes one page from [peerId]'s budget; false when none is left.
  bool tryUse(String peerId) {
    final used = _used[peerId] ?? 0;
    if (used >= limit) return false;
    _used[peerId] = used + 1;
    return true;
  }

  /// The peer reported something new, so what we push can be better aimed.
  void refill(String peerId) => _used.remove(peerId);

  int remaining(String peerId) => limit - (_used[peerId] ?? 0);

  void clear() => _used.clear();
}
