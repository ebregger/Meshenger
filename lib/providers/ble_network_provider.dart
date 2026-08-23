import 'dart:async';
import 'dart:convert';
import 'dart:io' show zlib;
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, listEquals;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../models/generated/mesh_data.pb.dart';
import '../services/api_service.dart';
import '../services/ble_discovery_service.dart';
import '../services/database_service.dart';
import '../services/local_write_hook.dart';
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
      onScannerError: _handleScannerError,
      onScannerStalled: _handleScannerStalled,
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
  bool _scannerRecovering = false;
  String? _localNodeId;
  String? _ownBleMac;
  bool _primeMessageListLength = true;
  String? _lastAdvertisedHashB64;
  Timer? _advertHashDebounce;
  DateTime? _lastAdvertHashPushedAt;
  /// Cap how often we rewrite ADV during a write burst (radio-facing rate limit).
  static const Duration _advertHashMinInterval = Duration(milliseconds: 150);

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

  int _scannerRecoverAttempt = 0;
  bool _scannerPowerCycled = false;

  void _handleScannerError(String error) {
    debugPrint('🚨 [MESH] Scanner hardware error: $error');
    state = state.copyWith(scannerHealthy: false);
    if (_meshSessionActive && !_scannerRecovering) {
      _handleScannerStalled();
    }
  }

  void _handleScannerStalled() {
    if (state.scannerHealthy && !state.scannerStalled) {
      debugPrint('🚨 [MESH] Scanner heuristic stalled!');
      state = state.copyWith(scannerStalled: true);
    }
    if (!_meshSessionActive || _scannerRecovering) return;
    if (_discovery.isConnecting) {
      debugPrint('♻️ [MESH] Defer scanner recover — GATT dial in flight');
      return;
    }

    // APPLICATION_REGISTRATION_FAILED soft-loops forever on Clear; after two
    // soft attempts, power-cycle the adapter once to free scanner slots.
    if (_scannerRecoverAttempt >= 2 && !_scannerPowerCycled) {
      _scannerRecovering = true;
      unawaited(() async {
        try {
          debugPrint(
            '🔥 [MESH] Scanner registration wedged — power-cycling Bluetooth',
          );
          _scannerPowerCycled = true;
          await powerCycleBluetooth();
          _scannerRecoverAttempt = 0;
        } catch (e) {
          debugPrint('⚠️ [MESH] Scanner power-cycle failed: $e');
        } finally {
          _scannerRecovering = false;
        }
      }());
      return;
    }
    if (_scannerRecoverAttempt >= 2 && _scannerPowerCycled) {
      // Already power-cycled this session — don't spam soft restarts.
      return;
    }

    _scannerRecovering = true;
    unawaited(() async {
      try {
        final delayMs =
            (8000 * (1 << _scannerRecoverAttempt.clamp(0, 2))).clamp(8000, 45000);
        debugPrint(
          '♻️ [MESH] Soft-restart stalled scanner (attempt $_scannerRecoverAttempt, wait ${delayMs}ms)...',
        );
        final myId = _localNodeId;
        if (myId == null) return;
        await Future<void>.delayed(Duration(milliseconds: delayMs));
        if (_discovery.isConnecting) {
          debugPrint('♻️ [MESH] Abort soft-restart — dial started during wait');
          return;
        }
        await _discovery.stopScanning();
        await Future<void>.delayed(const Duration(milliseconds: 800));
        await _discovery.startScanning(
          myNodeId: myId,
          ownMac: _ownBleMac,
          onDiscovered: _onPeerDiscovered,
          wipeMaps: false,
        );
        // Stay stalled until a real scan result arrives (_onPeerDiscovered).
        _scannerRecoverAttempt = (_scannerRecoverAttempt + 1).clamp(0, 6);
        debugPrint('✅ [MESH] Soft scanner restart issued');
      } catch (e) {
        debugPrint('⚠️ [MESH] Scanner restart failed: $e');
        _scannerRecoverAttempt = (_scannerRecoverAttempt + 1).clamp(0, 6);
      } finally {
        _scannerRecovering = false;
      }
    }());
  }

  /// Hard reset of the mesh radio stack (useful when Android's GATT/Scan slots are jammed).
  Future<void> resetRadio() async {
    debugPrint('♻️ [MESH] Resetting radio stack (Software)...');
    await _stopMeshSession();
    state = state.copyWith(scannerHealthy: true, scannerStalled: false);
    await _startMeshSession();
  }

  /// System-level power cycle of the Bluetooth adapter (Force OFF then ON).
  Future<void> powerCycleBluetooth() async {
    debugPrint('🔥 [MESH] POWER CYCLING Bluetooth hardware...');
    await _stopMeshSession();
    final attempted = await _nativeMesh.forceToggleBluetooth();
    if (!attempted) {
      debugPrint('⚠️ [MESH] Power cycle restricted by OS version. Please toggle manually.');
    }
    // Cool down to let the OS adapter state stabilize.
    await Future.delayed(const Duration(seconds: 4));
    state = state.copyWith(scannerHealthy: true, scannerStalled: false);
    await _startMeshSession();
  }

  Uint8List _buildAdvertiserPayload(Uint8List hashBytes) {
    // Payload layout: [8 bytes: 64-bit FNV hash][4 bytes: node ID prefix] = 12 bytes total.
    // Increased from 4→8 hash bytes to prevent Birthday Paradox collisions at scale.
    final payloadBytes = Uint8List(12);
    payloadBytes.setRange(0, 8, hashBytes);
    final myId = _localNodeId ?? '';
    final myIdSubstring = myId.length >= 4 ? myId.substring(0, 4) : myId.padRight(4, '0');
    final myIdBytes = utf8.encode(myIdSubstring);
    payloadBytes.setRange(8, 12, myIdBytes);
    return payloadBytes;
  }

  Map<String, dynamic> _mergeChangesets(
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
          byId[id ?? existing.indexOf(row).toString()] = row;
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

      // Active direct = recent physical contact (sync / GATT), not merely gossip.
      final activeDirectNodes = BleDiscoveryService.localSeenNodes.entries
          .where((e) => now.difference(e.value).inSeconds <= 60)
          .map((e) => e.key)
          .toSet();

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
          // Exactly one other node: there is no multi-hop path possible.
          if (secondsSinceLocal <= 60 || secondsSinceNetwork <= 60) {
            status = PeerStatus.direct;
          } else if (secondsSinceLocal <= 75 || secondsSinceNetwork <= 75) {
            status = PeerStatus.disconnected;
          }
        } else if (secondsSinceLocal <= 75) {
          // Still have (or recently had) direct contact. Stay direct — a fresher
          // gossip touch on networkLastSeen must not paint this peer yellow.
          status = PeerStatus.direct;
        } else if (secondsSinceNetwork <= 60) {
          // Directly inaccessible; only mesh gossip knows this peer.
          // Yellow only when a live direct neighbor can bridge to them.
          if (_findRoute(id, activeDirectNodes) != null) {
            status = PeerStatus.indirect;
          } else {
            status = PeerStatus.disconnected;
          }
        } else if (secondsSinceLocal <= 75 || secondsSinceNetwork <= 75) {
          status = PeerStatus.disconnected;
        }

        if (status == null) continue;

        var latestTime = localTime ?? DateTime.fromMillisecondsSinceEpoch(0);
        if (networkTime != null && networkTime.isAfter(latestTime)) {
          latestTime = networkTime;
        }

        final name = nameById[id] ?? (id.length <= 8 ? id : id.substring(0, 8));
        final mac = BleDiscoveryService.nodeIdToMac[id];
        final routeViaId =
            status == PeerStatus.indirect ? _findRoute(id, activeDirectNodes) : null;
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
    _adapterSub = FlutterBluePlus.adapterState.listen((event) {
      _onAdapterState(event);
      unawaited(refreshMeshHealth());
    });
    _onAdapterState(FlutterBluePlus.adapterStateNow);
    unawaited(refreshMeshHealth());
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

  /// Publish DB hash into ADV as writes happen, rate-limited to the radio — not
  /// "wait until sending stops". Pending updates flush as soon as the interval allows.
  void _scheduleAdvertiserHashUpdate(String myId) {
    Future<void> push() async {
      try {
        final db = await _ref.read(databaseProvider.future);
        final hashBytes = await db.getDatabaseHashBytes();
        final b64 = base64Encode(hashBytes);
        final payload = _buildAdvertiserPayload(hashBytes);
        _discovery.setLocalHash(payload);
        if (b64 == _lastAdvertisedHashB64) return;
        debugPrint('📡 [ADV] Hash changed to $b64 (rate-limited)');
        _lastAdvertisedHashB64 = b64;
        _lastAdvertHashPushedAt = DateTime.now();
        await _nativeMesh.updateAdvertiserHash(payload, myId);
      } catch (e, st) {
        debugPrint('NATIVE MESH HASH UPDATE FAILED: $e\n$st');
      }
    }

    final last = _lastAdvertHashPushedAt;
    final elapsed = last == null
        ? _advertHashMinInterval
        : DateTime.now().difference(last);
    if (elapsed >= _advertHashMinInterval) {
      _advertHashDebounce?.cancel();
      _advertHashDebounce = null;
      unawaited(push());
      return;
    }

    _advertHashDebounce?.cancel();
    _advertHashDebounce = Timer(_advertHashMinInterval - elapsed, () {
      unawaited(push());
    });
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

      // ADV only here — urgent GATT push is triggered from ChatActions on local send
      // so inbound merges don't stampede neighbors.
      _scheduleAdvertiserHashUpdate(myId);
    });
  }

  /// Local chat write: publish hash for pulls, and push a tiny newest slice so
  /// catch-up doesn't wait on scan/ADV alone.
  void onLocalDatabaseWrite() {
    final myId = _localNodeId;
    if (!_meshSessionActive || myId == null) return;
    _lastAdvertHashPushedAt = null;
    _scheduleAdvertiserHashUpdate(myId);
    _discovery.requestUrgentSyncWithKnownPeers(myId);
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

      _scheduleAdvertiserHashUpdate(myId);
    });
  }

  Future<void> _attachNativeIncomingSync() async {
    await _nativePayloadSub?.cancel();
    _nativePayloadSub = _nativeMesh.incomingPayloads.listen((incoming) {
      final eofMarker = utf8.encode('||EOF||');
      final senderMac = incoming.macAddress;
      final chunk = incoming.bytes;

      if (ApiService.ignoreMac != null && senderMac == ApiService.ignoreMac) {
        return; // Simulating out of range
      }
      if (ApiService.dropRate > 0 && Random().nextDouble() < ApiService.dropRate) {
        return; // Simulating packet drop
      }

      final buffer =
          _incomingBuffersByMac.putIfAbsent(senderMac, () => <int>[]);

      if (chunk.length == eofMarker.length && listEquals(chunk, eofMarker)) {
        debugPrint('📥 [SYNC] EOF received from $senderMac — buffer=${buffer.length} bytes');
        debugPrint('[BENCHMARK] TARGET_MAC:$senderMac | EVENT:DELTA_RECEIVED | BYTES:${buffer.length} | TIMESTAMP:${DateTime.now().millisecondsSinceEpoch}');
        if (buffer.isEmpty) {
          debugPrint('⚠️ [SYNC] Empty buffer at EOF from $senderMac — ignoring');
          return;
        }

        Future<void>.microtask(() async {
          try {
            debugPrint('🔄 [SYNC] Decompressing payload from $senderMac (${buffer.length} bytes)...');
            final decompressed = zlib.decode(buffer);
            final String jsonStr = utf8.decode(decompressed);
            final decodedJson = jsonDecode(jsonStr);
            if (decodedJson is! Map) {
              debugPrint('❌ [SYNC] Decoded JSON is not a Map from $senderMac');
              return;
            }
            final root = Map<String, dynamic>.from(decodedJson);
            final type = root['type'] as String?;
            debugPrint('📦 [SYNC] Received type=$type from $senderMac');

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

                // Prefer GATT callback MAC (server path); hash→MAC covers initiator scans.
                BleDiscoveryService.bindPeerIdentity(
                  nodeId: senderId,
                  mac: senderMac,
                  hash: senderHash,
                );
                final boundMac = BleDiscoveryService.nodeIdToMac[senderId];
                if (boundMac != null) {
                  // Upgrade UI "discovered" label from MAC -> nodeId.
                  final ids = Set<String>.from(state.discoveredNodeIds);
                  if (ids.remove(boundMac)) {
                    ids.add(senderId);
                    state = state.copyWith(discoveredNodeIds: ids);
                  }
                }
                _refreshNeighborClassification();
                _presenceBump.add(null);
              }

              // 2) Respond with an offer delta (surgical changeset).
              if (senderHash == null || vectorRaw is! Map) {
                debugPrint('⚠️ [SYNC] Offer missing senderHash or vector from $senderMac — skipping reply');
                return;
              }
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

              // 2a) Merge the initiator's own pushed changeset (offer+push bidirectional sync).
              // This is the key fix for the one-way propagation blackout: previously the server
              // (D1/D2) only replied to D3 with what D3 was missing, but never received D3's
              // own messages. Now D3 includes its changeset in the offer, and we merge it here.
              final initiatorDataRaw = root['initiator_data'];
              if (initiatorDataRaw is Map && initiatorDataRaw.isNotEmpty) {
                final initiatorChangeset = Map<String, dynamic>.from(initiatorDataRaw);
                final rowCounts = initiatorChangeset.map((t, rows) => MapEntry(t, (rows as List).length));
                final totalRows = rowCounts.values.fold(0, (a, b) => a + b);
                debugPrint('📥 [SYNC] Merging initiator_data from $senderMac — $totalRows rows: $rowCounts');
                await db.mergeSyncChangeset(initiatorChangeset);
                final messagesRaw = initiatorChangeset['messages'];
                if (messagesRaw is List) {
                  for (final row in messagesRaw) {
                    if (row is Map) {
                      final msgId = row['msg_id'] ?? row['msgId'];
                      if (msgId != null) {
                        debugPrint('[BENCHMARK] MSG_ID:$msgId | EVENT:MERGED | TIMESTAMP:${DateTime.now().millisecondsSinceEpoch}');
                      }
                    }
                  }
                }
              }

              debugPrint('📤 [SYNC] Computing delta for offer from senderId=$senderId...');
              var delta = await db.getDeltaChangeset(remoteVector);
              final ourSenderHash = await db.getDatabaseHash();
              var usedRepair = false;
              var fpsComplete = true;

              // Remember peer digests always; only scan for absent rows when the
              // version-vector delta is empty (avoids loading the full CRDT on
              // every live write — that stalled Pixel 3 replies for seconds).
              final fpsB64 = root['fps_b'] ?? root['row_fps'];
              if (fpsB64 is String && fpsB64.isNotEmpty) {
                try {
                  final raw = base64Decode(fpsB64);
                  if (raw.length == DatabaseService.fingerprintBucketCount * 4) {
                    final remoteBuckets =
                        DatabaseService.decodeBucketFingerprints(raw);
                    if (senderId != null) {
                      BleDiscoveryService.rememberPeerBuckets(
                        senderId,
                        remoteBuckets,
                      );
                    }
                    if (delta.isEmpty && senderHash != ourSenderHash) {
                      final absent = await db.getRowsForMismatchedBuckets(
                        remoteBuckets,
                        maxRows: 150,
                      );
                      if (absent.isNotEmpty) {
                        delta = absent;
                        usedRepair = true;
                        final absentCount = absent.values
                            .whereType<List>()
                            .fold<int>(0, (a, b) => a + b.length);
                        fpsComplete = absentCount < 150;
                        debugPrint(
                          '📥 [SYNC] Bucket gap-fill for $senderId — '
                          '$absentCount row(s) in mismatched buckets',
                        );
                      }
                    }
                  }
                } catch (e) {
                  debugPrint('⚠️ [SYNC] fps_b decode failed: $e');
                }
              } else if (delta.isEmpty && senderHash != ourSenderHash) {
                delta = await db.getHashRepairChangeset(peerKey: senderId);
                usedRepair = delta.isNotEmpty;
                fpsComplete = false;
                debugPrint(
                  '⚠️ [SYNC] Hash-mismatch repair for $senderId — '
                  'slice tables=${delta.keys.toList()}',
                );
              }
              debugPrint('📤 [SYNC] Delta has ${delta.length} entries — replying to $targetMac');

              // Keep reply GATT short so the initiator can turn around to peer #2.
              delta = usedRepair
                  ? BleDiscoveryService.truncateChangesetForBle(
                      delta,
                      maxRowsPerTable: 60,
                    )
                  : BleDiscoveryService.truncateChangesetForBle(
                      delta,
                      maxRowsPerTable: 25,
                    );

              final localId = _localNodeId ?? db.localNodeId;

              // Always send back a delta envelope so the initiator receives our
              // neighbor gossip even when no changes are needed.
              final ourFpsBlob = await db.getBucketFingerprintBlob();
              final deltaEnvelope = <String, dynamic>{
                'type': 'delta',
                'sender_id': localId,
                'sender_hash': ourSenderHash,
                'neighbors': _discovery.currentNeighborIds,
                'fps_b': base64Encode(ourFpsBlob),
                'data': delta,
              };
              var outBytes = zlib.encode(
                utf8.encode(jsonEncode(deltaEnvelope)),
              );
              // Prefer keeping gap-fill rows over fingerprints when over budget.
              var replyComplete = true;
              if (outBytes.length > BleDiscoveryService.maxOfferPushBytes) {
                deltaEnvelope.remove('fps_b');
                outBytes = zlib.encode(
                  utf8.encode(jsonEncode(deltaEnvelope)),
                );
                fpsComplete = false;
              }
              if (outBytes.length > BleDiscoveryService.maxOfferPushBytes) {
                delta = usedRepair
                    ? BleDiscoveryService.truncateChangesetForBle(delta)
                    : BleDiscoveryService.shrinkChangesetForBle(delta);
                deltaEnvelope['data'] = delta;
                outBytes = zlib.encode(
                  utf8.encode(jsonEncode(deltaEnvelope)),
                );
                replyComplete =
                    outBytes.length <= BleDiscoveryService.maxOfferPushBytes;
                if (!replyComplete) {
                  deltaEnvelope['data'] = <String, dynamic>{};
                  outBytes = zlib.encode(
                    utf8.encode(jsonEncode(deltaEnvelope)),
                  );
                }
                fpsComplete = false;
                debugPrint(
                  '⚠️ [SYNC] Delta reply capped for $targetMac '
                  '(${outBytes.length} bytes, complete=$replyComplete)',
                );
              }

              await _nativeMesh.replyPayload(
                targetMac,
                Uint8List.fromList(outBytes),
              );
              debugPrint('✅ [SYNC] Delta reply sent to $targetMac via NOTIFY (${outBytes.length} bytes)');

              if (senderId != null) {
                final normalizedRemote = <String, String>{
                  for (final e in remoteVector.entries)
                    if (e.value != null) e.key.toString(): e.value.toString(),
                };
                BleDiscoveryService.rememberPeerVector(
                  senderId,
                  normalizedRemote,
                );
                if (replyComplete &&
                    fpsComplete &&
                    senderHash == ourSenderHash) {
                  BleDiscoveryService.markSyncComplete(senderId);
                } else if (senderHash != ourSenderHash) {
                  BleDiscoveryService.lastFullSync.remove(senderId);
                }
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

                BleDiscoveryService.bindPeerIdentity(
                  nodeId: senderId,
                  mac: senderMac,
                  hash: senderHash,
                );
                final boundMac = BleDiscoveryService.nodeIdToMac[senderId];
                if (boundMac != null) {
                  final ids = Set<String>.from(state.discoveredNodeIds);
                  if (ids.remove(boundMac)) {
                    ids.add(senderId);
                    state = state.copyWith(discoveredNodeIds: ids);
                  }
                }

                _refreshNeighborClassification();
                _presenceBump.add(null);
              }

              final dataRaw = root['data'] ?? root['changes'];
              if (dataRaw is! Map) {
                debugPrint('⚠️ [SYNC] Delta from $senderMac has no data/changes field');
                return;
              }
              final changeset = Map<String, dynamic>.from(dataRaw);
              final rowCounts = changeset.map((t, rows) => MapEntry(t, (rows as List).length));
              final totalRows = rowCounts.values.fold(0, (a, b) => a + b);
              debugPrint('📥 [SYNC] Merging delta from $senderMac — $totalRows rows across ${changeset.length} tables: $rowCounts');
              if (changeset.isNotEmpty) {
                await db.mergeSyncChangeset(changeset);
                debugPrint('✅ [SYNC] Merged $totalRows rows from $senderMac');
                final messagesRaw = changeset['messages'];
                if (messagesRaw is List) {
                  for (final row in messagesRaw) {
                    if (row is Map) {
                      final msgId = row['msg_id'] ?? row['msgId'];
                      if (msgId != null) {
                        debugPrint('[BENCHMARK] MSG_ID:$msgId | EVENT:MERGED | TIMESTAMP:${DateTime.now().millisecondsSinceEpoch}');
                      }
                    }
                  }
                }
              } else {
                debugPrint('ℹ️ [SYNC] Empty changeset from $senderMac — nothing to merge');
              }

              // Client handshake finished once the server's delta reply arrives.
              if (senderId != null) {
                final fpsB64 = root['fps_b'] ?? root['row_fps'];
                if (fpsB64 is String && fpsB64.isNotEmpty) {
                  try {
                    final raw = base64Decode(fpsB64);
                    if (raw.length ==
                        DatabaseService.fingerprintBucketCount * 4) {
                      BleDiscoveryService.rememberPeerBuckets(
                        senderId,
                        DatabaseService.decodeBucketFingerprints(raw),
                      );
                    }
                  } catch (_) {}
                }
                final localHash = await db.getDatabaseHash();
                if (senderHash != null && senderHash != localHash) {
                  BleDiscoveryService.lastFullSync.remove(senderId);
                  debugPrint(
                    '⚠️ [SYNC] Hash still diverges after delta from $senderId — '
                    'clearing sync cooldown for fast retry',
                  );
                } else {
                  BleDiscoveryService.markSyncComplete(senderId);
                }
              }

              try {
                final hashBytes = await db.getDatabaseHashBytes();
                final b64 = base64Encode(hashBytes);
                if (b64 != _lastAdvertisedHashB64) {
                  _lastAdvertisedHashB64 = b64;
                  final payload = _buildAdvertiserPayload(hashBytes);
                  await _nativeMesh.updateAdvertiserHash(payload, _localNodeId ?? db.localNodeId);
                  _discovery.setLocalHash(payload);
                }
              } catch (e, st) {
                debugPrint('NATIVE MESH HASH UPDATE FAILED: $e\n$st');
              }
            }
          } catch (e, st) {
            debugPrint('❌ [SYNC] Mesh processing error from $senderMac: $e\n$st');
          } finally {
            buffer.clear();
            if (buffer.isEmpty) {
              _incomingBuffersByMac.remove(senderMac);
            }
          }
        });
      } else {
        buffer.addAll(chunk);
        debugPrint('📡 [SYNC] Chunk from $senderMac: ${chunk.length} bytes (total buffer: ${buffer.length})');
      }
    });
  }

  Future<void> _startMeshSession() async {
    if (_meshSessionActive || state.adapterStatus != BleAdapterStatus.on) {
      return;
    }
    _meshSessionActive = true;
    _scannerRecoverAttempt = 0;
    _scannerPowerCycled = false;
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
      final payload = _buildAdvertiserPayload(hashBytes);
      _discovery.setLocalHash(payload);
      final ownMac = await _nativeMesh.startNativeServer(payload, myId);
      _ownBleMac = ownMac;
      if (ownMac != null && ownMac.isNotEmpty) {
        debugPrint('[MESH] Own BLE MAC: $ownMac (will filter from scan results)');
      }
      await _attachNativeIncomingSync();
      await _discovery.startScanning(
        myNodeId: myId,
        ownMac: ownMac,
        onDiscovered: _onPeerDiscovered,
      );
      await _attachLocalMessageQuickScanTrigger(myId);
      await _attachLocalUserProfileHashUpdateTrigger(myId);
      onLocalCrdtWrite = onLocalDatabaseWrite;
      _publishRadioFlags();
      _refreshNeighborClassification();
      _neighborRefreshTimer?.cancel();
      _neighborRefreshTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => _refreshNeighborClassification(),
      );
    } catch (e, st) {
      debugPrint('🔥 [MESH] _startMeshSession FAILED: $e\n$st');
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
    if (state.scannerStalled ||
        _scannerRecoverAttempt != 0 ||
        _scannerPowerCycled) {
      _scannerRecoverAttempt = 0;
      _scannerPowerCycled = false;
      state = state.copyWith(scannerStalled: false, scannerHealthy: true);
    }
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
    onLocalCrdtWrite = null;
    _localNodeId = null;
    _neighborRefreshTimer?.cancel();
    _neighborRefreshTimer = null;
    _advertHashDebounce?.cancel();
    _advertHashDebounce = null;
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

  /// Pulls the latest hardware and permission statuses into the state.
  Future<void> refreshMeshHealth() async {
    final report = await PermissionsHelper.checkMeshHealth();
    
    final Map<String, String> statusMap = {};
    report.permissions.forEach((perm, status) {
      // Permission types: location, bluetoothScan, bluetoothConnect, bluetoothAdvertise, bluetooth
      final key = perm.toString().split('.').last;
      // Statuses: granted, denied, permanentlyDenied, restricted, limited, provisional
      final value = status.toString().split('.').last;
      statusMap[key] = value;
    });

    state = state.copyWith(
      locationServicesEnabled: report.locationServicesEnabled,
      bluetoothHardwareEnabled: FlutterBluePlus.adapterStateNow == BluetoothAdapterState.on,
      permissionStatuses: statusMap,
    );
  }

  /// Re-runs Android permission prompts (e.g. after returning from Settings).
  Future<BlePermissionRequestResult> retryAndroidPermissions() async {
    final outcome = await PermissionsHelper.requestAndroidBlePermissions();
    await refreshMeshHealth();

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

  /// Opens the system app settings to allow manual permission overrides.
  Future<void> promptOpenSettings() async {
    await PermissionsHelper.openApplicationSettings();
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
    final payload = _buildAdvertiserPayload(hashBytes);
    _discovery.setLocalHash(payload);
    await _nativeMesh.startNativeServer(payload, _localNodeId ?? '');
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
    _advertHashDebounce?.cancel();
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
