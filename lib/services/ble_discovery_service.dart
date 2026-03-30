import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform, zlib;

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants/ble_constants.dart';
import '../providers/database_provider.dart';

/// Byte budget in the ADV payload: we only send a fixed 8-char "Short Node ID".
const int meshShortNodeIdLength = 8;

/// Mesh discovery: central scanning via [FlutterBluePlus]; GAP advertise lives in [BleGattServer].
class BleDiscoveryService {
  BleDiscoveryService(
    this._ref, {
    this.onConnectionPhaseChanged,
  });

  final Ref _ref;
  final void Function()? onConnectionPhaseChanged;

  /// Lets the ACL/GATT stack settle so immediate [BluetoothDevice.discoverServices] is less likely
  /// to trip pairing heuristics on some Android OEM stacks.
  static const Duration _kPostConnectSettle = Duration(milliseconds: 500);
  static const Duration _kPostMtuSettle = Duration(milliseconds: 500);
  static const Duration _kPreStopScanPause = Duration(milliseconds: 200);
  static const Duration _kPostStopScanSettle = Duration(milliseconds: 500);
  static const Duration _kHandshakeCooldown = Duration(seconds: 10);
  static const Duration _kQuickScanWindow = Duration(seconds: 10);
  static const Duration _kResumeScanDelay = Duration(seconds: 2);
  static const Duration _kPreSyncDbSettle = Duration(seconds: 1);

  StreamSubscription<List<ScanResult>>? _scanSub;
  /// When true, scan callbacks must not start another handshake or fire discovery churn.
  bool _isConnecting = false;
  /// False after [stopScanning]/[stopAll] so [finally] does not restart scanning.
  bool _wantsScan = false;
  final Map<String, DateTime> _handshakeCooldownUntil = {};

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

  /// First [meshShortNodeIdLength] characters of [fullNodeId] (fits MAN data budget).
  static String shortNodeIdFromFull(String fullNodeId) {
    if (fullNodeId.isEmpty) return '';
    if (fullNodeId.length < meshShortNodeIdLength) {
      return fullNodeId;
    }
    return fullNodeId.substring(0, meshShortNodeIdLength);
  }

  bool _isPeerOnCooldown(String shortId) {
    final until = _handshakeCooldownUntil[shortId];
    if (until == null) return false;
    if (DateTime.now().isAfter(until)) {
      _handshakeCooldownUntil.remove(shortId);
      return false;
    }
    return true;
  }

  void _cooldownPeer(String shortId) {
    _handshakeCooldownUntil[shortId] =
        DateTime.now().add(_kHandshakeCooldown);
  }

