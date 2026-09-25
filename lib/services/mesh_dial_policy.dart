/// Chooses one side of a BLE peer pair to initiate a GATT connection.
///
/// A single connection carries deltas in both directions. Electing one dialer
/// avoids crossed connects when both devices notice the same divergence.
class MeshDialPolicy {
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

    // Equal short prefixes/hashes are rare; permit an identity handshake.
    return true;
  }
}
