import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, listEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../constants/ble_constants.dart';
import '../providers/database_provider.dart';
import 'benchmark_trace.dart';
import 'catchup_push_budget.dart';
import 'deep_catchup.dart';
import 'database_service.dart';
import 'deferred_repair.dart';
import 'mesh_advertisement.dart';
import 'mesh_catchup.dart';
import 'mesh_dial_policy.dart';
import 'mesh_payload_limits.dart';
import 'native_mesh_service.dart';
import 'native_ble_radio.dart';
import 'native_mesh_urgent.dart';
import 'peer_hash_observation.dart';

/// Byte budget in the ADV payload: we only send a fixed 8-char "Short Node ID".
const int meshShortNodeIdLength = 8;

enum _InboundUrgentWaitResult { delivered, released, timedOut }

class _UrgentInboundLinkStillActive implements Exception {
  const _UrgentInboundLinkStillActive(this.peerId, this.mac);

  final String peerId;
  final String mac;

  @override
  String toString() => 'Inbound GATT link still active for $peerId@$mac';
}

/// Mesh discovery: central scanning via [NativeBleRadio]; GAP advertise lives in native Android.
class BleDiscoveryService {
  /// Advertised database hash → stable node ID only when that hash currently
  /// belongs to exactly one known peer. Database hashes are state fingerprints,
  /// not unique peer identities, so never use them as an address route.
  static final Map<int, String> hashToNodeId = {};

  /// Latest advertised hash owner(s), used to keep [hashToNodeId] unambiguous.
  static final Map<int, Set<String>> hashOwners = {};
  static final Map<String, int> latestHashByNodeId = {};

  /// Stable nodeId -> last time we saw it directly via scan (presence window).
  static final Map<String, DateTime> localSeenNodes = {};

  /// Stable nodeId -> last known MAC address (best-effort, may go stale/out of range).
  static final Map<String, String> nodeIdToMac = {};

  /// When [nodeIdToMac] was last refreshed from a *scan* (not GATT bind).
  /// Urgent dials must use scan-fresh RPAs — GATT/bind MACs go stale under Android RPA.
  static final Map<String, DateTime> nodeIdMacSeenAt = {};

  /// Latest advertised single-client server state per known peer. A busy
  /// advertisement suppresses new cold dials briefly; an existing held link
  /// can still be used by the urgent path.
  static final Map<String, bool> peerBusyStateByNodeId = {};
  static final Map<String, DateTime> peerBusySeenAtByNodeId = {};
  static final Set<String> _urgentLegacyDialFallbacks = <String>{};
  static final Map<String, Timer> _urgentLegacyFallbackTimers =
      <String, Timer>{};
  static const Duration peerBusyFreshnessWindow = Duration(seconds: 2);

  /// Latest local scanner RSSI sample for each stable peer identity.
  static final Map<String, int> nodeIdRssiDbm = {};

  /// Host time of the latest [nodeIdRssiDbm] sample.
  static final Map<String, DateTime> nodeIdRssiSeenAt = {};

  /// Last MAC that completed a successful outbound offer to this nodeId.
  static final Map<String, String> lastGoodDialMac = {};

  /// Outbound dial MACs that succeeded before we knew the peer's nodeId.
  static final Map<String, DateTime> _orphanDialSuccessAt = {};

  /// Stable nodeId -> last time a sync handshake *completed* (anti-entropy heartbeat).
  /// Keyed by nodeId (not MAC) because Android RPAs rotate every connection.
  static final Map<String, DateTime> lastFullSync = {};

  /// Whether we last observed this peer's CRDT hash matching ours.
  /// Cleared only on divergence — not when urgent scheduling bumps [lastFullSync].
  static final Map<String, bool> peerCaughtUp = {};

  /// Last observed CRDT hash per peer (ADV or gossip) — relayed for multi-hop catch-up UI.
  static final Map<String, PeerHashObservation> peerObservedHash = {};

  /// Drop gossip older than this so stale fingerprints cannot recirculate.
  static const Duration peerHashMaxAge = Duration(minutes: 3);

  /// Match the scanner's cached-result cutoff before using an RPA to dial.
  static const Duration dialMacFreshnessWindow = Duration(seconds: 6);

  /// Stable nodeId -> last version vector we believe that peer held.
  /// Used so initiator pushes are true deltas instead of the entire DB every dial.
  static final Map<String, Map<String, String>> lastKnownPeerVector = {};

  /// Stable nodeId -> last known XOR bucket digests (for targeted initiator push).
  static final Map<String, List<int>> lastKnownPeerBuckets = {};

  /// Brief UI pulse for the single peer using the serialized GATT link.
  static String? _activeBluetoothNodeId;
  static DateTime? _lastBluetoothActivityAt;

  static void markBluetoothActivity(String nodeId) {
    if (nodeId.isEmpty) return;
    _activeBluetoothNodeId = nodeId;
    _lastBluetoothActivityAt = DateTime.now();
  }

  static bool isNodeTalking(String nodeId, {DateTime? now}) {
    final last = _lastBluetoothActivityAt;
    return _activeBluetoothNodeId == nodeId &&
        last != null &&
        (now ?? DateTime.now()).difference(last) <
            const Duration(milliseconds: 2500);
  }

  /// Soft cap for compressed offer+push payloads. Larger pushes routinely hit the
  /// 60s GATT transfer watchdog and leave lagging nodes stuck mid-transfer.
  static const int maxOfferPushBytes = 48 * 1024;

  /// Rows in one gap-fill page. The same number is asked of the database and
  /// allowed on the wire, so nothing selected is dropped afterwards.
  static const int repairPageRows = 80;

  /// The database repair cursor must advance by the rows this inbound link
  /// can send. Requesting 80 and then sending only 25 skips unsent candidates
  /// whenever the peer's fingerprint stays unchanged across held-link turns.
  static Future<Map<String, dynamic>> inboundRepairPage(
    DatabaseService db,
    List<int> remoteBuckets, {
    required String peerId,
    List<int>? remoteDeepBuckets,
  }) async {
    if (remoteDeepBuckets != null) {
      final deep = await db.getRowsForDeepMismatch(
        remoteDeepBuckets,
        maxRows: MeshCatchup.pageRows,
        peerKey: peerId,
      );
      if (deep.isNotEmpty) return deep;
    }
    return db.getRowsForMismatchedBuckets(
      remoteBuckets,
      maxRows: MeshCatchup.pageRows,
      peerKey: peerId,
    );
  }

  /// Envelope flag on a payload that carries gap-fill rows. Those rows are old
  /// history the receiver was missing, not new messages, so the receiver does
  /// not relay them onward as urgent pushes; its neighbors catch up through
  /// their own handshakes.
  static const String repairFlagKey = 'repair';

  /// Keep BLE payloads under the GATT transfer budget by preferring newest rows.
  static Map<String, dynamic> shrinkChangesetForBle(
    Map<String, dynamic> delta,
  ) {
    const maxRowsPerTable = 120;
    final out = <String, dynamic>{};
    for (final entry in delta.entries) {
      final rows = entry.value;
      if (rows is! List) {
        out[entry.key] = rows;
        continue;
      }
      if (rows.length <= maxRowsPerTable) {
        out[entry.key] = rows;
        continue;
      }
      final sorted = List<dynamic>.from(rows)
        ..sort((a, b) {
          final ha = a is Map ? (a['hlc']?.toString() ?? '') : '';
          final hb = b is Map ? (b['hlc']?.toString() ?? '') : '';
          return hb.compareTo(ha);
        });
      out[entry.key] = sorted.take(maxRowsPerTable).toList();
    }
    return out;
  }

  /// Truncate tables without reordering — used for hash-repair buckets so we
  /// don't throw away the older stranded rows that newest-first shrink drops.
  static Map<String, dynamic> truncateChangesetForBle(
    Map<String, dynamic> delta, {
    int maxRowsPerTable = 150,
  }) {
    final out = <String, dynamic>{};
    for (final entry in delta.entries) {
      final rows = entry.value;
      if (rows is! List) {
        out[entry.key] = rows;
        continue;
      }
      out[entry.key] = rows.length <= maxRowsPerTable
          ? rows
          : rows.take(maxRowsPerTable).toList();
    }
    return out;
  }

  /// Put recent chat rows ahead of bucket repair so a capped offer cannot
  /// omit a newly written message after an earlier connection failed.
  static Map<String, dynamic> prioritizeNewestMessages(
    Map<String, dynamic> changeset,
    Map<String, dynamic> newest,
  ) {
    final latest = newest['messages'];
    if (latest is! List || latest.isEmpty) return changeset;
    final combined = <dynamic>[];
    final seenIds = <String>{};
    for (final row in [...latest, ...?changeset['messages'] as List?]) {
      if (row is Map) {
        final id = row['msg_id']?.toString();
        if (id != null && !seenIds.add(id)) continue;
      }
      combined.add(row);
    }
    return <String, dynamic>{...changeset, 'messages': combined};
  }

  /// MAC -> suppress presence until this time (failed/uncallable peer).
  static final Map<String, DateTime> deadMacUntil = {};

  /// Advertised hash -> suppress attempts until this time (handles MAC randomization / phantom MACs).
  static final Map<int, DateTime> deadHashUntil = {};

  /// Best-effort MAC → stable nodeId mapping (filled after first offer/delta).
  static final Map<String, String> macToNodeId = {};

  /// First 4 chars of nodeId → full nodeId (survives advert hash rotation between syncs).
  static final Map<String, String> nodeIdPrefixToNodeId = {};

  /// Advertised peer dial capabilities keyed by stable node-ID prefix.
  /// Values are only recorded when the advertisement marks them as known.
  final Map<String, bool> _peerExtendedConnectableByPrefix = {};
  final Map<String, DateTime> _peerExtendedConnectableSeenAtByPrefix = {};
  final Set<String> _loggedPeerCapabilities = {};
  final Set<String> _loggedDialElections = {};

  static final List<void Function(String peerNodeId)> _syncCompletedListeners =
      <void Function(String peerNodeId)>[];

  static final List<void Function(String, List<String>)>
  _messagesRelayedListeners = [];

  static void addMessagesRelayedListener(
    void Function(String, List<String>) listener,
  ) {
    _messagesRelayedListeners.add(listener);
  }

  static void markMessagesRelayed(String peerId, List<String> messageIds) {
    if (peerId.isEmpty || messageIds.isEmpty) return;
    for (final listener in List<void Function(String, List<String>)>.of(
      _messagesRelayedListeners,
    )) {
      listener(peerId, messageIds);
    }
  }

  /// Notified after [markSyncComplete] records a finished bidirectional sync.
  static void addSyncCompletedListener(
    void Function(String peerNodeId) listener,
  ) {
    _syncCompletedListeners.add(listener);
  }

  /// Record a completed bidirectional sync with [peerNodeId].
  static void markSyncComplete(String peerNodeId) {
    if (peerNodeId.isEmpty) return;
    lastFullSync[peerNodeId] = DateTime.now();
    peerCaughtUp[peerNodeId] = true;
    for (final listener in List<void Function(String)>.of(
      _syncCompletedListeners,
    )) {
      listener(peerNodeId);
    }
  }

  /// Advertised or post-transfer hash no longer matches ours.
  static void markSyncDiverged(String peerNodeId) {
    if (peerNodeId.isEmpty) return;
    lastFullSync.remove(peerNodeId);
    peerCaughtUp[peerNodeId] = false;
  }

  /// Local CRDT write: every known peer is behind until hash-matched sync.
  static void markMeshStaleAfterLocalWrite({
    Iterable<String>? extraPeerIds,
    Iterable<String>? excludePeerIds,
  }) {
    final excluded = excludePeerIds?.toSet() ?? const <String>{};
    final ids = <String>{
      ...peerCaughtUp.keys,
      ...lastFullSync.keys,
      ...nodeIdToMac.keys,
      ...localSeenNodes.keys,
      ...?extraPeerIds,
    };
    for (final id in ids) {
      if (id.isEmpty || excluded.contains(id)) continue;
      // Skip provisional MAC-shaped scan keys.
      if (RegExp(r'^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$').hasMatch(id)) {
        continue;
      }
      lastFullSync.remove(id);
      peerCaughtUp[id] = false;
    }
  }

  static bool? isPeerCaughtUp(String peerNodeId) => peerCaughtUp[peerNodeId];

  static bool isPeerKnownBehind(String peerNodeId) =>
      peerCaughtUp[peerNodeId] == false;

  static bool isPeerKnownCaughtUp(String peerNodeId) =>
      peerCaughtUp[peerNodeId] == true;

  /// True when some other dialable peer still needs catch-up.
  static bool hasDialableBehindPeer({String? excluding}) {
    final candidates = <String>{...localSeenNodes.keys, ...nodeIdToMac.keys};
    for (final id in candidates) {
      if (id.isEmpty || id == excluding) continue;
      if (peerCaughtUp[id] != false) continue;
      if (preferredDialMac(id) != null || localSeenNodes.containsKey(id)) {
        return true;
      }
    }
    return false;
  }

  static bool _peerHashIsFresh(int observedAtMs, {DateTime? now}) {
    final ageMs = (now ?? DateTime.now()).millisecondsSinceEpoch - observedAtMs;
    return ageMs >= 0 && ageMs <= peerHashMaxAge.inMilliseconds;
  }

  /// First-hand observation (ADV / direct sync): always stamps [DateTime.now].
  static void rememberPeerHash(
    String peerNodeId,
    int hash, {
    int? observedAtMs,
  }) {
    if (peerNodeId.isEmpty) return;
    final at = observedAtMs ?? DateTime.now().millisecondsSinceEpoch;
    final existing = peerObservedHash[peerNodeId];
    if (existing != null && at < existing.observedAtMs) return;
    peerObservedHash[peerNodeId] = PeerHashObservation(
      hash: hash,
      observedAtMs: at,
    );
    _rememberHashOwner(peerNodeId, hash);
  }

  /// Compare an observed remote hash to [localHash] and update catch-up UI state.
  ///
  /// Older observations never overwrite newer ones (stops stale gossip loops).
  static void notePeerHashObservation(
    String peerNodeId,
    int remoteHash, {
    required int localHash,
    int? observedAtMs,
  }) {
    if (peerNodeId.isEmpty) return;
    final at = observedAtMs ?? DateTime.now().millisecondsSinceEpoch;
    final existing = peerObservedHash[peerNodeId];
    if (existing != null && at < existing.observedAtMs) return;
    if (!_peerHashIsFresh(at) &&
        existing != null &&
        _peerHashIsFresh(existing.observedAtMs)) {
      return;
    }
    peerObservedHash[peerNodeId] = PeerHashObservation(
      hash: remoteHash,
      observedAtMs: at,
    );
    _rememberHashOwner(peerNodeId, remoteHash);
    if (remoteHash == localHash) {
      peerCaughtUp[peerNodeId] = true;
    } else {
      lastFullSync.remove(peerNodeId);
      peerCaughtUp[peerNodeId] = false;
    }
  }

  /// Apply `peer_hashes` gossip from an offer/delta envelope.
  /// Wire shape: `{ nodeId: { "h": hash, "t": epochMs } }` (legacy bare int ignored).
  static void applyGossipPeerHashes(
    Object? raw, {
    required int localHash,
    String? excludeNodeId,
  }) {
    if (raw is! Map) return;
    for (final entry in raw.entries) {
      final id = entry.key?.toString() ?? '';
      if (id.isEmpty || id == excludeNodeId) continue;
      final parsed = _parseGossipHashEntry(entry.value);
      if (parsed == null) continue;
      notePeerHashObservation(
        id,
        parsed.hash,
        localHash: localHash,
        observedAtMs: parsed.observedAtMs,
      );
    }
  }

  static void _rememberHashOwner(String nodeId, int hash) {
    if (nodeId.isEmpty) return;
    final previousHash = latestHashByNodeId[nodeId];
    if (previousHash != null && previousHash != hash) {
      hashOwners[previousHash]?.remove(nodeId);
      _refreshUniqueHashOwner(previousHash);
    }
    latestHashByNodeId[nodeId] = hash;
    hashOwners.putIfAbsent(hash, () => <String>{}).add(nodeId);
    _refreshUniqueHashOwner(hash);
  }

  static void _refreshUniqueHashOwner(int hash) {
    final owners = hashOwners[hash];
    if (owners == null || owners.isEmpty) {
      hashOwners.remove(hash);
      hashToNodeId.remove(hash);
    } else if (owners.length == 1) {
      hashToNodeId[hash] = owners.single;
    } else {
      hashToNodeId.remove(hash);
    }
  }

  static PeerHashObservation? _parseGossipHashEntry(Object? value) {
    if (value is Map) {
      final hashRaw = value['h'] ?? value['hash'];
      final timeRaw = value['t'] ?? value['at'] ?? value['observedAtMs'];
      final hash = hashRaw is int
          ? hashRaw
          : hashRaw is num
          ? hashRaw.toInt()
          : int.tryParse('$hashRaw');
      final at = timeRaw is int
          ? timeRaw
          : timeRaw is num
          ? timeRaw.toInt()
          : int.tryParse('$timeRaw');
      if (hash == null || at == null) return null;
      return PeerHashObservation(hash: hash, observedAtMs: at);
    }
    // Legacy bare int has no time — treat as ancient so stamped peers win.
    if (value is int) {
      return PeerHashObservation(hash: value, observedAtMs: 0);
    }
    if (value is num) {
      return PeerHashObservation(hash: value.toInt(), observedAtMs: 0);
    }
    return null;
  }

  /// Compact timed hash map for offer/delta gossip (neighbors first).
  Map<String, Map<String, int>> peerHashesForGossip({int maxEntries = 12}) {
    final now = DateTime.now();
    final out = <String, Map<String, int>>{};
    void consider(String id) {
      if (out.length >= maxEntries || id.isEmpty || out.containsKey(id)) {
        return;
      }
      final obs = peerObservedHash[id];
      if (obs == null || !_peerHashIsFresh(obs.observedAtMs, now: now)) {
        return;
      }
      out[id] = {'h': obs.hash, 't': obs.observedAtMs};
    }

    for (final id in currentNeighborIds) {
      consider(id);
    }
    for (final id in peerCaughtUp.keys) {
      consider(id);
    }
    for (final id in peerObservedHash.keys) {
      consider(id);
    }
    return out;
  }

  /// Cache [vector] as what we last knew about [peerNodeId]'s CRDT frontier.
  static void rememberPeerVector(
    String peerNodeId,
    Map<String, String> vector,
  ) {
    if (peerNodeId.isEmpty) return;
    final previous = lastKnownPeerVector[peerNodeId];
    if (previous != null) {
      final regressedNodes = previous.entries.where((entry) {
        final next = vector[entry.key];
        return next == null || next.compareTo(entry.value) < 0;
      }).length;
      if (regressedNodes > 0) {
        debugPrint(
          '[BLE_TRACE] EVENT:PEER_VECTOR_REGRESSION_IGNORED | '
          'PEER_NODE_ID:$peerNodeId | '
          'REGRESSED_NODES:$regressedNodes | '
          'PREVIOUS_NODES:${previous.length} | '
          'INCOMING_NODES:${vector.length} | '
          'WALL_MS:${DateTime.now().millisecondsSinceEpoch}',
        );
      }
    }
    lastKnownPeerVector[peerNodeId] = MeshCatchup.mergeVectors(
      previous ?? const <String, String>{},
      vector,
    );
  }

