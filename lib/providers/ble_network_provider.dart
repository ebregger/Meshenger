import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../models/generated/mesh_data.pb.dart';
import '../services/ble_discovery_service.dart';
import '../services/ble_gatt_server.dart';
import '../utils/ble_permission_result.dart';
import '../utils/permissions_helper.dart';
import 'ble_network_state.dart';
import 'database_provider.dart';
import 'identity_provider.dart';

/// BLE adapter, permissions, and Phase 3 mesh discovery (scan + advertise).
class BleNetworkNotifier extends StateNotifier<BleNetworkState> {
  BleNetworkNotifier(this._ref)
      : _gattServer = BleGattServer(_ref),
        super(BleNetworkState.initial) {
    _discovery = BleDiscoveryService(
      _ref,
      onConnectionPhaseChanged: _handleMeshConnectionPhaseChanged,
    );
    Future<void>.microtask(_bootstrap);
  }

  final Ref _ref;
  late final BleDiscoveryService _discovery;
  final BleGattServer _gattServer;

  StreamSubscription<BluetoothAdapterState>? _adapterSub;
  StreamSubscription<List<TextMessage>>? _localMessagesSub;
  bool _meshSessionActive = false;
  String? _localNodeId;
  bool _primeLocalMessageCount = true;
  int _lastLocalMessageCount = 0;

  void _handleMeshConnectionPhaseChanged() {
    _publishRadioFlags();
  }

  void _publishRadioFlags() {
    final connecting = _discovery.isConnecting;
    final advertising = _meshSessionActive &&
        state.adapterStatus == BleAdapterStatus.on &&
        !connecting;
    if (connecting == state.radioMeshConnecting &&
        advertising == state.radioMeshAdvertising) {
      return;
    }
    state = state.copyWith(
      radioMeshConnecting: connecting,
      radioMeshAdvertising: advertising,
    );
  }

  Future<void> _bootstrap() async {
    final outcome = await PermissionsHelper.requestAndroidBlePermissions();
    if (outcome != BlePermissionRequestResult.granted) {
      state = state.copyWith(
        adapterStatus: BleAdapterStatus.unauthorized,
        lastPermissionResult: outcome,
      );
      return;
    }
    state = state.copyWith(lastPermissionResult: outcome);
    _attachAdapterListener();
  }

  void _attachAdapterListener() {
    unawaited(_adapterSub?.cancel());
    _adapterSub = FlutterBluePlus.adapterState.listen(_onAdapterState);
    _onAdapterState(FlutterBluePlus.adapterStateNow);
  }

  void _onAdapterState(BluetoothAdapterState value) {
    final wasOn = state.adapterStatus == BleAdapterStatus.on;
    final next = _mapAdapterState(value);
    state = state.copyWith(adapterStatus: next);
    final isOn = next == BleAdapterStatus.on;

    if (isOn && !wasOn) {
      unawaited(_startMeshSession());
    } else if (!isOn && wasOn) {
      unawaited(_stopMeshSession());
    }
    _publishRadioFlags();
  }

  static BleAdapterStatus _mapAdapterState(BluetoothAdapterState value) {
    switch (value) {
      case BluetoothAdapterState.on:
        return BleAdapterStatus.on;
      case BluetoothAdapterState.off:
      case BluetoothAdapterState.turningOff:
        return BleAdapterStatus.off;
      case BluetoothAdapterState.unauthorized:
        return BleAdapterStatus.unauthorized;
      case BluetoothAdapterState.unavailable:
        return BleAdapterStatus.off;
      case BluetoothAdapterState.unknown:
      case BluetoothAdapterState.turningOn:
        return BleAdapterStatus.unknown;
    }
  }

  Future<void> _attachLocalMessageQuickScanTrigger(String myId) async {
    await _localMessagesSub?.cancel();
    _primeLocalMessageCount = true;
    _lastLocalMessageCount = 0;
    final db = await _ref.read(databaseProvider.future);
    _localMessagesSub = db.watchTextMessages().listen((messages) {
      if (!_meshSessionActive) return;
      final self = _localNodeId;
      if (self == null || self != myId) return;

      final localCount =
          messages.where((m) => m.originNodeId == self).length;
      if (_primeLocalMessageCount) {
        _primeLocalMessageCount = false;
        _lastLocalMessageCount = localCount;
        return;
      }
      if (localCount <= _lastLocalMessageCount) {
        _lastLocalMessageCount = localCount;
        return;
      }
      _lastLocalMessageCount = localCount;

      if (_discovery.isConnecting) return;
      unawaited(_discovery.runQuickScan());
    });
  }