  /// Scans for advertisers that include [meshServiceUuid] in the payload.
  Future<void> startScanning({
    required String myNodeId,
    required void Function(String shortNodeId) onDiscovered,
  }) async {
    _isConnecting = false;
    _handshakeCooldownUntil.clear();
    _notifyConnectionPhase();
    debugPrint('🔓 BLE scan session reset (lock + cooldowns cleared)');

    _wantsScan = true;
    await _scanSub?.cancel();

    await FlutterBluePlus.startScan(
      withServices: [meshServiceUuid],
    );

    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        if (_isConnecting) continue;
        if (!advertisesMeshService(r)) continue;

        final id = decodeMeshNodeId(r.advertisementData.manufacturerData);
        if (id == null || id.isEmpty) continue;
        if (id == shortNodeIdFromFull(myNodeId)) continue;

        onDiscovered(id);
        unawaited(_runMeshInitiatorHandshake(myNodeId, id, r.device));
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
    if (shortNodeIdFromFull(myNodeId).compareTo(remoteShortId) <= 0) {
      return;
    }
    if (_isPeerOnCooldown(remoteShortId)) return;

    _isConnecting = true;
    _notifyConnectionPhase();
    try {
      await Future<void>.delayed(_kPreStopScanPause);

      await FlutterBluePlus.stopScan();
      await Future<void>.delayed(_kPostStopScanSettle);

      await device.connect(
        license: License.free,
        autoConnect: false,
        mtu: null,
      );
      await Future<void>.delayed(_kPostConnectSettle);

      if (!kIsWeb && Platform.isAndroid) {
        await device.requestMtu(512);
        await Future<void>.delayed(_kPostMtuSettle);
      }

      // Only touch mesh GATT; never subscribe (no setNotifyValue) — write-only sync.
      final services = await device.discoverServices();
      final chr = _findMeshCharacteristic(services);
      if (chr != null) {
        // Let local CRDT writes (e.g. just-sent message) finish before exporting.
        await Future<void>.delayed(_kPreSyncDbSettle);
        // Phase 3 handoff: compress changeset to fit within the 512-byte MTU pipe.
        final db = await _ref.read(databaseProvider.future);
        final changeset = await db.getSyncChangeset(null);
        final payload = zlib.encode(utf8.encode(jsonEncode(changeset)));
        try {
          await chr.write(
            payload,
            withoutResponse: false,
            allowLongWrite: false,
          );
        } catch (e) {
          debugPrint('🔥 WRITE CRASHED: $e');
          return;
        }

        await Future<void>.delayed(const Duration(milliseconds: 500));
        debugPrint('🔍 ATTEMPTING READ FROM PERIPHERAL...');
        try {
          final responseBytes = await chr.read();
          if (responseBytes.isNotEmpty) {
            try {
              final decompressed = zlib.decode(responseBytes);
              final responseJson = utf8.decode(decompressed);
              final raw = jsonDecode(responseJson);
              if (raw is Map) {
                final responseMap = Map<String, dynamic>.from(raw);
                final db2 = await _ref.read(databaseProvider.future);
                await db2.mergeSyncChangeset(responseMap);
              }
            } catch (e) {
              debugPrint('🔥 DECOMPRESSION FAILED: $e');
            }
          }
        } catch (e) {
          debugPrint('❌ READ FAILED: $e');
        }
      }
    } catch (_) {
      _cooldownPeer(remoteShortId);
    } finally {
      if (device.isConnected) {
        try {
          await device.disconnect();
        } catch (_) {}
      }
      _isConnecting = false;
      _notifyConnectionPhase();
      await Future<void>.delayed(_kResumeScanDelay);
      if (_wantsScan) {
        await FlutterBluePlus.startScan(
          withServices: [meshServiceUuid],
        );
      }
    }
  }

  /// Burst scan to pick up peers after a local DB write; resumes continuous scan after.
  Future<void> runQuickScan() async {
    if (!_wantsScan || _isConnecting) return;
    try {
      await FlutterBluePlus.startScan(
        withServices: [meshServiceUuid],
        timeout: _kQuickScanWindow,
      );
    } catch (_) {}
    await Future<void>.delayed(_kQuickScanWindow);
    if (_wantsScan && !_isConnecting) {
      try {
        await FlutterBluePlus.startScan(
          withServices: [meshServiceUuid],
        );
      } catch (_) {}
    }
  }

  static BluetoothCharacteristic? _findMeshCharacteristic(
    List<BluetoothService> services,
  ) {
    for (final s in services) {
      if (s.serviceUuid.str128 != meshServiceUuid.str128) continue;
      for (final c in s.characteristics) {
        if (c.characteristicUuid.str128 == meshCharacteristicUuid.str128) {
          return c;
        }
      }
    }
    return null;
  }

  Future<void> stopScanning() async {
    _wantsScan = false;
    await _scanSub?.cancel();
    _scanSub = null;
    await FlutterBluePlus.stopScan();
  }

  Future<void> stopAll() async {
    await stopScanning();
  }

  /// Decodes the Short Node ID (UTF-8, up to [meshShortNodeIdLength] chars).
  static String? decodeMeshNodeId(Map<int, List<int>> manufacturerData) {
    final raw = manufacturerData[meshManufacturerId];
    if (raw == null || raw.isEmpty) return null;
    final decoded = utf8.decode(raw, allowMalformed: true).trim();
    if (decoded.isEmpty) return null;
    final runes = decoded.runes.take(meshShortNodeIdLength).toList();
    return String.fromCharCodes(runes);
  }
}
