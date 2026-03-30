import 'package:flutter/foundation.dart' show immutable;

import '../utils/ble_permission_result.dart';

/// High-level radio + policy state for the BLE stack (adapter-level).
enum BleAdapterStatus {
  /// Initial or transitional (e.g. turning on).
  unknown,

  /// Bluetooth is available and powered on.
  on,

  /// Powered off or hardware unavailable for use.
  off,

  /// OS denied Bluetooth access (permissions or user toggle).
  unauthorized,
}

@immutable
class BleNetworkState {
  const BleNetworkState({
    required this.adapterStatus,
    this.lastPermissionResult,
    required this.discoveredNodeIds,
    this.radioMeshConnecting = false,
    this.radioMeshAdvertising = false,
  });

  final BleAdapterStatus adapterStatus;

  /// Android permission outcome; null before the first request finishes.
  final BlePermissionRequestResult? lastPermissionResult;

  /// Peer mesh node IDs observed via scan manufacturer payloads.
  final Set<String> discoveredNodeIds;

  /// Central-role GATT mesh sync in progress (scanner paused / ACL up).
  final bool radioMeshConnecting;

  /// Mesh session active and peripheral advertising (not mid-handshake).
  final bool radioMeshAdvertising;

  static final initial = BleNetworkState(
    adapterStatus: BleAdapterStatus.unknown,
    lastPermissionResult: null,
    discoveredNodeIds: <String>{},
    radioMeshConnecting: false,
    radioMeshAdvertising: false,
  );

  BleNetworkState copyWith({
    BleAdapterStatus? adapterStatus,
    BlePermissionRequestResult? lastPermissionResult,
    Set<String>? discoveredNodeIds,
    bool? radioMeshConnecting,
    bool? radioMeshAdvertising,
  }) {
    return BleNetworkState(
      adapterStatus: adapterStatus ?? this.adapterStatus,
      lastPermissionResult:
          lastPermissionResult ?? this.lastPermissionResult,
      discoveredNodeIds: discoveredNodeIds ?? this.discoveredNodeIds,
      radioMeshConnecting: radioMeshConnecting ?? this.radioMeshConnecting,
      radioMeshAdvertising: radioMeshAdvertising ?? this.radioMeshAdvertising,
    );
  }
}
