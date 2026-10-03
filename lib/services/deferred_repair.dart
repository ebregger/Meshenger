/// A sync round put off because an inbound link to the same peer was open.
class DeferredRepair {
  const DeferredRepair({
    required this.peerId,
    required this.myNodeId,
    required this.hash,
    required this.deferredAt,
  });

  final String peerId;
  final String myNodeId;
  final int hash;
  final DateTime deferredAt;
}

/// Remembers rounds that were put off, so they can be retried the moment the
/// link that blocked them closes instead of waiting for the next scan result.
class DeferredRepairQueue {
  /// How long a deferred round stays worth retrying.
  static const Duration lifetime = Duration(seconds: 10);

  final Map<String, DeferredRepair> _byPeer = {};

  bool get isEmpty => _byPeer.isEmpty;

  /// Only the latest request per peer matters.
  void defer(
    String peerId, {
    required String myNodeId,
    required int hash,
    required DateTime now,
  }) {
    _byPeer[peerId] = DeferredRepair(
      peerId: peerId,
      myNodeId: myNodeId,
      hash: hash,
      deferredAt: now,
    );
  }

  /// Everything still worth retrying at [now]. The queue is emptied either way.
  List<DeferredRepair> takeLive(DateTime now) {
    final live = [
      for (final repair in _byPeer.values)
        if (now.difference(repair.deferredAt) <= lifetime) repair,
    ];
    _byPeer.clear();
    return live;
  }
}
