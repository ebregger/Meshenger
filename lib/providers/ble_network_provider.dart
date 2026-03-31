import 'dart:async';
import 'dart:convert';
import 'dart:io' show zlib;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, listEquals;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../models/generated/mesh_data.pb.dart';
import '../services/ble_discovery_service.dart';
import '../services/native_mesh_service.dart';
import '../utils/ble_permission_result.dart';
import '../utils/permissions_helper.dart';
import 'ble_network_state.dart';
import 'database_provider.dart';
import 'identity_provider.dart';

/// BLE adapter, permissions, and Phase 3 mesh discovery (scan + advertise).
class BleNetworkNotifier extends StateNotifier<BleNetworkState> {
  BleNetworkNotifier(this._ref)
      : super(BleNetworkState.initial) {
    _discovery = BleDiscoveryService(
      _ref,
      onConnectionPhaseChanged: _handleMeshConnectionPhaseChanged,
    );
    Future<void>.microtask(_bootstrap);
  }

  final Ref _ref;
  late final BleDiscoveryService _discovery;
  final NativeMeshService _nativeMesh = NativeMeshService();

  StreamSubscription<BluetoothAdapterState>? _adapterSub;
  StreamSubscription<List<TextMessage>>? _localMessagesSub;
  StreamSubscription<Uint8List>? _nativePayloadSub;
  final List<int> _incomingBuffer = <int>[];
  bool _meshSessionActive = false;
  String? _localNodeId;
  bool _primeMessageListLength = true;
  String? _lastAdvertisedHashB64;

  /// NodeID -> its advertised physical neighbors (gossip-based topology).
  final Map<String, Set<String>> _meshTopology = {};

  /// Periodically refreshes UI classification from the Active Neighbor Table.
  Timer? _neighborRefreshTimer;

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

