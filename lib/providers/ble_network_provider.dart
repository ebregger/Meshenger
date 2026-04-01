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
  StreamSubscription<List<NodeProfile>>? _localProfilesSub;
  StreamSubscription<IncomingBleChunk>? _nativePayloadSub;
  final Map<String, List<int>> _incomingBuffersByMac = <String, List<int>>{};
  bool _meshSessionActive = false;
  String? _localNodeId;
  bool _primeMessageListLength = true;
  String? _lastAdvertisedHashB64;

  int? _lastLocalProfileTimestampMs;
  final Map<String, String> _nameById = <String, String>{};

  /// NodeID -> its advertised physical neighbors (gossip-based topology).
  final Map<String, Set<String>> _meshTopology = {};

  /// Stable nodeId -> last time we've heard about it via gossip (presence window).
  final Map<String, DateTime> networkLastSeen = {};

  /// Periodically refreshes UI classification from the Active Neighbor Table.
  Timer? _neighborRefreshTimer;

  final StreamController<void> _presenceBump =
      StreamController<void>.broadcast();

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

  String? _findRoute(String targetId, Set<String> directNodes) {
    if (directNodes.contains(targetId)) return null;

    // 1-Hop check
    for (final d in directNodes) {
      if (_meshTopology[d]?.contains(targetId) == true) return d;
    }

    // Multi-hop BFS: track which direct node is acting as the bridge.
    final visited = Set<String>.from(directNodes);
    final queue = directNodes.map((d) => MapEntry(d, d)).toList(growable: true);

    while (queue.isNotEmpty) {
      final curr = queue.removeAt(0);
      final neighbors = _meshTopology[curr.key] ?? const <String>{};

      if (neighbors.contains(targetId)) return curr.value;

      for (final n in neighbors) {
        if (!visited.contains(n)) {
          visited.add(n);
          queue.add(MapEntry(n, curr.value));
        }
      }
    }
    return null;
  }

  Stream<List<MeshNodeState>> watchActivePeers() async* {
    while (true) {
      // Either periodic tick or an explicit bump (e.g. after payload receive).
      await Future.any([
        Future<void>.delayed(const Duration(seconds: 1)),
        _presenceBump.stream.first,
      ]);

      final now = DateTime.now();
      final out = <MeshNodeState>[];

      final self = _localNodeId;
      final nameById = Map<String, String>.from(_nameById);

      // Retain presence entries long enough for tombstones to render.
      BleDiscoveryService.localSeenNodes.removeWhere((_, t) {
        return now.difference(t).inSeconds > 85;
      });

      // Retain gossip entries long enough for tombstones to render.
      networkLastSeen.removeWhere((_, t) {
        return now.difference(t).inSeconds > 85;
      });

      final directNodes = BleDiscoveryService.localSeenNodes.keys.toSet();
      final allUsers = <String>{
        ...BleDiscoveryService.localSeenNodes.keys,
        ...networkLastSeen.keys,
      };

      final remotePeerIds =
          allUsers.where((id) => self == null || id != self).toList();
      final singleRemotePeerTopology = remotePeerIds.length == 1;

      for (final id in allUsers) {
        if (self != null && id == self) continue;

        final localTime = BleDiscoveryService.localSeenNodes[id];
        final networkTime = networkLastSeen[id];

        final secondsSinceLocal =
            localTime != null ? now.difference(localTime).inSeconds : 9999;
        final secondsSinceNetwork =
            networkTime != null ? now.difference(networkTime).inSeconds : 9999;

        PeerStatus? status;

        if (singleRemotePeerTopology) {
          // Exactly one other node in presence maps: there is no multi-hop path.
          // Gossip can refresh [networkLastSeen] (e.g. via `neighbors` lists) without
          // refreshing [localSeenNodes], which previously produced spurious INDIRECT.
          if (secondsSinceLocal <= 60 || secondsSinceNetwork <= 60) {
            status = PeerStatus.direct;
          } else if (secondsSinceLocal <= 75 || secondsSinceNetwork <= 75) {
            status = PeerStatus.disconnected;
          }
        } else {
          // 0 to 60 Seconds: Node is Active (Green or Yellow)
          if (secondsSinceLocal <= 60) {
            status = PeerStatus.direct;
          } else if (secondsSinceNetwork <= 60) {
            // Pruning-race guard: ignore "microscopic" self-gossip near disconnect.
            if (localTime == null ||
                networkTime!.difference(localTime).inSeconds > 2) {
              status = PeerStatus.indirect;
            }
          }
          // 61 to 75 Seconds: Node is Offline/Tombstoned (Gray)
          else if (secondsSinceLocal <= 75 || secondsSinceNetwork <= 75) {
            status = PeerStatus.disconnected;
          }
        }

        if (status == null) continue;

        var latestTime = localTime ?? DateTime.fromMillisecondsSinceEpoch(0);
        if (networkTime != null && networkTime.isAfter(latestTime)) {
          latestTime = networkTime;
        }

        final name = nameById[id] ?? (id.length <= 8 ? id : id.substring(0, 8));
        final mac = BleDiscoveryService.nodeIdToMac[id];
        final routeViaId =
            status == PeerStatus.indirect ? _findRoute(id, directNodes) : null;
        final routeViaName =
            routeViaId == null ? null : (nameById[routeViaId] ?? routeViaId);

        out.add(
          MeshNodeState(
            id: id,
            name: name,
            macAddress: mac,
            status: status,
            lastSeen: latestTime,
            routeViaId: routeViaId,
            routeViaName: routeViaName,
          ),
        );
      }

      out.sort((a, b) => a.name.compareTo(b.name));
      yield out;
    }
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

  Future<void> _attachLocalUserProfileHashUpdateTrigger(String myId) async {
    await _localProfilesSub?.cancel();
    _lastLocalProfileTimestampMs = null;
    final db = await _ref.read(databaseProvider.future);

    _localProfilesSub = db.watchNodeProfiles().listen((profiles) {
      if (!_meshSessionActive) return;
      _nameById
        ..clear()
        ..addAll({
          for (final p in profiles)
            if (p.displayName.trim().isNotEmpty) p.nodeId: p.displayName.trim(),
        });

      final matches = profiles.where((p) => p.nodeId == myId).toList();
      if (matches.isEmpty) return;
      final profile = matches.first;

      final tsMs = profile.timestamp.toInt();
      if (_lastLocalProfileTimestampMs == tsMs) return;
      _lastLocalProfileTimestampMs = tsMs;

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
    });
  }

  Future<void> _attachNativeIncomingSync() async {
    await _nativePayloadSub?.cancel();
    _nativePayloadSub = _nativeMesh.incomingPayloads.listen((incoming) {
      final eofMarker = utf8.encode('||EOF||');
      final senderMac = incoming.macAddress;
      final chunk = incoming.bytes;

      final buffer =
          _incomingBuffersByMac.putIfAbsent(senderMac, () => <int>[]);

      if (chunk.length == eofMarker.length && listEquals(chunk, eofMarker)) {
        if (buffer.isEmpty) return;

        Future<void>.microtask(() async {
          try {
            final decompressed = zlib.decode(buffer);
            final String jsonStr = utf8.decode(decompressed);
            final decodedJson = jsonDecode(jsonStr);
            if (decodedJson is! Map) return;
            final root = Map<String, dynamic>.from(decodedJson);
            final type = root['type'] as String?;

            final db = await _ref.read(databaseProvider.future);

            if (type == 'offer') {
              final senderHash = root['sender_hash'] as int?;
              final senderId = root['sender_id'] as String?;
              final neighborsRaw = root['neighbors'];
              final vectorRaw = root['vector'];

              // 1) Store topology for the sender (offer gossip).
              if (senderId != null) {
                final now = DateTime.now();
                // The sender physically transmitted this payload: treat as Direct immediately.
                BleDiscoveryService.localSeenNodes[senderId] = now;
                networkLastSeen[senderId] = now;

                final neighborSet = <String>{};
                if (neighborsRaw is List) {
                  for (final n in neighborsRaw) {
                    if (n is String) {
                      neighborSet.add(n);
                      networkLastSeen[n] = now;
                    }
                  }
                }
                _meshTopology[senderId] = neighborSet;

                // Also teach neighbor-table routing: advertised hash -> node id.
                if (senderHash != null) {
                  BleDiscoveryService.hashToNodeId[senderHash] = senderId;
                  final mac = BleDiscoveryService.hashToMac[senderHash];
                  if (mac != null) {
                    BleDiscoveryService.macToNodeId[mac] = senderId;

                    // Upgrade UI "discovered" label from MAC -> nodeId.
                    final ids = Set<String>.from(state.discoveredNodeIds);
                    if (ids.remove(mac)) {
                      ids.add(senderId);
                      state = state.copyWith(discoveredNodeIds: ids);
                    }
                  }
                }
                _refreshNeighborClassification();
                _presenceBump.add(null);
              }

              // 2) Respond with an offer delta (surgical changeset).
              if (senderHash == null || vectorRaw is! Map) return;
              final remoteVector = Map<String, dynamic>.from(vectorRaw);
              // Prefer direct MAC from native GATT callback (more reliable than scan routing).
              final targetMac =
                  senderMac != '<unknown>' ? senderMac : BleDiscoveryService.hashToMac[senderHash];
              if (targetMac == null) {
                debugPrint(
                  '⚠️ Offer: no hash route for sender_hash=$senderHash',
                );
                return;
              }

              final delta = await db.getDeltaChangeset(remoteVector);

              final ourSenderHash = await db.getDatabaseHash();
              final localId = _localNodeId ?? db.localNodeId;

              // Always send back a delta envelope so the initiator receives our
              // neighbor gossip even when no changes are needed.
              final deltaEnvelope = <String, dynamic>{
                'type': 'delta',
                'sender_id': localId,
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
              }
              return;
            }

            if (type == 'delta' || type == null) {
              // Update topology/presence for delta gossip.
              final senderHash = root['sender_hash'] as int?;
              final senderId = root['sender_id'] as String?;
              final neighborsRaw = root['neighbors'];

              // Even legacy packets (type == null) can still teach identity/presence if they
              // include sender fields.
              if (senderId != null) {
                final now = DateTime.now();
                // The sender physically transmitted this payload: treat as Direct immediately.
                BleDiscoveryService.localSeenNodes[senderId] = now;
                networkLastSeen[senderId] = now;

                final neighborSet = <String>{};
                if (neighborsRaw is List) {
                  for (final n in neighborsRaw) {
                    if (n is String) {
                      neighborSet.add(n);
                      networkLastSeen[n] = now;
                    }
                  }
                }
                _meshTopology[senderId] = neighborSet;

                if (senderHash != null) {
                  BleDiscoveryService.hashToNodeId[senderHash] = senderId;
                  final mac = BleDiscoveryService.hashToMac[senderHash];
                  if (mac != null) {
                    BleDiscoveryService.macToNodeId[mac] = senderId;

                    final ids = Set<String>.from(state.discoveredNodeIds);
                    if (ids.remove(mac)) {
                      ids.add(senderId);
                      state = state.copyWith(discoveredNodeIds: ids);
                    }
                  }
                }

                _refreshNeighborClassification();
                _presenceBump.add(null);
              }

              final dataRaw = root['data'] ?? root['changes'];
              if (dataRaw is! Map) return;
              final changeset = Map<String, dynamic>.from(dataRaw);
              if (changeset.isNotEmpty) {
                await db.mergeSyncChangeset(changeset);
              }

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
            buffer.clear();
            if (buffer.isEmpty) {
              _incomingBuffersByMac.remove(senderMac);
            }
          }
        });
      } else {
        buffer.addAll(chunk);
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
      await _attachLocalUserProfileHashUpdateTrigger(myId);
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
      await _localProfilesSub?.cancel();
      _localProfilesSub = null;
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
    await _localProfilesSub?.cancel();
    _localProfilesSub = null;
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
      await _localProfilesSub?.cancel();
      _localProfilesSub = null;
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
    await _attachLocalUserProfileHashUpdateTrigger(myId);
    _publishRadioFlags();
  }

  /// Stops scan + peripheral advertising.
  Future<void> stopNetwork() async {
    _meshSessionActive = false;
    await _nativePayloadSub?.cancel();
    _nativePayloadSub = null;
    await _localMessagesSub?.cancel();
    _localMessagesSub = null;
    await _localProfilesSub?.cancel();
    _localProfilesSub = null;
    await _discovery.stopAll();
    _publishRadioFlags();
  }

  @override
  void dispose() {
    unawaited(_adapterSub?.cancel());
    unawaited(_nativePayloadSub?.cancel());
    unawaited(_localMessagesSub?.cancel());
    unawaited(_localProfilesSub?.cancel());
    _presenceBump.close();
    unawaited(_discovery.stopAll());
    super.dispose();
  }
}

/// Global BLE network / adapter state.
final bleNetworkProvider =
    StateNotifierProvider<BleNetworkNotifier, BleNetworkState>(
  (ref) => BleNetworkNotifier(ref),
);

class MeshNodeState {
  const MeshNodeState({
    required this.id,
    required this.name,
    this.macAddress,
    required this.status,
    required this.lastSeen,
    this.routeViaId,
    this.routeViaName,
  });

  final String id;
  final String name;
  final String? macAddress;
  final PeerStatus status;
  final DateTime lastSeen;
  final String? routeViaId;
  final String? routeViaName;
}

final activePeersProvider = StreamProvider<List<MeshNodeState>>((ref) async* {
  final notifier = ref.watch(bleNetworkProvider.notifier);
  yield* notifier.watchActivePeers();
});

enum PeerStatus { direct, indirect, disconnected }