  static void rememberPeerBuckets(String peerNodeId, List<int> buckets) {
    if (peerNodeId.isEmpty) return;
    final previous = lastKnownPeerBuckets[peerNodeId];
    if (previous == null || !listEquals(previous, buckets)) {
      CatchupPushBudget.shared.refill(peerNodeId);
    }
    lastKnownPeerBuckets[peerNodeId] = List<int>.from(buckets);
  }

  /// Bind a stable nodeId to a BLE MAC (and optional advertised hash).
  ///
  /// GATT MACs bind only that exact address to the peer. The advertised hash
  /// is tracked as an identity hint only while it remains unique; dial MAC
  /// ([nodeIdToMac]) is owned by [rememberScanMac] because GATT MACs may be
  /// stale under Android RPA.
  static void bindPeerIdentity({
    required String nodeId,
    String? mac,
    int? hash,
  }) {
    final resolvedMac = (mac != null && mac.isNotEmpty && mac != '<unknown>')
        ? mac
        : null;

    if (nodeId.length >= 4) {
      nodeIdPrefixToNodeId[nodeId.substring(0, 4)] = nodeId;
    }

    if (hash != null) rememberPeerHash(nodeId, hash);
    if (resolvedMac != null) {
      macToNodeId[resolvedMac] = nodeId;
      // Only seed dial MAC if scan has never seen this peer.
      if (!nodeIdToMac.containsKey(nodeId)) {
        nodeIdToMac[nodeId] = resolvedMac;
      }
      // Drop any leftover MAC-keyed presence once identity is known.
      localSeenNodes.remove(resolvedMac);
    }
  }

  /// Rebuild stable advertisement-prefix lookup after a fresh mesh session.
  /// A saved profile gives us the full node ID even before the first GATT
  /// handshake; ambiguous four-character prefixes must wait for that bind.
  static void seedKnownPeerPrefixes(
    Iterable<String> nodeIds, {
    required String localNodeId,
  }) {
    final owners = <String, Set<String>>{};
    for (final id in nodeIds) {
      if (id == localNodeId || id.length < 4) continue;
      owners
          .putIfAbsent(id.substring(0, 4).toLowerCase(), () => <String>{})
          .add(id);
    }
    for (final entry in owners.entries) {
      if (entry.value.length == 1) {
        nodeIdPrefixToNodeId[entry.key] = entry.value.single;
      } else {
        nodeIdPrefixToNodeId.remove(entry.key);
      }
    }
  }

  /// Record a connectable advertise MAC from scan results.
  static void rememberScanMac(String nodeId, String mac, {DateTime? seenAt}) {
    if (nodeId.isEmpty || mac.isEmpty || mac == '<unknown>') return;
    final at = seenAt ?? DateTime.now();
    // Android can deliver delayed batches. Never let an
    // older sighting of the *same* MAC overwrite a fresher one. A *different* MAC
    // is an RPA rotation — always take it even if its stamp lags slightly.
    final prevSeen = nodeIdMacSeenAt[nodeId];
    final prevMac = nodeIdToMac[nodeId];
    if (prevSeen != null &&
        at.isBefore(prevSeen) &&
        prevMac != null &&
        prevMac == mac) {
      return;
    }
    // RPA rotated — drop proven dial MAC so urgent prefers the live ADV.
    final prevGood = lastGoodDialMac[nodeId];
    if (prevGood != null && prevGood != mac) {
      lastGoodDialMac.remove(nodeId);
    }
    nodeIdToMac[nodeId] = mac;
    macToNodeId[mac] = nodeId;
    nodeIdMacSeenAt[nodeId] = at;
    // Fresh advertisement — clear Dart-side deadlist so urgent can dial again.
    deadMacUntil.remove(mac);
  }

  static void rememberPeerBusy(String nodeId, bool isBusy, {DateTime? seenAt}) {
    if (nodeId.isEmpty) return;
    final at = seenAt ?? DateTime.now();
    final previousAt = peerBusySeenAtByNodeId[nodeId];
    if (previousAt != null && at.isBefore(previousAt)) return;
    peerBusyStateByNodeId[nodeId] = isBusy;
    peerBusySeenAtByNodeId[nodeId] = at;
    if (isBusy) {
      _urgentLegacyDialFallbacks.remove(nodeId);
      _urgentLegacyFallbackTimers.remove(nodeId)?.cancel();
    }
  }

  static bool isPeerRecentlyBusy(String nodeId, {DateTime? now}) {
    if (peerBusyStateByNodeId[nodeId] != true) return false;
    final seenAt = peerBusySeenAtByNodeId[nodeId];
    if (seenAt == null) return false;
    final age = (now ?? DateTime.now()).difference(seenAt);
    return !age.isNegative && age <= peerBusyFreshnessWindow;
  }

  static int? peerBusyAgeMs(String nodeId, {DateTime? now}) {
    final seenAt = peerBusySeenAtByNodeId[nodeId];
    if (seenAt == null) return null;
    return (now ?? DateTime.now()).difference(seenAt).inMilliseconds;
  }

  static void rememberScanRssi(String nodeId, int rssi, {DateTime? seenAt}) {
    if (nodeId.isEmpty) return;
    final at = seenAt ?? DateTime.now();
    final previousAt = nodeIdRssiSeenAt[nodeId];
    if (previousAt != null && at.isBefore(previousAt)) return;
    nodeIdRssiDbm[nodeId] = rssi;
    nodeIdRssiSeenAt[nodeId] = at;
  }

  /// Bind a MAC learned from a GATT connection without marking it scan-fresh.
  static void rememberObservedPeerMac(String nodeId, String mac) {
    if (nodeId.isEmpty || mac.isEmpty || mac == '<unknown>') return;
    macToNodeId[mac] = nodeId;
  }

  /// Live scan MAC beats last successful dial (RPAs rotate; old dial MACs timeout).
  static String? preferredDialMac(String nodeId, {DateTime? now}) {
    final mac = nodeIdToMac[nodeId];
    final seenAt = nodeIdMacSeenAt[nodeId];
    if (mac == null || seenAt == null) return null;
    final mappedOwner = macToNodeId[mac];
    if (mappedOwner != null && mappedOwner != nodeId) return null;
    final age = (now ?? DateTime.now()).difference(seenAt);
    if (age > dialMacFreshnessWindow) return null;
    return mac;
  }

  static String? scanFreshDialMac(String nodeId, {DateTime? now}) {
    return preferredDialMac(nodeId, now: now);
  }

  /// Return a scan-fresh address for [nodeId] only when it differs from a
  /// failed RPA. A retry against the same address would repeat the stale target.
  static String? freshAlternateDialMac(
    String nodeId,
    String failedMac, {
    DateTime? now,
  }) {
    final candidate = scanFreshDialMac(nodeId, now: now);
    return candidate == null || candidate == failedMac ? null : candidate;
  }

  /// All known dial targets for [nodeId], freshest scan sighting first.
  static List<String> candidateDialMacs(String nodeId) {
    if (nodeId.isEmpty) return const [];
    final seenAt = nodeIdMacSeenAt[nodeId];
    final ranked = <String, DateTime>{};

    void add(String? mac, {DateTime? at}) {
      if (mac == null || mac.isEmpty || mac == '<unknown>') return;
      final mappedOwner = macToNodeId[mac];
      if (mappedOwner != null && mappedOwner != nodeId) return;
      ranked.putIfAbsent(
        mac,
        () => at ?? seenAt ?? DateTime.fromMillisecondsSinceEpoch(0),
      );
    }

    add(nodeIdToMac[nodeId], at: seenAt);
    add(lastGoodDialMac[nodeId], at: seenAt);
    for (final e in macToNodeId.entries) {
      if (e.value == nodeId) add(e.key, at: seenAt);
    }
    final list = ranked.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return [for (final e in list) e.key];
  }

  static List<String> dialMacSources(String nodeId, String mac) {
    final sources = <String>[];
    if (nodeIdToMac[nodeId] == mac) sources.add('nodeIdToMac');
    if (lastGoodDialMac[nodeId] == mac) sources.add('lastGoodDialMac');
    if (macToNodeId[mac] == nodeId) sources.add('macToNodeId');
    return sources.isEmpty ? const ['unknown'] : sources;
  }

  void _traceUrgentDialSelection(
    String peerId,
    List<String> macs,
    String? selectedMac,
  ) {
    final now = DateTime.now();
    final lastScanAt = nodeIdMacSeenAt[peerId];
    final lastScanAgeMs = lastScanAt == null
        ? 'unknown'
        : now.difference(lastScanAt).inMilliseconds.toString();
    final lastScanMac = nodeIdToMac[peerId] ?? 'unknown';
    final candidateDetails = macs
        .map((mac) {
          return '$mac:${dialMacSources(peerId, mac).join('+')}';
        })
        .join(',');
    final deadUntil = selectedMac == null ? null : deadMacUntil[selectedMac];
    final deadRemainingMs = deadUntil == null
        ? -1
        : deadUntil.difference(now).inMilliseconds;
    final selectedSources = selectedMac == null
        ? 'none'
        : dialMacSources(peerId, selectedMac).join('+');
    debugPrint(
      '[BLE_TRACE] EVENT:URGENT_DIAL_SELECTION | '
      'PEER_NODE_ID:$peerId | TARGET_MAC:${selectedMac ?? 'none'} | '
      'TARGET_SOURCES:$selectedSources | '
      'CANDIDATES:$candidateDetails | LAST_SCAN_MAC:$lastScanMac | '
      'LAST_SCAN_AGE_MS:$lastScanAgeMs | '
      'FRESH_SCAN_ALLOWED:${selectedMac != null} | '
      'CURRENT_NEIGHBOR:${currentNeighborIds.contains(peerId)} | '
      'DEAD_REMAINING_MS:$deadRemainingMs | '
      'WALL_MS:${now.millisecondsSinceEpoch}',
    );
  }

  void _traceUrgentFlow(
    String event, {
    Map<String, Object?> fields = const {},
  }) {
    final values = <String>[
      if (_urgentMessageId?.isNotEmpty == true) 'MSG_ID:$_urgentMessageId',
      for (final entry in fields.entries)
        if (entry.value != null) '${entry.key}:${entry.value}',
      'WALL_MS:${DateTime.now().millisecondsSinceEpoch}',
    ];
    debugPrint('[BLE_TRACE] EVENT:$event | ${values.join(' | ')}');
  }

  /// Call after a successful *outbound* dial whose peer nodeId is now known.
  static void rememberSuccessfulDial(String nodeId, String mac) {
    if (nodeId.isEmpty || mac.isEmpty || mac == '<unknown>') return;
    lastGoodDialMac[nodeId] = mac;
    macToNodeId[mac] = nodeId;
    // Do NOT bump nodeIdMacSeenAt here — observation timestamps lag wall-clock, so
    // stamping now() made every later scan sighting look "older" and got dropped.
    // Urgent freshness must stay scan-driven; only seed dial MAC if scan never saw peer.
    if (!nodeIdToMac.containsKey(nodeId)) {
      nodeIdToMac[nodeId] = mac;
    }
  }

  /// Outbound offer succeeded before identity was known — claim when sender_id arrives.
  static void noteOrphanDialSuccess(String mac) {
    if (mac.isEmpty || mac == '<unknown>') return;
    _orphanDialSuccessAt[mac] = DateTime.now();
  }

  /// If [mac] recently completed an outbound dial, bind it as the dial MAC for [nodeId].
  static bool claimOrphanDialSuccess(String nodeId, String mac) {
    final at = _orphanDialSuccessAt.remove(mac);
    if (at == null) return false;
    if (DateTime.now().difference(at) > const Duration(seconds: 30)) {
      return false;
    }
    rememberSuccessfulDial(nodeId, mac);
    return true;
  }

  BleDiscoveryService(
    this._ref, {
    this.onConnectionPhaseChanged,
    this.onScannerError,
    this.onScannerStalled,
    this.onUrgentGattRecovery,
  });

  final Ref _ref;
  final void Function()? onConnectionPhaseChanged;
  final void Function(String error)? onScannerError;
  final void Function()? onScannerStalled;
  final Future<void> Function()? onUrgentGattRecovery;

  final NativeMeshService _nativeMesh = NativeMeshService();
  Uint8List? _localHash;
  bool? _localExtendedConnectable;
  StreamSubscription<List<MeshScanResult>>? _scanSub;
  Timer? _heartbeatTimer;
  DateTime? _lastResultAt;
  final Map<String, DateTime> _lastRssiTraceAt = {};

  /// Set of remote hash values currently being connected to (prevents duplicate in-flight attempts).
  final Set<int> _connectingHashes = {};

  /// NodeIds with an in-flight handshake (advertised DB hash rotates; nodeId does not).
  final Set<String> _connectingNodeIds = {};

  /// Queue of peers waiting for a connection slot.
  final List<
    ({
      int hash,
      String device,
      String? peerNodeId,
      String? peerKeyHint,
      bool hashTrusted,
      bool forceNewest,
      Completer<void> done,
    })
  >
  _pendingQueue = [];
  final Map<int, DateTime> _hashCooldowns = {};

  /// Exposed for UI / notifier guards while a GATT sync is in flight.
  bool get isConnecting => _connectingHashes.isNotEmpty;

  Duration _deadlistDurationForError(Object error) {
    // Keep all cooldowns short so real peers are retried quickly after transient failures.
    var d = const Duration(seconds: 4);
    if (error is PlatformException) {
      switch (error.code) {
        case 'CHAR_NOT_FOUND':
          // Likely not our mesh GATT (ghost advertiser / stale cache).
          d = const Duration(seconds: 30);
          break;
        case 'held_link_stale':
          // This link was previously healthy; wait briefly for its close and
          // require a refreshed scan address before opening the replacement.
          d = const Duration(seconds: 1);
          break;
        case 'timeout':
          // Transient write/connection timeout — retry soon.
          d = const Duration(seconds: 4);
          break;
        case 'DISCONNECTED':
          // HCI 133 (GATT_ERROR / link-layer collision) — very short cooldown;
          // these are usually transient and the peer is still reachable.
          d = const Duration(seconds: 4);
          break;
      }
    }
    return d;
  }

  /// Neighbor IDs seen in the last 60 seconds (expired entries are pruned).
  List<String> get currentNeighborIds {
    final now = DateTime.now();
    // Retain presence entries longer than the active gossip window so UI can render
    // tombstones (60-75s) without the data disappearing prematurely.
    localSeenNodes.removeWhere((_, time) {
      return now.difference(time).inSeconds > 85;
    });

    final ids = localSeenNodes.entries
        .where((e) => now.difference(e.value).inSeconds <= 60)
        .map((e) => e.key)
        .toList(growable: false);
    ids.sort();
    return ids;
  }

  void _notifyConnectionPhase() {
    onConnectionPhaseChanged?.call();
  }

  /// Advertisement includes our GATT service UUID (ignore unrelated peripherals).
  static bool advertisesMeshService(MeshScanResult r) {
    return r.serviceUuids.any((u) => u.toLowerCase() == meshServiceUuid);
  }

  /// Identity fields the scanner uses when it sees [result].
  static MeshAdvertisement inspectAdvertisement(MeshScanResult result) {
    return MeshAdvertisement.fromScanResult(result);
  }

  void setLocalHash(Uint8List value) {
    _localHash = value;
  }

  Uint8List? _tryGetRemoteHash(MeshScanResult r) {
    return MeshAdvertisement.fromScanResult(r).payload;
  }

  bool _isLikelyNativeMeshAdvert(MeshScanResult r) {
    // Fast path: the primary advertisement always contains our Service UUID.
    // Accept the packet immediately so we don't drop results where the Scan
    // Response (which carries the 0xFFE0 manufacturer hash) hasn't merged yet.
    if (advertisesMeshService(r)) return true;

    // Legacy / fallback path: older builds that don't emit the service UUID
    // yet can still be matched by the full manufacturer magic-header check.
    final raw = r.manufacturerData[meshManufacturerId];
    if (raw == null || raw.length < 8) return false;
    return raw[0] == 0x4D && // M
        raw[1] == 0x45 && // E
        raw[2] == 0x53 && // S
        raw[3] == 0x48; // H
  }

  /// First [meshShortNodeIdLength] characters of [fullNodeId] (fits MAN data budget).
  static String shortNodeIdFromFull(String fullNodeId) {
    if (fullNodeId.isEmpty) return '';
    if (fullNodeId.length < meshShortNodeIdLength) {
      return fullNodeId;
    }
    return fullNodeId.substring(0, meshShortNodeIdLength);
  }