  void _refreshNeighborClassification() {
    if (!_meshSessionActive) return;

    final direct = _discovery.currentNeighborIds.toSet();
    final self = _localNodeId;

    final indirect = <String>{};
    for (final neighbors in _meshTopology.values) {
      for (final id in neighbors) {
        if (self != null && id == self) continue;
        if (!direct.contains(id)) {
          indirect.add(id);
        }
      }
    }

    state = state.copyWith(
      directNeighborIds: direct,
      indirectNeighborIds: indirect,
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
    _primeMessageListLength = true;
    final db = await _ref.read(databaseProvider.future);
    _localMessagesSub = db.watchTextMessages().listen((messages) {
      if (!_meshSessionActive) return;
      final self = _localNodeId;
      if (self == null || self != myId) return;

      if (_primeMessageListLength) {
        _primeMessageListLength = false;
        return;
      }

      Future<void>.microtask(() async {
        try {
          final hashBytes = await db.getDatabaseHashBytes();
          final b64 = base64Encode(hashBytes);
          if (b64 != _lastAdvertisedHashB64) {
            _lastAdvertisedHashB64 = b64;
            await _nativeMesh.updateAdvertiserHash(hashBytes);
            _discovery.setLocalHash(hashBytes);
          }
        } catch (e, st) {
          debugPrint('NATIVE MESH HASH UPDATE FAILED: $e\n$st');
        }
      });

      // Scanner stays on; advertiser hash update is enough.
    });
  }

  Future<void> _attachNativeIncomingSync() async {
    await _nativePayloadSub?.cancel();
    _nativePayloadSub = _nativeMesh.incomingPayloads.listen((chunk) {
      final eofMarker = utf8.encode('||EOF||');

      if (chunk.length == eofMarker.length && listEquals(chunk, eofMarker)) {
        if (_incomingBuffer.isEmpty) return;

        Future<void>.microtask(() async {
          try {
            final decompressed = zlib.decode(_incomingBuffer);
            final String jsonStr = utf8.decode(decompressed);
            final decodedJson = jsonDecode(jsonStr);
            if (decodedJson is! Map) return;
            final root = Map<String, dynamic>.from(decodedJson);
            final type = root['type'] as String?;

            final db = await _ref.read(databaseProvider.future);

            if (type == 'offer') {
              final senderHash = root['sender_hash'] as String?;
              final senderId = root['sender_id'] as String?;
              final neighborsRaw = root['neighbors'];
              final vectorRaw = root['vector'];

              // 1) Store topology for the sender (offer gossip).
              if (senderId != null) {
                final neighborSet = <String>{};
                if (neighborsRaw is List) {
                  for (final n in neighborsRaw) {
                    if (n is String) neighborSet.add(n);
                  }
                }
                _meshTopology[senderId] = neighborSet;

                // Also teach neighbor-table routing: advertised hash -> node id.
                if (senderHash != null) {
                  BleDiscoveryService.hashToNodeId[senderHash] = senderId;
                }
                _refreshNeighborClassification();
              }

              // 2) Respond with an offer delta (surgical changeset).
              if (senderHash == null || vectorRaw is! Map) return;
              final remoteVector = Map<String, dynamic>.from(vectorRaw);

              debugPrint('🤝 Received Offer. Calculating Delta...');
              final targetMac = BleDiscoveryService.hashToMac[senderHash];
              if (targetMac == null) {
                debugPrint(
                  '⚠️ Offer: no hash route for sender_hash=$senderHash',
                );
                return;
              }

              final delta = await db.getDeltaChangeset(remoteVector);

              final ourHashBytes = await db.getDatabaseHashBytes();
              final ourSenderHash = base64Encode(ourHashBytes);

              // Always send back a delta envelope so the initiator receives our
              // neighbor gossip even when no changes are needed.
              final deltaEnvelope = <String, dynamic>{
                'type': 'delta',
                'sender_id': db.localNodeId,
                'sender_hash': ourSenderHash,
                'neighbors': _discovery.currentNeighborIds,
                'data': delta,
              };
              final outBytes = zlib.encode(
                utf8.encode(jsonEncode(deltaEnvelope)),
              );
              await _nativeMesh.sendPayload(
                targetMac,
                Uint8List.fromList(outBytes),
              );

              if (delta.isNotEmpty) {
                debugPrint('🚀 Sent Surgical Delta to $targetMac');
              } else {
                debugPrint('📨 Sent Gossip Delta to $targetMac');
              }
              return;
            }

            if (type == 'delta' || type == null) {
              // Update topology for delta gossip.
              if (type == 'delta') {
                final senderHash = root['sender_hash'] as String?;
                final senderId = root['sender_id'] as String?;
                final neighborsRaw = root['neighbors'];

                if (senderId != null) {
                  final neighborSet = <String>{};
                  if (neighborsRaw is List) {
                    for (final n in neighborsRaw) {
                      if (n is String) neighborSet.add(n);
                    }
                  }
                  _meshTopology[senderId] = neighborSet;
                  if (senderHash != null) {
                    BleDiscoveryService.hashToNodeId[senderHash] = senderId;
                  }
                  _refreshNeighborClassification();
                }
              }

              final dataRaw = root['data'];
              if (dataRaw is! Map) return;
              final changeset = Map<String, dynamic>.from(dataRaw);

              debugPrint('📥 Merging Delta Payload...');
              await db.mergeSyncChangeset(changeset);

              try {
                final hashBytes = await db.getDatabaseHashBytes();
                final b64 = base64Encode(hashBytes);
                if (b64 != _lastAdvertisedHashB64) {
                  _lastAdvertisedHashB64 = b64;
                  await _nativeMesh.updateAdvertiserHash(hashBytes);
                  _discovery.setLocalHash(hashBytes);
                }
              } catch (e, st) {
                debugPrint('NATIVE MESH HASH UPDATE FAILED: $e\n$st');
              }
            }
          } catch (e) {
            debugPrint('Mesh merge error: $e');
          } finally {
            _incomingBuffer.clear();
          }
        });
      } else {
        _incomingBuffer.addAll(chunk);
      }
    });
  }

  Future<void> _startMeshSession() async {
    if (_meshSessionActive || state.adapterStatus != BleAdapterStatus.on) {
      return;
    }
    _meshSessionActive = true;
    _meshTopology.clear();
    state = state.copyWith(
      discoveredNodeIds: const <String>{},
      directNeighborIds: const <String>{},
      indirectNeighborIds: const <String>{},
    );
    try {
      final myId = await _ref.read(myNodeIdProvider.future);
      _localNodeId = myId;
      final db = await _ref.read(databaseProvider.future);
      final hashBytes = await db.getDatabaseHashBytes();
      _lastAdvertisedHashB64 = base64Encode(hashBytes);
      _discovery.setLocalHash(hashBytes);
      await _nativeMesh.startNativeServer(hashBytes);
      await _attachNativeIncomingSync();
      await _discovery.startScanning(
        myNodeId: myId,
        onDiscovered: _onPeerDiscovered,
      );
      await _attachLocalMessageQuickScanTrigger(myId);
      _publishRadioFlags();
      _refreshNeighborClassification();
      _neighborRefreshTimer?.cancel();
      _neighborRefreshTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => _refreshNeighborClassification(),
      );
    } catch (_) {
      _meshSessionActive = false;
      await _discovery.stopAll();
      _neighborRefreshTimer?.cancel();
      _neighborRefreshTimer = null;
      await _nativePayloadSub?.cancel();
      _nativePayloadSub = null;
      await _localMessagesSub?.cancel();
      _localMessagesSub = null;
      _publishRadioFlags();
    }
  }

