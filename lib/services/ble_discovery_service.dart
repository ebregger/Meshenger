import 'dart:async';
import 'dart:convert';
import 'dart:io' show zlib;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, listEquals;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants/ble_constants.dart';
import '../providers/database_provider.dart';
import 'native_mesh_service.dart';

/// Byte budget in the ADV payload: we only send a fixed 8-char "Short Node ID".
const int meshShortNodeIdLength = 8;

/// Mesh discovery: central scanning via [FlutterBluePlus]; GAP advertise lives in [BleGattServer].
class BleDiscoveryService {
  /// Advertised DB hash (base64) → last seen BLE [BluetoothDevice.remoteId] for offer replies.
  static final Map<String, String> hashToMac = {};

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
  final Map<String, DateTime> _hashCooldowns = {};

  /// Exposed for UI / notifier guards while a GATT sync is in flight.
  bool get isConnecting => _isConnecting;

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
    // Check for our specific manufacturer data flag
    final remoteHashRaw = r.advertisementData.manufacturerData[meshManufacturerId];
    if (remoteHashRaw != null && remoteHashRaw.isNotEmpty) {
      final local = _localHash;
      if (local != null && listEquals(remoteHashRaw, local)) {
        return false;
      }
      return true;
    }

    // Fallback: Safe UUID string comparison
    for (final guid in r.advertisementData.serviceUuids) {
      if (guid.toString().toLowerCase() ==
          meshServiceUuid.str128.toLowerCase()) {
        return true;
      }
    }
    return false;
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
        final remoteHashStr = base64Encode(remoteHash);
        hashToMac[remoteHashStr] = r.device.remoteId.str;
        final last = _hashCooldowns[remoteHashStr];
        if (last != null && DateTime.now().difference(last).inSeconds < 10) {
          continue;
        }
        _hashCooldowns[remoteHashStr] = DateTime.now();

        debugPrint('🎯 DISCOVERED MESH NODE: ${r.device.remoteId.str}');
        onDiscovered(r.device.remoteId.str);
        unawaited(_runMeshInitiatorHandshake(myNodeId, remoteHashStr, r.device));
      }
    });
  }

  /// Higher short node id acts as GATT client once per discovery stream event (collision avoidance).
  Future<void> _runMeshInitiatorHandshake(
    String myNodeId,
    String remoteShortId,
    BluetoothDevice device,
  ) async {
    if (_isConnecting) return;
    // Even if the connection fails/cancels, keep a short cooldown for this remote hash so
    // we don't spam connect() attempts to stale/cached advertisers.
    _hashCooldowns[remoteShortId] = DateTime.now();
    _isConnecting = true;
    _notifyConnectionPhase();
    try {
      final db = await _ref.read(databaseProvider.future);
      final vector = await db.getVersionVector();
      final myHashBytes = await db.getDatabaseHash();
      final envelope = <String, dynamic>{
        'type': 'offer',
        'sender_id': db.localNodeId,
        'sender_hash': base64Encode(myHashBytes),
        'vector': vector,
      };
      final payload = zlib.encode(utf8.encode(jsonEncode(envelope)));
      final macAddress = device.remoteId.str;
      await _nativeMesh.sendPayload(macAddress, Uint8List.fromList(payload));
    } catch (_) {
      // Cooldown is handled at scan time by advertised remote hash.
      _hashCooldowns[remoteShortId] = DateTime.now();
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