  /// Scans for advertisers that include [meshServiceUuid] in the payload.
  ///
  /// [wipeMaps]: full session start clears routing tables. Soft recoveries
  /// (stalled/failed scanner) must keep [nodeIdToMac] / vectors so urgent
  /// push-on-write still has someone to dial.
  Future<void> startScanning({
    required String myNodeId,
    String? ownMac,
    required void Function(String shortNodeId) onDiscovered,
    bool wipeMaps = true,
  }) async {
    _localNodeId = myNodeId;
    _localExtendedConnectable = await _nativeMesh
        .usesExtendedConnectableAdvertising();
    final localPrefixForTrace = myNodeId.length >= 4
        ? myNodeId.substring(0, 4)
        : myNodeId;
    debugPrint(
      '[DIAL_CAPABILITY] local_prefix=$localPrefixForTrace local_extended_connectable=$_localExtendedConnectable',
    );
    if (wipeMaps) {
      _connectingHashes.clear();
      _connectingNodeIds.clear();
      _pendingQueue.clear();
      _hashCooldowns.clear();
      _lastRssiTraceAt.clear();
      hashToNodeId.clear();
      hashOwners.clear();
      latestHashByNodeId.clear();
      macToNodeId.clear();
      nodeIdPrefixToNodeId.clear();
      _peerExtendedConnectableByPrefix.clear();
      _peerExtendedConnectableSeenAtByPrefix.clear();
      _loggedPeerCapabilities.clear();
      _loggedDialElections.clear();
      localSeenNodes.clear();
      nodeIdToMac.clear();
      nodeIdMacSeenAt.clear();
      peerBusyStateByNodeId.clear();
      peerBusySeenAtByNodeId.clear();
      nodeIdRssiDbm.clear();
      nodeIdRssiSeenAt.clear();
      lastGoodDialMac.clear();
      _orphanDialSuccessAt.clear();
      lastFullSync.clear();
      peerCaughtUp.clear();
      peerObservedHash.clear();
      lastKnownPeerVector.clear();
      lastKnownPeerBuckets.clear();
      DeepCatchup.reset();
      CatchupPushBudget.shared.clear();
      _activeBluetoothNodeId = null;
      _lastBluetoothActivityAt = null;
      _lastUrgentAttemptAt.clear();
      _urgentExcludedPeerIds.clear();
      _urgentLegacyDialFallbacks.clear();
      for (final timer in _urgentLegacyFallbackTimers.values) {
        timer.cancel();
      }
      _urgentLegacyFallbackTimers.clear();
      _scanHandshakeThrottle.clear();
      _lastLocalWriteAt = null;
      _localWriteRateEwma = 0;
      deadMacUntil.clear();
      deadHashUntil.clear();
    }
    if (wipeMaps) {
      final db = await _ref.read(databaseProvider.future);
      seedKnownPeerPrefixes(await db.getAllUserIds(), localNodeId: myNodeId);
    }
    _notifyConnectionPhase();

    await _scanSub?.cancel();
    _heartbeatTimer?.cancel();

    final ownMacUpper = ownMac?.toUpperCase();

    debugPrint(
      '⏳ [BENCHMARK] EVENT:SCAN_COMMANDED | TIMESTAMP:${DateTime.now().millisecondsSinceEpoch}',
    );

    _scanSub = NativeBleRadio.instance.scanResults.listen(
      (results) {
        if (results.isNotEmpty) {
          // Any callback proves scanner liveness. Busy mesh peers can briefly
          // omit their service ADV, which must not trigger a radio restart.
          _lastResultAt = DateTime.now();
        }
        // Native callbacks contain only new observations. Order batched callbacks
        // by observation time and keep the age guard for delayed Android batches.
        final sortedResults = results.toList()
          ..sort((a, b) => b.seenAt.compareTo(a.seenAt));

        final scanNow = DateTime.now();
        for (final r in sortedResults) {
          // Ignore delayed sightings so stale rotating addresses cannot overwrite
          // the current dial address.
          if (scanNow.difference(r.seenAt).inSeconds > 6) {
            continue;
          }
          if (!_isLikelyNativeMeshAdvert(r)) {
            continue;
          }

          final mac = r.macAddress;
          final lastRssiTraceAt = _lastRssiTraceAt[mac];
          if (lastRssiTraceAt == null ||
              scanNow.difference(lastRssiTraceAt).inSeconds >= 5) {
            _lastRssiTraceAt[mac] = scanNow;
            debugPrint(
              '[BLE_TRACE] EVENT:SCAN_SEEN | TARGET_MAC:$mac | '
              'RSSI:${r.rssi} | WALL_MS:${DateTime.now().millisecondsSinceEpoch}',
            );
          }

          // CRITICAL: skip self-advertisements. Android can see its own BLE advertisement
          // in scan results. Connecting to self causes a loopback that wastes all attempts.
          if (ownMacUpper != null && mac.toUpperCase() == ownMacUpper) {
            continue;
          }

          // --- SMART TELEMETRY / ROUTING GUARD ---
          var targetBusy = false;
          int? telemetryHash16;
          String? telemetryNodeIdPrefix;
          bool? remoteExtendedConnectable;
          final telemetryData = r.manufacturerData[0xFFE1];
          if (telemetryData != null && telemetryData.length >= 4) {
            final tBytes = Uint8List.fromList(telemetryData);
            // Bit Unpacking
            final int flags = tBytes[2] | (tBytes[3] << 8);
            final bool isBusy = (flags & (1 << 4)) != 0;
            targetBusy = isBusy;
            final capabilitiesKnown = (flags & (1 << 7)) != 0;
            if (capabilitiesKnown) {
              remoteExtendedConnectable = (flags & (1 << 8)) != 0;
            }
            if ((flags & (1 << 15)) != 0) {
              telemetryNodeIdPrefix = tBytes
                  .take(2)
                  .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
                  .join();
              if (remoteExtendedConnectable != null) {
                final normalizedPrefix = telemetryNodeIdPrefix.toLowerCase();
                _rememberPeerExtendedConnectable(
                  normalizedPrefix,
                  remoteExtendedConnectable,
                  r.seenAt,
                );
                if (_loggedPeerCapabilities.add(
                  '$normalizedPrefix:$remoteExtendedConnectable',
                )) {
                  debugPrint(
                    '[DIAL_CAPABILITY] local_extended_connectable=$_localExtendedConnectable remote_prefix=$telemetryNodeIdPrefix remote_extended_connectable=$remoteExtendedConnectable',
                  );
                }
              }
            } else {
              // Older builds advertise a 16-bit hash fragment here.
              telemetryHash16 = (tBytes[0] << 8) | tBytes[1];
            }
          }
          // ---------------------------------------

          final localNodeIdPrefix = myNodeId.length >= 4
              ? myNodeId.substring(0, 4).toLowerCase()
              : myNodeId.padRight(4, '0').toLowerCase();
          Uint8List? remotePayload = _tryGetRemoteHash(r);
          if (remotePayload != null) {
            final payloadBusy = MeshDialPolicy.busyFromMeshPayload(
              remotePayload,
            );
            if (payloadBusy != null) targetBusy = payloadBusy;
          }
          if (remoteExtendedConnectable == null && remotePayload != null) {
            remoteExtendedConnectable =
                MeshDialPolicy.extendedConnectableFromMeshPayload(
                  remotePayload,
                );
          }
          if (telemetryNodeIdPrefix == null && remotePayload != null) {
            telemetryNodeIdPrefix = MeshAdvertisement.readNodeIdPrefix(
              remotePayload,
            )?.toLowerCase();
          }
          if (remoteExtendedConnectable != null &&
              telemetryNodeIdPrefix != null) {
            _rememberPeerExtendedConnectable(
              telemetryNodeIdPrefix.toLowerCase(),
              remoteExtendedConnectable,
              r.seenAt,
            );
          }
          if (telemetryNodeIdPrefix == localNodeIdPrefix) {
            // The stable prefix catches our own advertiser even while Android
            // rotates its BLE address and the scan response is still missing.
            continue;
          }

          final hasRealHash =
              remotePayload != null && remotePayload.length >= 8;

          // Service UUID / telemetry often arrive before the 0xFFE0 scan-response hash.
          // Still dial those peers — skipping them left the mesh with zero peers after restart.
          if (!hasRealHash && advertisesMeshService(r)) {
            String? known;
            if (telemetryNodeIdPrefix != null) {
              known = nodeIdPrefixToNodeId[telemetryNodeIdPrefix];
              final mappedMacNode = macToNodeId[mac];
              if (known == null &&
                  mappedMacNode != null &&
                  mappedMacNode.toLowerCase().startsWith(
                    telemetryNodeIdPrefix,
                  )) {
                known = mappedMacNode;
              }
            } else {
              known = macToNodeId[mac];
            }
            if (known == null &&
                telemetryNodeIdPrefix == null &&
                telemetryHash16 != null) {
              for (final entry in hashToNodeId.entries) {
                final fragment = (entry.key >> 32) & 0xffff;
                if (fragment == telemetryHash16) {
                  known = entry.value;
                  break;
                }
              }
            }
            if (known != null) {
              localSeenNodes[known] = DateTime.now();
              rememberScanMac(known, mac, seenAt: r.seenAt);
              rememberScanRssi(known, r.rssi, seenAt: r.seenAt);
              rememberPeerBusy(known, targetBusy, seenAt: r.seenAt);
            }
            final coolKey = mac.hashCode | 0x100000000;
            if (targetBusy) {
              // Match the full-hash path: do not open another client while the
              // peer advertises that its single inbound slot is occupied.
              _hashCooldowns[coolKey] = DateTime.now();
              continue;
            }
            // Unknown advertisers stay off the UI until the identity handshake
            // returns a stable nodeId — raw MACs would look like extra devices.
            // Stable per-MAC cooldown key (not a DB hash — never compare for hashesMatch).
            final last = _hashCooldowns[coolKey];
            final coolSecs = known == null
                ? 4 + (coolKey.abs() % 3)
                : (targetBusy ? 8 : 5) + (coolKey.abs() % 4);
            if (last == null ||
                DateTime.now().difference(last).inSeconds >= coolSecs) {
              // Use the primary advertisement's stable node prefix when
              // available so this path elects the same dialer as full scan data.
              final localHash = _localHash;
              final localHashFragment =
                  localHash != null && localHash.length >= 4
                  ? ByteData.sublistView(localHash).getUint16(2, Endian.big)
                  : null;
              final electedToInitiate = telemetryNodeIdPrefix != null
                  ? _shouldInitiatePeer(
                      localNodeId: myNodeId,
                      remoteNodeIdPrefix: telemetryNodeIdPrefix,
                      remoteExtendedConnectable: remoteExtendedConnectable,
                    )
                  : known != null
                  ? _shouldInitiatePeer(
                      localNodeId: myNodeId,
                      remoteNodeId: known,
                      remoteExtendedConnectable: remoteExtendedConnectable,
                    )
                  : MeshDialPolicy.shouldInitiateFromPartialHash(
                      localHashFragment: localHashFragment,
                      remoteHashFragment: telemetryHash16,
                    );

              if (!electedToInitiate) {
                _hashCooldowns[coolKey] = DateTime.now();
                if (known != null) {
                  unawaited(_tryInboundCatchupPush(myNodeId, known));
                }
                continue;
              }

              final syncKey = known ?? mac;
              final lastSync = lastFullSync[syncKey];
              // Unknown mesh advertisers always get an identity handshake, even when
              // neither side has a new message and CRDT hashes currently match.
              final needsIdentity = known == null;
              final needsAntiEntropy =
                  needsIdentity ||
                  lastSync == null ||
                  DateTime.now().difference(lastSync).inSeconds > 8;
              if (needsAntiEntropy) {
                onDiscovered(known ?? mac);
                unawaited(
                  _runMeshInitiatorHandshake(
                    myNodeId,
                    coolKey,
                    r.macAddress,
                    peerNodeId: known,
                    peerKeyHint: known,
                    remoteHashTrusted: false,
                  ),
                );
              } else {
                _hashCooldowns[coolKey] = DateTime.now();
              }
            }
            continue;
          }
          if (remotePayload == null) {
            debugPrint(
              '[ROUTING] Dropping $mac: remotePayload is null (no 0xFFE0 and advertisesMeshService=false)',
            );
            continue;
          }
          if (remotePayload.length < 8) {
            debugPrint('[ROUTING] Dropping $mac: remotePayload < 8 bytes');
            continue; // Need at least 8 bytes for the 64-bit hash
          }

          // CRITICAL: Extract 4-byte node ID prefix (at bytes 8-11) and skip if it's our own advertisement!
          // Payload layout: [8 bytes hash][4 bytes nodeId prefix]
          final remoteNodeIdStr = MeshAdvertisement.readNodeIdPrefix(
            remotePayload,
          );
          if (remoteNodeIdStr != null) {
            final localNodeIdPrefix = myNodeId.length >= 4
                ? myNodeId.substring(0, 4)
                : myNodeId.padRight(4, '0');
            if (remoteNodeIdStr == localNodeIdPrefix) {
              continue; // Drop self-advertisement completely
            }
          }
          final remoteHashInt = MeshAdvertisement.databaseHashFromPayload(
            remotePayload,
          );
          if (remoteHashInt == null) {
            debugPrint('⚠️ [SCAN] Failed to parse 64-bit hash from $mac');
            continue;
          }

          // Resolve identity + refresh UI presence BEFORE connect cooldowns/deadlists.
          // A peer in the penalty box is still "nearby" if we keep hearing its ads.
          final prefix = MeshAdvertisement.readNodeIdPrefix(remotePayload);
          // The node-ID prefix and exact scan address identify the advertiser.
          // Its DB hash can match another peer after the mesh converges, so only
          // use a hash as a last resort while it has one known owner.
          final stableNodeId =
              (prefix != null ? nodeIdPrefixToNodeId[prefix] : null) ??
              macToNodeId[mac] ??
              hashToNodeId[remoteHashInt];

          if (stableNodeId != null) {
            rememberScanMac(stableNodeId, mac, seenAt: r.seenAt);
            rememberScanRssi(stableNodeId, r.rssi, seenAt: r.seenAt);
            rememberPeerBusy(stableNodeId, targetBusy, seenAt: r.seenAt);
            localSeenNodes[stableNodeId] = DateTime.now();
            if (prefix != null && prefix.isNotEmpty) {
              nodeIdPrefixToNodeId[prefix] = stableNodeId;
              if (remoteExtendedConnectable != null) {
                _rememberPeerExtendedConnectable(
                  prefix.toLowerCase(),
                  remoteExtendedConnectable,
                  r.seenAt,
                );
              }
            }
          }

          // The peer advertises busy when its single inbound GATT slot is in
          // use. Let that exchange finish instead of starting another connect.
          if (targetBusy) {
            // Busy is peer state, not hash state. Multiple peers can advertise
            // the same converged database hash, so do not cool down that hash
            // and accidentally throttle another node.
            continue;
          }

          final deadHashTime = deadHashUntil[remoteHashInt];
          if (deadHashTime != null && DateTime.now().isBefore(deadHashTime)) {
            continue;
          }

          final deadUntil = deadMacUntil[mac];
          if (deadUntil != null && DateTime.now().isBefore(deadUntil)) {
            continue;
          }

          final discoveredId = stableNodeId ?? mac;

          final localHashBytes = _localHash;
          // Read local hash as 64-bit (two uint32 words) to match new 8-byte payload format.
          final localHashInt =
              (localHashBytes != null && localHashBytes.length >= 8)
              ? (ByteData.sublistView(
                          localHashBytes,
                        ).getUint32(0, Endian.big) <<
                        32) |
                    ByteData.sublistView(
                      localHashBytes,
                    ).getUint32(4, Endian.big)
              : null;

          final hashesMatch =
              localHashInt != null && remoteHashInt == localHashInt;
          if (stableNodeId != null && localHashInt != null) {
            rememberPeerHash(stableNodeId, remoteHashInt);
            if (hashesMatch) {
              peerCaughtUp[stableNodeId] = true;
            } else {
              markSyncDiverged(stableNodeId);
            }
          }

          final last = _hashCooldowns[remoteHashInt];
          // Diverged peers: dial as soon as the prior attempt's short cool ends.
          // Matched peers keep longer cooldown so we don't stampede.
          if (last != null) {
            final coolSecs = hashesMatch
                ? ((targetBusy ? 7 : 5) + (remoteHashInt.abs() % 4))
                : (targetBusy ? 2 : 1);
            if (DateTime.now().difference(last).inSeconds < coolSecs) {
              continue;
            }
          }

          // When hashes diverge, always dial (cooldown is the only rate limit).
          // A recent successful sync must not delay catch-up of new writes.
          // Unknown advertisers also always dial — identity handshake must not wait
          // for a new chat message just because DBs currently hash-match.
          final syncKey = stableNodeId ?? mac;
          final lastSync = lastFullSync[syncKey];
          final needsIdentity = stableNodeId == null;
          final needsAntiEntropy =
              needsIdentity ||
              !hashesMatch ||
              lastSync == null ||
              DateTime.now().difference(lastSync).inSeconds > 90;

          if (hashesMatch && !needsAntiEntropy) {
            _hashCooldowns[remoteHashInt] = DateTime.now();
            continue;
          }

          // While any dialable peer is known behind, don't spend the outbound
          // slot on someone we already know is caught up.
          if (stableNodeId != null &&
              isPeerKnownCaughtUp(stableNodeId) &&
              hasDialableBehindPeer(excluding: stableNodeId)) {
            _hashCooldowns[remoteHashInt] = DateTime.now();
            continue;
          }

          if (!hashesMatch) {
            final divKey = stableNodeId ?? mac;
            _peerHashDivergedAt.putIfAbsent(divKey, () => DateTime.now());
            final divergedAt = _peerHashDivergedAt[divKey];
            // Fresh divergence: defer scan dial so writer urgent wins (2-node).
            if (divergedAt != null &&
                DateTime.now().difference(divergedAt).inMilliseconds < 800) {
              continue;
            }
          } else if (stableNodeId != null) {
            _peerHashDivergedAt.remove(stableNodeId);
          }

          // Elect one dialer for every peer pair, including divergent hashes.
          // Previously both sides initiated after simultaneous writes, creating
          // crossed GATT connects and a burst of connect watchdog timeouts.
          if (!_shouldInitiatePeer(
            localNodeId: myNodeId,
            remoteNodeId: stableNodeId,
            remoteNodeIdPrefix: prefix,
            localHash: localHashInt,
            remoteHash: remoteHashInt,
            remoteExtendedConnectable: remoteExtendedConnectable,
          )) {
            _hashCooldowns[remoteHashInt] = DateTime.now();
            if (stableNodeId != null) {
              unawaited(_tryInboundCatchupPush(myNodeId, stableNodeId));
            }
            continue;
          }

          // Yield the outbound slot to urgent push-on-write, but still NOTIFY
          // over an existing inbound link (server-side catch-up during a burst).
          final hold = _urgentRadioHoldUntil;
          if (hold != null && DateTime.now().isBefore(hold)) {
            final nid = stableNodeId;
            if (nid != null) {
              unawaited(_tryInboundCatchupPush(myNodeId, nid));
            }
            continue;
          }
          final circuit = _outboundCircuitUntil;
          if (circuit != null && DateTime.now().isBefore(circuit)) {
            continue;
          }
          onDiscovered(discoveredId);
          unawaited(
            _runMeshInitiatorHandshake(
              myNodeId,
              remoteHashInt,
              r.macAddress,
              peerNodeId: stableNodeId,
              peerKeyHint: stableNodeId ?? prefix,
              remoteHashTrusted: true,
            ),
          );
        }
      },
      onError: (Object e, StackTrace st) {
        debugPrint('⚠️ [SCAN] scanResults stream error: $e');
        // Error only — stall recover would stopScan/clear dials mid urgent sync.
        onScannerError?.call(e.toString());
      },
    );

    // Robust startScan with retry for "APPLICATION_REGISTRATION_FAILED" (Android code 2).
    int attempts = 0;
    var started = false;
    while (attempts < 3) {
      try {
        attempts++;
        // Explicitly stop any existing scan before starting a new one.
        // This clears any stale scanner registrations in some Android stacks.
        await NativeBleRadio.instance.stopScan();
        if (attempts > 1) {
          await Future.delayed(Duration(milliseconds: 500 * attempts));
        }

        await NativeBleRadio.instance.startScan();
        // Do NOT stamp liveness here — Android can return success then async
        // APPLICATION_REGISTRATION_FAILED, which would silence the watchdog.
        final scanStartedAt = DateTime.now();
        _lastResultAt = null;
        _heartbeatTimer = Timer.periodic(const Duration(seconds: 8), (timer) {
          final last = _lastResultAt;
          final quietFor = last != null
              ? DateTime.now().difference(last)
              : DateTime.now().difference(scanStartedAt);
          if (quietFor.inSeconds > 12) {
            debugPrint(
              '⚠️ [SCAN] Watchdog: No scan results for 12s. Scanner may be stalled.',
            );
            onScannerStalled?.call();
          }
        });
        started = true;
        break;
      } catch (e) {
        debugPrint('⚠️ [SCAN] Start failure (attempt $attempts): $e');
        if (attempts >= 3) {
          onScannerError?.call(e.toString());
          await _scanSub?.cancel();
          _scanSub = null;
          return;
        }
      }
    }
    if (!started) return;
  }