  void _onPeerDiscovered(String shortNodeId) {
    if (_discovery.isConnecting) return;

    final self = _localNodeId;
    if (self != null &&
        (shortNodeId == self ||
            shortNodeId == BleDiscoveryService.shortNodeIdFromFull(self))) {
      return;
    }

    debugPrint('🎯 DISCOVERED MESH NODE: $shortNodeId');

    final ids = Set<String>.from(state.discoveredNodeIds)..add(shortNodeId);
    state = state.copyWith(discoveredNodeIds: ids);
  }

  Future<void> _stopMeshSession() async {
    _meshSessionActive = false;
    _localNodeId = null;
    _neighborRefreshTimer?.cancel();
    _neighborRefreshTimer = null;
    _meshTopology.clear();
    state = state.copyWith(
      directNeighborIds: const <String>{},
      indirectNeighborIds: const <String>{},
    );
    await _nativePayloadSub?.cancel();
    _nativePayloadSub = null;
    await _localMessagesSub?.cancel();
    _localMessagesSub = null;
    await _discovery.stopAll();
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
      await _nativePayloadSub?.cancel();
      _nativePayloadSub = null;
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
    final db = await _ref.read(databaseProvider.future);
    final hashBytes = await db.getDatabaseHashBytes();
    _lastAdvertisedHashB64 = base64Encode(hashBytes);
    _discovery.setLocalHash(hashBytes);
    await _nativeMesh.startNativeServer(hashBytes);
    await _attachNativeIncomingSync();
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
    await _nativePayloadSub?.cancel();
    _nativePayloadSub = null;
    await _localMessagesSub?.cancel();
    _localMessagesSub = null;
    await _discovery.stopAll();
    _publishRadioFlags();
  }

  @override
  void dispose() {
    unawaited(_adapterSub?.cancel());
    unawaited(_nativePayloadSub?.cancel());
    unawaited(_localMessagesSub?.cancel());
    unawaited(_discovery.stopAll());
    super.dispose();
  }
}

/// Global BLE network / adapter state.
final bleNetworkProvider =
    StateNotifierProvider<BleNetworkNotifier, BleNetworkState>(
  (ref) => BleNetworkNotifier(ref),
);
