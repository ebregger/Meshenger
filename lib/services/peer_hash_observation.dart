/// Last-seen CRDT hash for a mesh peer, with when that observation was made.
class PeerHashObservation {
  const PeerHashObservation({required this.hash, required this.observedAtMs});

  final int hash;

  /// Epoch ms of the original observation (preserved across gossip relays).
  final int observedAtMs;
}
