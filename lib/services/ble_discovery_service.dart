import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../constants/ble_constants.dart';
import '../providers/database_provider.dart';
import 'mesh_catchup.dart';
import 'native_mesh_service.dart';
import 'native_mesh_urgent.dart';

/// Byte budget in the ADV payload: we only send a fixed 8-char "Short Node ID".
const int meshShortNodeIdLength = 8;

/// Mesh discovery: central scanning via [FlutterBluePlus]; GAP advertise lives in [BleGattServer].
class BleDiscoveryService {
  /// Advertised DB hash (uint32 int) → last seen BLE [BluetoothDevice.remoteId] for offer replies.
  static final Map<int, String> hashToMac = {};

  /// Advertised DB hash (uint32 int) → stable CRDT `nodeId` (used for neighbor tables).
  static final Map<int, String> hashToNodeId = {};

  /// Stable nodeId -> last time we saw it directly via scan (presence window).
  static final Map<String, DateTime> localSeenNodes = {};

  /// Stable nodeId -> last known MAC address (best-effort, may go stale/out of range).
  static final Map<String, String> nodeIdToMac = {};

  /// When [nodeIdToMac] was last refreshed from a *scan* (not GATT bind).
  /// Urgent dials must use scan-fresh RPAs — GATT/bind MACs go stale under Android RPA.
  static final Map<String, DateTime> nodeIdMacSeenAt = {};

  /// Last MAC that completed a successful outbound offer to this nodeId.
  static final Map<String, String> lastGoodDialMac = {};

  /// Outbound dial MACs that succeeded before we knew the peer's nodeId.
  static final Map<String, DateTime> _orphanDialSuccessAt = {};

  /// Stable nodeId -> last time a sync handshake *completed* (anti-entropy heartbeat).
  /// Keyed by nodeId (not MAC) because Android RPAs rotate every connection.
  static final Map<String, DateTime> lastFullSync = {};

  /// Stable nodeId -> last version vector we believe that peer held.
  /// Used so initiator pushes are true deltas instead of the entire DB every dial.
  static final Map<String, Map<String, String>> lastKnownPeerVector = {};

  /// Stable nodeId -> last known XOR bucket digests (for targeted initiator push).
  static final Map<String, List<int>> lastKnownPeerBuckets = {};

  /// Soft cap for compressed offer+push payloads. Larger pushes routinely hit the
  /// 60s GATT transfer watchdog and leave lagging nodes stuck mid-transfer.
  static const int maxOfferPushBytes = 48 * 1024;

