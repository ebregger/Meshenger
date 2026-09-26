/// Chooses one side of a BLE peer pair to initiate a GATT connection.
///
/// A single connection carries deltas in both directions. Electing one dialer
/// avoids crossed connects when both devices notice the same divergence.
class MeshDialPolicy {
  /// Elects one initiator when only a 16-bit database-hash fragment is
  /// available. Equal or missing fragments are ambiguous, so callers wait for
  /// the full hash and node-ID prefix.
  static bool shouldInitiateFromPartialHash({
    required int? localHashFragment,
    required int? remoteHashFragment,
  }) {
    if (localHashFragment == null || remoteHashFragment == null) return false;
    if (localHashFragment == remoteHashFragment) return false;
    return localHashFragment < remoteHashFragment;
  }

  static bool shouldInitiate({
    required String localNodeId,
    String? remoteNodeId,
    String? remoteNodeIdPrefix,
    int? localHash,
    int? remoteHash,
  }) {
    if (remoteNodeId != null && remoteNodeId.isNotEmpty) {
      if (remoteNodeId == localNodeId) return false;
      return localNodeId.compareTo(remoteNodeId) < 0;
    }

    if (remoteNodeIdPrefix != null && remoteNodeIdPrefix.isNotEmpty) {
      final localPrefix = localNodeId.length >= remoteNodeIdPrefix.length
          ? localNodeId.substring(0, remoteNodeIdPrefix.length)
          : localNodeId;
      final prefixOrder = localPrefix.compareTo(remoteNodeIdPrefix);
      if (prefixOrder != 0) return prefixOrder < 0;
    }

    // During first contact, before identity is known, divergent database hashes
    // still provide the same ordering from both ends of the link.
    if (localHash != null && remoteHash != null && localHash != remoteHash) {
      return localHash < remoteHash;
    }

    // Without a stable identity or a differing hash there is no symmetric
    // tie-breaker. Wait for a complete advertisement instead of cross-dialing.
    return false;
  }
}

/// Limits repeated scan-path handshakes for the same peer.
///
/// FlutterBluePlus emits growing batches of recent advertisements. Without a
/// per-peer gate, each copy can trigger the same native connection lookup and
/// trace event while an inbound GATT link is already active.
class MeshScanHandshakeThrottle {
  MeshScanHandshakeThrottle({required this.window});

  final Duration window;
  final Map<String, DateTime> _lastHandledAt = {};

  bool shouldThrottle(String peerId, {DateTime? now}) {
    if (peerId.isEmpty) return false;
    final current = now ?? DateTime.now();
    final previous = _lastHandledAt[peerId];
    if (previous != null && current.difference(previous) < window) {
      return true;
    }
    _lastHandledAt[peerId] = current;
    return false;
  }

  void clear() => _lastHandledAt.clear();
}