  bool _shouldInitiatePeer({
    required String localNodeId,
    String? remoteNodeId,
    String? remoteNodeIdPrefix,
    int? localHash,
    int? remoteHash,
    bool? remoteExtendedConnectable,
  }) {
    final peerIdentity = remoteNodeIdPrefix ?? remoteNodeId;
    final remoteCapability =
        remoteExtendedConnectable ??
        _remoteExtendedConnectableForPeer(peerIdentity);
    final localPrefix = localNodeId.length >= 4
        ? localNodeId.substring(0, 4).toLowerCase()
        : localNodeId.toLowerCase();
    final preferredLegacyInitiatorPrefix = remoteCapability == false
        ? _preferredLegacyPeerInitiatorPrefix(
            localNodeId,
            legacyPeerIdentity: peerIdentity,
          )
        : null;
    final isLegacySecondary =
        _localExtendedConnectable == true &&
        remoteCapability == false &&
        preferredLegacyInitiatorPrefix != null &&
        preferredLegacyInitiatorPrefix != localPrefix;
    final legacyFallbackActive =
        remoteNodeId != null &&
        _urgentLegacyDialFallbacks.contains(remoteNodeId);
    final elected = isLegacySecondary
        ? legacyFallbackActive
        : MeshDialPolicy.shouldInitiate(
            localNodeId: localNodeId,
            remoteNodeId: remoteNodeId,
            remoteNodeIdPrefix: remoteNodeIdPrefix,
            localHash: localHash,
            remoteHash: remoteHash,
            localExtendedConnectable: _localExtendedConnectable,
            remoteExtendedConnectable: remoteCapability,
          );
    final peerLabel = peerIdentity ?? 'unknown';
    final decisionKey =
        '$localPrefix:$peerLabel:$_localExtendedConnectable:$remoteCapability:$elected';
    if (_loggedDialElections.add(decisionKey)) {
      debugPrint(
        '[BLE_TRACE] EVENT:DIAL_ELECTION | '
        'LOCAL_PREFIX:$localPrefix | PEER:$peerLabel | '
        'LOCAL_EXTENDED_CONNECTABLE:${_localExtendedConnectable ?? 'unknown'} | '
        'REMOTE_EXTENDED_CONNECTABLE:${remoteCapability ?? 'unknown'} | '
        'PREFERRED_LEGACY_INITIATOR_PREFIX:${preferredLegacyInitiatorPrefix ?? 'none'} | '
        'LEGACY_FALLBACK:$legacyFallbackActive | '
        'INITIATE:$elected | WALL_MS:${DateTime.now().millisecondsSinceEpoch}',
      );
    }
    return elected;
  }

  bool _shouldInitiateUrgentPeer(String localNodeId, String peerNodeId) {
    return _shouldInitiatePeer(
      localNodeId: localNodeId,
      remoteNodeId: peerNodeId,
    );
  }

  void _rememberPeerExtendedConnectable(
    String prefix,
    bool extendedConnectable,
    DateTime seenAt,
  ) {
    final normalizedPrefix = prefix.toLowerCase();
    final previousAt = _peerExtendedConnectableSeenAtByPrefix[normalizedPrefix];
    if (previousAt != null && seenAt.isBefore(previousAt)) return;
    _peerExtendedConnectableByPrefix[normalizedPrefix] = extendedConnectable;
    _peerExtendedConnectableSeenAtByPrefix[normalizedPrefix] = seenAt;
  }

  String? _preferredLegacyPeerInitiatorPrefix(
    String localNodeId, {
    String? legacyPeerIdentity,
  }) {
    if (_localExtendedConnectable != true) return null;
    final now = DateTime.now();
    final localPrefix = localNodeId.length >= 4
        ? localNodeId.substring(0, 4).toLowerCase()
        : localNodeId.toLowerCase();
    final legacyPrefix = legacyPeerIdentity == null
        ? null
        : (legacyPeerIdentity.length >= 4
              ? legacyPeerIdentity.substring(0, 4).toLowerCase()
              : legacyPeerIdentity.toLowerCase());
    if (localPrefix.isEmpty) return null;
    final candidates = <String>{localPrefix};
    // A peer can be directly reachable before its capability trailer is
    // observed. Include such peers unless they are known legacy, so two
    // modern nodes do not both elect themselves during initial discovery.
    for (final entry in localSeenNodes.entries) {
      final nodeId = entry.key;
      if (nodeId.length < 8 || !nodeId.contains('-')) continue;
      final prefix = nodeId.substring(0, 4).toLowerCase();
      if (prefix == legacyPrefix ||
          _peerExtendedConnectableByPrefix[prefix] == false) {
        continue;
      }
      final age = now.difference(entry.value);
      if (age > const Duration(seconds: 15) ||
          age < const Duration(seconds: -5)) {
        continue;
      }
      candidates.add(prefix);
    }
    for (final entry in _peerExtendedConnectableByPrefix.entries) {
      if (entry.value != true) continue;
      if (entry.key == legacyPrefix) continue;
      final seenAt = _peerExtendedConnectableSeenAtByPrefix[entry.key];
      if (seenAt == null) continue;
      final age = now.difference(seenAt);
      if (age > const Duration(seconds: 15) ||
          age < const Duration(seconds: -5)) {
        continue;
      }
      candidates.add(entry.key.toLowerCase());
    }
    return MeshDialPolicy.preferredLegacyPeerInitiator(candidates);
  }

  bool _isLegacyFallbackCandidate(String localNodeId, String peerNodeId) {
    if (_localExtendedConnectable != true ||
        _remoteExtendedConnectableForPeer(peerNodeId) != false) {
      return false;
    }
    final preferred = _preferredLegacyPeerInitiatorPrefix(
      localNodeId,
      legacyPeerIdentity: peerNodeId,
    );
    final localPrefix = localNodeId.length >= 4
        ? localNodeId.substring(0, 4).toLowerCase()
        : localNodeId.toLowerCase();
    return preferred != null && preferred != localPrefix;
  }

  void _scheduleLegacyInitiatorFallback(String myNodeId, String peerId) {
    if (_urgentLegacyFallbackTimers[peerId]?.isActive == true) return;
    const delay = Duration(milliseconds: 1600);
    _traceUrgentFlow(
      'URGENT_LEGACY_DIAL_FALLBACK_SCHEDULED',
      fields: {'PEER_NODE_ID': peerId, 'DELAY_MS': delay.inMilliseconds},
    );
    late final Timer timer;
    timer = Timer(delay, () {
      if (identical(_urgentLegacyFallbackTimers[peerId], timer)) {
        _urgentLegacyFallbackTimers.remove(peerId);
      }
      if (isPeerRecentlyBusy(peerId)) return;
      _urgentLegacyDialFallbacks.add(peerId);
      _traceUrgentFlow(
        'URGENT_LEGACY_DIAL_FALLBACK_READY',
        fields: {'PEER_NODE_ID': peerId},
      );
      if (_urgentSyncRunning) {
        _urgentSyncDirty = true;
      } else {
        unawaited(_runUrgentSync(myNodeId));
      }
    });
    _urgentLegacyFallbackTimers[peerId] = timer;
  }

  bool? _remoteExtendedConnectableForPeer(String? peerIdentity) {
    if (peerIdentity == null || peerIdentity.isEmpty) return null;
    final normalized = peerIdentity.toLowerCase();
    final direct = _peerExtendedConnectableByPrefix[normalized];
    if (direct != null) return direct;
    if (normalized.length < 4) return null;
    return _peerExtendedConnectableByPrefix[normalized.substring(0, 4)];
  }

  bool _prefersRemoteExtendedInitiator(String peerId) =>
      _localExtendedConnectable != true &&
      _remoteExtendedConnectableForPeer(peerId) == true;

  /// Initiates a GATT sync handshake to the given device, or queues it if one is already in flight.
  /// Returns a Future that completes when *this* dial attempt finishes (including if queued).
  Future<void> _runMeshInitiatorHandshake(
    String myNodeId,
    int remoteHashInt,
    String device, {
    String? peerNodeId,
    String? peerKeyHint,
    bool remoteHashTrusted = true,
    bool forceNewestPush = false,
  }) async {
    Completer<void> enqueue({required bool front}) {
      final done = Completer<void>();
      final superseded = [
        for (final e in _pendingQueue)
          if (e.hash == remoteHashInt ||
              (peerNodeId != null && e.peerNodeId == peerNodeId))
            e,
      ];
      for (final e in superseded) {
        if (!e.done.isCompleted) e.done.complete();
      }
      _pendingQueue.removeWhere(
        (e) =>
            e.hash == remoteHashInt ||
            (peerNodeId != null && e.peerNodeId == peerNodeId),
      );
      final entry = (
        hash: remoteHashInt,
        device: device,
        peerNodeId: peerNodeId,
        peerKeyHint: peerKeyHint,
        hashTrusted: remoteHashTrusted,
        forceNewest: forceNewestPush,
        done: done,
      );
      if (front) {
        _pendingQueue.insert(0, entry);
      } else {
        _pendingQueue.add(entry);
      }
      return done;
    }

    final busy =
        _connectingHashes.isNotEmpty ||
        _connectingHashes.contains(remoteHashInt) ||
        (peerNodeId != null && _connectingNodeIds.contains(peerNodeId));
    if (busy) {
      if (forceNewestPush && peerNodeId != null) {
        if (await _tryInboundUrgentPush(myNodeId, peerNodeId)) return;
      }
      if (forceNewestPush) {
        _traceUrgentFlow(
          'URGENT_HANDSHAKE_QUEUED',
          fields: {
            'PEER_NODE_ID': peerNodeId,
            'QUEUE_LENGTH': _pendingQueue.length + 1,
            'CONNECTING_HASH_COUNT': _connectingHashes.length,
            'CONNECTING_PEER': _connectingNodeIds.contains(peerNodeId),
          },
        );
        return enqueue(front: true).future;
      }
      for (final e in _pendingQueue) {
        if (e.hash == remoteHashInt ||
            (peerNodeId != null && e.peerNodeId == peerNodeId)) {
          return e.done.future;
        }
      }
      return enqueue(front: false).future;
    }

    await _doHandshake(
      myNodeId,
      remoteHashInt,
      device,
      peerNodeId: peerNodeId,
      peerKeyHint: peerKeyHint,
      remoteHashTrusted: remoteHashTrusted,
      forceNewestPush: forceNewestPush,
    );
  }