  Future<void> _startMeshSession() async {
    if (_meshSessionActive || state.adapterStatus != BleAdapterStatus.on) {
      return;
    }
    _meshSessionActive = true;
    try {
      final myId = await _ref.read(myNodeIdProvider.future);
      _localNodeId = myId;
      await _gattServer.start(myId);
      await _discovery.startScanning(
        myNodeId: myId,
        onDiscovered: _onPeerDiscovered,
      );
      await _attachLocalMessageQuickScanTrigger(myId);
      _publishRadioFlags();
    } catch (_) {
      _meshSessionActive = false;
      await _discovery.stopAll();
      await _gattServer.stop();
      await _localMessagesSub?.cancel();
      _localMessagesSub = null;
      _publishRadioFlags();
    }
  }

  void _onPeerDiscovered(String shortNodeId) {
    if (_discovery.isConnecting) return;

    final self = _localNodeId;
    if (self != null &&
        shortNodeId == BleDiscoveryService.shortNodeIdFromFull(self)) {
      return;
    }

    debugPrint('🎯 DISCOVERED MESH NODE: $shortNodeId');

    final ids = Set<String>.from(state.discoveredNodeIds)..add(shortNodeId);
    state = state.copyWith(discoveredNodeIds: ids);
  }

  Future<void> _stopMeshSession() async {
    _meshSessionActive = false;
    _localNodeId = null;
    await _localMessagesSub?.cancel();
    _localMessagesSub = null;
    await _discovery.stopAll();
    await _gattServer.stop();
    _publishRadioFlags();
  }

  /// Re-runs Android permission prompts (e.g. after returning from Settings).
  Future<BlePermissionRequestResult> retryAndroidPermissions() async {
    final outcome = await PermissionsHelper.requestAndroidBlePermissions();

    if (outcome != BlePermissionRequestResult.granted) {
      state = state.copyWith(
        adapterStatus: BleAdapterStatus.unauthorized,
        lastPermissionResult: outcome,
      );
      await _adapterSub?.cancel();
      _adapterSub = null;
      await _discovery.stopAll();
      await _gattServer.stop();
      await _localMessagesSub?.cancel();
      _localMessagesSub = null;
      _meshSessionActive = false;
      _publishRadioFlags();
      return outcome;
    }

    state = state.copyWith(lastPermissionResult: outcome);
    _attachAdapterListener();
    return outcome;
  }

  /// System UI to enable the Bluetooth radio when [BleAdapterStatus.off].
  Future<void> promptEnableBluetooth() async {
    try {
      await FlutterBluePlus.turnOn();
    } catch (_) {
      // User dismissed or platform rejected; [adapterState] will still update.
    }
  }

  /// Restarts GAP advertising with the persisted local node id.
  Future<void> startAdvertising() async {
    final myId = await _ref.read(myNodeIdProvider.future);
    await _gattServer.start(myId);
    _publishRadioFlags();
  }

  /// Subscribes to mesh scan results (typically already running when adapter is on).
  Future<void> startScanning() async {
    final myId = await _ref.read(myNodeIdProvider.future);
    await _discovery.startScanning(
      myNodeId: myId,
      onDiscovered: _onPeerDiscovered,
    );
    await _attachLocalMessageQuickScanTrigger(myId);
    _publishRadioFlags();
  }

  /// Stops scan + peripheral advertising.
  Future<void> stopNetwork() async {
    _meshSessionActive = false;
    await _localMessagesSub?.cancel();
    _localMessagesSub = null;
    await _discovery.stopAll();
    await _gattServer.stop();
    _publishRadioFlags();
  }

  @override
  void dispose() {
    unawaited(_adapterSub?.cancel());
    unawaited(_localMessagesSub?.cancel());
    unawaited(_discovery.stopAll());
    unawaited(_gattServer.stop());
    super.dispose();
  }
}

/// Global BLE network / adapter state.
final bleNetworkProvider =
    StateNotifierProvider<BleNetworkNotifier, BleNetworkState>(
  (ref) => BleNetworkNotifier(ref),
);