  /// Keep BLE payloads under the GATT transfer budget by preferring newest rows.
  static Map<String, dynamic> shrinkChangesetForBle(Map<String, dynamic> delta) {
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

  static Map<String, dynamic> _mergeChangesetMaps(
    Map<String, dynamic> a,
    Map<String, dynamic> b,
  ) {
    if (a.isEmpty) return Map<String, dynamic>.from(b);
    if (b.isEmpty) return Map<String, dynamic>.from(a);
    final out = Map<String, dynamic>.from(a);
    for (final entry in b.entries) {
      final existing = out[entry.key];
      if (existing is List && entry.value is List) {
        final byId = <String, dynamic>{};
        for (final row in existing) {
          final id = row is Map
              ? (row['msg_id'] ?? row['msgId'] ?? row['id'] ?? row['node_id'])
                  ?.toString()
              : null;
          byId[id ?? 'a${byId.length}'] = row;
        }
        for (final row in entry.value as List) {
          final id = row is Map
              ? (row['msg_id'] ?? row['msgId'] ?? row['id'] ?? row['node_id'])
                  ?.toString()
              : null;
          byId[id ?? 'b${byId.length}'] = row;
        }
        out[entry.key] = byId.values.toList();
      } else {
        out[entry.key] = entry.value;
      }
    }
    return out;
  }

  /// MAC -> suppress presence until this time (failed/uncallable peer).
  static final Map<String, DateTime> deadMacUntil = {};

  /// Advertised hash -> suppress attempts until this time (handles MAC randomization / phantom MACs).
  static final Map<int, DateTime> deadHashUntil = {};

  /// Best-effort MAC → stable nodeId mapping (filled after first offer/delta).
  static final Map<String, String> macToNodeId = {};

  /// First 4 chars of nodeId → full nodeId (survives advert hash rotation between syncs).
  static final Map<String, String> nodeIdPrefixToNodeId = {};

  /// Record a completed bidirectional sync with [peerNodeId].
  static void markSyncComplete(String peerNodeId) {
    if (peerNodeId.isEmpty) return;
    lastFullSync[peerNodeId] = DateTime.now();
  }

  /// Cache [vector] as what we last knew about [peerNodeId]'s CRDT frontier.
  static void rememberPeerVector(
    String peerNodeId,
    Map<String, String> vector,
  ) {
    if (peerNodeId.isEmpty) return;
    lastKnownPeerVector[peerNodeId] = Map<String, String>.from(vector);
  }

  static void rememberPeerBuckets(String peerNodeId, List<int> buckets) {
    if (peerNodeId.isEmpty) return;
    lastKnownPeerBuckets[peerNodeId] = List<int>.from(buckets);
  }

  /// Bind a stable nodeId to a BLE MAC (and optional advertised hash).
  ///
  /// Identity maps (mac→nodeId, hash→nodeId) always update. Dial MAC
  /// ([nodeIdToMac]) is owned by [rememberScanMac] — GATT connection MACs are
  /// often not valid reconnect targets under Android RPA.
  static void bindPeerIdentity({
    required String nodeId,
    String? mac,
    int? hash,
  }) {
    final resolvedMac =
        (mac != null && mac.isNotEmpty && mac != '<unknown>') ? mac : null;

    if (nodeId.length >= 4) {
      nodeIdPrefixToNodeId[nodeId.substring(0, 4)] = nodeId;
    }

    if (hash != null) {
      hashToNodeId[hash] = nodeId;
      if (resolvedMac != null) {
        hashToMac[hash] = resolvedMac;
      }
    }
    if (resolvedMac != null) {
      macToNodeId[resolvedMac] = nodeId;
      // Only seed dial MAC if scan has never seen this peer.
      if (!nodeIdToMac.containsKey(nodeId)) {
        nodeIdToMac[nodeId] = resolvedMac;
      }
    } else if (hash != null) {
      final scanned = hashToMac[hash];
      if (scanned != null) {
        macToNodeId[scanned] = nodeId;
        if (!nodeIdToMac.containsKey(nodeId)) {
          nodeIdToMac[nodeId] = scanned;
        }
      }
    }
  }

  /// Record a connectable advertise MAC from scan results.
  static void rememberScanMac(String nodeId, String mac, {DateTime? seenAt}) {
    if (nodeId.isEmpty || mac.isEmpty || mac == '<unknown>') return;
    final at = seenAt ?? DateTime.now();
    // FBP delivers a mixed-age batch (newest-first, then older <3s). Never let an
    // older sighting of the *same* MAC overwrite a fresher one. A *different* MAC
    // is an RPA rotation — always take it even if FBP's stamp lags slightly.
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

  /// Live scan MAC beats last successful dial (RPAs rotate; old dial MACs timeout).
  static String? preferredDialMac(String nodeId) {
    final candidates = candidateDialMacs(nodeId);
    return candidates.isEmpty ? null : candidates.first;
  }

  /// All known dial targets for [nodeId], freshest scan sighting first.
  static List<String> candidateDialMacs(String nodeId) {
    if (nodeId.isEmpty) return const [];
    final seenAt = nodeIdMacSeenAt[nodeId];
    final ranked = <String, DateTime>{};

    void add(String? mac, {DateTime? at}) {
      if (mac == null || mac.isEmpty || mac == '<unknown>') return;
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
    for (final e in hashToNodeId.entries) {
      if (e.value == nodeId) add(hashToMac[e.key], at: seenAt);
    }

    final list = ranked.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return [for (final e in list) e.key];
  }

  /// Call after a successful *outbound* dial whose peer nodeId is now known.
  static void rememberSuccessfulDial(String nodeId, String mac) {
    if (nodeId.isEmpty || mac.isEmpty || mac == '<unknown>') return;
    lastGoodDialMac[nodeId] = mac;
    macToNodeId[mac] = nodeId;
    // Do NOT bump nodeIdMacSeenAt here — FBP scan timestamps lag wall-clock, so
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
    if (DateTime.now().difference(at) > const Duration(seconds: 30)) return false;
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
  StreamSubscription<List<ScanResult>>? _scanSub;
  Timer? _heartbeatTimer;
  DateTime? _lastResultAt;

  /// Set of remote hash values currently being connected to (prevents duplicate in-flight attempts).
  final Set<int> _connectingHashes = {};
  /// NodeIds with an in-flight handshake (advertised DB hash rotates; nodeId does not).
  final Set<String> _connectingNodeIds = {};
  /// Queue of peers waiting for a connection slot.
  final List<
      ({
        int hash,
        BluetoothDevice device,
        String? peerNodeId,
        String? peerKeyHint,
        bool hashTrusted,
        bool forceNewest,
        Completer<void> done,
      })> _pendingQueue = [];
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
  static bool advertisesMeshService(ScanResult r) {
    return r.advertisementData.serviceUuids
        .any((u) => u.str128.toLowerCase() == meshServiceUuid.str128);
  }

  void setLocalHash(Uint8List value) {
    _localHash = value;
  }

  Uint8List? _tryGetRemoteHash(ScanResult r) {
    final raw = r.advertisementData.manufacturerData[meshManufacturerId];
    if (raw == null || raw.isEmpty) return null;
    final bytes = Uint8List.fromList(raw);
    // Manufacturer payload format:
    // [0..3]="MESH", [4..7]=uint32 hash (big endian)
    if (bytes.length < 8) return null;
    if (bytes[0] != 0x4D || // M
        bytes[1] != 0x45 || // E
        bytes[2] != 0x53 || // S
        bytes[3] != 0x48) { // H
      return null;
    }
    return bytes.sublist(4);
  }

  bool _isLikelyNativeMeshAdvert(ScanResult r) {
    // Fast path: the primary advertisement always contains our Service UUID.
    // Accept the packet immediately so we don't drop results where the Scan
    // Response (which carries the 0xFFE0 manufacturer hash) hasn't merged yet.
    if (advertisesMeshService(r)) return true;

    // Legacy / fallback path: older builds that don't emit the service UUID
    // yet can still be matched by the full manufacturer magic-header check.
    final raw = r.advertisementData.manufacturerData[meshManufacturerId];
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
    if (wipeMaps) {
      _connectingHashes.clear();
      _connectingNodeIds.clear();
      _pendingQueue.clear();
      _hashCooldowns.clear();
      hashToMac.clear();
      hashToNodeId.clear();
      macToNodeId.clear();
      nodeIdPrefixToNodeId.clear();
      localSeenNodes.clear();
      nodeIdToMac.clear();
      nodeIdMacSeenAt.clear();
      lastGoodDialMac.clear();
      _orphanDialSuccessAt.clear();
      lastFullSync.clear();
      lastKnownPeerVector.clear();
      lastKnownPeerBuckets.clear();
      deadMacUntil.clear();
      deadHashUntil.clear();
    }
    _notifyConnectionPhase();

    await _scanSub?.cancel();
    _heartbeatTimer?.cancel();

    final ownMacUpper = ownMac?.toUpperCase();

    debugPrint('⏳ [BENCHMARK] EVENT:SCAN_COMMANDED | TIMESTAMP:${DateTime.now().millisecondsSinceEpoch}');
    
    // Robust startScan with retry for "APPLICATION_REGISTRATION_FAILED" (Android code 2).
    int attempts = 0;
    var started = false;
    while (attempts < 3) {
      try {
        attempts++;
        // Explicitly stop any existing scan before starting a new one.
        // This clears any stale scanner registrations in some Android stacks.
        await FlutterBluePlus.stopScan();
        if (attempts > 1) {
          await Future.delayed(Duration(milliseconds: 500 * attempts));
        }

        await FlutterBluePlus.startScan(
          androidUsesFineLocation: true,
          androidScanMode: AndroidScanMode.lowLatency,
          androidLegacy: true, // Reverted to true: fixes scanner stall on Android 9
          continuousUpdates: true,
        );
        // Do NOT stamp _lastResultAt here — FBP can return success then async
        // APPLICATION_REGISTRATION_FAILED, which would silence the watchdog.
        final scanStartedAt = DateTime.now();
        _lastResultAt = null;
        _heartbeatTimer = Timer.periodic(const Duration(seconds: 8), (timer) {
          final last = _lastResultAt;
          final quietFor = last != null
              ? DateTime.now().difference(last)
              : DateTime.now().difference(scanStartedAt);
          if (quietFor.inSeconds > 12) {
            debugPrint('⚠️ [SCAN] Watchdog: No scan results for 12s. Scanner may be stalled.');
            onScannerStalled?.call();
          }
        });
        started = true;
        break; 
      } catch (e) {
        debugPrint('⚠️ [SCAN] Start failure (attempt $attempts): $e');
        if (attempts >= 3) {
          onScannerError?.call(e.toString());
          return;
        }
      }
    }
    if (!started) return;

    _scanSub = FlutterBluePlus.scanResults.listen(
      (results) {
      if (results.isNotEmpty) {
        // Stamp liveness on any callback so the 12s watchdog does not soft-restart
        // during quiet ADV intervals (restart loops were killing catch-up).
        _lastResultAt = DateTime.now();
      }
      // CRITICAL: Sort by timestamp descending. FBP maintains a growing historical List.
      // Dead/ghost MACs will fall to the bottom, ensuring we process actively broadcasting peers first,
      // avoiding catastrophic 12s timeout deadlocks trying to connect to dead iterations of ourselves.
      final sortedResults = results.toList()
        ..sort((a, b) => b.timeStamp.compareTo(a.timeStamp));

      final scanNow = DateTime.now();
      for (final r in sortedResults) {
        // Ignore FBP's cached historical sightings — they overwrite dial MACs with
        // dead RPAs and make urgent sync dial ghosts (Red→Clear timeouts).
        if (scanNow.difference(r.timeStamp).inSeconds > 3) {
          continue;
        }
        if (!_isLikelyNativeMeshAdvert(r)) {
          continue;
        }

        final mac = r.device.remoteId.str;

        // CRITICAL: skip self-advertisements. Android can see its own BLE advertisement
        // in scan results. Connecting to self causes a loopback that wastes all attempts.
        if (ownMacUpper != null && mac.toUpperCase() == ownMacUpper) {
          continue;
        }

        // --- SMART TELEMETRY / ROUTING GUARD ---
        var targetBusy = false;
        final telemetryData = r.advertisementData.manufacturerData[0xFFE1];
        if (telemetryData != null && telemetryData.length >= 4) {
          final tBytes = Uint8List.fromList(telemetryData);
          // Bit Unpacking
          final int flags = tBytes[2] | (tBytes[3] << 8);
          final bool isBusy = (flags & (1 << 4)) != 0;
          targetBusy = isBusy;
        }
        // ---------------------------------------

        Uint8List? remotePayload = _tryGetRemoteHash(r);
        final hasRealHash = remotePayload != null && remotePayload.length >= 8;

        // Service UUID / telemetry often arrive before the 0xFFE0 scan-response hash.
        // Still dial those peers — skipping them left the mesh with zero peers after restart.
        if (!hasRealHash && advertisesMeshService(r)) {
          final known = macToNodeId[mac];
          if (known != null) {
            localSeenNodes[known] = DateTime.now();
            rememberScanMac(known, mac, seenAt: r.timeStamp);
          } else if (nodeIdToMac.isNotEmpty || currentNeighborIds.isNotEmpty) {
            // Single live neighbor: treat unknown mesh ADV as that peer's RPA
            // rotation so urgent keeps a connectable MAC (2-node death spiral).
            final neighbors = currentNeighborIds;
            if (neighbors.length == 1) {
              rememberScanMac(neighbors.first, mac, seenAt: r.timeStamp);
              localSeenNodes[neighbors.first] = DateTime.now();
            }
            // Do not dial anonymous ADVs once the mesh has identities.
            continue;
          }
          // Stable per-MAC cooldown key (not a DB hash — never compare for hashesMatch).
          final coolKey = mac.hashCode | 0x100000000;
          final last = _hashCooldowns[coolKey];
          final coolSecs = known == null
              ? 12 + (coolKey.abs() % 4)
              : (targetBusy ? 8 : 5) + (coolKey.abs() % 4);
          if (last == null ||
              DateTime.now().difference(last).inSeconds >= coolSecs) {
            final syncKey = known ?? mac;
            final lastSync = lastFullSync[syncKey];
            final needsAntiEntropy = lastSync == null ||
                DateTime.now().difference(lastSync).inSeconds > 8;
            if (needsAntiEntropy) {
              onDiscovered(known ?? mac);
              unawaited(
                _runMeshInitiatorHandshake(
                  myNodeId,
                  coolKey,
                  r.device,
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
          debugPrint('[ROUTING] Dropping $mac: remotePayload is null (no 0xFFE0 and advertisesMeshService=false)');
          continue;
        }
        if (remotePayload.length < 8) {
          debugPrint('[ROUTING] Dropping $mac: remotePayload < 8 bytes');
          continue; // Need at least 8 bytes for the 64-bit hash
        }

        // CRITICAL: Extract 4-byte node ID prefix (at bytes 8-11) and skip if it's our own advertisement!
        // Payload layout: [8 bytes hash][4 bytes nodeId prefix]
        if (remotePayload.length >= 12) {
          try {
            final remoteNodeIdStr = utf8.decode(remotePayload.sublist(8, 12), allowMalformed: true);
            final localNodeIdPrefix = myNodeId.length >= 4 ? myNodeId.substring(0, 4) : myNodeId.padRight(4, '0');
            if (remoteNodeIdStr == localNodeIdPrefix) {
              continue; // Drop self-advertisement completely
            }
          } catch (e) {
            debugPrint('⚠️ [SCAN] Failed to decode node ID prefix from $mac: $e');
          }
        }

        final int remoteHashInt;

        try {
          // Read 64-bit hash as two big-endian uint32 words (Dart ByteData has no getUint64).
          final bd = ByteData.sublistView(remotePayload);
          final hashHigh = bd.getUint32(0, Endian.big);
          final hashLow = bd.getUint32(4, Endian.big);
          remoteHashInt = (hashHigh << 32) | hashLow;
        } catch (e) {
          debugPrint('⚠️ [SCAN] Failed to parse 64-bit hash from $mac: $e');
          continue;
        }

        hashToMac[remoteHashInt] = mac;

        // Resolve identity + refresh UI presence BEFORE connect cooldowns/deadlists.
        // A peer in the penalty box is still "nearby" if we keep hearing its ads.
        String? prefix;
        if (remotePayload.length >= 12) {
          try {
            prefix =
                utf8.decode(remotePayload.sublist(8, 12), allowMalformed: true);
          } catch (_) {}
        }
        final stableNodeId = hashToNodeId[remoteHashInt] ??
            macToNodeId[mac] ??
            (prefix != null ? nodeIdPrefixToNodeId[prefix] : null);

        if (stableNodeId != null) {
          hashToNodeId[remoteHashInt] = stableNodeId;
          rememberScanMac(stableNodeId, mac, seenAt: r.timeStamp);
          localSeenNodes[stableNodeId] = DateTime.now();
          if (prefix != null && prefix.isNotEmpty) {
            nodeIdPrefixToNodeId[prefix] = stableNodeId;
          }
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
        final localHashInt = (localHashBytes != null && localHashBytes.length >= 8)
            ? (ByteData.sublistView(localHashBytes).getUint32(0, Endian.big) << 32) |
              ByteData.sublistView(localHashBytes).getUint32(4, Endian.big)
            : null;

        final hashesMatch =
            localHashInt != null && remoteHashInt == localHashInt;

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
        final syncKey = stableNodeId ?? mac;
        final lastSync = lastFullSync[syncKey];
        final needsAntiEntropy = !hashesMatch ||
            lastSync == null ||
            DateTime.now().difference(lastSync).inSeconds > 90;

        if (hashesMatch && !needsAntiEntropy) {
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

        // Initiator election ONLY for matched-hash anti-entropy. When hashes differ,
        // either side may dial — otherwise the lowest node-id becomes a single
        // point of failure (seen: Pixel 9 stuck behind while peers never pull).
        if (hashesMatch) {
          String? remotePrefix = prefix;
          final localPrefix = myNodeId.length >= 4
              ? myNodeId.substring(0, 4)
              : myNodeId.padRight(4, '0');
          if (remotePrefix != null && remotePrefix.isNotEmpty) {
            final cmp = localPrefix.compareTo(remotePrefix);
            if (cmp > 0) {
              continue; // Peer owns idle anti-entropy.
            }
            if (cmp == 0 &&
                localHashInt != null &&
                localHashInt >= remoteHashInt) {
              continue;
            }
          }
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
            r.device,
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
  }

  /// Initiates a GATT sync handshake to the given device, or queues it if one is already in flight.
  /// Returns a Future that completes when *this* dial attempt finishes (including if queued).
  Future<void> _runMeshInitiatorHandshake(
    String myNodeId,
    int remoteHashInt,
    BluetoothDevice device, {
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

    final busy = _connectingHashes.isNotEmpty ||
        _connectingHashes.contains(remoteHashInt) ||
        (peerNodeId != null && _connectingNodeIds.contains(peerNodeId));
    if (busy) {
      if (forceNewestPush && peerNodeId != null) {
        if (await _tryInboundUrgentPush(myNodeId, peerNodeId)) return;
      }
      if (forceNewestPush) {
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
    BluetoothDevice device, {
    String? peerNodeId,
    String? peerKeyHint,
    bool remoteHashTrusted = true,
    bool forceNewestPush = false,
  }) async {
    // If the peer is already our GATT client, NOTIFY catch-up instead of a
    // second outbound (dual-role is what wedges Red→Clear after a burst).
    final inboundPeer = peerNodeId ?? macToNodeId[device.remoteId.str];
    if (inboundPeer != null &&
        await _tryInboundCatchupPush(myNodeId, inboundPeer)) {
      return;
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
    final targetMac = device.remoteId.str;
    debugPrint('[BENCHMARK] TARGET_MAC:$targetMac | EVENT:SCAN_HIT | TIMESTAMP:${DateTime.now().millisecondsSinceEpoch}');

    StreamSubscription<BluetoothConnectionState>? stateSub;
    try {
      // Best-effort state listener: we no longer use FlutterBluePlus for the actual GATT
      // transfer, but this can still reveal unexpected stack transitions.
      stateSub = device.connectionState.listen((BluetoothConnectionState state) {
        if (state == BluetoothConnectionState.connected) {
        } else if (state == BluetoothConnectionState.disconnected) {
        }
      });
    } catch (_) {
      // Some platform implementations may not support this stream reliably.
    }
    try {
      final db = await _ref.read(databaseProvider.future);
      // Combined offer+push: vector so the server can compute what WE lack, plus a
      // *delta* of what we think the peer still lacks (from lastKnownPeerVector).
      // Full-DB pushes balloon past the GATT transfer watchdog and stall lagging nodes.
      final myVector = await db.getVersionVector();
      final myHashInt = await db.getDatabaseHash();
      final myNodeId2 = myNodeId;
      final resolvedPeer = peerNodeId ??
          macToNodeId[targetMac] ??
          hashToNodeId[remoteHashInt];
      final priorVector = resolvedPeer != null
          ? Map<String, dynamic>.from(lastKnownPeerVector[resolvedPeer] ?? {})
          : <String, dynamic>{};
      final priorBuckets = resolvedPeer != null
          ? lastKnownPeerBuckets[resolvedPeer]
          : null;
      Map<String, dynamic> ourChangeset;
      if (forceNewestPush) {
        // Burst writes (stress 500 @ 0.3s) outrun a 1-row push; newest-40
        // still fits NOTIFY and covers ~12s of chat at that rate.
        ourChangeset = await db.getNewestRowsChangeset(maxRows: 8);
      } else if (priorBuckets != null && priorBuckets.isNotEmpty) {
        // Prefer bucket gap-fill — newest-N cannot heal stranded rows once they
        // fall outside the sliding window (seen: Red stuck ~30 behind forever).
        ourChangeset = await db.getRowsForMismatchedBuckets(priorBuckets);
        if (ourChangeset.isEmpty && priorVector.isNotEmpty) {
          ourChangeset = await db.getDeltaChangeset(priorVector);
        }
      } else if (priorVector.isNotEmpty) {
        ourChangeset = await db.getDeltaChangeset(priorVector);
      } else {
        // Unknown peer frontier — never ship full DB (empty vector = all rows).
        ourChangeset = await db.getNewestRowsChangeset(maxRows: 8);
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
      // Include a complete typical fingerprint bucket. An 8-row slice can
      // repeatedly miss the one stranded row in a 500-message run.
      if (!forceNewestPush) {
        ourChangeset =
            truncateChangesetForBle(ourChangeset, maxRowsPerTable: 25);
      }
      final fpsBlob = await db.getBucketFingerprintBlob();
      final offerEnvelope = <String, dynamic>{
        'type': 'offer',
        'sender_id': myNodeId2,
        'sender_hash': myHashInt,
        'neighbors': currentNeighborIds,
        'vector': myVector,
        'fps_b': base64Encode(fpsBlob),
        'initiator_data': ourChangeset,
      };
      var payload = zlib.encode(utf8.encode(jsonEncode(offerEnvelope)));
      if (payload.length > maxOfferPushBytes) {
        // Keep fps_b (128B — instant gap fill); drop/shrink initiator_data.
        ourChangeset = truncateChangesetForBle(ourChangeset, maxRowsPerTable: 20);
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
        debugPrint(
          '📤 [DISCOVERY] Sending offer+push to $targetMac — '
          'vector=${myVector.length} rows=$rowCounts peer=$resolvedPeer '
          'fps=${fpsBlob.length}B',
        );
      }
      final macAddress = device.remoteId.str;
      // Android mesh advertisers use Random Resolvable Addresses.
      // We pass isRandom: true to ensure the native layer uses the correct addressing mode.
      await _nativeMesh.sendPayload(
        macAddress,
        Uint8List.fromList(payload),
        isRandom: true,
        bypassDeadCache: forceNewestPush,
      );
      debugPrint('✅ [DISCOVERY] Offer sent to $targetMac (${payload.length} bytes) — awaiting delta reply');
      if (resolvedPeer != null) {
        rememberSuccessfulDial(resolvedPeer, targetMac);
      } else {
        // Identity comes back on the delta — keep this MAC as the proven dial target.
        noteOrphanDialSuccess(targetMac);
      }
      debugPrint('[BENCHMARK] TARGET_MAC:$targetMac | EVENT:OFFER_SENT | TIMESTAMP:${DateTime.now().millisecondsSinceEpoch}');
      // Do NOT mark lastFullSync here — send ≠ completed sync. Completion is recorded
      // when we process the peer's delta (or finish serving their offer).
    } catch (e) {
      debugPrint('🟥 Connection/GATT failed for $targetMac: $e');

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
        _outboundCircuitUntil = DateTime.now().add(const Duration(seconds: 8));
      }
      // Refresh hash cooldown so retries respect the scan debounce window.
      _hashCooldowns[remoteHashInt] = DateTime.now();
      // Suppress this specific MAC briefly; urgent retries need a lighter penalty.
      final duration = _deadlistDurationForError(e);
      if (!forceNewestPush) {
        deadMacUntil[targetMac] = DateTime.now().add(duration);
      } else {
        deadMacUntil[targetMac] =
            DateTime.now().add(const Duration(milliseconds: 400));
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
      // Best-effort: drop presence only for persistent non-mesh peers. Transient
      // timeouts must NOT clear localSeenNodes — that made urgent think the peer
      // vanished (known=1 fresh=0) right after a 2.2s connect miss.
      final mapped = macToNodeId[targetMac] ?? peerNodeId;
      if (mapped != null &&
          e is PlatformException &&
          e.code == 'CHAR_NOT_FOUND') {
        localSeenNodes.remove(mapped);
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
      // NOTE: Do NOT call device.disconnect() here.
      // The native GATT layer now keeps the connection open so the Server can push
      // the Delta reply back via NOTIFY. The Client's onCharacteristicChanged handler
      // will close the connection cleanly when it receives the "||EOF||" notify chunk.
      // The 60-second transferWatchdog guards against a server that never replies.
      try {
        await stateSub?.cancel();
      } catch (_) {}
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
      }
      _pendingQueue.removeAt(0);
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
    if (mac == null || mac.isEmpty) return;
    _lastHashRepairAttempt[peerId] = now;
    unawaited(
      _runMeshInitiatorHandshake(
        myNodeId,
        remoteHash,
        BluetoothDevice.fromId(mac),
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
  final Map<String, DateTime> _lastInboundCatchupAt = {};
  final Set<String> _inboundPushBusy = {};
  final Set<String> _inboundCatchupPending = {};
  final Map<String, DateTime> _lastHashRepairAttempt = {};
  bool _urgentSyncRunning = false;
  bool _urgentSyncDirty = false;
  final Map<String, DateTime> _peerHashDivergedAt = {};
  String? _urgentMyNodeId;
  String? _urgentTargetPeer;
  Completer<bool>? _urgentInboundCompleter;

  /// Native GATT server accepted a client — map RPA early for urgent targeting.
  void onServerClientConnected(String mac) {
    debugPrint('🔗 [DISCOVERY] Server client connected: $mac');
    final myNodeId = _urgentMyNodeId;
    if (myNodeId == null || mac.isEmpty) return;

    var peer = macToNodeId[mac];
    if (peer == null && currentNeighborIds.length == 1) {
      peer = _urgentTargetPeer ?? currentNeighborIds.first;
    }
    if (peer != null) {
      rememberScanMac(peer, mac, seenAt: DateTime.now());
    }
  }

  /// CCCD enabled — NOTIFY push is safe on this inbound link.
  void onServerClientReady(String mac) {
    debugPrint('🔗 [DISCOVERY] Server client NOTIFY-ready: $mac');
    final myNodeId = _urgentMyNodeId;
    if (myNodeId == null || mac.isEmpty) return;

    var peer = macToNodeId[mac];
    if (peer == null && currentNeighborIds.length == 1) {
      peer = _urgentTargetPeer ?? currentNeighborIds.first;
    }
    if (peer == null) return;

    rememberScanMac(peer, mac, seenAt: DateTime.now());
    if (_urgentTargetPeer != null && peer != _urgentTargetPeer) return;

    unawaited(() async {
      if (await _tryInboundUrgentPush(myNodeId, peer!)) {
        await _nativeMesh.cancelOutbound();
        final c = _urgentInboundCompleter;
        if (c != null && !c.isCompleted) c.complete(true);
      }
    }());
  }

  /// Dial known neighbors immediately after a local write (don't wait for ADV/scan).
  void requestUrgentSyncWithKnownPeers(String myNodeId) {
    _lastLocalWriteAt = DateTime.now();
    if (_urgentSyncRunning) {
      _urgentSyncDirty = true;
      return;
    }
    _urgentSyncDebounce?.cancel();
    _urgentSyncDebounce = Timer(const Duration(milliseconds: 50), () {
      unawaited(_runUrgentSync(myNodeId));
    });
  }

  /// Peer is already connected to our GATT server — NOTIFY [changeset].
  Future<void> _pushChangesetOverInbound(
    String myNodeId,
    String mac,
    Map<String, dynamic> changeset,
  ) async {
    final db = await _ref.read(databaseProvider.future);
    final myHashInt = await db.getDatabaseHash();
    final fpsBlob = await db.getBucketFingerprintBlob();
    final envelope = <String, dynamic>{
      'type': 'delta',
      'sender_id': myNodeId,
      'sender_hash': myHashInt,
      'neighbors': currentNeighborIds,
      'fps_b': base64Encode(fpsBlob),
      'data': changeset,
    };
    final payload = zlib.encode(utf8.encode(jsonEncode(envelope)));
    await _nativeMesh.replyPayload(mac, Uint8List.fromList(payload));
    final rowCounts = changeset.map(
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
    int maxRows = 8,
  }) async {
    final db = await _ref.read(databaseProvider.future);
    final changeset = await db.getNewestRowsChangeset(maxRows: maxRows);
    await _pushChangesetOverInbound(myNodeId, mac, changeset);
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

  /// Try NOTIFY push over an inbound link the peer already opened to us.
  Future<bool> _tryInboundUrgentPush(String myNodeId, String peerId) async {
    final connected = await _nativeMesh.getConnectedServerMacs();
    final mac = _resolveInboundMacForPeer(peerId, connected);
    if (mac == null || mac.isEmpty) return false;
    if (!_inboundPushBusy.add(peerId)) {
      // A real transfer is in flight. Coalesce this write into the ordered
      // vector catch-up that runs as soon as that transfer completes.
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
    _lastInboundCatchupAt[peerId] = DateTime.now();

    try {
      await _pushNewestOverInbound(myNodeId, mac);
      rememberSuccessfulDial(peerId, mac);
      rememberScanMac(peerId, mac, seenAt: DateTime.now());
      // Newest-N is latency-only — do not credit the vector (that skips holes).
      return true;
    } catch (e) {
      debugPrint('⚠️ [DISCOVERY] Inbound urgent push $peerId@$mac: $e');
      return false;
    } finally {
      _inboundPushBusy.remove(peerId);
      if (_inboundCatchupPending.remove(peerId)) {
        unawaited(Future<void>.delayed(const Duration(milliseconds: 120), () {
          unawaited(_tryInboundCatchupPush(myNodeId, peerId));
        }));
      }
    }
  }

  /// Catch-up over an existing inbound client using vector/bucket delta
  /// (newest-N cannot heal rows that have fallen out of the sliding window).
  Future<bool> _tryInboundCatchupPush(String myNodeId, String peerId) async {
    final connected = await _nativeMesh.getConnectedServerMacs();
    final mac = _resolveInboundMacForPeer(peerId, connected);
    if (mac == null || mac.isEmpty) return false;
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
    try {
      final db = await _ref.read(databaseProvider.future);
      final prior = Map<String, String>.from(lastKnownPeerVector[peerId] ?? {});
      var fromVector = true;
      var changeset = await db.getDeltaChangeset(prior);
      if (changeset.isEmpty) {
        final buckets = lastKnownPeerBuckets[peerId];
        if (buckets != null && buckets.isNotEmpty) {
          changeset = await db.getRowsForMismatchedBuckets(buckets);
          fromVector = false;
        }
      }
      if (changeset.isEmpty) {
        _lastInboundCatchupAt[peerId] = DateTime.now();
        return true;
      }
      final page = MeshCatchup.takeOldest(
        changeset,
        maxRows: MeshCatchup.pageRows,
      );
      _lastInboundCatchupAt[peerId] = DateTime.now();
      await _pushChangesetOverInbound(myNodeId, mac, page);
      if (fromVector) {
        rememberPeerVector(
          peerId,
          MeshCatchup.mergeVectorFromChangeset(prior, page),
        );
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
      if (hasMore || pending) {
        unawaited(Future<void>.delayed(const Duration(milliseconds: 120), () {
          unawaited(_tryInboundCatchupPush(myNodeId, peerId));
        }));
      }
    }
  }

  /// Wait briefly for a mutual-dial inbound link, then NOTIFY-push.
  Future<bool> _waitForInboundUrgentPush(
    String myNodeId,
    String peerId, {
    Duration timeout = const Duration(milliseconds: 1500),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await _tryInboundUrgentPush(myNodeId, peerId)) return true;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return false;
  }

  /// Inbound-first, then parallel outbound/inbound race — under [maxBudget].
  Future<bool> _urgentDeliverPeer(
    String myNodeId,
    String peerId, {
    Duration maxBudget = const Duration(milliseconds: 4200),
  }) async {
    final stopwatch = Stopwatch()..start();
    final totalCap = maxBudget;

    Duration remaining() {
      final left = totalCap - stopwatch.elapsed;
      return left.isNegative ? Duration.zero : left;
    }

    if (await _tryInboundUrgentPush(myNodeId, peerId)) return true;

    final wait1 = remaining();
    if (wait1 > Duration.zero &&
        await _waitForInboundUrgentPush(
          myNodeId,
          peerId,
          timeout: wait1 < const Duration(milliseconds: 700)
              ? wait1
              : const Duration(milliseconds: 700),
        )) {
      return true;
    }

    final macs = candidateDialMacs(peerId);
    if (macs.isEmpty) {
      final wait = remaining();
      if (wait <= Duration.zero) return false;
      return _waitForInboundUrgentPush(myNodeId, peerId, timeout: wait);
    }

    final raceBudget = remaining();
    if (raceBudget > const Duration(milliseconds: 800)) {
      final budget = raceBudget < const Duration(milliseconds: 2800)
          ? raceBudget
          : const Duration(milliseconds: 2800);
      if (await _raceUrgentDeliver(
        myNodeId,
        peerId,
        macs.first,
        budget: budget,
      )) {
        return true;
      }
    }

    final tail = remaining();
    if (tail <= Duration.zero) return false;
    return _waitForInboundUrgentPush(myNodeId, peerId, timeout: tail);
  }

  /// Last-resort outbound dial after urgent pipeline exhausts (~2.5s cap).
  Future<bool> _urgentScanFallbackDial(String myNodeId, String peerId) async {
    final mac = preferredDialMac(peerId);
    if (mac == null || mac.isEmpty) return false;
    deadMacUntil.remove(mac);
    try {
      final device = BluetoothDevice.fromId(mac);
      final coolKey = 0x200000000 | (peerId.hashCode & 0xffffffff);
      await _runMeshInitiatorHandshake(
        myNodeId,
        coolKey,
        device,
        peerNodeId: peerId,
        peerKeyHint: peerId,
        remoteHashTrusted: false,
        forceNewestPush: true,
      ).timeout(const Duration(milliseconds: 1200));
      return true;
    } catch (e) {
      debugPrint('⚠️ [DISCOVERY] Urgent fallback dial $peerId@$mac: $e');
      return false;
    }
  }

  /// Outbound dial vs inbound NOTIFY — first success wins within [budget].
  Future<bool> _raceUrgentDeliver(
    String myNodeId,
    String peerId,
    String mac, {
    Duration budget = const Duration(milliseconds: 2700),
  }) async {
    _urgentTargetPeer = peerId;
    final winner = Completer<bool>();
    _urgentInboundCompleter = winner;
    Timer? deadline;

    Future<void> tryOutbound() async {
      try {
        final device = BluetoothDevice.fromId(mac);
        final coolKey = 0x200000000 | (peerId.hashCode & 0xffffffff);
        await _runMeshInitiatorHandshake(
          myNodeId,
          coolKey,
          device,
          peerNodeId: peerId,
          peerKeyHint: peerId,
          remoteHashTrusted: false,
          forceNewestPush: true,
        ).timeout(budget);
        if (!winner.isCompleted) winner.complete(true);
      } catch (e) {
        debugPrint('⚠️ [DISCOVERY] Urgent sync try $peerId@$mac: $e');
        lastGoodDialMac.remove(peerId);
      }
    }

    Future<void> pollInbound() async {
      final end = DateTime.now().add(budget);
      while (DateTime.now().isBefore(end) && !winner.isCompleted) {
        if (await _tryInboundUrgentPush(myNodeId, peerId)) {
          await _nativeMesh.cancelOutbound();
          if (!winner.isCompleted) winner.complete(true);
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }

    unawaited(tryOutbound());
    unawaited(pollInbound());
    deadline = Timer(budget, () {
      if (!winner.isCompleted) winner.complete(false);
    });

    try {
      final ok = await winner.future;
      if (!ok) await _nativeMesh.cancelOutbound();
      return ok;
    } finally {
      deadline.cancel();
      _urgentInboundCompleter = null;
      _urgentTargetPeer = null;
    }
  }

  Future<void> _runUrgentSync(String myNodeId) async {
    if (_urgentSyncRunning) {
      _urgentSyncDirty = true;
      return;
    }
    _urgentSyncRunning = true;
    _urgentMyNodeId = myNodeId;
    _urgentRadioHoldUntil = DateTime.now().add(const Duration(seconds: 5));
    await _nativeMesh.setUrgentHold(true);
    final urgentSw = Stopwatch()..start();
    const urgentBudget = Duration(milliseconds: 4800);
    try {
      do {
        _urgentSyncDirty = false;
    // Only dial scan-fresh RPAs. Stale GATT/bind MACs routinely 4s-timeout and
    // burn the only outbound slot (seen: P9→Clear miss while Red also times out).
    final now = DateTime.now();
    final peerIds = <String>{
      ...currentNeighborIds,
      ...nodeIdToMac.keys,
    };
    peerIds.remove(myNodeId);

    bool macUsable(String id) {
      final liveNeighbor = currentNeighborIds.contains(id);
      final macs = candidateDialMacs(id);
      if (macs.isEmpty) return liveNeighbor;

      for (final mac in macs) {
        final dead = deadMacUntil[mac];
        if (liveNeighbor || dead == null || now.isAfter(dead)) return true;
      }
      // Live neighbor: dial anyway — native bypassDeadCache clears penalty box.
      return liveNeighbor;
    }

    final freshPeers = peerIds.where(macUsable).toList();
    if (freshPeers.isEmpty) {
      debugPrint(
        '🚀 [DISCOVERY] Urgent sync: no dial MACs '
        '(known=${peerIds.length}) — nudging scanner',
      );
      print('URGENT_SYNC peers= none fresh=0/${peerIds.length}');
      final live = currentNeighborIds;
      if (live.isNotEmpty) {
        final nudge = DateTime.now();
        for (final id in live) {
          localSeenNodes[id] = nudge;
        }
        onScannerStalled?.call();
        _urgentSyncDebounce?.cancel();
        _urgentSyncDebounce = Timer(const Duration(milliseconds: 600), () {
          unawaited(_runUrgentSync(myNodeId));
        });
      }
      return;
    }
    freshPeers.sort((a, b) {
      final ta = lastFullSync[a];
      final tb = lastFullSync[b];
      if (ta == null && tb == null) return a.compareTo(b);
      if (ta == null) return -1;
      if (tb == null) return 1;
      return ta.compareTo(tb);
    });
    final live = freshPeers.where(currentNeighborIds.contains).toList();
    final pool = (live.isNotEmpty ? live : freshPeers).take(1).toList();
    debugPrint(
      '🚀 [DISCOVERY] Urgent sync → ${pool.length} peer(s) '
      '(fresh=${freshPeers.length}/${peerIds.length})',
    );
    print(
      'URGENT_SYNC peers=${pool.join(",")} fresh=${freshPeers.length}/${peerIds.length}',
    );

    // Drop non-urgent queued dials so push-on-write isn't stuck behind fat offers.
    final dropped = _pendingQueue.where((e) => !e.forceNewest).toList();
    for (final e in dropped) {
      if (!e.done.isCompleted) e.done.complete();
    }
    _pendingQueue.removeWhere((e) => !e.forceNewest);

    for (final pick in pool) {
      lastFullSync.remove(pick);
      localSeenNodes[pick] = DateTime.now();
      for (final mac in candidateDialMacs(pick)) {
        deadMacUntil.remove(mac);
      }
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
          debugPrint('🔄 [DISCOVERY] Urgent failed on $pick — GATT recovery');
          try {
            await onUrgentGattRecovery!();
            await Future<void>.delayed(const Duration(milliseconds: 300));
            final retry = urgentBudget - urgentSw.elapsed;
            if (retry > const Duration(milliseconds: 900)) {
              dialed = await _urgentDeliverPeer(myNodeId, pick, maxBudget: retry);
            }
          } catch (e) {
            debugPrint('⚠️ [DISCOVERY] GATT recovery failed: $e');
          }
        }
      }
      if (!dialed) {
        final left = urgentBudget - urgentSw.elapsed;
        if (left > const Duration(milliseconds: 1200)) {
          dialed = await _urgentScanFallbackDial(myNodeId, pick);
        }
      }
      if (!dialed) {
        debugPrint('⚠️ [DISCOVERY] Urgent sync gave up on $pick');
      }
    }
      } while (_urgentSyncDirty && urgentSw.elapsed < urgentBudget);
    } finally {
      _urgentSyncRunning = false;
      _urgentMyNodeId = null;
      _urgentTargetPeer = null;
      _urgentInboundCompleter = null;
      _urgentRadioHoldUntil = null;
      await _nativeMesh.setUrgentHold(false);
      _drainPendingQueue(myNodeId);
      if (_urgentSyncDirty) {
        // Brief yield so scan-path can use the held link between burst pushes.
        unawaited(Future<void>.delayed(const Duration(milliseconds: 200), () {
          if (!_urgentSyncRunning) {
            unawaited(_runUrgentSync(myNodeId));
          }
        }));
      }
    }
  }

  
  Future<void> stopScanning() async {
    await _scanSub?.cancel();
    _scanSub = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    await FlutterBluePlus.stopScan();
  }

  Future<void> stopAll() async {
    await stopScanning();
  }

}