  Future<void> _doHandshake(
    String myNodeId,
    int remoteHashInt,
    String device, {
    String? peerNodeId,
    String? peerKeyHint,
    bool remoteHashTrusted = true,
    bool forceNewestPush = false,
  }) async {
    // If the peer is already our GATT client, NOTIFY catch-up instead of a
    // second outbound (dual-role is what wedges Red→Clear after a burst).
    final inboundPeer = peerNodeId ?? macToNodeId[device];
    if (inboundPeer != null && !forceNewestPush) {
      final now = DateTime.now();
      if (_scanHandshakeThrottle.shouldThrottle(inboundPeer, now: now)) {
        // scanResults contains repeated cached advertisements. Bound repeated
        // active-link checks and trace logging to one per peer per second.
        _hashCooldowns[remoteHashInt] = now;
        return;
      }
    }
    if (inboundPeer != null) {
      final inboundCatchupTimer = Stopwatch()..start();
      final inboundCatchupHandled = await _tryInboundCatchupPush(
        myNodeId,
        inboundPeer,
      );
      if (forceNewestPush) {
        _traceUrgentFlow(
          'URGENT_PRE_SEND_STAGE',
          fields: {
            'STAGE': 'inbound_catchup_probe',
            'ELAPSED_US': inboundCatchupTimer.elapsedMicroseconds,
            'HANDLED': inboundCatchupHandled,
          },
        );
      }
      if (inboundCatchupHandled) return;

      // The peer already owns the central role for this pair. Avoid a new
      // connection while that server-side link is being set up, but let urgent
      // traffic reuse an idle client link that is already open to this MAC.
      final activeServerLookupTimer = Stopwatch()..start();
      var activeServerMacs = (await _readInboundServerState())['active']!;
      if (forceNewestPush) {
        _traceUrgentFlow(
          'URGENT_PRE_SEND_STAGE',
          fields: {
            'STAGE': 'active_server_lookup',
            'ELAPSED_US': activeServerLookupTimer.elapsedMicroseconds,
            'ACTIVE_MAC_COUNT': activeServerMacs.length,
          },
        );
      }
      var inboundMac = _resolveInboundMacForPeer(inboundPeer, activeServerMacs);
      if (inboundMac != null) {
        activeServerMacs = (await _readInboundServerState(
          forceRefresh: true,
        ))['active']!;
        inboundMac = _resolveInboundMacForPeer(inboundPeer, activeServerMacs);
      }
      if (inboundMac != null) {
        if (!forceNewestPush) {
          debugPrint(
            '[BLE_TRACE] EVENT:OUTBOUND_DEFERRED_INBOUND_ACTIVE | '
            'PEER_NODE_ID:$inboundPeer | TARGET_MAC:$inboundMac | '
            'WALL_MS:${DateTime.now().millisecondsSinceEpoch}',
          );
          // The link that blocks us usually closes within a second (it is the
          // tail of the round that just finished). Retry then instead of
          // waiting for the next scan result to come round.
          _deferredRepairs.defer(
            inboundPeer,
            myNodeId: myNodeId,
            hash: remoteHashInt,
            now: DateTime.now(),
          );
          return;
        }

        final heldClientLookupTimer = Stopwatch()..start();
        final targetMac = device;
        final cachedHeldClientMac = await _readReusableHeldClientMac();
        var reusableHeldClient =
            cachedHeldClientMac?.toUpperCase() == targetMac.toUpperCase();
        var nativeFallbackUs = 0;
        if (!reusableHeldClient && cachedHeldClientMac == null) {
          final nativeFallbackTimer = Stopwatch()..start();
          reusableHeldClient = await _nativeMesh.hasReusableHeldClientForMac(
            targetMac,
          );
          nativeFallbackUs = nativeFallbackTimer.elapsedMicroseconds;
        }
        _traceUrgentFlow(
          'URGENT_PRE_SEND_STAGE',
          fields: {
            'STAGE': 'held_client_lookup',
            'ELAPSED_US': heldClientLookupTimer.elapsedMicroseconds,
            'FOUND': reusableHeldClient,
            'NATIVE_FALLBACK_US': nativeFallbackUs,
          },
        );
        if (reusableHeldClient) {
          _inboundCatchupPending.remove(inboundPeer);
          _traceUrgentFlow(
            'URGENT_REUSING_HELD_OUTBOUND',
            fields: {
              'PEER_NODE_ID': inboundPeer,
              'TARGET_MAC': device,
              'INBOUND_MAC': inboundMac,
            },
          );
        } else {
          _inboundCatchupPending.add(inboundPeer);
          _traceUrgentFlow(
            'URGENT_WAITING_FOR_INBOUND_LINK',
            fields: {'PEER_NODE_ID': inboundPeer, 'TARGET_MAC': inboundMac},
          );
          final waitResult = await _waitForInboundUrgentLinkState(
            myNodeId,
            inboundPeer,
            timeout: const Duration(seconds: 4),
          );
          if (waitResult == _InboundUrgentWaitResult.delivered) return;
          if (waitResult == _InboundUrgentWaitResult.timedOut) {
            _traceUrgentFlow(
              'URGENT_INBOUND_LINK_WAIT_TIMED_OUT',
              fields: {'PEER_NODE_ID': inboundPeer, 'TARGET_MAC': inboundMac},
            );
            throw _UrgentInboundLinkStillActive(inboundPeer, inboundMac);
          }

          // The peer's unready server link has released its GATT slot. The
          // urgent offer below can now use a real outbound connection.
          _inboundCatchupPending.remove(inboundPeer);
          _traceUrgentFlow(
            'URGENT_INBOUND_LINK_RELEASED',
            fields: {'PEER_NODE_ID': inboundPeer, 'TARGET_MAC': inboundMac},
          );
        }
      }
    }
    // Scan-path dials must yield while urgent push-on-write holds the radio.
    if (!forceNewestPush) {
      final hold = _urgentRadioHoldUntil;
      if (hold != null && DateTime.now().isBefore(hold)) {
        return;
      }
    }
    _connectingHashes.add(remoteHashInt);
    if (peerNodeId != null) _connectingNodeIds.add(peerNodeId);
    // Even if the connection fails/cancels, keep a short cooldown for this remote hash so
    // we don't spam connect() attempts to stale/cached advertisers.
    _hashCooldowns[remoteHashInt] = DateTime.now();
    _notifyConnectionPhase();
    final targetMac = device;
    debugPrint(
      '[BENCHMARK] TARGET_MAC:$targetMac | EVENT:SCAN_HIT | TIMESTAMP:${DateTime.now().millisecondsSinceEpoch}',
    );

    try {
      final db = await _ref.read(databaseProvider.future);
      Future<T> traceUrgentStage<T>(
        String stage,
        Future<T> Function() action,
      ) async {
        final timer = Stopwatch()..start();
        final value = await action();
        if (forceNewestPush) {
          _traceUrgentFlow(
            'URGENT_SYNC_STAGE',
            fields: {'STAGE': stage, 'ELAPSED_US': timer.elapsedMicroseconds},
          );
        }
        return value;
      }

      // Combined offer+push: vector so the server can compute what WE lack, plus a
      // *delta* of what we think the peer still lacks (from lastKnownPeerVector).
      // Full-DB pushes balloon past the GATT transfer watchdog and stall lagging nodes.
      final myVector = await traceUrgentStage(
        'version_vector',
        db.getVersionVector,
      );
      final myHashInt = await traceUrgentStage(
        'database_hash',
        db.getDatabaseHash,
      );
      final myNodeId2 = myNodeId;
      final resolvedPeer =
          peerNodeId ?? macToNodeId[targetMac] ?? hashToNodeId[remoteHashInt];
      final priorVector = resolvedPeer != null
          ? Map<String, dynamic>.from(lastKnownPeerVector[resolvedPeer] ?? {})
          : <String, dynamic>{};
      final priorBuckets = resolvedPeer != null
          ? lastKnownPeerBuckets[resolvedPeer]
          : null;
      Map<String, dynamic> ourChangeset;
      var usedGapFill = false;
      // Everything below that uses the whole-history digest wants it current
      // (a stale one points at rows the peer just sent us). The urgent path
      // never waits for it.
      if (!forceNewestPush) await db.computeDeepDigest();
      if (forceNewestPush) {
        // Keep the urgent per-write payload small. Re-sending the full 25-row
        // page on every local message repeatedly transferred rows the peer had
        // just received; ordered catch-up still fills older gaps.
        ourChangeset = await traceUrgentStage(
          'newest_rows',
          () => db.getNewestRowsChangeset(maxRows: 8),
        );
      } else if (priorBuckets != null && priorBuckets.isNotEmpty) {
        // Prefer bucket gap-fill — newest-N cannot heal stranded rows once they
        // fall outside the sliding window (seen: Red stuck ~30 behind forever).
        // The whole-history fingerprints are 32x finer than the window ones,
        // so use them when the peer has sent them.
        final peerDeep = resolvedPeer == null
            ? null
            : DeepCatchup.peer(resolvedPeer);
        ourChangeset = <String, dynamic>{};
        if (peerDeep != null &&
            peerDeep.hasBuckets &&
            DeepCatchup.differs(db.freshDeepDigest, peerDeep)) {
          ourChangeset = await db.getRowsForDeepMismatch(
            peerDeep.buckets,
            maxRows: repairPageRows,
            peerKey: resolvedPeer ?? '',
          );
        }
        if (ourChangeset.isEmpty) {
          ourChangeset = await db.getRowsForMismatchedBuckets(
            priorBuckets,
            maxRows: repairPageRows,
            peerKey: resolvedPeer ?? '',
          );
        }
        usedGapFill = ourChangeset.isNotEmpty;
        if (ourChangeset.isEmpty && priorVector.isNotEmpty) {
          ourChangeset = await db.getDeltaChangeset(
            priorVector,
            maxRows: MeshCatchup.pageRows,
          );
        }
      } else if (priorVector.isNotEmpty) {
        ourChangeset = await db.getDeltaChangeset(
          priorVector,
          maxRows: MeshCatchup.pageRows,
        );
      } else {
        // Unknown peer frontier — never ship full DB (empty vector = all rows).
        ourChangeset = await db.getNewestRowsChangeset(maxRows: 8);
      }
      // Nothing newer to send but whole-history digests differ: trade older
      // rows from the mismatched deep buckets. Skipped on the urgent path and
      // whenever our digest is still being recomputed, so it never adds delay.
      if (ourChangeset.isEmpty && !forceNewestPush && resolvedPeer != null) {
        final peerDeep = DeepCatchup.peer(resolvedPeer);
        if (peerDeep != null &&
            peerDeep.hasBuckets &&
            DeepCatchup.differs(db.freshDeepDigest, peerDeep)) {
          ourChangeset = await db.getRowsForDeepMismatch(
            peerDeep.buckets,
            maxRows: repairPageRows,
            peerKey: resolvedPeer,
          );
          usedGapFill = ourChangeset.isNotEmpty;
        }
      }
      // Large rotating repair ONLY when we have nothing else to send.
      // Merging 100+ repair rows into every diverge offer ballooned GATT (~149
      // msgs) and blocked the second peer for many seconds.
      if (ourChangeset.isEmpty &&
          remoteHashTrusted &&
          remoteHashInt != myHashInt) {
        ourChangeset = await db.getHashRepairChangeset(
          peerKey: resolvedPeer ?? peerKeyHint ?? targetMac,
          maxRows: 40,
        );
      }
      if (ourChangeset.isEmpty) {
        ourChangeset = await db.getNewestRowsChangeset(maxRows: 8);
      }
      // A gap-fill page is chosen because the peer is missing those rows, so
      // the newest ones (which it holds) would only take up room in it.
      if (!forceNewestPush && !usedGapFill) {
        ourChangeset = prioritizeNewestMessages(
          ourChangeset,
          await db.getNewestRowsChangeset(maxRows: 8),
        );
      }
      // Only currently reachable peers consume a turn. nodeIdToMac retains
      // historical rotating addresses, so including its keys shrinks a live
      // two-node link's lease even after those peers have disappeared.
      final leasePeers = <String>{...currentNeighborIds}..remove(myNodeId);
      final lease = MeshLeasePolicy.calculate(
        meshNodeCount: (leasePeers.length + 1).clamp(2, 12),
        backlogRows: MeshCatchup.rowCount(ourChangeset),
        messagesPerSecond: _localWriteRateEwma,
      );
      await _nativeMesh.setHeldLinkLease(
        idle: lease.idle,
        maximum: lease.maximum,
      );
      // Include a complete typical fingerprint bucket. An 8-row slice can
      // repeatedly miss the one stranded row in a 500-message run.
      if (!forceNewestPush) {
        ourChangeset = truncateChangesetForBle(
          ourChangeset,
          maxRowsPerTable: usedGapFill ? repairPageRows : 25,
        );
      }
      final fpsBlob = await traceUrgentStage(
        'bucket_fingerprints',
        db.getBucketFingerprintBlob,
      );
      final peerDeepKnown = resolvedPeer == null
          ? null
          : DeepCatchup.peer(resolvedPeer);
      final deepFields = forceNewestPush
          ? const <String, dynamic>{}
          : DeepCatchup.envelopeFields(
              db,
              withBuckets: DeepCatchup.differs(
                db.freshDeepDigest,
                peerDeepKnown,
              ),
            );
      final offerEnvelope = <String, dynamic>{
        'type': 'offer',
        'sender_id': myNodeId2,
        'sender_hash': myHashInt,
        'neighbors': currentNeighborIds,
        'peer_hashes': peerHashesForGossip(),
        'vector': myVector,
        'fps_b': base64Encode(fpsBlob),
        ...deepFields,
        if (usedGapFill) repairFlagKey: true,
        'initiator_data': ourChangeset,
      };
      final encodeTimer = Stopwatch()..start();
      var payload = zlib.encode(utf8.encode(jsonEncode(offerEnvelope)));
      if (forceNewestPush) {
        _traceUrgentFlow(
          'URGENT_SYNC_STAGE',
          fields: {
            'STAGE': 'offer_encode_compress',
            'ELAPSED_US': encodeTimer.elapsedMicroseconds,
            'PAYLOAD_BYTES': payload.length,
          },
        );
      }
      if (payload.length > maxOfferPushBytes) {
        // Keep fps_b (128B — instant gap fill); drop/shrink initiator_data.
        ourChangeset = truncateChangesetForBle(
          ourChangeset,
          maxRowsPerTable: 20,
        );
        offerEnvelope['initiator_data'] = ourChangeset;
        payload = zlib.encode(utf8.encode(jsonEncode(offerEnvelope)));
        if (payload.length > maxOfferPushBytes) {
          offerEnvelope.remove('initiator_data');
          payload = zlib.encode(utf8.encode(jsonEncode(offerEnvelope)));
          debugPrint(
            '⚠️ [DISCOVERY] Offer capped for $targetMac — '
            'fps-only (${payload.length} bytes; peer=$resolvedPeer)',
          );
        } else {
          final rowCounts = ourChangeset.map(
            (t, rows) => MapEntry(t, (rows as List).length),
          );
          debugPrint(
            '⚠️ [DISCOVERY] Offer push truncated for $targetMac — '
            'rows=$rowCounts peer=$resolvedPeer fps=${fpsBlob.length}B',
          );
        }
      } else {
        final rowCounts = ourChangeset.map(
          (t, rows) => MapEntry(t, (rows as List).length),
        );
        final deepMode = deepFields.containsKey(DeepCatchup.bucketsKey)
            ? 'buckets'
            : deepFields.isNotEmpty
            ? 'hash'
            : forceNewestPush
            ? 'urgent'
            : 'stale';
        debugPrint(
          '📤 [DISCOVERY] Sending offer+push to $targetMac — '
          'vector=${myVector.length} rows=$rowCounts peer=$resolvedPeer '
          'fps=${fpsBlob.length}B deep=$deepMode',
        );
      }
      final macAddress = device;
      // Android mesh advertisers use Random Resolvable Addresses.
      // We pass isRandom: true to ensure the native layer uses the correct addressing mode.
      if (resolvedPeer != null) {
        markBluetoothActivity(resolvedPeer);
      }
      final finalOfferDataRaw = offerEnvelope['initiator_data'];
      final finalOfferData = finalOfferDataRaw is Map
          ? Map<String, dynamic>.from(finalOfferDataRaw)
          : <String, dynamic>{};
      final offerMessageIds = benchmarkMessageIds(finalOfferData);
      traceBenchmarkMessageRows(
        'OFFER_INCLUDED',
        finalOfferData,
        fields: {
          'TARGET_MAC': targetMac,
          'PEER_NODE': resolvedPeer,
          'PAYLOAD_BYTES': payload.length,
        },
      );
      await _nativeMesh.sendPayload(
        macAddress,
        Uint8List.fromList(payload),
        isRandom: true,
        bypassDeadCache: forceNewestPush,
        benchmarkMessageIds: offerMessageIds,
      );
      if (resolvedPeer != null) {
        markMessagesRelayed(resolvedPeer, offerMessageIds);
      }
      if (resolvedPeer != null) markBluetoothActivity(resolvedPeer);
      debugPrint(
        '✅ [DISCOVERY] Offer sent to $targetMac (${payload.length} bytes) — awaiting delta reply',
      );
      if (resolvedPeer != null) {
        rememberSuccessfulDial(resolvedPeer, targetMac);
      } else {
        // Identity comes back on the delta — keep this MAC as the proven dial target.
        noteOrphanDialSuccess(targetMac);
      }
      debugPrint(
        '[BENCHMARK] TARGET_MAC:$targetMac | EVENT:OFFER_SENT | TIMESTAMP:${DateTime.now().millisecondsSinceEpoch}',
      );
      // Do NOT mark lastFullSync here — send ≠ completed sync. Completion is recorded
      // when we process the peer's delta (or finish serving their offer).
    } catch (e) {
      if (forceNewestPush) {
        _traceUrgentFlow(
          'URGENT_HANDSHAKE_FAILED',
          fields: {
            'PEER_NODE_ID': peerNodeId,
            'TARGET_MAC': targetMac,
            'ERROR': e.toString(),
          },
        );
      }
      debugPrint('🟥 Connection/GATT failed for $targetMac: $e');
      final heldLinkFailed =
          e is PlatformException && e.code == 'held_link_stale';

      // Peer already dialed us — push newest over the open server link instead of
      // burning another outbound attempt (seen: urgent retry → already_connected).
      if (forceNewestPush &&
          e is PlatformException &&
          (e.code == 'already_connected' || e.code == 'gatt_busy')) {
        try {
          if (peerNodeId != null &&
              await _tryInboundUrgentPush(myNodeId, peerNodeId)) {
            return;
          }
          if (e.code == 'already_connected') {
            await _pushNewestOverInbound(myNodeId, targetMac);
            if (peerNodeId != null) {
              rememberSuccessfulDial(peerNodeId, targetMac);
            } else {
              noteOrphanDialSuccess(targetMac);
            }
            return;
          }
        } catch (pushErr) {
          debugPrint(
            '⚠️ [DISCOVERY] Inbound urgent push failed for $targetMac: $pushErr',
          );
          if (e.code == 'already_connected') rethrow;
        }
      }

      // Pause scan-path dials (not urgent) so the radio can recover.
      if (!forceNewestPush) {
        final circuitDelay = heldLinkFailed
            ? const Duration(milliseconds: 500)
            : const Duration(seconds: 8);
        _outboundCircuitUntil = DateTime.now().add(circuitDelay);
        _traceUrgentFlow(
          'OUTBOUND_CIRCUIT_DELAY_SET',
          fields: {
            'PEER_NODE_ID': peerNodeId,
            'TARGET_MAC': targetMac,
            'DELAY_MS': circuitDelay.inMilliseconds,
            'REASON': heldLinkFailed ? 'held_link_stale' : 'gatt_failure',
          },
        );
      }
      // Refresh hash cooldown so retries respect the scan debounce window.
      _hashCooldowns[remoteHashInt] = DateTime.now();
      // Suppress this specific MAC briefly; urgent retries need a lighter penalty.
      final duration = _deadlistDurationForError(e);
      if (!forceNewestPush) {
        deadMacUntil[targetMac] = DateTime.now().add(duration);
      } else {
        deadMacUntil[targetMac] = DateTime.now().add(
          const Duration(milliseconds: 400),
        );
      }
      // Only add hash-based cooldown for persistent failures (CHAR_NOT_FOUND, not transient 133).
      // For DISCONNECTED/timeout, the hash cooldown (8s) already covers the retry window —
      // adding a separate deadHashUntil would double-suppress and skip the peer entirely.
      if (e is PlatformException && e.code == 'CHAR_NOT_FOUND') {
        deadHashUntil[remoteHashInt] = DateTime.now().add(duration);
      }
      // Drop proven-dial cache for this MAC so the next attempt can use a fresher scan RPA.
      if (peerNodeId != null && lastGoodDialMac[peerNodeId] == targetMac) {
        lastGoodDialMac.remove(peerNodeId);
      }
      // A stale RPA can reach the wrong cached GATT service. Penalize that MAC,
      // but let presence decay naturally so one bad dial cannot erase a known peer.
      final mapped = macToNodeId[targetMac] ?? peerNodeId;
      if (mapped != null &&
          e is PlatformException &&
          e.code == 'CHAR_NOT_FOUND') {
        if (nodeIdToMac[mapped] == targetMac) {
          nodeIdMacSeenAt.remove(mapped);
        }
      } else if (mapped != null && nodeIdToMac[mapped] == targetMac) {
        // Keep presence; only drop scan-fresh stamp so the next scan can refresh.
        nodeIdMacSeenAt.remove(mapped);
      }
      // Urgent path must observe failure so it can retry an alternate scan MAC.
      if (forceNewestPush) rethrow;
    } finally {
      // Native GATT callbacks own connection teardown here.
      // The native GATT layer now keeps the connection open so the Server can push
      // the Delta reply back via NOTIFY. The Client's onCharacteristicChanged handler
      // will close the connection cleanly when it receives the "||EOF||" notify chunk.
      // The 60-second transferWatchdog guards against a server that never replies.
      _connectingHashes.remove(remoteHashInt);
      if (peerNodeId != null) _connectingNodeIds.remove(peerNodeId);
      _notifyConnectionPhase();
      // Drain queue only when urgent is not holding the radio for scan-path work.
      _drainPendingQueue(myNodeId);
    }
  }

  void _drainPendingQueue(String myNodeId) {
    if (_pendingQueue.isEmpty || _connectingHashes.isNotEmpty) return;
    while (_pendingQueue.isNotEmpty && _connectingHashes.isEmpty) {
      final next = _pendingQueue.first;
      if (!next.forceNewest) {
        final hold = _urgentRadioHoldUntil;
        if (hold != null && DateTime.now().isBefore(hold)) return;
        final nid = next.peerNodeId;
        // Defer caught-up dials while a behind peer still needs the radio.
        if (nid != null &&
            isPeerKnownCaughtUp(nid) &&
            hasDialableBehindPeer(excluding: nid)) {
          _pendingQueue.removeAt(0);
          if (!next.done.isCompleted) next.done.complete();
          continue;
        }
      }
      _pendingQueue.removeAt(0);
      if (next.forceNewest) {
        _traceUrgentFlow(
          'URGENT_HANDSHAKE_DEQUEUED',
          fields: {
            'PEER_NODE_ID': next.peerNodeId,
            'QUEUE_LENGTH': _pendingQueue.length,
          },
        );
      }
      unawaited(() async {
        try {
          await _doHandshake(
            myNodeId,
            next.hash,
            next.device,
            peerNodeId: next.peerNodeId,
            peerKeyHint: next.peerKeyHint,
            remoteHashTrusted: next.hashTrusted,
            forceNewestPush: next.forceNewest,
          );
          if (!next.done.isCompleted) next.done.complete();
        } catch (e, st) {
          if (!next.done.isCompleted) next.done.completeError(e, st);
        }
      }());
      break; // one slot at a time
    }
  }

  /// Burst scan to pick up peers after a local DB write; resumes continuous scan after.
  Future<void> runQuickScan() async {
    // Deprecated: scanning stays continuously enabled to avoid Android scan rate limits.
    // Keep method for any legacy callers; it is now a no-op.
    return;
  }

  /// Reconcile persistent hash drift with bucket repair over the held link.
  void requestHashRepair(String myNodeId, String peerId, int remoteHash) {
    final now = DateTime.now();
    final last = _lastHashRepairAttempt[peerId];
    if (last != null && now.difference(last) < const Duration(seconds: 2)) {
      return;
    }
    final mac = preferredDialMac(peerId);
    if (mac == null || mac.isEmpty) {
      debugPrint('🗄️ [SYNC] Hash repair skipped: no dial address for $peerId');
      return;
    }
    _lastHashRepairAttempt[peerId] = now;
    unawaited(
      _runMeshInitiatorHandshake(
        myNodeId,
        remoteHash,
        mac,
        peerNodeId: peerId,
        peerKeyHint: peerId,
        remoteHashTrusted: true,
        forceNewestPush: false,
      ),
    );
  }

  Timer? _urgentSyncDebounce;
  DateTime? _urgentRadioHoldUntil;
  DateTime? _outboundCircuitUntil;
  DateTime? _lastLocalWriteAt;
  double _localWriteRateEwma = 0;

  /// Keep inbound offer replies focused on live chat rows during a write burst.
  /// Older anti-entropy rows are still sent after the burst quiets down.
  bool get hasRecentLocalWrite {
    final lastWrite = _lastLocalWriteAt;
    return lastWrite != null &&
        DateTime.now().difference(lastWrite) <= const Duration(seconds: 3);
  }

  final Map<String, DateTime> _lastInboundCatchupAt = {};
  final Set<String> _inboundPushBusy = {};
  final Set<String> _inboundCatchupPending = {};
  final Set<String> _inboundUrgentPending = {};
  final Map<String, DateTime> _lastHashRepairAttempt = {};
  final Map<String, DateTime> _lastUrgentAttemptAt = {};

  /// Peers a relayed message must not be sent back to (the peer it came from),
  /// keyed to that message so a later local write still reaches them.
  final Map<String, String> _urgentExcludedPeerIds = <String, String>{};
  final _scanHandshakeThrottle = MeshScanHandshakeThrottle(
    window: const Duration(seconds: 1),
  );
  bool _urgentSyncRunning = false;
  bool _urgentSyncDirty = false;
  String? _urgentMessageId;
  final Map<String, DateTime> _peerHashDivergedAt = {};
  String? _localNodeId;
  String? _urgentMyNodeId;
  String? _urgentTargetPeer;
  Completer<bool>? _urgentInboundCompleter;
  final Set<String> _activeInboundServerMacs = <String>{};
  final Set<String> _notifyReadyInboundServerMacs = <String>{};
  bool _inboundServerStateInitialized = false;
  Completer<void>? _inboundServerStateChanged;
  String? _cachedReusableHeldClientMac;
  Stopwatch? _heldClientLeaseClock;
  Duration _heldClientCacheLifetime = Duration.zero;
  bool _heldClientStateInitialized = false;

  void _signalInboundServerStateChanged() {
    final changed = _inboundServerStateChanged;
    _inboundServerStateChanged = null;
    if (changed != null && !changed.isCompleted) changed.complete();
  }

  /// Seed the event-driven inbound-link cache from native state after the
  /// EventChannel subscription is attached.
  void replaceInboundServerState({
    required Iterable<String> activeMacs,
    required Iterable<String> readyMacs,
  }) {
    _activeInboundServerMacs
      ..clear()
      ..addAll(activeMacs.where((mac) => mac.isNotEmpty));
    _notifyReadyInboundServerMacs
      ..clear()
      ..addAll(readyMacs.where((mac) => mac.isNotEmpty));
    _activeInboundServerMacs.addAll(_notifyReadyInboundServerMacs);
    _inboundServerStateInitialized = true;
    _signalInboundServerStateChanged();
  }

