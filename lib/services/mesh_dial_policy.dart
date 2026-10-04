import 'dart:typed_data';

/// Chooses one side of a BLE peer pair to initiate a GATT connection.
///
/// A single connection carries deltas in both directions. Electing one dialer
/// avoids crossed connects when both devices notice the same divergence.
class MeshDialPolicy {
  static const int meshDialCapabilityMarker = 0xD1;

  /// Reads the optional capability trailer after the fixed hash and node
  /// prefix in an FFE0 payload. Older advertisements have no trailer.
  static bool? extendedConnectableFromMeshPayload(Uint8List payload) {
    if (payload.length < 14 || payload[12] != meshDialCapabilityMarker) {
      return null;
    }
    final capabilityFlags = payload[13];
    if ((capabilityFlags & 1) == 0) return null;
    return (capabilityFlags & (1 << 1)) != 0;
  }

  /// Reads the optional busy bit mirrored into the FFE0 capability trailer.
  /// Null means the advertiser predates this field or reports unknown flags.
  static bool? busyFromMeshPayload(Uint8List payload) {
    if (payload.length < 14 || payload[12] != meshDialCapabilityMarker) {
      return null;
    }
    final capabilityFlags = payload[13];
    if ((capabilityFlags & 1) == 0) return null;
    return (capabilityFlags & (1 << 2)) != 0;
  }

  /// Selects one extended-connectable node ID or prefix when several newer
  /// peers can reach the same legacy advertiser with a single inbound GATT slot.
  /// The highest prefix owns the cold dial; others use its mesh relay and may
  /// fall back if it does not connect.
  static String? preferredLegacyPeerInitiator(
    Iterable<String> extendedConnectableNodeIds,
  ) {
    final candidates =
        extendedConnectableNodeIds.where((id) => id.isNotEmpty).toSet().toList()
          ..sort();
    return candidates.isEmpty ? null : candidates.last;
  }

  /// Select a reconnect target after a held GATT write fails.
  ///
  /// A held link can fail while its peer is still advertising the same RPA.
  /// Accept that address only after a newer scan observation than the one
  /// used when the failed attempt started; otherwise require an alternate
  /// address so an actually stale RPA is not retried.
  static String? freshHeldLinkRetryTarget({
    required String failedMac,
    required String? scannedMac,
    required DateTime? scanSeenAt,
    required DateTime? scanSeenAtBeforeAttempt,
  }) {
    if (scannedMac == null || scannedMac.isEmpty || scanSeenAt == null) {
      return null;
    }
    if (scanSeenAtBeforeAttempt != null &&
        !scanSeenAt.isAfter(scanSeenAtBeforeAttempt)) {
      return null;
    }
    if (scannedMac == failedMac && scanSeenAtBeforeAttempt == null) {
      return null;
    }
    return scannedMac;
  }

  /// Selects scan-fresh peers this node may serve, plus a peer whose outbound
  /// GATT link is already held. An active connection remains a valid route
  /// after its advertising address ages out of the scan-fresh window.
  static List<String> urgentCandidates({
    required String localNodeId,
    required Iterable<String> freshPeerIds,
    String? heldClientPeerId,
    bool? localExtendedConnectable,
    Map<String, bool> remoteExtendedConnectableByPeer = const {},
    bool Function(String peerId)? shouldInitiatePeer,
  }) {
    final candidates = <String>[...freshPeerIds];
    if (heldClientPeerId != null && !candidates.contains(heldClientPeerId)) {
      candidates.add(heldClientPeerId);
    }
    return candidates
        .where(
          (peerId) =>
              peerId == heldClientPeerId ||
              (shouldInitiatePeer?.call(peerId) ??
                  shouldInitiate(
                    localNodeId: localNodeId,
                    remoteNodeId: peerId,
                    localExtendedConnectable: localExtendedConnectable,
                    remoteExtendedConnectable:
                        remoteExtendedConnectableByPeer[peerId],
                  )),
        )
        .toList(growable: false);
  }

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
    bool? localExtendedConnectable,
    bool? remoteExtendedConnectable,
  }) {
    // If both peers report this capability and only one uses connectable
    // extended advertising, let that side initiate. The opposite direction
    // has repeatedly timed out on Android 9 -> Android 15 despite strong RSSI.
    if (remoteExtendedConnectable == true && localExtendedConnectable != true) {
      // If local capability is temporarily unavailable, yield to a peer that
      // explicitly reports extended connectable advertising.
      return false;
    }
    if (localExtendedConnectable == true &&
        remoteExtendedConnectable == false) {
      return true;
    }

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
/// Repeated advertisements can trigger the same native connection lookup and
/// trace event. A per-peer gate avoids repeating that work while an inbound
/// GATT link is already active.
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
