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

  /// Stable nodeId -> last time a sync handshake *completed* (anti-entropy heartbeat).
  /// Keyed by nodeId (not MAC) because Android RPAs rotate every connection.
  static final Map<String, DateTime> lastFullSync = {};

  /// Stable nodeId -> last version vector we believe that peer held.
  /// Used so initiator pushes are true deltas instead of the entire DB every dial.
  static final Map<String, Map<String, String>> lastKnownPeerVector = {};

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

  /// Bind a stable nodeId to a BLE MAC (and optional advertised hash).
  ///
  /// Call this on every successful sync so the UI can show a real MAC for
  /// direct peers — not only after a later scan tick updates [nodeIdToMac].
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
      nodeIdToMac[nodeId] = resolvedMac;
    } else if (hash != null) {
      // Fall back to last scanned MAC for this hash (initiator path).
      final scanned = hashToMac[hash];
      if (scanned != null) {
        macToNodeId[scanned] = nodeId;
        nodeIdToMac[nodeId] = scanned;
      }
    }
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
  final List<({int hash, BluetoothDevice device, String? peerNodeId, bool hashTrusted})>
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
  Future<void> startScanning({
    required String myNodeId,
    String? ownMac,
    required void Function(String shortNodeId) onDiscovered,
  }) async {
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
    lastFullSync.clear();
    lastKnownPeerVector.clear();
    deadMacUntil.clear();
    deadHashUntil.clear();
    _notifyConnectionPhase();

    await _scanSub?.cancel();
    _heartbeatTimer?.cancel();

    final ownMacUpper = ownMac?.toUpperCase();

    debugPrint('⏳ [BENCHMARK] EVENT:SCAN_COMMANDED | TIMESTAMP:${DateTime.now().millisecondsSinceEpoch}');
    
    // Robust startScan with retry for "APPLICATION_REGISTRATION_FAILED" (Android code 2).
    int attempts = 0;
    while (attempts < 3) {
      try {
        attempts++;
        // Explicitly stop any existing scan before starting a new one.
        // This clears any stale scanner registrations in some Android stacks.
        await FlutterBluePlus.stopScan();
        if (attempts > 1) await Future.delayed(const Duration(milliseconds: 500));

        await FlutterBluePlus.startScan(
          androidUsesFineLocation: true,
          androidScanMode: AndroidScanMode.lowLatency,
          androidLegacy: true, // Reverted to true: fixes scanner stall on Android 9
          continuousUpdates: true,
        );
        // If we reach here, it started!
        _lastResultAt = DateTime.now();
        _heartbeatTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
          final last = _lastResultAt;
          if (last != null && DateTime.now().difference(last).inSeconds > 25) {
            debugPrint('⚠️ [SCAN] Watchdog: No scan results for 25s. Scanner may be stalled.');
            onScannerStalled?.call();
          }
        });
        break; 
      } catch (e) {
        debugPrint('⚠️ [SCAN] Start failure (attempt $attempts): $e');
        if (attempts >= 3) {
          onScannerError?.call(e.toString());
          return;
        }
      }
    }

    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      debugPrint('[DIAGNOSTIC] SCAN_TICK | count=${results.length}');
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
          // Check if this might be D3 being erroneously dropped
          final mac = r.device.remoteId.str;
          final svc = r.advertisementData.serviceUuids;
          final mfg = r.advertisementData.manufacturerData.keys.toList();
          debugPrint('[ROUTING] _isLikelyNativeMeshAdvert rejected MAC $mac. Svcs: $svc, MfgKeys: $mfg');
          continue;
        }

        final mac = r.device.remoteId.str;

        // CRITICAL: skip self-advertisements. Android can see its own BLE advertisement
        // in scan results. Connecting to self causes a loopback that wastes all attempts.
        if (ownMacUpper != null && mac.toUpperCase() == ownMacUpper) {
          continue;
        }

        // --- SMART TELEMETRY / ROUTING GUARD ---
        final telemetryData = r.advertisementData.manufacturerData[0xFFE1];
        if (telemetryData != null && telemetryData.length >= 4) {
          final tBytes = Uint8List.fromList(telemetryData);
          final hex0 = tBytes[0].toRadixString(16).padLeft(2, '0').toUpperCase();
          final hex1 = tBytes[1].toRadixString(16).padLeft(2, '0').toUpperCase();
          debugPrint('[DIAGNOSTIC] SCANNED TELEMETRY HEADER FROM $mac: 0x$hex0 0x$hex1');

          // Bit Unpacking
          final int flags = tBytes[2] | (tBytes[3] << 8);
          final bool isGateway = (flags & (1 << 0)) != 0;
          final bool isLowBattery = (flags & (1 << 1)) != 0;
          final bool isLegacy = (flags & (1 << 2)) != 0;
          final bool isIOS = (flags & (1 << 3)) != 0;
          final bool isBusy = (flags & (1 << 4)) != 0;
          final int hopDistance = (flags >> 5) & 0x03;

          // Busy is advisory only. Hard-skipping caused a mesh deadlock during heavy
          // floods: every node advertised busy, so nobody initiated and peers vanished.
          if (isBusy) {
            debugPrint('[ROUTING] Target $mac reports busy (still eligible to dial)');
          }
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
            nodeIdToMac[known] = mac;
          }
          // Stable per-MAC cooldown key (not a DB hash — never compare for hashesMatch).
          final coolKey = mac.hashCode | 0x100000000;
          final last = _hashCooldowns[coolKey];
          final coolSecs = 10 + (coolKey.abs() % 5);
          if (last == null ||
              DateTime.now().difference(last).inSeconds >= coolSecs) {
            final syncKey = known ?? mac;
            final lastSync = lastFullSync[syncKey];
            final needsAntiEntropy = lastSync == null ||
                DateTime.now().difference(lastSync).inSeconds > 12;
            if (needsAntiEntropy) {
              onDiscovered(known ?? mac);
              unawaited(
                _runMeshInitiatorHandshake(
                  myNodeId,
                  coolKey,
                  r.device,
                  peerNodeId: known,
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
          macToNodeId[mac] = stableNodeId;
          nodeIdToMac[stableNodeId] = mac;
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

        final last = _hashCooldowns[remoteHashInt];
        // Cooldown must be longer than _deadlistDurationForError to ensure the hash
        // path doesn't immediately retry a peer that's in the deadMacUntil window.
        // Add small jitter so N phones don't stampede the same peer in lockstep.
        if (last != null) {
          final coolSecs = 10 + (remoteHashInt.abs() % 5);
          if (DateTime.now().difference(last).inSeconds < coolSecs) {
            continue;
          }
        }

        final localHashBytes = _localHash;
        // Read local hash as 64-bit (two uint32 words) to match new 8-byte payload format.
        final localHashInt = (localHashBytes != null && localHashBytes.length >= 8)
            ? (ByteData.sublistView(localHashBytes).getUint32(0, Endian.big) << 32) |
              ByteData.sublistView(localHashBytes).getUint32(4, Endian.big)
            : null;

        final hashesMatch =
            localHashInt != null && remoteHashInt == localHashInt;

        // Anti-entropy: when DBs already match, dial rarely. When they diverge, retry sooner.
        // Prefer stable nodeId — MAC keys never hit after RPA rotation.
        final syncKey = stableNodeId ?? mac;
        final lastSync = lastFullSync[syncKey];
        final antiEntropySecs = hashesMatch ? 90 : 12;
        final needsAntiEntropy = lastSync == null ||
            DateTime.now().difference(lastSync).inSeconds > antiEntropySecs;

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

        onDiscovered(discoveredId);
        unawaited(
          _runMeshInitiatorHandshake(
            myNodeId,
            remoteHashInt,
            r.device,
            peerNodeId: stableNodeId,
            remoteHashTrusted: true,
          ),
        );
      }
    });
  }

  /// Initiates a GATT sync handshake to the given device, or queues it if one is already in flight.
  Future<void> _runMeshInitiatorHandshake(
    String myNodeId,
    int remoteHashInt,
    BluetoothDevice device, {
    String? peerNodeId,
    bool remoteHashTrusted = true,
  }) async {
    // If already connecting to this exact hash, skip entirely (duplicate).
    if (_connectingHashes.contains(remoteHashInt)) return;
    // Same peer under a rotated DB hash — don't stack parallel dials.
    if (peerNodeId != null && _connectingNodeIds.contains(peerNodeId)) return;

    // If another connection is already in flight, enqueue this peer instead of dropping it.
    if (_connectingHashes.isNotEmpty) {
      // Only enqueue if not already pending for this hash or nodeId.
      final alreadyQueued = _pendingQueue.any(
        (e) =>
            e.hash == remoteHashInt ||
            (peerNodeId != null && e.peerNodeId == peerNodeId),
      );
      if (!alreadyQueued) {
        _pendingQueue.add((
          hash: remoteHashInt,
          device: device,
          peerNodeId: peerNodeId,
          hashTrusted: remoteHashTrusted,
        ));
      }
      return;
    }

    await _doHandshake(
      myNodeId,
      remoteHashInt,
      device,
      peerNodeId: peerNodeId,
      remoteHashTrusted: remoteHashTrusted,
    );
  }

  Future<void> _doHandshake(
    String myNodeId,
    int remoteHashInt,
    BluetoothDevice device, {
    String? peerNodeId,
    bool remoteHashTrusted = true,
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
      var ourChangeset = await db.getDeltaChangeset(priorVector);
      if (ourChangeset.isEmpty &&
          remoteHashTrusted &&
          remoteHashInt != myHashInt) {
        ourChangeset = await db.getHashRepairChangeset();
        if (ourChangeset.isNotEmpty) {
          debugPrint(
            '⚠️ [DISCOVERY] Hash-mismatch repair push to $targetMac '
            '(peer=$resolvedPeer)',
          );
        }
      }
      final offerEnvelope = <String, dynamic>{
        'type': 'offer',
        'sender_id': myNodeId2,
        'sender_hash': myHashInt,
        'neighbors': currentNeighborIds,
        'vector': myVector,
        'initiator_data': ourChangeset,
      };
      var payload = zlib.encode(utf8.encode(jsonEncode(offerEnvelope)));
      if (payload.length > maxOfferPushBytes) {
        if (priorVector.isEmpty) {
          // Full-DB dump + newest-N shrink permanently strands older unique rows
          // (seen: BenchMsg#001 stuck on 2/3 nodes). Vector-only; peer replies with
          // what we lack, and our older rows move when they dial with a real vector.
          offerEnvelope.remove('initiator_data');
          payload = zlib.encode(utf8.encode(jsonEncode(offerEnvelope)));
          debugPrint(
            '⚠️ [DISCOVERY] Offer push capped for $targetMac — '
            'vector-only (${payload.length} bytes; peer=$resolvedPeer prior=empty)',
          );
        } else {
          ourChangeset = shrinkChangesetForBle(ourChangeset);
          offerEnvelope['initiator_data'] = ourChangeset;
          payload = zlib.encode(utf8.encode(jsonEncode(offerEnvelope)));
          if (payload.length > maxOfferPushBytes) {
            offerEnvelope.remove('initiator_data');
            payload = zlib.encode(utf8.encode(jsonEncode(offerEnvelope)));
            debugPrint(
              '⚠️ [DISCOVERY] Offer push capped for $targetMac — '
              'vector-only (${payload.length} bytes; peer=$resolvedPeer)',
            );
          } else {
            final rowCounts = ourChangeset.map(
              (t, rows) => MapEntry(t, (rows as List).length),
            );
            debugPrint(
              '⚠️ [DISCOVERY] Offer push shrunk for $targetMac — '
              'rows=$rowCounts peer=$resolvedPeer',
            );
          }
        }
      } else {
        final rowCounts = ourChangeset.map(
          (t, rows) => MapEntry(t, (rows as List).length),
        );
        debugPrint(
          '📤 [DISCOVERY] Sending offer+push to $targetMac — '
          'vector=${myVector.length} prior=${priorVector.length} rows=$rowCounts peer=$resolvedPeer',
        );
      }
      final macAddress = device.remoteId.str;
      // Android mesh advertisers use Random Resolvable Addresses.
      // We pass isRandom: true to ensure the native layer uses the correct addressing mode.
      await _nativeMesh.sendPayload(macAddress, Uint8List.fromList(payload), isRandom: true);
      debugPrint('✅ [DISCOVERY] Offer sent to $targetMac (${payload.length} bytes) — awaiting delta reply');
      debugPrint('[BENCHMARK] TARGET_MAC:$targetMac | EVENT:OFFER_SENT | TIMESTAMP:${DateTime.now().millisecondsSinceEpoch}');
      // Do NOT mark lastFullSync here — send ≠ completed sync. Completion is recorded
      // when we process the peer's delta (or finish serving their offer).
    } catch (e) {
      debugPrint('🟥 Connection/GATT failed for $targetMac: $e');
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
      // Best-effort: remove from direct presence so UI can drop it.
      final mapped = macToNodeId[targetMac] ?? peerNodeId;
      if (mapped != null) {
        localSeenNodes.remove(mapped);
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
            remoteHashTrusted: next.hashTrusted,
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