  void clearInboundServerState() {
    _activeInboundServerMacs.clear();
    _notifyReadyInboundServerMacs.clear();
    _inboundServerStateInitialized = true;
    onHeldClientUnavailable();
    _signalInboundServerStateChanged();
  }

  void replaceReusableHeldClientState(String? mac) {
    if (mac == null || mac.isEmpty) {
      onHeldClientUnavailable();
    } else {
      onHeldClientAvailable(mac, releaseInMs: 3000);
    }
  }

  void onHeldClientAvailable(String mac, {int? releaseInMs}) {
    if (mac.isEmpty) {
      onHeldClientUnavailable();
      return;
    }
    // Expire the local hint early so Android's delayed lease callback cannot
    // leave Dart attempting to reuse a link after its actual release.
    final safeLifetimeMs = ((releaseInMs ?? 3000) - 500)
        .clamp(0, 10000)
        .toInt();
    _heldClientStateInitialized = true;
    if (safeLifetimeMs == 0) {
      onHeldClientUnavailable();
      return;
    }
    _cachedReusableHeldClientMac = mac;
    _heldClientCacheLifetime = Duration(milliseconds: safeLifetimeMs);
    _heldClientLeaseClock = Stopwatch()..start();
  }

  void onHeldClientUnavailable() {
    _heldClientStateInitialized = true;
    _cachedReusableHeldClientMac = null;
    _heldClientCacheLifetime = Duration.zero;
    _heldClientLeaseClock = null;
  }

  Future<String?> _readReusableHeldClientMac() async {
    if (_heldClientStateInitialized) {
      final mac = _cachedReusableHeldClientMac;
      final clock = _heldClientLeaseClock;
      if (mac != null &&
          clock != null &&
          clock.elapsed < _heldClientCacheLifetime) {
        return mac;
      }
      if (mac != null) onHeldClientUnavailable();
      return null;
    }

    final mac = await _nativeMesh.getReusableHeldClientMac();
    if (mac == null) {
      onHeldClientUnavailable();
    } else {
      onHeldClientAvailable(mac, releaseInMs: 3000);
    }
    return mac;
  }

  /// Native GATT server accepted a client — map RPA early for urgent targeting.
  void onServerClientConnected(String mac) {
    debugPrint('🔗 [DISCOVERY] Server client connected: $mac');
    if (mac.isNotEmpty) {
      _activeInboundServerMacs.add(mac);
      _notifyReadyInboundServerMacs.remove(mac);
      _inboundServerStateInitialized = true;
      _signalInboundServerStateChanged();
    }
    final myNodeId = _urgentMyNodeId ?? _localNodeId;
    if (myNodeId == null || mac.isEmpty) return;

    var peer = macToNodeId[mac];
    if (peer == null && currentNeighborIds.length == 1) {
      peer = _urgentTargetPeer ?? currentNeighborIds.first;
    }
    if (peer != null) {
      rememberObservedPeerMac(peer, mac);
    }
  }

  /// CCCD enabled — NOTIFY push is safe on this inbound link.
  void onServerClientReady(String mac) {
    debugPrint('🔗 [DISCOVERY] Server client NOTIFY-ready: $mac');
    if (mac.isNotEmpty) {
      _activeInboundServerMacs.add(mac);
      _notifyReadyInboundServerMacs.add(mac);
      _inboundServerStateInitialized = true;
      _signalInboundServerStateChanged();
    }
    final myNodeId = _urgentMyNodeId ?? _localNodeId;
    if (myNodeId == null || mac.isEmpty) return;

    var peer = macToNodeId[mac];
    if (peer == null && currentNeighborIds.length == 1) {
      peer = _urgentTargetPeer ?? currentNeighborIds.first;
    }
    if (peer == null) return;

    rememberObservedPeerMac(peer, mac);
    if (_urgentMyNodeId == null && !_inboundCatchupPending.contains(peer)) {
      return;
    }
    if (_urgentTargetPeer != null && peer != _urgentTargetPeer) return;

    unawaited(() async {
      if (await _tryInboundUrgentPush(myNodeId, peer!)) {
        _inboundCatchupPending.remove(peer);
        // Cancel only this peer's active outbound. A ready inbound link is the
        // preferred path, while unrelated peers should keep their own transfer.
        if (_connectingNodeIds.contains(peer)) {
          await _nativeMesh.cancelOutbound();
        }
        final c = _urgentInboundCompleter;
        if (_urgentTargetPeer == peer && c != null && !c.isCompleted) {
          c.complete(true);
        }
      }
    }());
  }

  void onServerClientNotReady(String mac) {
    if (mac.isEmpty) return;
    _notifyReadyInboundServerMacs.remove(mac);
    _activeInboundServerMacs.add(mac);
    _signalInboundServerStateChanged();
  }

  void onServerClientDisconnected(String mac) {
    if (mac.isEmpty) return;
    _activeInboundServerMacs.remove(mac);
    _notifyReadyInboundServerMacs.remove(mac);
    _inboundServerStateInitialized = true;
    _signalInboundServerStateChanged();
    debugPrint('🔗 [DISCOVERY] Server client disconnected: $mac');
    _retryDeferredRepairs();
  }

  final DeferredRepairQueue _deferredRepairs = DeferredRepairQueue();

  /// Re-dials peers whose round was put off while an inbound link was open.
  void _retryDeferredRepairs() {
    if (_deferredRepairs.isEmpty) return;
    Timer(const Duration(milliseconds: 300), () {
      for (final repair in _deferredRepairs.takeLive(DateTime.now())) {
        _lastHashRepairAttempt.remove(repair.peerId);
        requestHashRepair(repair.myNodeId, repair.peerId, repair.hash);
      }
    });
  }

  /// Dial known neighbors immediately after a local write (don't wait for ADV/scan).
  void requestUrgentSyncWithKnownPeers(
    String myNodeId, {
    String? messageId,
    String? excludePeerId,
  }) {
    if (messageId?.isNotEmpty == true) _urgentMessageId = messageId;
    if (excludePeerId?.isNotEmpty == true) {
      _urgentExcludedPeerIds[excludePeerId!] = messageId ?? '';
    }
    final now = DateTime.now();
    final previous = _lastLocalWriteAt;
    _lastLocalWriteAt = now;
    if (previous != null) {
      final intervalMs = now.difference(previous).inMilliseconds;
      if (intervalMs > 0) {
        final instantaneous = (1000 / intervalMs).clamp(0, 20).toDouble();
        _localWriteRateEwma = _localWriteRateEwma == 0
            ? instantaneous
            : (_localWriteRateEwma * 0.75) + (instantaneous * 0.25);
      }
    }
    _traceUrgentFlow(
      _urgentSyncRunning ? 'URGENT_SYNC_COALESCED' : 'URGENT_SYNC_REQUESTED',
      fields: {
        'RUNNING': _urgentSyncRunning,
        'DIRTY': _urgentSyncDirty,
        'PEER_COUNT': currentNeighborIds.length,
      },
    );
    if (_urgentSyncRunning) {
      _urgentSyncDirty = true;
      return;
    }
    _urgentSyncDebounce?.cancel();
    _urgentSyncDebounce = null;
    unawaited(_runUrgentSync(myNodeId));
  }

  /// Peer is already connected to our GATT server — NOTIFY [changeset].
  Future<void> _pushChangesetOverInbound(
    String myNodeId,
    String mac,
    Map<String, dynamic> changeset, {
    String pushPath = 'unspecified',
  }) async {
    final db = await _ref.read(databaseProvider.future);
    final myHashInt = await db.getDatabaseHash();
    final fpsBlob = await db.getBucketFingerprintBlob();
    final envelope = <String, dynamic>{
      'type': 'delta',
      'sender_id': myNodeId,
      'sender_hash': myHashInt,
      'neighbors': currentNeighborIds,
      'peer_hashes': peerHashesForGossip(),
      'fps_b': base64Encode(fpsBlob),
      if (pushPath != 'urgent_newest') ...DeepCatchup.envelopeFields(db),
      'data': changeset,
    };
    final payload = MeshPayloadLimits.encodeDelta(envelope);
    final sentChangeset = Map<String, dynamic>.from(envelope['data'] as Map);
    final peerId = macToNodeId[mac];
    final includedMessageIds = benchmarkMessageIds(sentChangeset);
    final totalRows = MeshCatchup.rowCount(sentChangeset);
    var tombstoneRows = 0;
    for (final rows in sentChangeset.values) {
      if (rows is! List) continue;
      for (final row in rows) {
        if (row is! Map) continue;
        final deleted = row['is_deleted'];
        if (deleted == 1 || deleted == true || deleted?.toString() == '1') {
          tombstoneRows++;
        }
      }
    }
    debugPrint(
      '[BLE_TRACE] EVENT:INBOUND_PUSH_PLAN | '
      'PUSH_PATH:$pushPath | PEER_NODE_ID:${peerId ?? ''} | '
      'ROWS:$totalRows | TOMBSTONE_ROWS:$tombstoneRows | '
      'PAYLOAD_BYTES:${payload.length} | '
      'WALL_MS:${DateTime.now().millisecondsSinceEpoch}',
    );
    traceBenchmarkMessageRows(
      'INBOUND_PUSH_INCLUDED',
      sentChangeset,
      fields: {
        'TARGET_MAC': mac,
        'PEER_NODE': peerId,
        'PUSH_PATH': pushPath,
        'PAYLOAD_BYTES': payload.length,
      },
    );
    if (peerId != null) markBluetoothActivity(peerId);
    await _nativeMesh.replyPayload(
      mac,
      Uint8List.fromList(payload),
      benchmarkMessageIds: includedMessageIds,
    );
    if (peerId != null) markMessagesRelayed(peerId, includedMessageIds);
    if (peerId != null) markBluetoothActivity(peerId);
    final rowCounts = sentChangeset.map(
      (t, rows) => MapEntry(t, (rows as List).length),
    );
    debugPrint(
      '🚀 [DISCOVERY] Inbound-push to $mac '
      '(${payload.length}B rows=$rowCounts)',
    );
  }

  Future<void> _pushNewestOverInbound(
    String myNodeId,
    String mac, {
    int maxRows = MeshCatchup.pageRows,
  }) async {
    final db = await _ref.read(databaseProvider.future);
    final changeset = await db.getNewestRowsChangeset(maxRows: maxRows);
    await _pushChangesetOverInbound(
      myNodeId,
      mac,
      changeset,
      pushPath: 'urgent_newest',
    );
  }

  /// Pick an inbound GATT client MAC that plausibly belongs to [peerId].
  /// Never blindly use connected.first — stale RPAs cause false-positive pushes.
  String? _resolveInboundMacForPeer(String peerId, List<String> connected) {
    if (connected.isEmpty || peerId.isEmpty) return null;
    for (final m in connected) {
      if (macToNodeId[m] == peerId) return m;
    }
    final candidates = candidateDialMacs(peerId);
    for (final m in connected) {
      if (candidates.contains(m)) return m;
    }
    // 2-node: sole NOTIFY-ready inbound link during mutual-dial (CCCD verified).
    if (currentNeighborIds.length == 1 &&
        currentNeighborIds.contains(peerId) &&
        connected.length == 1) {
      return connected.first;
    }
    return null;
  }

  Future<Map<String, List<String>>> _readInboundServerState({
    bool forceRefresh = false,
  }) async {
    if (_inboundServerStateInitialized && !forceRefresh) {
      return <String, List<String>>{
        'active': _activeInboundServerMacs.toList(growable: false),
        'ready': _notifyReadyInboundServerMacs.toList(growable: false),
      };
    }

    final snapshot = await _nativeMesh.getInboundServerState();
    if (snapshot != null) {
      replaceInboundServerState(
        activeMacs: snapshot['active'] ?? const <String>[],
        readyMacs: snapshot['ready'] ?? const <String>[],
      );
      return <String, List<String>>{
        'active': _activeInboundServerMacs.toList(growable: false),
        'ready': _notifyReadyInboundServerMacs.toList(growable: false),
      };
    }

    // Preserve the previous defensive fallback if the combined snapshot call
    // is unavailable on an older or partially initialized native build.
    final fallback = await Future.wait<List<String>>([
      _nativeMesh.getActiveServerMacs(),
      _nativeMesh.getConnectedServerMacs(),
    ]);
    return <String, List<String>>{'active': fallback[0], 'ready': fallback[1]};
  }

  /// Try NOTIFY push over an inbound link the peer already opened to us.
  Future<bool> _tryInboundUrgentPush(String myNodeId, String peerId) async {
    final probeTimer = Stopwatch()..start();
    final usedNativeSnapshot = !_inboundServerStateInitialized;
    final stateQueryTimer = Stopwatch()..start();
    final state = await _readInboundServerState();
    final readyMacs = state['ready']!;
    final activeMacs = state['active']!;
    final stateQueryUs = stateQueryTimer.elapsedMicroseconds;
    final mac = _resolveInboundMacForPeer(peerId, readyMacs);
    if (mac == null || mac.isEmpty) {
      _traceUrgentFlow(
        'URGENT_INBOUND_LINK_NOT_READY',
        fields: {
          'PEER_NODE_ID': peerId,
          'READY_MACS': readyMacs.join(','),
          'ACTIVE_MACS': activeMacs.join(','),
          'ACTIVE_PEER_MAC': _resolveInboundMacForPeer(peerId, activeMacs),
          'STATE_SOURCE': usedNativeSnapshot
              ? 'native_snapshot'
              : 'event_cache',
          'READY_QUERY_US': usedNativeSnapshot ? stateQueryUs : 0,
          'ACTIVE_QUERY_US': 0,
          'PROBE_TOTAL_US': probeTimer.elapsedMicroseconds,
        },
      );
      return false;
    }
    if (!_inboundPushBusy.add(peerId)) {
      // A real transfer is in flight. Coalesce the write and give newest rows
      // the next turn before resuming ordered gap-fill.
      _inboundUrgentPending.add(peerId);
      _inboundCatchupPending.add(peerId);
      _traceUrgentFlow(
        'URGENT_INBOUND_PUSH_COALESCED',
        fields: {'PEER_NODE_ID': peerId, 'TARGET_MAC': mac},
      );
      return true;
    }

    // Urgent newest-N messages preempt background catch-up pacing. Do not throttle
    // urgent user-visible writes with the 400ms catch-up pacing delay.
    _lastInboundCatchupAt[peerId] = DateTime.now();

    try {
      // Keep the latency path small. Ordered gap-fill runs after this push.
      await _pushNewestOverInbound(myNodeId, mac, maxRows: 8);
      rememberSuccessfulDial(peerId, mac);
      _traceUrgentFlow(
        'URGENT_INBOUND_PUSH_SENT',
        fields: {'PEER_NODE_ID': peerId, 'TARGET_MAC': mac},
      );
      // Newest-N is latency-only — do not credit the vector (that skips holes).
      return true;
    } catch (e) {
      _traceUrgentFlow(
        'URGENT_INBOUND_PUSH_FAILED',
        fields: {
          'PEER_NODE_ID': peerId,
          'TARGET_MAC': mac,
          'ERROR': e.toString(),
        },
      );
      debugPrint('⚠️ [DISCOVERY] Inbound urgent push $peerId@$mac: $e');
      return false;
    } finally {
      _inboundPushBusy.remove(peerId);
      final urgentPending = _inboundUrgentPending.remove(peerId);
      final catchupPending = _inboundCatchupPending.remove(peerId);
      if (urgentPending) {
        unawaited(
          Future<void>.delayed(Duration.zero, () {
            unawaited(_tryInboundUrgentPush(myNodeId, peerId));
          }),
        );
      }
      if (catchupPending) {
        unawaited(
          Future<void>.delayed(const Duration(milliseconds: 120), () {
            unawaited(_tryInboundCatchupPush(myNodeId, peerId));
          }),
        );
      }
    }
  }

