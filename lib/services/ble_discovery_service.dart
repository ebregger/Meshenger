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
import 'native_mesh_service.dart';

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
  static void rememberScanMac(String nodeId, String mac) {
    if (nodeId.isEmpty || mac.isEmpty || mac == '<unknown>') return;
    nodeIdToMac[nodeId] = mac;
    macToNodeId[mac] = nodeId;
    nodeIdMacSeenAt[nodeId] = DateTime.now();
  }


  BleDiscoveryService(
    this._ref, {
    this.onConnectionPhaseChanged,
    this.onScannerError,
    this.onScannerStalled,
  });

  final Ref _ref;
  final void Function()? onConnectionPhaseChanged;
  final void Function(String error)? onScannerError;
  final void Function()? onScannerStalled;

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
        _lastResultAt = DateTime.now();
      }
      // CRITICAL: Sort by timestamp descending. FBP maintains a growing historical List.
      // Dead/ghost MACs will fall to the bottom, ensuring we process actively broadcasting peers first,
      // avoiding catastrophic 12s timeout deadlocks trying to connect to dead iterations of ourselves.
      final sortedResults = results.toList()
        ..sort((a, b) => b.timeStamp.compareTo(a.timeStamp));

      for (final r in sortedResults) {
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
            rememberScanMac(known, mac);
          }
          // Stable per-MAC cooldown key (not a DB hash — never compare for hashesMatch).
          final coolKey = mac.hashCode | 0x100000000;
          final last = _hashCooldowns[coolKey];
          final coolSecs = (targetBusy ? 8 : 5) + (coolKey.abs() % 4);
          if (last == null ||
              DateTime.now().difference(last).inSeconds >= coolSecs) {
            final syncKey = known ?? mac;
            final lastSync = lastFullSync[syncKey];
            final needsAntiEntropy = lastSync == null ||
                DateTime.now().difference(lastSync).inSeconds > 2;
            if (needsAntiEntropy) {
              // When hashes are unknown (hashless path), still dial even if busy —
              // hard-defer caused Red3 to starve while peers only sent vector-only.
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
          rememberScanMac(stableNodeId, mac);
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
              : (targetBusy ? 6 : 4);
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

        // Yield the outbound slot to urgent push-on-write for a few seconds.
        final hold = _urgentRadioHoldUntil;
        if (hold != null && DateTime.now().isBefore(hold)) {
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
  Future<void> _runMeshInitiatorHandshake(
    String myNodeId,
    int remoteHashInt,
    BluetoothDevice device, {
    String? peerNodeId,
    String? peerKeyHint,
    bool remoteHashTrusted = true,
    bool forceNewestPush = false,
  }) async {
    void enqueue({required bool front}) {
      final entry = (
        hash: remoteHashInt,
        device: device,
        peerNodeId: peerNodeId,
        peerKeyHint: peerKeyHint,
        hashTrusted: remoteHashTrusted,
        forceNewest: forceNewestPush,
      );
      _pendingQueue.removeWhere(
        (e) =>
            e.hash == remoteHashInt ||
            (peerNodeId != null && e.peerNodeId == peerNodeId),
      );
      if (front) {
        _pendingQueue.insert(0, entry);
      } else {
        _pendingQueue.add(entry);
      }
    }

    if (_connectingHashes.contains(remoteHashInt)) {
      if (forceNewestPush) enqueue(front: true);
      return;
    }
    if (peerNodeId != null && _connectingNodeIds.contains(peerNodeId)) {
      if (forceNewestPush) enqueue(front: true);
      return;
    }

    if (_connectingHashes.isNotEmpty) {
      final alreadyQueued = _pendingQueue.any(
        (e) =>
            e.hash == remoteHashInt ||
            (peerNodeId != null && e.peerNodeId == peerNodeId),
      );
      if (forceNewestPush) {
        enqueue(front: true);
      } else if (!alreadyQueued) {
        enqueue(front: false);
      }
      return;
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
        // Local write: keep offer tiny so both peers get a turn within seconds.
        ourChangeset = await db.getNewestRowsChangeset(maxRows: 5);
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
        ourChangeset = await db.getNewestRowsChangeset(maxRows: 15);
      }
      // Large rotating repair ONLY when we have nothing else to send.
      // Merging 100+ repair rows into every diverge offer ballooned GATT (~149
      // msgs) and blocked the second peer for many seconds.
      if (ourChangeset.isEmpty &&
          remoteHashTrusted &&
          remoteHashInt != myHashInt) {
        ourChangeset = await db.getHashRepairChangeset(
          peerKey: resolvedPeer ?? peerKeyHint ?? targetMac,
          maxRows: 80,
        );
      }
      if (ourChangeset.isEmpty) {
        ourChangeset = await db.getNewestRowsChangeset(maxRows: 15);
      }
      // Live scan-path offers must stay small — 30+ row GATT transfers starve the
      // 2nd/3rd peer and blow past the few-second catch-up budget. fps_b stays so
      // the peer can still request stranded buckets on the reply.
      if (!forceNewestPush) {
        ourChangeset =
            truncateChangesetForBle(ourChangeset, maxRowsPerTable: 20);
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
      await _nativeMesh.sendPayload(macAddress, Uint8List.fromList(payload), isRandom: true);
      debugPrint('✅ [DISCOVERY] Offer sent to $targetMac (${payload.length} bytes) — awaiting delta reply');
      if (resolvedPeer != null) {
        lastGoodDialMac[resolvedPeer] = targetMac;
        nodeIdToMac[resolvedPeer] = targetMac;
        nodeIdMacSeenAt[resolvedPeer] = DateTime.now();
      }
      debugPrint('[BENCHMARK] TARGET_MAC:$targetMac | EVENT:OFFER_SENT | TIMESTAMP:${DateTime.now().millisecondsSinceEpoch}');
      // Do NOT mark lastFullSync here — send ≠ completed sync. Completion is recorded
      // when we process the peer's delta (or finish serving their offer).
    } catch (e) {
      debugPrint('🟥 Connection/GATT failed for $targetMac: $e');
      // Pause scan-path dials so the radio can recover from timeout storms.
      _outboundCircuitUntil = DateTime.now().add(const Duration(seconds: 10));
      // Refresh hash cooldown so retries respect the scan debounce window.
      _hashCooldowns[remoteHashInt] = DateTime.now();
      // Suppress this specific MAC briefly; use hash-based deadlist for MAC-randomized devices.
      final duration = _deadlistDurationForError(e);
      deadMacUntil[targetMac] = DateTime.now().add(duration);
      // Only add hash-based cooldown for persistent failures (CHAR_NOT_FOUND, not transient 133).
      // For DISCONNECTED/timeout, the hash cooldown (8s) already covers the retry window —
      // adding a separate deadHashUntil would double-suppress and skip the peer entirely.
      if (e is PlatformException && e.code == 'CHAR_NOT_FOUND') {
        deadHashUntil[remoteHashInt] = DateTime.now().add(duration);
      }
      // Best-effort: drop presence + scan freshness so urgent won't re-dial a dead RPA.
      final mapped = macToNodeId[targetMac] ?? peerNodeId;
      if (mapped != null) {
        localSeenNodes.remove(mapped);
        nodeIdMacSeenAt.remove(mapped);
      }
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
      // Drain one item from the queue and attempt it now that we have a free slot.
      if (_pendingQueue.isNotEmpty) {
        final next = _pendingQueue.removeAt(0);
        // Fire-and-forget: don't await so this finally block can return promptly.
        unawaited(
          _doHandshake(
            myNodeId,
            next.hash,
            next.device,
            peerNodeId: next.peerNodeId,
            peerKeyHint: next.peerKeyHint,
            remoteHashTrusted: next.hashTrusted,
            forceNewestPush: next.forceNewest,
          ),
        );
      }
    }
  }

  /// Burst scan to pick up peers after a local DB write; resumes continuous scan after.
  Future<void> runQuickScan() async {
    // Deprecated: scanning stays continuously enabled to avoid Android scan rate limits.
    // Keep method for any legacy callers; it is now a no-op.
    return;
  }

  Timer? _urgentSyncDebounce;
  DateTime? _urgentRadioHoldUntil;
  DateTime? _outboundCircuitUntil;

  /// Dial known neighbors immediately after a local write (don't wait for ADV/scan).
  void requestUrgentSyncWithKnownPeers(String myNodeId) {
    _urgentRadioHoldUntil = DateTime.now().add(const Duration(seconds: 6));
    _urgentSyncDebounce?.cancel();
    _urgentSyncDebounce = Timer(const Duration(milliseconds: 100), () {
      unawaited(_runUrgentSync(myNodeId));
    });
  }

  Future<void> _runUrgentSync(String myNodeId) async {
    // Only dial scan-fresh RPAs. Stale GATT/bind MACs routinely 4s-timeout and
    // burn the only outbound slot (seen: P9→Clear miss while Red also times out).
    final now = DateTime.now();
    const fresh = Duration(seconds: 12);
    final peerIds = <String>{
      ...currentNeighborIds,
      ...nodeIdToMac.keys,
    };
    peerIds.remove(myNodeId);

    bool macUsable(String id) {
      final mac = lastGoodDialMac[id] ?? nodeIdToMac[id];
      if (mac == null || mac.isEmpty) return false;
      final dead = deadMacUntil[mac];
      if (dead != null && now.isBefore(dead)) return false;
      final seen = nodeIdMacSeenAt[id];
      // Proven dial MACs stay usable longer than never-connected scan sightings.
      final maxAge = lastGoodDialMac.containsKey(id)
          ? const Duration(seconds: 45)
          : fresh;
      if (seen == null || now.difference(seen) > maxAge) return false;
      return true;
    }

    final freshPeers = peerIds.where(macUsable).toList();
    if (freshPeers.isEmpty) {
      debugPrint(
        '🚀 [DISCOVERY] Urgent sync: no scan-fresh MACs '
        '(known=${peerIds.length}) — waiting for scan',
      );
      print('URGENT_SYNC peers= none fresh=0/${peerIds.length}');
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
    final pool = (live.isNotEmpty ? live : freshPeers).take(2).toList();
    debugPrint(
      '🚀 [DISCOVERY] Urgent sync → ${pool.length} peer(s) '
      '(fresh=${freshPeers.length}/${peerIds.length})',
    );
    print(
      'URGENT_SYNC peers=${pool.join(",")} fresh=${freshPeers.length}/${peerIds.length}',
    );

    for (final pick in pool) {
      lastFullSync.remove(pick);
      final mac = lastGoodDialMac[pick] ?? nodeIdToMac[pick];
      if (mac == null || mac.isEmpty) continue;
      final dead = deadMacUntil[mac];
      if (dead != null && DateTime.now().isBefore(dead)) continue;
      // Do NOT clear deadMacUntil — that caused urgent to re-dial known-dead RPAs.
      try {
        final device = BluetoothDevice.fromId(mac);
        final coolKey = 0x200000000 | (pick.hashCode & 0xffffffff);
        await _runMeshInitiatorHandshake(
          myNodeId,
          coolKey,
          device,
          peerNodeId: pick,
          peerKeyHint: pick,
          remoteHashTrusted: false,
          forceNewestPush: true,
        );
      } catch (e) {
        debugPrint('⚠️ [DISCOVERY] Urgent sync skip $pick@$mac: $e');
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
