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

  /// MAC -> last time we performed a full sync handshake (anti-entropy heartbeat).
  static final Map<String, DateTime> lastFullSync = {};

  /// MAC -> suppress presence until this time (failed/uncallable peer).
  static final Map<String, DateTime> deadMacUntil = {};

  /// Advertised hash -> suppress attempts until this time (handles MAC randomization / phantom MACs).
  static final Map<int, DateTime> deadHashUntil = {};

  /// Best-effort MAC → stable nodeId mapping (filled after first offer/delta).
  static final Map<String, String> macToNodeId = {};

  BleDiscoveryService(
    this._ref, {
    this.onConnectionPhaseChanged,
  });

  final Ref _ref;
  final void Function()? onConnectionPhaseChanged;

  final NativeMeshService _nativeMesh = NativeMeshService();
  Uint8List? _localHash;
  StreamSubscription<List<ScanResult>>? _scanSub;
  /// When true, scan callbacks must not start another handshake or fire discovery churn.
  bool _isConnecting = false;
  final Map<int, DateTime> _hashCooldowns = {};

  /// Exposed for UI / notifier guards while a GATT sync is in flight.
  bool get isConnecting => _isConnecting;

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
    // Only accept devices running our mesh program:
    // they must advertise our manufacturer payload (0xFFE0) containing a magic header + 4-byte hash.
    final raw = r.advertisementData.manufacturerData[meshManufacturerId];
    if (raw == null) return false;
    if (raw.length < 8) return false;
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
    _isConnecting = false;
    _hashCooldowns.clear();
    hashToMac.clear();
    hashToNodeId.clear();
    macToNodeId.clear();
    localSeenNodes.clear();
    nodeIdToMac.clear();
    lastFullSync.clear();
    deadMacUntil.clear();
    deadHashUntil.clear();
    _notifyConnectionPhase();

    await _scanSub?.cancel();

    final ownMacUpper = ownMac?.toUpperCase();

    // Do not use [withServices] filtering here: some Android stacks omit/truncate 128-bit UUIDs
    // when the advertisement includes a device name. We'll filter manually in the listener.
    debugPrint('⏳ [BENCHMARK] EVENT:SCAN_COMMANDED | TIMESTAMP:${DateTime.now().millisecondsSinceEpoch}');
    await FlutterBluePlus.startScan(
      androidUsesFineLocation: true,
      continuousUpdates: true, // Forces immediate delivery of scan hits
    );

    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      // CRITICAL: Sort by timestamp descending. FBP maintains a growing historical List.
      // Dead/ghost MACs will fall to the bottom, ensuring we process actively broadcasting peers first,
      // avoiding catastrophic 12s timeout deadlocks trying to connect to dead iterations of ourselves.
      final sortedResults = results.toList()
        ..sort((a, b) => b.timeStamp.compareTo(a.timeStamp));

      for (final r in sortedResults) {
        if (_isConnecting) continue;
        if (!_isLikelyNativeMeshAdvert(r)) continue;

        final mac = r.device.remoteId.str;

        // CRITICAL: skip self-advertisements. Android can see its own BLE advertisement
        // in scan results. Connecting to self causes a loopback that wastes all attempts.
        if (ownMacUpper != null && mac.toUpperCase() == ownMacUpper) {
          continue;
        }

        final remotePayload = _tryGetRemoteHash(r);
        if (remotePayload == null) continue;
        if (remotePayload.length < 8) continue; // Need at least 8 bytes for the 64-bit hash

        // CRITICAL: Extract 4-byte node ID prefix (at bytes 8-11) and skip if it's our own advertisement!
        // Payload layout: [8 bytes hash][4 bytes nodeId prefix]
        if (remotePayload.length >= 12) {
          try {
            final remoteNodeIdStr = utf8.decode(remotePayload.sublist(8, 12), allowMalformed: true);
            final localNodeIdPrefix = myNodeId.length >= 4 ? myNodeId.substring(0, 4) : myNodeId.padRight(4, '0');
            if (remoteNodeIdStr == localNodeIdPrefix) {
              continue; // Drop self-advertisement completely
            }
          } catch (_) {}
        }

        // Read 64-bit hash as two big-endian uint32 words (Dart ByteData has no getUint64).
        final bd = ByteData.sublistView(remotePayload);
        final hashHigh = bd.getUint32(0, Endian.big);
        final hashLow = bd.getUint32(4, Endian.big);
        final remoteHashInt = (hashHigh << 32) | hashLow;

        hashToMac[remoteHashInt] = mac;

        final deadHashTime = deadHashUntil[remoteHashInt];
        if (deadHashTime != null && DateTime.now().isBefore(deadHashTime)) {
          continue;
        }

        final deadUntil = deadMacUntil[mac];
        if (deadUntil != null && DateTime.now().isBefore(deadUntil)) {
          continue;
        }

        // Passive mapping: if we already mapped this hash to a stable nodeId, remember its MAC.
        // IMPORTANT: do NOT refresh `localSeenNodes` purely from scan packets; Android can keep
        // emitting cached advertisements even after the peer app is killed.
        final mapped = hashToNodeId[remoteHashInt];
        if (mapped != null) {
          nodeIdToMac[mapped] = mac;
          final lastOk = lastFullSync[mac];
          if (lastOk != null &&
              DateTime.now().difference(lastOk) <=
                  const Duration(seconds: 15)) {
            localSeenNodes[mapped] = DateTime.now();
          }
        }

        // Update active neighbor table using the stable nodeId mapped from the advertised hash.
        final stableNodeId =
            hashToNodeId[remoteHashInt] ?? macToNodeId[mac];
        if (stableNodeId != null) {
          final lastOk = lastFullSync[mac];
          if (lastOk != null &&
              DateTime.now().difference(lastOk) <=
                  const Duration(seconds: 15)) {
            localSeenNodes[stableNodeId] = DateTime.now();
          }
        }
        final discoveredId = stableNodeId ?? mac;

        final last = _hashCooldowns[remoteHashInt];
        // Cooldown must be longer than _deadlistDurationForError to ensure the hash
        // path doesn't immediately retry a peer that's in the deadMacUntil window.
        // 8s matches the DISCONNECTED/timeout cooldown (4s) with enough headroom.
        if (last != null && DateTime.now().difference(last).inSeconds < 8) {
          continue;
        }

        final localHashBytes = _localHash;
        // Read local hash as 64-bit (two uint32 words) to match new 8-byte payload format.
        final localHashInt = (localHashBytes != null && localHashBytes.length >= 8)
            ? (ByteData.sublistView(localHashBytes).getUint32(0, Endian.big) << 32) |
              ByteData.sublistView(localHashBytes).getUint32(4, Endian.big)
            : null;

        // 20s anti-entropy heartbeat: even if hashes match, force a connection periodically.
        // Reduced from 50s so missed or failed syncs are retried within the test window.
        final lastSync = lastFullSync[mac];
        final needsAntiEntropy = lastSync == null ||
            DateTime.now().difference(lastSync).inSeconds > 20;

        // If hashes match and we don't need anti-entropy, skip and cooldown this hash.
        if (localHashInt != null && remoteHashInt == localHashInt && !needsAntiEntropy) {
          _hashCooldowns[remoteHashInt] = DateTime.now();
          continue;
        }

        onDiscovered(discoveredId);
        unawaited(_runMeshInitiatorHandshake(myNodeId, remoteHashInt, r.device));
      }
    });
  }

  /// Higher short node id acts as GATT client once per discovery stream event (collision avoidance).
  Future<void> _runMeshInitiatorHandshake(
    String myNodeId,
    int remoteHashInt,
    BluetoothDevice device,
  ) async {
    if (_isConnecting) return;
    // Even if the connection fails/cancels, keep a short cooldown for this remote hash so
    // we don't spam connect() attempts to stale/cached advertisers.
    _hashCooldowns[remoteHashInt] = DateTime.now();
    _isConnecting = true;
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
      // Send a compact 'offer' packet containing our local version vector.
      // The receiver's offer-handler (in ble_network_provider._attachNativeIncomingSync)
      // will compute only the rows we are missing and reply with a surgical 'delta'.
      // This replaces the old full-dump approach (empty remoteVector → every row sent)
      // which was timing out on every transfer due to 5,000+ row payloads.
      final myVector = await db.getVersionVector();
      final myHashInt = await db.getDatabaseHash();
      final myNodeId2 = myNodeId;
      debugPrint('📤 [DISCOVERY] Sending offer to $targetMac — vector has ${myVector.length} entries');
      final offerEnvelope = <String, dynamic>{
        'type': 'offer',
        'sender_id': myNodeId2,
        'sender_hash': myHashInt,
        'neighbors': currentNeighborIds,
        'vector': myVector,
      };
      final payload = zlib.encode(utf8.encode(jsonEncode(offerEnvelope)));
      final macAddress = device.remoteId.str;
      // Android mesh advertisers use Random Resolvable Addresses.
      // We pass isRandom: true to ensure the native layer uses the correct addressing mode.
      await _nativeMesh.sendPayload(macAddress, Uint8List.fromList(payload), isRandom: true);
      debugPrint('✅ [DISCOVERY] Offer sent to $targetMac (${payload.length} bytes) — awaiting delta reply');
      debugPrint('[BENCHMARK] TARGET_MAC:$targetMac | EVENT:OFFER_SENT | TIMESTAMP:${DateTime.now().millisecondsSinceEpoch}');
      // Only mark lastFullSync on a SUCCESSFUL offer send — do NOT set this on the error
      // path. If we set it even on failed sends, the 20s anti-entropy timer starts from a
      // failed attempt and the peer won't be retried until the window expires.
      lastFullSync[targetMac] = DateTime.now();
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
      final mapped = macToNodeId[targetMac];
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
      _isConnecting = false;
      _notifyConnectionPhase();
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
    await FlutterBluePlus.stopScan();
  }

  Future<void> stopAll() async {
    await stopScanning();
  }

}