  /// Wait for an active inbound link to become safe for NOTIFY or release its
  /// GATT slot so the urgent path can make a real outbound attempt.
  Future<_InboundUrgentWaitResult> _waitForInboundUrgentLinkState(
    String myNodeId,
    String peerId, {
    required Duration timeout,
  }) async {
    final stopwatch = Stopwatch()..start();
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final state = await _readInboundServerState(forceRefresh: true);
      final readyMac = _resolveInboundMacForPeer(peerId, state['ready']!);
      if (readyMac != null && await _tryInboundUrgentPush(myNodeId, peerId)) {
        _traceUrgentFlow(
          'URGENT_INBOUND_LINK_BECAME_READY',
          fields: {
            'PEER_NODE_ID': peerId,
            'TARGET_MAC': readyMac,
            'WAIT_MS': stopwatch.elapsedMilliseconds,
          },
        );
        return _InboundUrgentWaitResult.delivered;
      }

      final activeMac = _resolveInboundMacForPeer(peerId, state['active']!);
      if (activeMac == null) return _InboundUrgentWaitResult.released;
      await Future<void>.delayed(const Duration(milliseconds: 75));
    }
    return _InboundUrgentWaitResult.timedOut;
  }

  /// Catch-up over an existing inbound client using vector/bucket delta
  /// (newest-N cannot heal rows that have fallen out of the sliding window).
  Future<bool> _tryInboundCatchupPush(String myNodeId, String peerId) async {
    final connected = (await _readInboundServerState())['ready']!;
    final mac = _resolveInboundMacForPeer(peerId, connected);
    if (mac == null || mac.isEmpty) return false;
    if (_inboundUrgentPending.contains(peerId) || _urgentSyncDirty) {
      // Urgent live writes take precedence over background catchup streaming.
      _inboundCatchupPending.add(peerId);
      return false;
    }
    if (!_inboundPushBusy.add(peerId)) {
      _inboundCatchupPending.add(peerId);
      return true;
    }

    final last = _lastInboundCatchupAt[peerId];
    if (last != null) {
      final waitMs = 400 - DateTime.now().difference(last).inMilliseconds;
      if (waitMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: waitMs));
      }
    }

    var hasMore = false;
    var retryDelay = const Duration(milliseconds: 120);
    try {
      final db = await _ref.read(databaseProvider.future);
      final prior = Map<String, String>.from(lastKnownPeerVector[peerId] ?? {});
      var fromVector = true;
      final deltaTimer = Stopwatch()..start();
      var changeset = await db.getDeltaChangeset(
        prior,
        maxRows: MeshCatchup.pageRows,
      );
      debugPrint(
        '[BLE_TRACE] EVENT:INBOUND_CATCHUP_STAGE | '
        'STAGE:delta_query | ELAPSED_US:${deltaTimer.elapsedMicroseconds} | '
        'PRIOR_VECTOR_NODES:${prior.length} | '
        'ROWS:${MeshCatchup.rowCount(changeset)} | '
        'WALL_MS:${DateTime.now().millisecondsSinceEpoch}',
      );
      if (changeset.isEmpty) {
        final buckets = lastKnownPeerBuckets[peerId];
        if (buckets != null && buckets.isNotEmpty) {
          final bucketTimer = Stopwatch()..start();
          final peerDeep = DeepCatchup.peer(peerId);
          changeset = await inboundRepairPage(
            db,
            buckets,
            peerId: peerId,
            remoteDeepBuckets:
                peerDeep != null &&
                    peerDeep.hasBuckets &&
                    DeepCatchup.differs(db.freshDeepDigest, peerDeep)
                ? peerDeep.buckets
                : null,
          );
          fromVector = false;
          debugPrint(
            '[BLE_TRACE] EVENT:INBOUND_CATCHUP_STAGE | '
            'STAGE:bucket_query | ELAPSED_US:${bucketTimer.elapsedMicroseconds} | '
            'ROWS:${MeshCatchup.rowCount(changeset)} | '
            'WALL_MS:${DateTime.now().millisecondsSinceEpoch}',
          );
        }
      }
      if (changeset.isEmpty) {
        _lastInboundCatchupAt[peerId] = DateTime.now();
        return true;
      }
      final pageTimer = Stopwatch()..start();
      final page = fromVector
          ? MeshCatchup.takeOldest(changeset, maxRows: MeshCatchup.pageRows)
          : truncateChangesetForBle(
              changeset,
              maxRowsPerTable: MeshCatchup.pageRows,
            );
      debugPrint(
        '[BLE_TRACE] EVENT:INBOUND_CATCHUP_STAGE | '
        'STAGE:page_select | ELAPSED_US:${pageTimer.elapsedMicroseconds} | '
        'SOURCE_ROWS:${MeshCatchup.rowCount(changeset)} | '
        'PAGE_ROWS:${MeshCatchup.rowCount(page)} | '
        'FROM_VECTOR:$fromVector | '
        'WALL_MS:${DateTime.now().millisecondsSinceEpoch}',
      );
      if (!fromVector) {
        // Give the peer time to refresh its fingerprints between repair pages.
        retryDelay = const Duration(seconds: 3);
      }
      _lastInboundCatchupAt[peerId] = DateTime.now();
      if (!CatchupPushBudget.shared.tryUse(peerId)) {
        // These pages are aimed by fingerprints the peer sent a while ago and
        // may be well out of date. Stop until it reports again; its request
        // for fresh ones may be waiting for this link to go quiet.
        debugPrint(
          '[BLE_TRACE] EVENT:INBOUND_CATCHUP_BUDGET_SPENT | '
          'PEER_NODE_ID:$peerId | '
          'WALL_MS:${DateTime.now().millisecondsSinceEpoch}',
        );
        return true;
      }
      final shouldYieldBurst = CatchupPushBudget.shared.shouldYieldBurst(
        peerId,
      );
      if (shouldYieldBurst) {
        CatchupPushBudget.shared.resetBurst(peerId);
        // Pause between bursts so peer can respond, exchange fresh fingerprints,
        // and allow other mesh nodes to connect or discover each other.
        retryDelay = const Duration(milliseconds: 1500);
        debugPrint(
          '[BLE_TRACE] EVENT:INBOUND_CATCHUP_BURST_YIELD | '
          'PEER_NODE_ID:$peerId | '
          'WALL_MS:${DateTime.now().millisecondsSinceEpoch}',
        );
      }
      await _pushChangesetOverInbound(
        myNodeId,
        mac,
        page,
        pushPath: fromVector ? 'catchup_vector' : 'catchup_bucket',
      );
      if (fromVector) {
        final nextVector = MeshCatchup.mergeVectorFromChangeset(prior, page);
        final advancedNodes = nextVector.entries.where((entry) {
          final old = prior[entry.key];
          return old == null || entry.value.compareTo(old) > 0;
        }).length;
        debugPrint(
          '[BLE_TRACE] EVENT:INBOUND_CATCHUP_PAGE | '
          'PEER_NODE_ID:$peerId | PRIOR_VECTOR_NODES:${prior.length} | '
          'NEXT_VECTOR_NODES:${nextVector.length} | '
          'ADVANCED_NODES:$advancedNodes | PAGE_ROWS:${MeshCatchup.rowCount(page)} | '
          'WALL_MS:${DateTime.now().millisecondsSinceEpoch}',
        );
        rememberPeerVector(peerId, nextVector);
      }
      rememberSuccessfulDial(peerId, mac);
      hasMore = MeshCatchup.rowCount(changeset) > MeshCatchup.pageRows;
      return true;
    } catch (e) {
      debugPrint('⚠️ [DISCOVERY] Inbound catch-up $peerId: $e');
      return false;
    } finally {
      _inboundPushBusy.remove(peerId);
      final pending = _inboundCatchupPending.remove(peerId);
      final urgentPending = _inboundUrgentPending.remove(peerId);
      if (urgentPending) {
        unawaited(
          Future<void>.delayed(Duration.zero, () {
            unawaited(_tryInboundUrgentPush(myNodeId, peerId));
          }),
        );
      }
      // If an urgent write is pending, yield: _tryInboundUrgentPush will resume catchup in its own finally.
      if ((hasMore || pending) && !urgentPending) {
        unawaited(
          Future<void>.delayed(retryDelay, () {
            unawaited(_tryInboundCatchupPush(myNodeId, peerId));
          }),
        );
      }
    }
  }

  /// Wait briefly for a mutual-dial inbound link, then NOTIFY-push.
  Future<bool> _waitForInboundUrgentPush(
    String myNodeId,
    String peerId, {
    Duration timeout = const Duration(milliseconds: 1500),
  }) async {
    final stopwatch = Stopwatch()..start();
    while (stopwatch.elapsed < timeout) {
      // Subscribe to the next native link-state event before checking the cache
      // to avoid missing a connect/ready event between the check and the wait.
      final changed = _inboundServerStateChanged ??= Completer<void>();
      if (await _tryInboundUrgentPush(myNodeId, peerId)) return true;
      final remaining = timeout - stopwatch.elapsed;
      if (remaining <= Duration.zero) break;
      await changed.future.timeout(remaining, onTimeout: () {});
    }
    return _tryInboundUrgentPush(myNodeId, peerId);
  }

  bool _isTransientUrgentDialFailure(Object error) {
    if (error is TimeoutException) return true;
    if (error is! PlatformException) return false;
    return const {
      'DISCONNECTED',
      'CCCD_FAILED',
      'timeout',
      'gatt_busy',
      'already_connected',
      'no_server',
    }.contains(error.code);
  }

  /// Prefer an existing inbound link; otherwise the elected peer dials and
  /// quickly retries one transient GATT failure with the latest scan address.
  Future<bool> _urgentDeliverPeer(
    String myNodeId,
    String peerId, {
    Duration maxBudget = const Duration(milliseconds: 7000),
  }) async {
    final stopwatch = Stopwatch()..start();
    var totalCap = maxBudget;

    Duration remaining() {
      final left = totalCap - stopwatch.elapsed;
      return left.isNegative ? Duration.zero : left;
    }

    final previousTarget = _urgentTargetPeer;
    final previousCompleter = _urgentInboundCompleter;
    final inboundDelivered = Completer<bool>();
    _urgentTargetPeer = peerId;
    _urgentInboundCompleter = inboundDelivered;
    try {
      final inboundProbe = _tryInboundUrgentPush(myNodeId, peerId);
      // Resolve reusable outbound-link state while the inbound check runs.
      // The event cache avoids a per-message MethodChannel query after startup.
      final heldClientStateWasCached = _heldClientStateInitialized;
      final heldClientLookupTimer = Stopwatch()..start();
      final heldClientLookup = _readReusableHeldClientMac().catchError(
        (Object _) => null,
      );
      if (await inboundProbe) return true;

      final electedToInitiate = _shouldInitiateUrgentPeer(myNodeId, peerId);
      final heldClientAddress = await heldClientLookup;
      _traceUrgentFlow(
        'URGENT_HELD_CLIENT_LOOKUP_COMPLETE',
        fields: {
          'PEER_NODE_ID': peerId,
          'ELAPSED_US': heldClientLookupTimer.elapsedMicroseconds,
          'FOUND': heldClientAddress != null,
          'STATE_SOURCE': heldClientStateWasCached
              ? 'event_cache'
              : 'native_snapshot',
        },
      );
      String? reusableHeldMac;
      if (heldClientAddress != null) {
        for (final candidate in candidateDialMacs(peerId)) {
          if (candidate.toUpperCase() == heldClientAddress.toUpperCase()) {
            reusableHeldMac = candidate;
            break;
          }
        }
      }
      if (!electedToInitiate) {
        if (reusableHeldMac != null) {
          _traceUrgentFlow(
            'URGENT_REUSING_HELD_OUTBOUND',
            fields: {'PEER_NODE_ID': peerId, 'TARGET_MAC': reusableHeldMac},
          );
        } else {
          final activeMac = _resolveInboundMacForPeer(
            peerId,
            (await _readInboundServerState())['active']!,
          );
          if (activeMac != null) {
            final wait = remaining();
            final inboundWait = wait < const Duration(seconds: 4)
                ? wait
                : const Duration(seconds: 4);
            final linkState = inboundWait > Duration.zero
                ? await _waitForInboundUrgentLinkState(
                    myNodeId,
                    peerId,
                    timeout: inboundWait,
                  )
                : _InboundUrgentWaitResult.timedOut;
            if (linkState == _InboundUrgentWaitResult.delivered) return true;
            if (linkState != _InboundUrgentWaitResult.released) return false;
            _traceUrgentFlow(
              'URGENT_INBOUND_RELEASED_FALLBACK_DIAL',
              fields: {
                'PEER_NODE_ID': peerId,
                'TARGET_MAC': activeMac,
                'WAIT_MS': inboundWait.inMilliseconds,
              },
            );
            if (_prefersRemoteExtendedInitiator(peerId)) {
              final wait = remaining();
              _traceUrgentFlow(
                'URGENT_REMOTE_ELECTED_WAIT',
                fields: {
                  'PEER_NODE_ID': peerId,
                  'REMOTE_EXTENDED_CONNECTABLE': true,
                  'WAIT_MS': wait.inMilliseconds,
                },
              );
              return wait > Duration.zero &&
                  await _waitForInboundUrgentPush(
                    myNodeId,
                    peerId,
                    timeout: wait,
                  );
            }
          } else {
            final wait = remaining();
            return wait > Duration.zero &&
                await _waitForInboundUrgentPush(
                  myNodeId,
                  peerId,
                  timeout: wait,
                );
          }
        }
      }

      // Wait briefly only when a live inbound link can become notify-ready.
      // The elected peer owns the cold dial when no inbound connection exists.
      if (reusableHeldMac == null) {
        final activeInboundMac = _resolveInboundMacForPeer(
          peerId,
          (await _readInboundServerState())['active']!,
        );
        if (activeInboundMac == null) {
          _traceUrgentFlow(
            'URGENT_INBOUND_GRACE_SKIPPED',
            fields: {
              'PEER_NODE_ID': peerId,
              'REASON': 'no_active_inbound_link',
            },
          );
        } else {
          final initialWait = remaining();
          final inboundGrace = electedToInitiate
              ? const Duration(milliseconds: 100)
              : const Duration(milliseconds: 250);
          if (initialWait > Duration.zero) {
            final graceTimeout = initialWait < inboundGrace
                ? initialWait
                : inboundGrace;
            final graceTimer = Stopwatch()..start();
            final deliveredDuringGrace = await _waitForInboundUrgentPush(
              myNodeId,
              peerId,
              timeout: graceTimeout,
            );
            _traceUrgentFlow(
              'URGENT_INBOUND_GRACE_COMPLETE',
              fields: {
                'PEER_NODE_ID': peerId,
                'TARGET_MAC': activeInboundMac,
                'BUDGET_MS': graceTimeout.inMilliseconds,
                'ELAPSED_US': graceTimer.elapsedMicroseconds,
                'DELIVERED': deliveredDuringGrace,
              },
            );
            if (deliveredDuringGrace) return true;
          }
        }
      } else {
        _traceUrgentFlow(
          'URGENT_HELD_LINK_INBOUND_GRACE_SKIPPED',
          fields: {
            'PEER_NODE_ID': peerId,
            'TARGET_MAC': reusableHeldMac,
            'REASON': 'reusable_outbound_link',
          },
        );
      }

      var selectedMac = reusableHeldMac ?? scanFreshDialMac(peerId);
      if (selectedMac == null) {
        final wait = remaining();
        if (wait <= Duration.zero) return false;
        final freshWait = Stopwatch()..start();
        _traceUrgentFlow(
          'URGENT_WAITING_FOR_FRESH_DIAL_MAC',
          fields: {
            'PEER_NODE_ID': peerId,
            'REASON': 'address_expired_during_inbound_grace',
            'RETRY_IN_MS': 75,
          },
        );
        while (freshWait.elapsed < wait) {
          if (inboundDelivered.isCompleted) {
            return await inboundDelivered.future;
          }
          final now = DateTime.now();
          final freshMac = scanFreshDialMac(peerId, now: now);
          final deadUntil = freshMac == null ? null : deadMacUntil[freshMac];
          if (freshMac != null &&
              (deadUntil == null || !now.isBefore(deadUntil))) {
            selectedMac = freshMac;
            _traceUrgentFlow(
              'URGENT_FRESH_DIAL_MAC_READY',
              fields: {
                'PEER_NODE_ID': peerId,
                'TARGET_MAC': freshMac,
                'WAIT_MS': freshWait.elapsedMilliseconds,
              },
            );
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 75));
        }
        if (selectedMac == null) {
          _traceUrgentFlow(
            'URGENT_FRESH_DIAL_MAC_TIMEOUT',
            fields: {
              'PEER_NODE_ID': peerId,
              'WAIT_MS': freshWait.elapsedMilliseconds,
            },
          );
          return false;
        }
      }

      for (var attempt = 0; attempt < 2; attempt++) {
        if (await _tryInboundUrgentPush(myNodeId, peerId)) return true;

        final attemptMac = selectedMac;
        if (attemptMac == null) return false;
        final candidates = candidateDialMacs(peerId);
        _traceUrgentDialSelection(peerId, candidates, attemptMac);
        final scanSeenAtBeforeAttempt = nodeIdMacSeenAt[peerId];
        final budgetLeft = remaining();
        if (budgetLeft <= Duration.zero) return false;
        final attemptBudget = budgetLeft < const Duration(milliseconds: 7000)
            ? budgetLeft
            : const Duration(milliseconds: 7000);

        try {
          final device = attemptMac;
          final coolKey = 0x200000000 | (peerId.hashCode & 0xffffffff);
          _traceUrgentFlow(
            'URGENT_FORCE_DIAL_STARTED',
            fields: {
              'PEER_NODE_ID': peerId,
              'TARGET_MAC': attemptMac,
              'TRY': attempt + 1,
            },
          );
          await _runMeshInitiatorHandshake(
            myNodeId,
            coolKey,
            device,
            peerNodeId: peerId,
            peerKeyHint: peerId,
            remoteHashTrusted: false,
            forceNewestPush: true,
          ).timeout(attemptBudget);
          _traceUrgentFlow(
            'URGENT_FORCE_DIAL_COMPLETED',
            fields: {
              'PEER_NODE_ID': peerId,
              'TARGET_MAC': attemptMac,
              'TRY': attempt + 1,
            },
          );
          return true;
        } catch (e) {
          _traceUrgentFlow(
            'URGENT_FORCE_DIAL_FAILED',
            fields: {
              'PEER_NODE_ID': peerId,
              'TARGET_MAC': attemptMac,
              'TRY': attempt + 1,
              'ERROR': e.toString(),
            },
          );
          if (inboundDelivered.isCompleted) {
            return await inboundDelivered.future;
          }
          if (e is _UrgentInboundLinkStillActive) {
            final wait = remaining();
            if (wait <= Duration.zero) return false;
            final linkState = await _waitForInboundUrgentLinkState(
              myNodeId,
              peerId,
              timeout: wait,
            );
            if (linkState == _InboundUrgentWaitResult.delivered) return true;
            if (linkState == _InboundUrgentWaitResult.released &&
                attempt == 0 &&
                remaining() > const Duration(milliseconds: 500)) {
              continue;
            }
            return false;
          }
          debugPrint(
            '⚠️ [DISCOVERY] Urgent sync try $peerId@$attemptMac failed: $e',
          );
          lastGoodDialMac.remove(peerId);
          if (e is TimeoutException) await _nativeMesh.cancelOutbound();

          final heldLinkFailed =
              e is PlatformException && e.code == 'held_link_stale';
          final transientDialFailure = _isTransientUrgentDialFailure(e);
          if (heldLinkFailed && attempt == 0) {
            const retryReserve = Duration(milliseconds: 3000);
            totalCap += retryReserve;
            _traceUrgentFlow(
              'URGENT_HELD_LINK_RETRY_BUDGET_EXTENDED',
              fields: {
                'PEER_NODE_ID': peerId,
                'RESERVE_MS': retryReserve.inMilliseconds,
              },
            );
          }

          if (attempt == 0) {
            final wait = remaining();
            final refreshBudget = wait < const Duration(milliseconds: 1200)
                ? wait
                : const Duration(milliseconds: 1200);
            if (heldLinkFailed) {
              final refreshed = await _waitForFreshScanRetryDialMac(
                peerId,
                attemptMac,
                scanSeenAtBeforeAttempt: scanSeenAtBeforeAttempt,
                timeout: refreshBudget,
              );
              if (refreshed != null) {
                _traceUrgentFlow(
                  'URGENT_HELD_LINK_FRESH_RETRY_TARGET',
                  fields: {
                    'PEER_NODE_ID': peerId,
                    'FAILED_MAC': attemptMac,
                    'TARGET_MAC': refreshed,
                  },
                );
                selectedMac = refreshed;
                continue;
              }
            } else if (transientDialFailure) {
              // A DISCONNECTED/CCCD failure is usually a short-lived Android
              // GATT race. Waiting the rest of the urgent budget for an
              // alternate RPA delayed the next attempt by 5–7 seconds even
              // when the current scan address was still fresh. Let Android
              // finish closing the failed GATT, then retry once against the
              // latest scan result (which may be the same still-valid RPA).
              const retryPause = Duration(milliseconds: 250);
              if (remaining() >
                  retryPause + const Duration(milliseconds: 500)) {
                await Future<void>.delayed(retryPause);
                if (inboundDelivered.isCompleted) {
                  return await inboundDelivered.future;
                }
                final retryMac = scanFreshDialMac(peerId);
                if (retryMac != null) {
                  selectedMac = retryMac;
                  _traceUrgentFlow(
                    'URGENT_TRANSIENT_FAST_RETRY',
                    fields: {
                      'PEER_NODE_ID': peerId,
                      'FAILED_MAC': attemptMac,
                      'TARGET_MAC': retryMac,
                      'SAME_MAC': retryMac == attemptMac,
                      'ERROR': e.toString(),
                    },
                  );
                  continue;
                }
              }
            }
          }

          final tail = remaining();
          final inboundGrace =
              (heldLinkFailed || transientDialFailure) &&
                  tail > const Duration(milliseconds: 500)
              ? const Duration(milliseconds: 500)
              : tail;
          if (inboundGrace != tail) {
            _traceUrgentFlow(
              'URGENT_TRANSIENT_FAILURE_YIELD',
              fields: {
                'PEER_NODE_ID': peerId,
                'ATTEMPT': attempt + 1,
                'ERROR': e.toString(),
                'INBOUND_GRACE_MS': inboundGrace.inMilliseconds,
                'BUDGET_REMAINING_MS': tail.inMilliseconds,
              },
            );
          }
          return inboundGrace > Duration.zero &&
              await _waitForInboundUrgentPush(
                myNodeId,
                peerId,
                timeout: inboundGrace,
              );
        }
      }
      return false;
    } finally {
      _urgentInboundCompleter = previousCompleter;
      _urgentTargetPeer = previousTarget;
    }
  }

  Future<String?> _waitForFreshScanRetryDialMac(
    String peerId,
    String failedMac, {
    required DateTime? scanSeenAtBeforeAttempt,
    required Duration timeout,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final now = DateTime.now();
      final candidate = scanFreshDialMac(peerId, now: now);
      final retryTarget = MeshDialPolicy.freshHeldLinkRetryTarget(
        failedMac: failedMac,
        scannedMac: candidate,
        scanSeenAt: nodeIdMacSeenAt[peerId],
        scanSeenAtBeforeAttempt: scanSeenAtBeforeAttempt,
      );
      if (retryTarget != null) {
        final deadUntil = deadMacUntil[retryTarget];
        if (deadUntil == null || !now.isBefore(deadUntil)) return retryTarget;
      }
      await Future<void>.delayed(const Duration(milliseconds: 75));
    }
    return null;
  }

  /// Last-resort outbound dial after the urgent pipeline exhausts.
  Future<bool> _urgentScanFallbackDial(String myNodeId, String peerId) async {
    if (!_shouldInitiateUrgentPeer(myNodeId, peerId)) {
      return false;
    }
    final mac = scanFreshDialMac(peerId);
    if (mac == null || mac.isEmpty) return false;
    deadMacUntil.remove(mac);
    try {
      final device = mac;
      final coolKey = 0x200000000 | (peerId.hashCode & 0xffffffff);
      await _runMeshInitiatorHandshake(
        myNodeId,
        coolKey,
        device,
        peerNodeId: peerId,
        peerKeyHint: peerId,
        remoteHashTrusted: false,
        forceNewestPush: true,
      ).timeout(const Duration(milliseconds: 4000));
      return true;
    } catch (e) {
      debugPrint('⚠️ [DISCOVERY] Urgent fallback dial $peerId@$mac: $e');
      if (e is TimeoutException) await _nativeMesh.cancelOutbound();
      return false;
    }
  }

  Future<void> _runUrgentSync(String myNodeId) async {
    if (_urgentSyncRunning) {
      _urgentSyncDirty = true;
      _traceUrgentFlow('URGENT_SYNC_ALREADY_RUNNING', fields: {'DIRTY': true});
      return;
    }
    _urgentSyncRunning = true;
    _urgentMyNodeId = myNodeId;
    _urgentRadioHoldUntil = DateTime.now().add(const Duration(seconds: 8));
    _traceUrgentFlow(
      'URGENT_SYNC_STARTED',
      fields: {
        'PEER_COUNT': currentNeighborIds.length,
        'QUEUE_LENGTH': _pendingQueue.length,
      },
    );
    final urgentSw = Stopwatch()..start();
    const urgentBudget = Duration(milliseconds: 7500);
    try {
      do {
        // Keep late coalesced writes for a fresh urgent window. Starting a
        // second dial with only a few hundred milliseconds left made the
        // active run report success for its older payload, then silently drop
        // the newer row when its total budget expired.
        if (_urgentSyncDirty &&
            urgentSw.elapsed >=
                urgentBudget - const Duration(milliseconds: 2500)) {
          _traceUrgentFlow(
            'URGENT_SYNC_DEFERRED_FOR_FRESH_BUDGET',
            fields: {
              'ELAPSED_MS': urgentSw.elapsedMilliseconds,
              'REMAINING_MS': (urgentBudget - urgentSw.elapsed).inMilliseconds,
            },
          );
          break;
        }
        _urgentSyncDirty = false;
        // A relayed message is not sent back to its source, including when
        // this loop runs again for it. Exclusions belonging to an older
        // message are dropped, so a newer local write still reaches everyone.
        final currentMessage = _urgentMessageId ?? '';
        _urgentExcludedPeerIds.removeWhere((_, id) => id != currentMessage);
        final excludedPeerIds = Set<String>.from(_urgentExcludedPeerIds.keys);
        final peerSelectionTimer = Stopwatch()..start();
        // Only dial scan-fresh RPAs. Stale GATT/bind MACs routinely 4s-timeout and
        // burn the only outbound slot (seen: P9→Clear miss while Red also times out).
        final now = DateTime.now();
        final peerIds = <String>{...currentNeighborIds, ...nodeIdToMac.keys};
        peerIds.remove(myNodeId);
        peerIds.removeAll(excludedPeerIds);

        bool macUsable(String id) {
          final liveNeighbor = currentNeighborIds.contains(id);
          final mac = scanFreshDialMac(id, now: now);
          if (mac == null) return false;
          if (isPeerRecentlyBusy(id, now: now)) {
            _traceUrgentFlow(
              'URGENT_PEER_SKIPPED_BUSY',
              fields: {
                'PEER_NODE_ID': id,
                'BUSY_AGE_MS': peerBusyAgeMs(id, now: now),
                'BUSY_FRESHNESS_MS': peerBusyFreshnessWindow.inMilliseconds,
              },
            );
            return false;
          }
          final dead = deadMacUntil[mac];
          return liveNeighbor || dead == null || now.isAfter(dead);
        }

        final freshKnownPeers = peerIds.where(macUsable).toList();
        // Usually only the elected side opens a connection. A peer with an
        // already-open held client link is the exception: it can safely carry
        // urgent data without creating a crossed GATT attempt, even when the
        // other node owns the next cold dial. The delivery path checks the
        // held link itself, so avoid a duplicate MethodChannel query when all
        // fresh peers are elected to this device.
        final hasNonElectedFreshPeer = freshKnownPeers.any(
          (id) => !_shouldInitiateUrgentPeer(myNodeId, id),
        );
        // Check a held client link when scan freshness alone would leave us
        // without a route. An active GATT link is still addressable after the
        // advertiser's RPA ages out of the scan cache.
        final checkHeldClient =
            hasNonElectedFreshPeer || freshKnownPeers.isEmpty;
        final heldClientMac = checkHeldClient
            ? await _readReusableHeldClientMac()
            : null;
        String? heldClientPeer;
        if (heldClientMac != null) {
          for (final id in peerIds) {
            if (candidateDialMacs(id).any(
              (candidate) =>
                  candidate.toUpperCase() == heldClientMac.toUpperCase(),
            )) {
              heldClientPeer = id;
              break;
            }
          }
        }
        final freshPeers = MeshDialPolicy.urgentCandidates(
          localNodeId: myNodeId,
          freshPeerIds: freshKnownPeers,
          heldClientPeerId: heldClientPeer,
          shouldInitiatePeer: (id) => _shouldInitiateUrgentPeer(myNodeId, id),
        );
        if (heldClientPeer != null &&
            freshPeers.isNotEmpty &&
            !freshPeers.contains(heldClientPeer)) {
          unawaited(_nativeMesh.releaseHeldClient('urgent_switch'));
        }
        final heldPeerIsNonElected =
            heldClientPeer != null &&
            !_shouldInitiateUrgentPeer(myNodeId, heldClientPeer);
        if (heldClientPeer != null &&
            (heldPeerIsNonElected ||
                !freshKnownPeers.contains(heldClientPeer))) {
          _traceUrgentFlow(
            'URGENT_HELD_LINK_PEER_SELECTED',
            fields: {
              'PEER_NODE_ID': heldClientPeer,
              'TARGET_MAC': heldClientMac,
              'SCAN_FRESH': freshKnownPeers.contains(heldClientPeer),
            },
          );
        }
        for (final peerId in freshKnownPeers) {
          if (!freshPeers.contains(peerId)) {
            // The elected peer owns the outbound. If its GATT client is already
            // connected to us, push the newest rows first for message latency;
            // ordered anti-entropy follows without opening a crossed dial.
            final urgentPushTimer = Stopwatch()..start();
            final urgentPushHandled = await _tryInboundUrgentPush(
              myNodeId,
              peerId,
            );
            _traceUrgentFlow(
              'URGENT_NON_ELECTED_PUSH_STAGE',
              fields: {
                'PEER_NODE_ID': peerId,
                'HANDLED': urgentPushHandled,
                'ELAPSED_US': urgentPushTimer.elapsedMicroseconds,
              },
            );
            unawaited(_tryInboundCatchupPush(myNodeId, peerId));
          }
        }
        if (freshPeers.isEmpty && freshKnownPeers.isEmpty) {
          // A stale scan RPA blocks a new outbound dial, but it must not block
          // a reply over an already-ready inbound GATT link. Try the small
          // newest-row push first; ordered catch-up may be in fingerprint
          // repair mode and defer its next page for several seconds.
          for (final peerId in currentNeighborIds) {
            if (peerId == myNodeId || excludedPeerIds.contains(peerId)) {
              continue;
            }
            final inboundUrgentTimer = Stopwatch()..start();
            final urgentPushHandled = await _tryInboundUrgentPush(
              myNodeId,
              peerId,
            );
            _traceUrgentFlow(
              'URGENT_INBOUND_PUSH_WITHOUT_FRESH_SCAN',
              fields: {
                'PEER_NODE_ID': peerId,
                'HANDLED': urgentPushHandled,
                'ELAPSED_US': inboundUrgentTimer.elapsedMicroseconds,
              },
            );
            if (urgentPushHandled) {
              unawaited(_tryInboundCatchupPush(myNodeId, peerId));
              // Another peer may still need this row. In a three-node mesh,
              // returning here can discard the only retry for a busy peer.
              continue;
            }

            final inboundCatchupTimer = Stopwatch()..start();
            if (await _tryInboundCatchupPush(myNodeId, peerId)) {
              _traceUrgentFlow(
                'URGENT_INBOUND_CATCHUP_WITHOUT_FRESH_SCAN',
                fields: {
                  'PEER_NODE_ID': peerId,
                  'ELAPSED_US': inboundCatchupTimer.elapsedMicroseconds,
                },
              );
              continue;
            }
          }
        }
        if (freshPeers.isEmpty) {
          final recentlyBusyPeers = peerIds
              .where((id) => isPeerRecentlyBusy(id, now: now))
              .toList(growable: false);
          if (freshKnownPeers.isEmpty && recentlyBusyPeers.isNotEmpty) {
            _traceUrgentFlow(
              'URGENT_WAITING_FOR_BUSY_PEER',
              fields: {
                'PEER_NODE_IDS': recentlyBusyPeers.join(','),
                'RETRY_IN_MS': 600,
              },
            );
            _urgentSyncDebounce?.cancel();
            _urgentSyncDebounce = Timer(const Duration(milliseconds: 600), () {
              unawaited(_runUrgentSync(myNodeId));
            });
            return;
          }
          _traceUrgentFlow(
            'URGENT_SYNC_STAGE',
            fields: {
              'STAGE': 'peer_selection',
              'ELAPSED_US': peerSelectionTimer.elapsedMicroseconds,
              'PEER_COUNT': 0,
            },
          );
          if (freshKnownPeers.isNotEmpty) {
            debugPrint(
              '🚀 [DISCOVERY] Urgent sync waiting for elected peer '
              '(known=${freshKnownPeers.length})',
            );
            debugPrint('URGENT_SYNC peers= waiting-for-elected-peer');
            for (final peerId in freshKnownPeers) {
              if (_isLegacyFallbackCandidate(myNodeId, peerId)) {
                _scheduleLegacyInitiatorFallback(myNodeId, peerId);
              }
            }
            return;
          }
          debugPrint(
            '🚀 [DISCOVERY] Urgent sync: no dial MACs '
            '(known=${peerIds.length}) — nudging scanner',
          );
          debugPrint('URGENT_SYNC peers= none fresh=0/${peerIds.length}');
          final live = currentNeighborIds;
          if (live.isNotEmpty) {
            // A stale dial address does not mean the scanner itself is stalled.
            // The normal scan stream may be healthy while an advertiser rotates
            // its RPA; treating this as a scanner failure schedules needless
            // stop/start cycles and can delay learning the new address further.
            final now = DateTime.now();
            final peerId = live.first;
            final lastScanAt = nodeIdMacSeenAt[peerId];
            final scanQuietMs = _lastResultAt == null
                ? -1
                : now.difference(_lastResultAt!).inMilliseconds;
            _traceUrgentFlow(
              'URGENT_WAITING_FOR_FRESH_DIAL_MAC',
              fields: {
                'PEER_NODE_ID': peerId,
                'LIVE_PEER_COUNT': live.length,
                'KNOWN_PEER_COUNT': peerIds.length,
                'LAST_SCAN_MAC': nodeIdToMac[peerId] ?? 'unknown',
                'LAST_SCAN_AGE_MS': lastScanAt == null
                    ? -1
                    : now.difference(lastScanAt).inMilliseconds,
                'SCAN_QUIET_MS': scanQuietMs,
                'RETRY_IN_MS': 600,
              },
            );
            _urgentSyncDebounce?.cancel();
            _urgentSyncDebounce = Timer(const Duration(milliseconds: 600), () {
              unawaited(_runUrgentSync(myNodeId));
            });
          }
          return;
        }
        // Prefer peers we know are behind; ignore caught-up ones while any remain.
        final behindPeers = freshPeers
            .where(isPeerKnownBehind)
            .toList(growable: false);
        final focusPeers = behindPeers.isNotEmpty ? behindPeers : freshPeers;
        focusPeers.sort((a, b) {
          final ua = _lastUrgentAttemptAt[a];
          final ub = _lastUrgentAttemptAt[b];
          if (ua == null && ub != null) return -1;
          if (ua != null && ub == null) return 1;
          if (ua != null && ub != null) {
            final urgentOrder = ua.compareTo(ub);
            if (urgentOrder != 0) return urgentOrder;
          }
          final ta = lastFullSync[a];
          final tb = lastFullSync[b];
          if (ta == null && tb == null) return a.compareTo(b);
          if (ta == null) return -1;
          if (tb == null) return 1;
          return ta.compareTo(tb);
        });
        final live = focusPeers.where(currentNeighborIds.contains).toList();
        final pool = (live.isNotEmpty ? live : focusPeers).take(2).toList();
        _traceUrgentFlow(
          'URGENT_SYNC_STAGE',
          fields: {
            'STAGE': 'peer_selection',
            'ELAPSED_US': peerSelectionTimer.elapsedMicroseconds,
            'PEER_COUNT': pool.length,
          },
        );
        debugPrint(
          '🚀 [DISCOVERY] Urgent sync → ${pool.length} peer(s) '
          '(behind=${behindPeers.length} fresh=${freshPeers.length}/${peerIds.length})',
        );
        debugPrint(
          'URGENT_SYNC peers=${pool.join(",")} behind=${behindPeers.length} '
          'fresh=${freshPeers.length}/${peerIds.length}',
        );

        // Drop non-urgent queued dials so push-on-write isn't stuck behind fat offers.
        final dropped = _pendingQueue.where((e) => !e.forceNewest).toList();
        for (final e in dropped) {
          if (!e.done.isCompleted) e.done.complete();
        }
        _pendingQueue.removeWhere((e) => !e.forceNewest);

        for (final pick in pool) {
          if (urgentSw.elapsed >= urgentBudget) break;
          _lastUrgentAttemptAt[pick] = DateTime.now();
          lastFullSync.remove(pick);
          localSeenNodes[pick] = DateTime.now();
          final freshMac = scanFreshDialMac(pick);
          if (freshMac != null) deadMacUntil.remove(freshMac);
          for (final e in hashToNodeId.entries) {
            if (e.value == pick) _hashCooldowns.remove(e.key);
          }

          var dialed = await _urgentDeliverPeer(
            myNodeId,
            pick,
            maxBudget: urgentBudget - urgentSw.elapsed,
          );
          if (!dialed && onUrgentGattRecovery != null) {
            final left = urgentBudget - urgentSw.elapsed;
            // resetServer mid-probe drops the inbound that was about to save us.
            if (left > const Duration(milliseconds: 2500)) {
              debugPrint(
                '🔄 [DISCOVERY] Urgent failed on $pick — GATT recovery',
              );
              try {
                await onUrgentGattRecovery!();
                await Future<void>.delayed(const Duration(milliseconds: 300));
                final retry = urgentBudget - urgentSw.elapsed;
                if (retry > const Duration(milliseconds: 900)) {
                  dialed = await _urgentDeliverPeer(
                    myNodeId,
                    pick,
                    maxBudget: retry,
                  );
                }
              } catch (e) {
                debugPrint('⚠️ [DISCOVERY] GATT recovery failed: $e');
              }
            }
          }
          if (!dialed) {
            final left = urgentBudget - urgentSw.elapsed;
            if (left > const Duration(milliseconds: 4000)) {
              dialed = await _urgentScanFallbackDial(myNodeId, pick);
            }
          }
          if (!dialed) {
            debugPrint('⚠️ [DISCOVERY] Urgent sync gave up on $pick');
          }
          if (_urgentLegacyDialFallbacks.remove(pick)) {
            _traceUrgentFlow(
              'URGENT_LEGACY_DIAL_FALLBACK_CONSUMED',
              fields: {'PEER_NODE_ID': pick, 'DELIVERED_OR_QUEUED': dialed},
            );
          }
          _traceUrgentFlow(
            'URGENT_PEER_DELIVERY_RESULT',
            fields: {'PEER_NODE_ID': pick, 'DELIVERED_OR_QUEUED': dialed},
          );
        }
      } while (_urgentSyncDirty && urgentSw.elapsed < urgentBudget);
    } finally {
      _traceUrgentFlow(
        'URGENT_SYNC_FINISHED',
        fields: {
          'ELAPSED_MS': urgentSw.elapsedMilliseconds,
          'DIRTY': _urgentSyncDirty,
          'QUEUE_LENGTH': _pendingQueue.length,
        },
      );
      _urgentSyncRunning = false;
      _urgentMyNodeId = null;
      _urgentTargetPeer = null;
      _urgentInboundCompleter = null;
      _urgentRadioHoldUntil = null;
      _drainPendingQueue(myNodeId);
      if (_urgentSyncDirty) {
        // Brief yield so scan-path can use the held link between burst pushes.
        unawaited(
          Future<void>.delayed(const Duration(milliseconds: 200), () {
            if (!_urgentSyncRunning) {
              unawaited(_runUrgentSync(myNodeId));
            }
          }),
        );
      } else {
        _urgentMessageId = null;
        _urgentExcludedPeerIds.clear();
      }
    }
  }

  Future<void> stopScanning() async {
    await _scanSub?.cancel();
    _scanSub = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    await NativeBleRadio.instance.stopScan();
  }

  Future<void> stopAll() async {
    await stopScanning();
  }
}
