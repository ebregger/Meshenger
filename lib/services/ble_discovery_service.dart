import 'dart:async';
import 'dart:convert';
import 'dart:io' show zlib;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

  /// Neighbor IDs seen in the last 60 seconds (expired entries are pruned).
  List<String> get currentNeighborIds {
    final now = DateTime.now();
    localSeenNodes.removeWhere((_, lastSeen) {
      return now.difference(lastSeen) > const Duration(seconds: 60);
    });
    final ids = localSeenNodes.keys.toList(growable: false);
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
    return Uint8List.fromList(raw);
  }

  bool _isLikelyNativeMeshAdvert(ScanResult r) {
    // Only accept devices running our mesh program:
    // they must advertise our manufacturer payload (0xFFE0) containing a 4-byte hash.
    final raw = r.advertisementData.manufacturerData[meshManufacturerId];
    return raw != null && raw.length >= 4;
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
    _notifyConnectionPhase();
    debugPrint('🔓 BLE scan session reset (lock + cooldowns cleared)');

    await _scanSub?.cancel();

    // Do not use [withServices] filtering here: some Android stacks omit/truncate 128-bit UUIDs
    // when the advertisement includes a device name. We'll filter manually in the listener.
    await FlutterBluePlus.startScan();

    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        if (_isConnecting) continue;
        if (!_isLikelyNativeMeshAdvert(r)) continue;

        final remoteHash = _tryGetRemoteHash(r);
        if (remoteHash == null) continue;
        if (remoteHash.length < 4) continue;
        final remoteHashInt =
            ByteData.sublistView(remoteHash).getUint32(0, Endian.big);
        final mac = r.device.remoteId.str;
        hashToMac[remoteHashInt] = mac;

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
                  const Duration(seconds: 60)) {
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
                  const Duration(seconds: 60)) {
            localSeenNodes[stableNodeId] = DateTime.now();
          }
        }
        final discoveredId = stableNodeId ?? mac;

        final last = _hashCooldowns[remoteHashInt];
        if (last != null && DateTime.now().difference(last).inSeconds < 10) {
          continue;
        }

        final localHashBytes = _localHash;
        final localHashInt = (localHashBytes != null && localHashBytes.length >= 4)
            ? ByteData.sublistView(localHashBytes).getUint32(0, Endian.big)
            : null;

        // 50s anti-entropy heartbeat: even if hashes match, force a connection periodically.
        final lastSync = lastFullSync[mac];
        final needsAntiEntropy = lastSync == null ||
            DateTime.now().difference(lastSync).inSeconds > 50;

        // If hashes match and we don't need anti-entropy, skip and cooldown this hash.
        if (localHashInt != null && remoteHashInt == localHashInt && !needsAntiEntropy) {
          _hashCooldowns[remoteHashInt] = DateTime.now();
          continue;
        }

        if (_localHash != null && _localHash!.length >= 4) {
          final localU32 = ByteData.sublistView(_localHash!)
              .getUint32(0, Endian.big);
          if (remoteHashInt == localU32) {
            // Hashes match; anti-entropy handled above.
          }
        }

        _hashCooldowns[remoteHashInt] = DateTime.now();

        debugPrint('🎯 DISCOVERED MESH NODE: $discoveredId');
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
    try {
      final targetMac = device.remoteId.str;
      final db = await _ref.read(databaseProvider.future);
      final vector = await db.getVersionVector();
      final myHashInt = await db.getDatabaseHash();
      final envelope = <String, dynamic>{
        'type': 'offer',
        // Use application-layer node UUID (IdentityService) so it matches `users.mesh_node_id`
        // and `messages.origin_node_id` for display-name resolution.
        'sender_id': myNodeId,
        'sender_hash': myHashInt,
        'vector': vector,
        'neighbors': currentNeighborIds,
      };
      final payload = zlib.encode(utf8.encode(jsonEncode(envelope)));
      final macAddress = device.remoteId.str;
      await _nativeMesh.sendPayload(macAddress, Uint8List.fromList(payload));
      // Mark successful anti-entropy sync time.
      lastFullSync[targetMac] = DateTime.now();
    } catch (_) {
      // Cooldown is handled at scan time by advertised remote hash.
      _hashCooldowns[remoteHashInt] = DateTime.now();
      final targetMac = device.remoteId.str;
      // If we can't connect, treat this as stale/cached advertising for a while.
      deadMacUntil[targetMac] =
          DateTime.now().add(const Duration(seconds: 60));
      // Best-effort: remove from direct presence so UI can drop it.
      final mapped = macToNodeId[targetMac];
      if (mapped != null) {
        localSeenNodes.remove(mapped);
      }
    } finally {
      if (device.isConnected) {
        try {
          await device.disconnect();
        } catch (_) {}
      }
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
