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
import '../services/benchmark_trace.dart';
import '../services/deep_catchup.dart';
import '../services/offer_reply_planner.dart';
import '../services/framed_reply_retry_state.dart';
import '../services/local_write_hook.dart';
import '../services/native_mesh_service.dart';
import '../utils/ble_permission_result.dart';
import '../utils/permissions_helper.dart';
import 'ble_network_state.dart';
import 'database_provider.dart';
import 'identity_provider.dart';

class _IncomingFramedReply {
  final Map<int, Uint8List> chunks = <int, Uint8List>{};
  int? transferId;
  int? chunkCount;
  int? totalBytes;
  int? crc32;
  String? attemptId;
  String? connectionId;
  final FramedReplyRetryState feedbackState = FramedReplyRetryState();
}

int _blePayloadCrc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final byte in bytes) {
    crc ^= byte & 0xFF;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

/// BLE adapter, permissions, and Phase 3 mesh discovery (scan + advertise).
class BleNetworkNotifier extends StateNotifier<BleNetworkState> {
  BleNetworkNotifier(this._ref) : super(BleNetworkState.initial) {
    _localWriteHook = (messageId) =>
        onLocalDatabaseWrite(messageId: messageId, source: 'chat_hook');
    onLocalCrdtWrite = _localWriteHook;
    _discovery = BleDiscoveryService(
      _ref,
      onConnectionPhaseChanged: _handleMeshConnectionPhaseChanged,
      onScannerError: _handleScannerError,
      onScannerStalled: _handleScannerStalled,
      onUrgentGattRecovery: _recoverGattForUrgent,
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
  late final void Function(String messageId) _localWriteHook;
  final Map<String, List<int>> _incomingBuffersByMac = <String, List<int>>{};
  final Map<String, Map<String, String>> _incomingTransferByMac =
      <String, Map<String, String>>{};
  final Map<String, _IncomingFramedReply> _incomingFramedRepliesByMac =
      <String, _IncomingFramedReply>{};
  bool _meshSessionActive = false;
  bool _meshSessionReady = false;
  bool _pendingLocalDatabaseWrite = false;
  String? _pendingLocalWriteMessageId;
  String? _pendingLocalWriteSource;
  bool _scannerRecovering = false;
  String? _localNodeId;
  String? _ownBleMac;
  bool _primeMessageListLength = true;
  String? _lastAdvertisedHashB64;
  Timer? _advertHashDebounce;

  /// Refresh the whole-database hash after writes settle, not during each send.
  static const Duration _advertHashQuietPeriod = Duration(seconds: 1);
  static const int _maxReplyMissingIndices = 7;

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

  /// Flush leaked GATT slots after urgent push failure, then re-advertise.
  Future<void> _recoverGattForUrgent() async {
    await _nativeMesh.resetServer();
    await startAdvertising();
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
        final delayMs = (2000 * (1 << _scannerRecoverAttempt.clamp(0, 2)))
            .clamp(2000, 16000);
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
    await _stopMeshSession(stopForegroundService: false);
    state = state.copyWith(scannerHealthy: true, scannerStalled: false);
    await _startMeshSession();
  }

  /// System-level power cycle of the Bluetooth adapter (Force OFF then ON).
  Future<void> powerCycleBluetooth() async {
    debugPrint('🔥 [MESH] POWER CYCLING Bluetooth hardware...');
    await _stopMeshSession(stopForegroundService: false);
    final attempted = await _nativeMesh.forceToggleBluetooth();
    if (!attempted) {
      debugPrint(
        '⚠️ [MESH] Power cycle restricted by OS version. Please toggle manually.',
      );
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
    final myIdSubstring = myId.length >= 4
        ? myId.substring(0, 4)
        : myId.padRight(4, '0');
    final myIdBytes = utf8.encode(myIdSubstring);
    payloadBytes.setRange(8, 12, myIdBytes);
    return payloadBytes;
  }

  void _handleMeshConnectionPhaseChanged() {
    _publishRadioFlags();
  }

  void _publishRadioFlags() {
    final connecting = _discovery.isConnecting;
    final advertising =
        _meshSessionActive &&
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

  /// Provisional scan keys use raw BLE addresses; never render those as peers.
  static bool _looksLikeBleMac(String id) {
    final parts = id.split(':');
    if (parts.length != 6) return false;
    for (final part in parts) {
      if (part.length != 2) return false;
      final value = int.tryParse(part, radix: 16);
      if (value == null) return false;
    }
    return true;
  }

  Stream<List<MeshNodeState>> watchActivePeers() async* {
    while (!_presenceBump.isClosed) {
      // Either periodic tick or an explicit bump (e.g. after payload receive).
      Timer? timer;
      try {
        final completer = Completer<void>();
        timer = Timer(const Duration(seconds: 1), () {
          if (!completer.isCompleted) completer.complete();
        });
        await Future.any([completer.future, _presenceBump.stream.first]);
      } catch (_) {
        break;
      } finally {
        timer?.cancel();
      }

      if (_presenceBump.isClosed) break;

      final now = DateTime.now();
      final out = <MeshNodeState>[];

      final self = _localNodeId;
      final nameById = Map<String, String>.from(_nameById);

      // Retain presence entries long enough for tombstones to render.
      BleDiscoveryService.localSeenNodes.removeWhere((id, t) {
        return _looksLikeBleMac(id) || now.difference(t).inSeconds > 85;
      });

      // Retain gossip entries long enough for tombstones to render.
      networkLastSeen.removeWhere((id, t) {
        return _looksLikeBleMac(id) || now.difference(t).inSeconds > 85;
      });

      // Active direct = recent physical contact (sync / GATT), not merely gossip.
      final activeDirectNodes = BleDiscoveryService.localSeenNodes.entries
          .where((e) => now.difference(e.value).inSeconds <= 60)
          .map((e) => e.key)
          .toSet();

      final allUsers = <String>{
        ...BleDiscoveryService.localSeenNodes.keys,
        ...networkLastSeen.keys,
        ...BleDiscoveryService.nodeIdToMac.keys,
      }..removeWhere(_looksLikeBleMac);

      final remotePeerIds = allUsers
          .where((id) => self == null || id != self)
          .toList();
      final singleRemotePeerTopology = remotePeerIds.length == 1;

      for (final id in allUsers) {
        if (self != null && id == self) continue;

        final localTime = BleDiscoveryService.localSeenNodes[id];
        final networkTime = networkLastSeen[id];

        final secondsSinceLocal = localTime != null
            ? now.difference(localTime).inSeconds
            : 9999;
        final secondsSinceNetwork = networkTime != null
            ? now.difference(networkTime).inSeconds
            : 9999;

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

        // Keep known identities visible as disconnected tombstones. Their scan
        // MAC can refresh after RPA rotation and rejoin without looking deleted.
        if (status == null && BleDiscoveryService.nodeIdToMac.containsKey(id)) {
          status = PeerStatus.disconnected;
        }
        if (status == null) continue;

        var latestTime =
            localTime ??
            BleDiscoveryService.nodeIdMacSeenAt[id] ??
            DateTime.fromMillisecondsSinceEpoch(0);
        if (networkTime != null && networkTime.isAfter(latestTime)) {
          latestTime = networkTime;
        }

        final name = nameById[id] ?? (id.length <= 8 ? id : id.substring(0, 8));
        final mac = BleDiscoveryService.nodeIdToMac[id];
        final routeViaId = status == PeerStatus.indirect
            ? _findRoute(id, activeDirectNodes)
            : null;
        final routeViaName = routeViaId == null
            ? null
            : (nameById[routeViaId] ?? routeViaId);

        out.add(
          MeshNodeState(
            id: id,
            name: name,
            macAddress: mac,
            status: status,
            lastSeen: latestTime,
            rssiDbm: BleDiscoveryService.nodeIdRssiDbm[id],
            rssiSeenAt: BleDiscoveryService.nodeIdRssiSeenAt[id],
            isTalking: BleDiscoveryService.isNodeTalking(id, now: now),
            meshCaughtUp: BleDiscoveryService.isPeerCaughtUp(id),
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
    debugPrint('[MESH] Adapter state=$value wasOn=$wasOn mapped=$next');
    state = state.copyWith(adapterStatus: next);
    final isOn = next == BleAdapterStatus.on;

    if (isOn && !wasOn) {
      unawaited(_startMeshSession());
    } else if (!isOn && wasOn) {
      // Keep the already-running foreground service alive while Bluetooth is
      // temporarily unavailable. Android won't allow us to start it again
      // from the background when the adapter comes back.
      unawaited(
        _stopMeshSession(stopForegroundService: next != BleAdapterStatus.off),
      );
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

  /// Publish a settled DB hash after a short quiet period. Urgent offers and
  /// deltas carry the live frontier, so rebuilding the whole-table hash for
  /// every message write only contends with the transfer they are meant to speed up.
  void _scheduleAdvertiserHashUpdate(String myId) {
    Future<void> push() async {
      try {
        final db = await _ref.read(databaseProvider.future);
        final hashBytes = await db.getDatabaseHashBytes();
        final b64 = base64Encode(hashBytes);
        final payload = _buildAdvertiserPayload(hashBytes);
        _discovery.setLocalHash(payload);
        if (b64 == _lastAdvertisedHashB64) return;
        debugPrint('📡 [ADV] Hash changed to $b64 (quiet-period refresh)');
        _lastAdvertisedHashB64 = b64;
        await _nativeMesh.updateAdvertiserHash(payload, myId);
      } catch (e, st) {
        debugPrint('NATIVE MESH HASH UPDATE FAILED: $e\n$st');
      }
    }

    _advertHashDebounce?.cancel();
    _advertHashDebounce = Timer(_advertHashQuietPeriod, () {
      _advertHashDebounce = null;
      unawaited(push());
    });
  }

  /// Our whole-history digest just finished recomputing in the background:
  /// resume older-history catch-up with any neighbor that still differs.
  void _onDeepDigestReady(String myId) {
    if (!_meshSessionActive || _localNodeId != myId) return;
    for (final peerId in List<String>.of(_discovery.currentNeighborIds)) {
      _continueDeepCatchup(peerId);
    }
  }

  /// Neighbors we have already offered our deep digest to this session.
  final Set<String> _deepProbed = <String>{};

  /// Older-history catch-up with [peerId], once our recent windows agree.
  ///
  /// Runs after the new messages have been exchanged, never before, and only
  /// with a digest that is already computed, so it adds no latency to live
  /// traffic. Stops on its own when a round changes nothing.
  void _continueDeepCatchup(String peerId, [int? remoteTailHash]) {
    final myId = _localNodeId;
    if (!_meshSessionActive || myId == null) return;
    unawaited(() async {
      final db = await _ref.read(databaseProvider.future);
      // A stale digest is already being rebuilt; its completion calls back.
      final ours = db.freshDeepDigest;
      if (ours == null) return;
      final theirTail =
          remoteTailHash ?? BleDiscoveryService.peerObservedHash[peerId]?.hash;
      if (theirTail == null) return;
      // Recent messages always come first.
      if (theirTail != await db.getDatabaseHash()) return;
      final peer = DeepCatchup.peer(peerId);
      if (peer == null) {
        // Matching recent windows never trigger a handshake by themselves, so
        // offer our digest once per neighbor and learn theirs in the reply.
        if (_deepProbed.add(peerId)) {
          debugPrint('🗄️ [SYNC] Deep catch-up probe to $peerId');
          _discovery.requestHashRepair(myId, peerId, theirTail);
        }
        return;
      }
      if (!DeepCatchup.differs(ours, peer)) return;
      if (!DeepCatchup.claimRound(
        peerId,
        ourHash: ours.hash,
        theirHash: peer.hash,
      )) {
        return;
      }
      debugPrint('🗄️ [SYNC] Older-history catch-up round with $peerId');
      _discovery.requestHashRepair(myId, peerId, theirTail);
    }());
  }

  Future<void> _attachLocalMessageQuickScanTrigger(String myId) async {
    await _localMessagesSub?.cancel();
    _primeMessageListLength = true;
    final db = await _ref.read(databaseProvider.future);
    db.onDeepDigestReady = () => _onDeepDigestReady(myId);
    db.scheduleDeepDigest();
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
  void onLocalDatabaseWrite({
    String? messageId,
    String source = 'local_write',
    String? excludePeerId,
  }) {
    final myId = _localNodeId;
    if (!_meshSessionActive || !_meshSessionReady || myId == null) {
      _pendingLocalDatabaseWrite = true;
      if (messageId?.isNotEmpty == true) {
        _pendingLocalWriteMessageId = messageId;
        traceBenchmarkMessage(
          messageId!,
          'SYNC_DEFERRED',
          fields: {
            'SOURCE': source,
            'MESH_SESSION_ACTIVE': _meshSessionActive,
            'MESH_SESSION_READY': _meshSessionReady,
            'LOCAL_NODE_ID_AVAILABLE': myId != null,
          },
        );
      }
      _pendingLocalWriteSource = source;
      debugPrint(
        '[MESH] Deferring local database sync '
        '(active=$_meshSessionActive ready=$_meshSessionReady '
        'nodeId=${myId != null} messageId=${messageId != null})',
      );
      return;
    }
    if (messageId != null) {
      traceBenchmarkMessage(
        messageId,
        'SYNC_REQUESTED',
        fields: {'SOURCE': source},
      );
    }
    // Our DB moved; every peer is behind until they hash-match again.
    BleDiscoveryService.markMeshStaleAfterLocalWrite(
      extraPeerIds: [...networkLastSeen.keys, ..._nameById.keys],
      excludePeerIds: excludePeerId == null ? const [] : [excludePeerId],
    );
    _presenceBump.add(null);
    _scheduleAdvertiserHashUpdate(myId);
    _discovery.requestUrgentSyncWithKnownPeers(
      myId,
      messageId: messageId,
      excludePeerId: excludePeerId,
    );
  }

  void _flushPendingLocalDatabaseWrite() {
    if (!_pendingLocalDatabaseWrite) return;
    final messageId = _pendingLocalWriteMessageId;
    final source = _pendingLocalWriteSource ?? 'local_write';
    _pendingLocalDatabaseWrite = false;
    _pendingLocalWriteMessageId = null;
    _pendingLocalWriteSource = null;
    debugPrint('[MESH] Flushing deferred local database sync');
    onLocalDatabaseWrite(messageId: messageId, source: 'deferred_$source');
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
      if (incoming.isMeshServiceStopRequested) {
        unawaited(_stopMeshSession());
        return;
      }
      if (incoming.isHeldClientAvailable) {
        _discovery.onHeldClientAvailable(
          incoming.macAddress,
          releaseInMs: incoming.heldClientReleaseInMs,
        );
        return;
      }
      if (incoming.isHeldClientUnavailable) {
        _discovery.onHeldClientUnavailable();
        return;
      }
      if (incoming.isServerConnect) {
        // A previous transfer may have lost its EOF when this MAC disconnected.
        // Its compressed bytes cannot be part of the new connection's offer.
        _incomingBuffersByMac.remove(incoming.macAddress);
        _incomingTransferByMac.remove(incoming.macAddress);
        _incomingFramedRepliesByMac.remove(incoming.macAddress);
        _discovery.onServerClientConnected(incoming.macAddress);
        return;
      }
      if (incoming.isServerReady) {
        _discovery.onServerClientReady(incoming.macAddress);
        return;
      }
      if (incoming.isServerNotReady) {
        _discovery.onServerClientNotReady(incoming.macAddress);
        return;
      }
      if (incoming.isServerDisconnect) {
        if (incoming.macAddress.isEmpty) {
          _incomingBuffersByMac.clear();
          _incomingTransferByMac.clear();
          _incomingFramedRepliesByMac.clear();
          _discovery.clearInboundServerState();
        } else {
          final activeConnectionId =
              _incomingTransferByMac[incoming.macAddress]?['CONNECTION_ID'];
          if (incoming.connectionId == null ||
              activeConnectionId == null ||
              activeConnectionId == incoming.connectionId) {
            _incomingBuffersByMac.remove(incoming.macAddress);
            _incomingTransferByMac.remove(incoming.macAddress);
            _incomingFramedRepliesByMac.remove(incoming.macAddress);
          }
          _discovery.onServerClientDisconnected(incoming.macAddress);
        }
        return;
      }
      final eofMarker = utf8.encode('||EOF||');
      final senderMac = incoming.macAddress;
      var chunk = incoming.bytes;
      final existingConnectionId =
          _incomingTransferByMac[senderMac]?['CONNECTION_ID'];
      if (existingConnectionId != null &&
          incoming.connectionId != null &&
          existingConnectionId != incoming.connectionId) {
        _incomingBuffersByMac.remove(senderMac);
        _incomingTransferByMac.remove(senderMac);
        _incomingFramedRepliesByMac.remove(senderMac);
      }
      final transfer = _incomingTransferByMac.putIfAbsent(
        senderMac,
        () => <String, String>{},
      );
      if (incoming.attemptId?.isNotEmpty == true) {
        transfer['ATTEMPT_ID'] = incoming.attemptId!;
      }
      if (incoming.connectionId?.isNotEmpty == true) {
        transfer['CONNECTION_ID'] = incoming.connectionId!;
      }

      if (ApiService.ignoreMac != null && senderMac == ApiService.ignoreMac) {
        return; // Simulating out of range
      }
      if (ApiService.dropRate > 0 &&
          Random().nextDouble() < ApiService.dropRate) {
        return; // Simulating packet drop
      }

      FramedReplyRetryState? replyFeedbackState;
      int? replyFeedbackRound;
      bool markReplyFeedbackSent() {
        final state = replyFeedbackState;
        final round = replyFeedbackRound;
        return state != null &&
            round != null &&
            state.tryMarkFeedbackSent(round);
      }

      if (incoming.isReplyStart) {
        final framedReply = _IncomingFramedReply()
          ..transferId = incoming.replyTransferId
          ..chunkCount = incoming.replyChunkCount
          ..totalBytes = incoming.replyTotalBytes
          ..crc32 = incoming.replyCrc32
          ..attemptId = incoming.attemptId
          ..connectionId = incoming.connectionId;
        _incomingFramedRepliesByMac[senderMac] = framedReply;
        debugPrint(
          '[BLE_TRACE] EVENT:CLIENT_REPLY_TRANSFER_STARTED | '
          'TARGET_MAC:$senderMac | TRANSFER_ID:${incoming.replyTransferId} | '
          'CHUNKS:${incoming.replyChunkCount} | BYTES:${incoming.replyTotalBytes} | '
          'CRC32:${incoming.replyCrc32}',
        );
        return;
      }

      if (incoming.isReplyData) {
        final index = incoming.replyChunkIndex!;
        var framedReply = _incomingFramedRepliesByMac[senderMac];
        if (framedReply != null &&
            framedReply.attemptId != null &&
            incoming.attemptId != null &&
            framedReply.attemptId != incoming.attemptId) {
          framedReply = null;
        }
        framedReply ??= _IncomingFramedReply();
        if (incoming.attemptId?.isNotEmpty == true) {
          framedReply.attemptId = incoming.attemptId;
        }
        if (incoming.connectionId?.isNotEmpty == true) {
          framedReply.connectionId = incoming.connectionId;
        }
        if (index <= 0xFFFF && framedReply.chunks.length <= 0xFFFF) {
          framedReply.chunks[index] = incoming.bytes;
          _incomingFramedRepliesByMac[senderMac] = framedReply;
        }
        debugPrint(
          '[BLE_TRACE] EVENT:CLIENT_REPLY_CHUNK_BUFFERED | '
          'TARGET_MAC:$senderMac | INDEX:$index | '
          'BYTES:${incoming.bytes.length} | '
          'BUFFERED:${framedReply.chunks.length} | '
          'WALL_MS:${DateTime.now().millisecondsSinceEpoch}',
        );
        return;
      }

      if (incoming.isReplyEnd) {
        final transferId = incoming.replyTransferId!;
        final chunkCount = incoming.replyChunkCount;
        final totalBytes = incoming.replyTotalBytes;
        final expectedCrc32 = incoming.replyCrc32;
        var framedReply = _incomingFramedRepliesByMac[senderMac];
        if (framedReply == null ||
            (framedReply.attemptId != null &&
                incoming.attemptId != null &&
                framedReply.attemptId != incoming.attemptId)) {
          framedReply = _IncomingFramedReply();
          _incomingFramedRepliesByMac[senderMac] = framedReply;
        }
        if (incoming.attemptId?.isNotEmpty == true) {
          framedReply.attemptId = incoming.attemptId;
        }
        if (incoming.connectionId?.isNotEmpty == true) {
          framedReply.connectionId = incoming.connectionId;
        }
        replyFeedbackState = framedReply.feedbackState;
        replyFeedbackRound = replyFeedbackState.beginRound();
        if (chunkCount == null ||
            chunkCount < 0 ||
            chunkCount > 0xFFFF ||
            totalBytes == null ||
            totalBytes < 0 ||
            expectedCrc32 == null) {
          debugPrint(
            '[BLE_TRACE] EVENT:CLIENT_REPLY_END_METADATA_INVALID | '
            'TARGET_MAC:$senderMac | TRANSFER_ID:$transferId',
          );
          if (markReplyFeedbackSent()) {
            unawaited(
              _nativeMesh
                  .sendReplyFeedback(
                    senderMac,
                    transferId: transferId,
                    accepted: false,
                    retryAll: true,
                  )
                  .catchError((Object error) {
                    debugPrint('⚠️ Reply NACK failed for $senderMac: $error');
                  }),
            );
          }
          return;
        }

        final startMetadataMatches =
            (framedReply.transferId == null ||
                framedReply.transferId == transferId) &&
            (framedReply.chunkCount == null ||
                framedReply.chunkCount == chunkCount) &&
            (framedReply.totalBytes == null ||
                framedReply.totalBytes == totalBytes) &&
            (framedReply.crc32 == null || framedReply.crc32 == expectedCrc32);
        if (!startMetadataMatches) {
          debugPrint(
            '[BLE_TRACE] EVENT:CLIENT_REPLY_METADATA_MISMATCH | '
            'TARGET_MAC:$senderMac | TRANSFER_ID:$transferId',
          );
          if (markReplyFeedbackSent()) {
            unawaited(
              _nativeMesh
                  .sendReplyFeedback(
                    senderMac,
                    transferId: transferId,
                    accepted: false,
                    retryAll: true,
                  )
                  .catchError((Object error) {
                    debugPrint('⚠️ Reply NACK failed for $senderMac: $error');
                  }),
            );
          }
          return;
        }
        framedReply
          ..transferId = transferId
          ..chunkCount = chunkCount
          ..totalBytes = totalBytes
          ..crc32 = expectedCrc32;

        framedReply.chunks.removeWhere((index, _) => index >= chunkCount);
        final missing = <int>[
          for (var index = 0; index < chunkCount; index++)
            if (!framedReply.chunks.containsKey(index)) index,
        ];
        final useRetryAll = missing.length > _maxReplyMissingIndices;
        if (missing.isNotEmpty) {
          debugPrint(
            '[BLE_TRACE] EVENT:CLIENT_REPLY_CHUNKS_MISSING | '
            'TARGET_MAC:$senderMac | TRANSFER_ID:$transferId | '
            'MISSING:${missing.length} | RETRY_ALL:$useRetryAll',
          );
          if (markReplyFeedbackSent()) {
            unawaited(
              _nativeMesh
                  .sendReplyFeedback(
                    senderMac,
                    transferId: transferId,
                    accepted: false,
                    missingIndices: useRetryAll ? const <int>[] : missing,
                    retryAll: useRetryAll,
                  )
                  .catchError((Object error) {
                    debugPrint('⚠️ Reply NACK failed for $senderMac: $error');
                  }),
            );
          }
          return;
        }

        final builder = BytesBuilder(copy: false);
        for (var index = 0; index < chunkCount; index++) {
          builder.add(framedReply.chunks[index]!);
        }
        final payloadBytes = builder.takeBytes();
        final valid =
            payloadBytes.length == totalBytes &&
            _blePayloadCrc32(payloadBytes) == expectedCrc32;
        if (!valid) {
          debugPrint(
            '[BLE_TRACE] EVENT:CLIENT_REPLY_CHECKSUM_FAILED | '
            'TARGET_MAC:$senderMac | TRANSFER_ID:$transferId | '
            'EXPECTED_BYTES:$totalBytes | ACTUAL_BYTES:${payloadBytes.length} | '
            'EXPECTED_CRC32:$expectedCrc32 | ACTUAL_CRC32:${_blePayloadCrc32(payloadBytes)}',
          );
          if (markReplyFeedbackSent()) {
            unawaited(
              _nativeMesh
                  .sendReplyFeedback(
                    senderMac,
                    transferId: transferId,
                    accepted: false,
                    retryAll: true,
                  )
                  .catchError((Object error) {
                    debugPrint('⚠️ Reply NACK failed for $senderMac: $error');
                  }),
            );
          }
          return;
        }

        _incomingBuffersByMac[senderMac] = payloadBytes.toList(growable: true);
        transfer['REPLY_TRANSFER_ID'] = transferId.toString();
        transfer['REPLY_CHUNK_COUNT'] = chunkCount.toString();
        transfer['REPLY_CRC32'] = expectedCrc32.toString();
        chunk = eofMarker;
        debugPrint(
          '[BLE_TRACE] EVENT:CLIENT_REPLY_PAYLOAD_VALIDATED | '
          'TARGET_MAC:$senderMac | TRANSFER_ID:$transferId | '
          'CHUNKS:$chunkCount | BYTES:${payloadBytes.length} | '
          'CRC32:$expectedCrc32 | '
          'WALL_MS:${DateTime.now().millisecondsSinceEpoch}',
        );
      }

      final buffer = _incomingBuffersByMac.putIfAbsent(
        senderMac,
        () => <int>[],
      );

      if (chunk.length == eofMarker.length && listEquals(chunk, eofMarker)) {
        final transferFields = Map<String, Object?>.from(transfer);
        debugPrint(
          '📥 [SYNC] EOF received from $senderMac — buffer=${buffer.length} bytes',
        );
        debugPrint(
          '[BENCHMARK] TARGET_MAC:$senderMac | EVENT:DELTA_RECEIVED | BYTES:${buffer.length} | TIMESTAMP:${DateTime.now().millisecondsSinceEpoch}'
          '${transferFields.entries.map((entry) => ' | ${entry.key}:${entry.value}').join()}',
        );
        if (buffer.isEmpty) {
          debugPrint(
            '⚠️ [SYNC] Empty buffer at EOF from $senderMac — ignoring',
          );
          _incomingBuffersByMac.remove(senderMac);
          _incomingTransferByMac.remove(senderMac);
          return;
        }
        // Detach the complete frame now. A new transfer on the same MAC can
        // arrive while the asynchronous merge below is still running.
        final payloadBytes = List<int>.from(buffer);
        _incomingBuffersByMac.remove(senderMac);
        _incomingTransferByMac.remove(senderMac);

        Future<void>.microtask(() async {
          final serverSyncTotal = Stopwatch()..start();
          final replyTransferId = int.tryParse(
            transferFields['REPLY_TRANSFER_ID']?.toString() ?? '',
          );
          var replyPayloadValidated = false;
          final remoteMessageIdsToRelay = <String>{};
          String? remoteMessageSourceNodeId;
          void traceServerSyncStage(
            String stage,
            int elapsedUs, {
            Map<String, Object?> extraFields = const {},
          }) {
            final traceFields = <String>[
              'STAGE:$stage',
              'ELAPSED_US:$elapsedUs',
              'TOTAL_US:${serverSyncTotal.elapsedMicroseconds}',
              for (final entry in extraFields.entries)
                if (entry.value != null) '${entry.key}:${entry.value}',
              for (final entry in transferFields.entries)
                if (entry.value != null) '${entry.key}:${entry.value}',
              'WALL_MS:${DateTime.now().millisecondsSinceEpoch}',
            ];
            debugPrint(
              '[BLE_TRACE] EVENT:SERVER_SYNC_STAGE | ${traceFields.join(' | ')}',
            );
          }

          Future<T> measureServerSyncStage<T>(
            String stage,
            Future<T> Function() action, {
            Map<String, Object?> fields = const {},
          }) async {
            final timer = Stopwatch()..start();
            final value = await action();
            traceServerSyncStage(
              stage,
              timer.elapsedMicroseconds,
              extraFields: fields,
            );
            return value;
          }

          try {
            debugPrint(
              '🔄 [SYNC] Decompressing payload from $senderMac (${payloadBytes.length} bytes)...',
            );
            final decodeTimer = Stopwatch()..start();
            final decompressed = zlib.decode(payloadBytes);
            final String jsonStr = utf8.decode(decompressed);
            final decodedJson = jsonDecode(jsonStr);
            traceServerSyncStage(
              'payload_decode',
              decodeTimer.elapsedMicroseconds,
            );
            if (decodedJson is! Map) {
              debugPrint('❌ [SYNC] Decoded JSON is not a Map from $senderMac');
              if (replyTransferId != null) {
                if (markReplyFeedbackSent()) {
                  await _nativeMesh.sendReplyFeedback(
                    senderMac,
                    transferId: replyTransferId,
                    accepted: false,
                    retryAll: true,
                  );
                }
              }
              return;
            }
            final root = Map<String, dynamic>.from(decodedJson);
            final type = root['type'] as String?;
            if (type != null && type != 'offer' && type != 'delta') {
              debugPrint(
                '❌ [SYNC] Unexpected payload type=$type from $senderMac',
              );
              if (replyTransferId != null) {
                if (markReplyFeedbackSent()) {
                  await _nativeMesh.sendReplyFeedback(
                    senderMac,
                    transferId: replyTransferId,
                    accepted: false,
                    retryAll: true,
                  );
                }
              }
              return;
            }
            replyPayloadValidated = true;
            if (replyTransferId != null) {
              await _nativeMesh.sendReplyFeedback(
                senderMac,
                transferId: replyTransferId,
                accepted: true,
              );
              _incomingFramedRepliesByMac.remove(senderMac);
              traceServerSyncStage(
                'reply_payload_ack_sent',
                serverSyncTotal.elapsedMicroseconds,
                extraFields: {
                  'TRANSFER_ID': replyTransferId,
                  'PAYLOAD_BYTES': payloadBytes.length,
                  'VALIDATION': 'length_crc_zlib_json_map',
                },
              );
            }
            debugPrint('📦 [SYNC] Received type=$type from $senderMac');

            final traceChangesetRaw = type == 'offer'
                ? root['initiator_data']
                : (root['data'] ?? root['changes']);
            if (traceChangesetRaw is Map) {
              traceBenchmarkMessageRows(
                'PAYLOAD_DECODED',
                Map<String, dynamic>.from(traceChangesetRaw),
                fields: {
                  'TARGET_MAC': senderMac,
                  'PAYLOAD_TYPE': type ?? 'legacy_delta',
                  ...transferFields,
                },
              );
            }

            final db = await _ref.read(databaseProvider.future);

            if (type == 'offer') {
              final senderHash = root['sender_hash'] as int?;
              final senderId = root['sender_id'] as String?;
              remoteMessageSourceNodeId = senderId;
              final neighborsRaw = root['neighbors'];
              final vectorRaw = root['vector'];

              // 1) Store topology for the sender (offer gossip).
              if (senderId != null) {
                BleDiscoveryService.markBluetoothActivity(senderId);
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

              // Hash gossip is useful even when we cannot build a delta reply.
              final gossipHash = await measureServerSyncStage(
                'offer_gossip_hash',
                db.getDatabaseHash,
              );
              BleDiscoveryService.applyGossipPeerHashes(
                root['peer_hashes'],
                localHash: gossipHash,
                excludeNodeId: _localNodeId ?? db.localNodeId,
              );
              if (senderId != null && senderHash != null) {
                BleDiscoveryService.notePeerHashObservation(
                  senderId,
                  senderHash,
                  localHash: gossipHash,
                );
              }

              // 2) Respond with an offer delta (surgical changeset).
              if (senderHash == null || vectorRaw is! Map) {
                debugPrint(
                  '⚠️ [SYNC] Offer missing senderHash or vector from $senderMac — skipping reply',
                );
                return;
              }
              final remoteVector = Map<String, dynamic>.from(vectorRaw);
              final normalizedRemoteVector = <String, String>{
                for (final entry in remoteVector.entries)
                  if (entry.value != null)
                    entry.key.toString(): entry.value.toString(),
              };
              // A database hash can be shared by converged peers, so it cannot
              // identify the active GATT connection. Reply only to the exact
              // address reported by the native connection callback.
              final targetMac = senderMac.isNotEmpty && senderMac != '<unknown>'
                  ? senderMac
                  : null;
              if (targetMac == null) {
                debugPrint(
                  '⚠️ Offer: no direct GATT address for sender_id=$senderId',
                );
                return;
              }

              // 2a) Merge the initiator's own pushed changeset (offer+push bidirectional sync).
              // This is the key fix for the one-way propagation blackout: previously the server
              // (D1/D2) only replied to D3 with what D3 was missing, but never received D3's
              // own messages. Now D3 includes its changeset in the offer, and we merge it here.
              final initiatorDataRaw = root['initiator_data'];
              if (initiatorDataRaw is Map && initiatorDataRaw.isNotEmpty) {
                final initiatorChangeset = Map<String, dynamic>.from(
                  initiatorDataRaw,
                );
                final shouldRelayMessages = OfferReplyPlanner.shouldRelay(
                  envelope: root,
                  hasNewerMessages: await db.hasNewerIncomingMessages(
                    initiatorChangeset,
                  ),
                );
                final rowCounts = initiatorChangeset.map(
                  (t, rows) => MapEntry(t, (rows as List).length),
                );
                final totalRows = rowCounts.values.fold(0, (a, b) => a + b);
                debugPrint(
                  '📥 [SYNC] Merging initiator_data from $senderMac — $totalRows rows: $rowCounts',
                );
                traceBenchmarkMessageRows(
                  'MERGE_STARTED',
                  initiatorChangeset,
                  fields: {
                    'TARGET_MAC': senderMac,
                    'MERGE_PATH': 'offer_initiator_data',
                    ...transferFields,
                  },
                );
                await measureServerSyncStage(
                  'offer_merge',
                  () => db.mergeSyncChangeset(
                    initiatorChangeset,
                    onStage: (stage, elapsedUs) {
                      traceServerSyncStage(
                        'offer_merge_$stage',
                        elapsedUs,
                        extraFields: {
                          'MERGE_ROW_COUNT': totalRows,
                          'MERGE_TABLE_COUNT': rowCounts.length,
                        },
                      );
                    },
                  ),
                  fields: {
                    'MERGE_ROW_COUNT': totalRows,
                    'MERGE_TABLE_COUNT': rowCounts.length,
                  },
                );
                traceBenchmarkMessageRows(
                  'MERGED',
                  initiatorChangeset,
                  fields: {
                    'TARGET_MAC': senderMac,
                    'MERGE_PATH': 'offer_initiator_data',
                    ...transferFields,
                  },
                );
                if (shouldRelayMessages) {
                  remoteMessageIdsToRelay.addAll(
                    benchmarkMessageIds(initiatorChangeset),
                  );
                }
              }

              debugPrint(
                '📤 [SYNC] Computing delta for offer from senderId=$senderId...',
              );
              final prioritizeNewestForLatency = _discovery.hasRecentLocalWrite;
              if (!prioritizeNewestForLatency) {
                final localVector = await measureServerSyncStage(
                  'offer_version_vector',
                  db.getVersionVector,
                );
                final localAheadNodes = localVector.entries.where((entry) {
                  final remoteHlc = normalizedRemoteVector[entry.key];
                  return remoteHlc == null ||
                      entry.value.compareTo(remoteHlc) > 0;
                }).length;
                final remoteAheadNodes = normalizedRemoteVector.entries.where((
                  entry,
                ) {
                  final localHlc = localVector[entry.key];
                  return localHlc == null ||
                      entry.value.compareTo(localHlc) > 0;
                }).length;
                traceServerSyncStage(
                  'offer_frontier_compare',
                  0,
                  extraFields: {
                    'LOCAL_VECTOR_NODES': localVector.length,
                    'REMOTE_VECTOR_NODES': normalizedRemoteVector.length,
                    'LOCAL_AHEAD_NODES': localAheadNodes,
                    'REMOTE_AHEAD_NODES': remoteAheadNodes,
                    'LOCAL_NODE_ID': db.localNodeId,
                    'LOCAL_NODE_FRONTIER': localVector[db.localNodeId],
                    'REMOTE_LOCAL_NODE_FRONTIER':
                        normalizedRemoteVector[db.localNodeId],
                  },
                );
              }
              var delta = prioritizeNewestForLatency
                  ? await measureServerSyncStage(
                      'offer_urgent_newest_rows',
                      () => db.getNewestRowsChangeset(maxRows: 8),
                    )
                  : await measureServerSyncStage(
                      'offer_delta_query',
                      () => db.getDeltaChangeset(remoteVector, maxRows: 25),
                    );
              if (prioritizeNewestForLatency) {
                debugPrint(
                  '[BLE_TRACE] EVENT:SERVER_REPLY_PRIORITY | '
                  'MODE:newest_rows | MAX_ROWS:8 | TARGET_MAC:$targetMac | '
                  'WALL_MS:${DateTime.now().millisecondsSinceEpoch}',
                );
              }
              final ourSenderHash = await measureServerSyncStage(
                'offer_post_merge_hash',
                db.getDatabaseHash,
              );
              // Whole-history digest. Never consulted on the urgent path, so it
              // cannot slow live messages down. Elsewhere it is brought up to
              // date first (about 80 ms on a Pixel 3, and only when something
              // was just merged): a digest one merge out of date would make
              // the peer re-send the very rows we just received.
              final remoteDeep = DeepCatchup.parse(root);
              if (senderId != null && remoteDeep != null) {
                DeepCatchup.remember(senderId, remoteDeep);
              }
              final ourDeep = prioritizeNewestForLatency
                  ? null
                  : await db.computeDeepDigest();
              final deepMismatch = DeepCatchup.differs(ourDeep, remoteDeep);
              debugPrint(
                '🔎 [SYNC] Offer from $senderId — deep: '
                'ours=${ourDeep == null ? 'none' : 'hash'}, '
                'theirs=${remoteDeep == null
                    ? 'none'
                    : remoteDeep.hasBuckets
                    ? 'buckets'
                    : 'hash'}, '
                'mismatch=$deepMismatch, delta=${delta.isEmpty ? 'empty' : 'rows'}',
              );

              // Remember the peer's window fingerprints whenever they arrive.
              var fingerprints = PeerFingerprints.missing;
              List<int>? remoteBuckets;
              final fpsB64 = root['fps_b'] ?? root['row_fps'];
              if (fpsB64 is String && fpsB64.isNotEmpty) {
                fingerprints = PeerFingerprints.unusable;
                try {
                  final raw = base64Decode(fpsB64);
                  if (raw.length ==
                      DatabaseService.fingerprintBucketCount * 4) {
                    remoteBuckets = DatabaseService.decodeBucketFingerprints(
                      raw,
                    );
                    fingerprints = PeerFingerprints.usable;
                    if (senderId != null) {
                      BleDiscoveryService.rememberPeerBuckets(
                        senderId,
                        remoteBuckets,
                      );
                    }
                  }
                } catch (e) {
                  debugPrint('⚠️ [SYNC] fps_b decode failed: $e');
                }
              }

              // Which rows to send back. Repairs only scan for absent rows when
              // the version-vector delta is empty (loading the full CRDT on
              // every live write stalled Pixel 3 replies for seconds).
              var deltaStalled = false;
              if (senderId != null && !prioritizeNewestForLatency) {
                if (delta.isEmpty) {
                  OfferReplyPlanner.stalledDeltas.forget(senderId);
                } else {
                  deltaStalled = OfferReplyPlanner.stalledDeltas.record(
                    senderId,
                    jsonEncode(delta).hashCode,
                  );
                  if (deltaStalled) {
                    debugPrint(
                      '⚠️ [SYNC] Same delta sent to $senderId again and '
                      'again — trying gap repair first',
                    );
                  }
                }
              }
              final plan = await OfferReplyPlanner.plan(
                delta: delta,
                deltaStalled: deltaStalled,
                deepBucketsMismatch:
                    deepMismatch && (remoteDeep?.hasBuckets ?? false),
                fingerprints: fingerprints,
                windowHashesDiffer: senderHash != ourSenderHash,
                deepRows: () => measureServerSyncStage(
                  'offer_deep_repair',
                  () => db.getRowsForDeepMismatch(
                    remoteDeep!.buckets,
                    maxRows: BleDiscoveryService.repairPageRows,
                    peerKey: senderId ?? '',
                  ),
                ),
                windowRows: () => measureServerSyncStage(
                  'offer_bucket_repair',
                  () => db.getRowsForMismatchedBuckets(
                    remoteBuckets!,
                    maxRows: BleDiscoveryService.repairPageRows,
                    peerKey: senderId ?? '',
                  ),
                ),
                hashRepairRows: () => measureServerSyncStage(
                  'offer_hash_repair',
                  () => db.getHashRepairChangeset(peerKey: senderId),
                ),
                newestRows: () => db.getNewestRowsChangeset(maxRows: 8),
              );
              delta = plan.delta;
              final usedRepair = plan.isRepair;
              var fpsComplete = plan.fingerprintsComplete;
              if (usedRepair) {
                debugPrint(
                  '📥 [SYNC] Gap fill for $senderId via ${plan.source.name} — '
                  '${OfferReplyPlanner.countRows(delta)} row(s)',
                );
              }
              var selectedDeltaRows = 0;
              var selectedDeltaTombstones = 0;
              for (final rows in delta.values) {
                if (rows is! List) continue;
                selectedDeltaRows += rows.length;
                for (final row in rows) {
                  if (row is! Map) continue;
                  final deleted = row['is_deleted'];
                  if (deleted == 1 ||
                      deleted == true ||
                      deleted?.toString() == '1') {
                    selectedDeltaTombstones++;
                  }
                }
              }
              traceServerSyncStage(
                'offer_delta_selected',
                0,
                extraFields: {
                  'MODE': prioritizeNewestForLatency
                      ? 'newest_rows'
                      : (usedRepair
                            ? 'bucket_or_hash_repair'
                            : 'version_vector'),
                  'DELTA_ROWS': selectedDeltaRows,
                  'DELTA_TOMBSTONES': selectedDeltaTombstones,
                  'DELTA_TABLES': delta.length,
                  'REMOTE_VECTOR_NODES': normalizedRemoteVector.length,
                },
              );
              debugPrint(
                '📤 [SYNC] Delta has ${delta.length} entries — replying to $targetMac',
              );

              // Keep reply GATT short so the initiator can turn around to peer #2.
              delta = usedRepair
                  ? BleDiscoveryService.truncateChangesetForBle(
                      delta,
                      maxRowsPerTable: BleDiscoveryService.repairPageRows,
                    )
                  : BleDiscoveryService.truncateChangesetForBle(
                      delta,
                      maxRowsPerTable: 25,
                    );

              final localId = _localNodeId ?? db.localNodeId;

              // Always send back a delta envelope so the initiator receives our
              // neighbor gossip even when no changes are needed.
              final ourFpsBlob = await measureServerSyncStage(
                'offer_bucket_fingerprints',
                db.getBucketFingerprintBlob,
              );
              final replyEncodeTimer = Stopwatch()..start();
              final deltaEnvelope = <String, dynamic>{
                'type': 'delta',
                'sender_id': localId,
                'sender_hash': ourSenderHash,
                'neighbors': _discovery.currentNeighborIds,
                'peer_hashes': _discovery.peerHashesForGossip(),
                'fps_b': base64Encode(ourFpsBlob),
                if (ourDeep != null) ...{
                  DeepCatchup.hashKey: ourDeep.hash,
                  // Fingerprints follow only once the hashes are known to differ.
                  if (deepMismatch)
                    DeepCatchup.bucketsKey: base64Encode(ourDeep.buckets),
                },
                if (usedRepair) BleDiscoveryService.repairFlagKey: true,
                'data': delta,
              };
              var outBytes = zlib.encode(
                utf8.encode(jsonEncode(deltaEnvelope)),
              );
              // Prefer keeping gap-fill rows over fingerprints when over budget.
              var replyComplete = true;
              if (outBytes.length > BleDiscoveryService.maxOfferPushBytes) {
                deltaEnvelope
                  ..remove(DeepCatchup.hashKey)
                  ..remove(DeepCatchup.bucketsKey);
                outBytes = zlib.encode(utf8.encode(jsonEncode(deltaEnvelope)));
              }
              if (outBytes.length > BleDiscoveryService.maxOfferPushBytes) {
                deltaEnvelope.remove('fps_b');
                outBytes = zlib.encode(utf8.encode(jsonEncode(deltaEnvelope)));
                fpsComplete = false;
              }
              if (outBytes.length > BleDiscoveryService.maxOfferPushBytes) {
                delta = usedRepair
                    ? BleDiscoveryService.truncateChangesetForBle(delta)
                    : BleDiscoveryService.shrinkChangesetForBle(delta);
                deltaEnvelope['data'] = delta;
                outBytes = zlib.encode(utf8.encode(jsonEncode(deltaEnvelope)));
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
              traceServerSyncStage(
                'offer_reply_encode',
                replyEncodeTimer.elapsedMicroseconds,
              );

              final replyChangeset = Map<String, dynamic>.from(
                deltaEnvelope['data'] as Map,
              );
              final replyMessageIds = benchmarkMessageIds(replyChangeset);
              traceBenchmarkMessageRows(
                'REPLY_INCLUDED',
                replyChangeset,
                fields: {
                  'TARGET_MAC': targetMac,
                  'PAYLOAD_TYPE': 'delta',
                  'ROW_COUNT': replyMessageIds.length,
                },
              );
              await _nativeMesh.replyPayload(
                targetMac,
                Uint8List.fromList(outBytes),
                benchmarkMessageIds: replyMessageIds,
              );
              traceServerSyncStage('offer_reply_submit', 0);
              debugPrint(
                '✅ [SYNC] Delta reply sent to $targetMac via NOTIFY (${outBytes.length} bytes)',
              );

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
                    !deepMismatch &&
                    senderHash == ourSenderHash) {
                  BleDiscoveryService.markSyncComplete(senderId);
                } else if (senderHash != ourSenderHash) {
                  BleDiscoveryService.markSyncDiverged(senderId);
                }
              }
              return;
            }

            if (type == 'delta' || type == null) {
              // Update topology/presence for delta gossip.
              final senderHash = root['sender_hash'] as int?;
              final senderId = root['sender_id'] as String?;
              remoteMessageSourceNodeId = senderId;
              final neighborsRaw = root['neighbors'];

              // Even legacy packets (type == null) can still teach identity/presence if they
              // include sender fields.
              if (senderId != null) {
                BleDiscoveryService.markBluetoothActivity(senderId);
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
                // We dialed this MAC as initiator — bind it as the reconnect target.
                BleDiscoveryService.claimOrphanDialSuccess(senderId, senderMac);
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
                final gossipHash = await db.getDatabaseHash();
                BleDiscoveryService.applyGossipPeerHashes(
                  root['peer_hashes'],
                  localHash: gossipHash,
                  excludeNodeId: _localNodeId ?? db.localNodeId,
                );
                if (senderId != null && senderHash != null) {
                  BleDiscoveryService.notePeerHashObservation(
                    senderId,
                    senderHash,
                    localHash: gossipHash,
                  );
                }
                debugPrint(
                  '⚠️ [SYNC] Delta from $senderMac has no data/changes field',
                );
                return;
              }
              final changeset = Map<String, dynamic>.from(dataRaw);
              final rowCounts = changeset.map(
                (t, rows) => MapEntry(t, (rows as List).length),
              );
              final totalRows = rowCounts.values.fold(0, (a, b) => a + b);
              debugPrint(
                '📥 [SYNC] Merging delta from $senderMac — $totalRows rows across ${changeset.length} tables: $rowCounts',
              );
              if (changeset.isNotEmpty) {
                final shouldRelayMessages = OfferReplyPlanner.shouldRelay(
                  envelope: root,
                  hasNewerMessages: await db.hasNewerIncomingMessages(
                    changeset,
                  ),
                );
                traceBenchmarkMessageRows(
                  'MERGE_STARTED',
                  changeset,
                  fields: {
                    'TARGET_MAC': senderMac,
                    'MERGE_PATH': 'delta',
                    ...transferFields,
                  },
                );
                await db.mergeSyncChangeset(changeset);
                debugPrint('✅ [SYNC] Merged $totalRows rows from $senderMac');
                traceBenchmarkMessageRows(
                  'MERGED',
                  changeset,
                  fields: {
                    'TARGET_MAC': senderMac,
                    'MERGE_PATH': 'delta',
                    ...transferFields,
                  },
                );
                if (shouldRelayMessages) {
                  remoteMessageIdsToRelay.addAll(
                    benchmarkMessageIds(changeset),
                  );
                }
              } else {
                debugPrint(
                  'ℹ️ [SYNC] Empty changeset from $senderMac — nothing to merge',
                );
              }

              // Client handshake finished once the server's delta reply arrives.
              final localHash = await db.getDatabaseHash();
              BleDiscoveryService.applyGossipPeerHashes(
                root['peer_hashes'],
                localHash: localHash,
                excludeNodeId: _localNodeId ?? db.localNodeId,
              );
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
                final remoteDeep = DeepCatchup.parse(root);
                if (remoteDeep != null) {
                  DeepCatchup.remember(senderId, remoteDeep);
                }
                if (senderHash != null) {
                  BleDiscoveryService.notePeerHashObservation(
                    senderId,
                    senderHash,
                    localHash: localHash,
                  );
                }
                if (senderHash != null && senderHash != localHash) {
                  BleDiscoveryService.markSyncDiverged(senderId);
                  debugPrint(
                    '⚠️ [SYNC] Hash still diverges after delta from $senderId — '
                    'clearing sync cooldown for fast retry',
                  );
                  _discovery.requestHashRepair(
                    _localNodeId ?? db.localNodeId,
                    senderId,
                    senderHash,
                  );
                } else {
                  BleDiscoveryService.markSyncComplete(senderId);
                  // Recent windows agree: keep reconciling older history until
                  // the whole-history digests agree too. If ours is stale it
                  // is recomputing and [_continueDeepCatchup] picks this up.
                  if (senderHash != null) {
                    _continueDeepCatchup(senderId, senderHash);
                  }
                }
              }
              _presenceBump.add(null);

              try {
                final hashBytes = await db.getDatabaseHashBytes();
                final b64 = base64Encode(hashBytes);
                if (b64 != _lastAdvertisedHashB64) {
                  _lastAdvertisedHashB64 = b64;
                  final payload = _buildAdvertiserPayload(hashBytes);
                  await _nativeMesh.updateAdvertiserHash(
                    payload,
                    _localNodeId ?? db.localNodeId,
                  );
                  _discovery.setLocalHash(payload);
                }
              } catch (e, st) {
                debugPrint('NATIVE MESH HASH UPDATE FAILED: $e\n$st');
              }
            }
          } catch (e, st) {
            if (replyTransferId != null && !replyPayloadValidated) {
              if (markReplyFeedbackSent()) {
                try {
                  await _nativeMesh.sendReplyFeedback(
                    senderMac,
                    transferId: replyTransferId,
                    accepted: false,
                    retryAll: true,
                  );
                } catch (feedbackError) {
                  debugPrint(
                    '⚠️ [SYNC] Reply NACK failed for $senderMac: $feedbackError',
                  );
                }
              }
            }
            debugPrint(
              '❌ [SYNC] Mesh processing error from $senderMac: $e\n$st',
            );
          } finally {
            if (remoteMessageIdsToRelay.isNotEmpty) {
              final sourceNodeId =
                  remoteMessageSourceNodeId ??
                  BleDiscoveryService.macToNodeId[senderMac];
              traceBenchmarkMessageRows(
                'REMOTE_RELAY_SCHEDULED',
                {
                  'messages': [
                    for (final messageId in remoteMessageIdsToRelay)
                      {'msg_id': messageId},
                  ],
                },
                fields: {
                  'SOURCE_NODE_ID': sourceNodeId ?? '',
                  'TARGET_MAC': senderMac,
                },
              );
              onLocalDatabaseWrite(
                messageId: remoteMessageIdsToRelay.first,
                source: 'remote_merge',
                excludePeerId: sourceNodeId,
              );
            }
          }
        });
      } else {
        buffer.addAll(chunk);
        debugPrint(
          '📡 [SYNC] Chunk from $senderMac: ${chunk.length} bytes (total buffer: ${buffer.length})',
        );
      }
    });
    final inboundState = await _nativeMesh.getInboundServerState();
    if (inboundState != null) {
      _discovery.replaceInboundServerState(
        activeMacs: inboundState['active'] ?? const <String>[],
        readyMacs: inboundState['ready'] ?? const <String>[],
      );
    }
    _discovery.replaceReusableHeldClientState(
      await _nativeMesh.getReusableHeldClientMac(),
    );
  }

  Future<void> _startMeshSession() async {
    if (_meshSessionActive || state.adapterStatus != BleAdapterStatus.on) {
      return;
    }
    _meshSessionActive = true;
    _meshSessionReady = false;
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
      // Start while the app is visible so Android's background-start rules are
      // satisfied before mesh radio work begins.
      await _nativeMesh.startMeshForegroundService();
      final ownMac = await _nativeMesh.startNativeServer(payload, myId);
      _ownBleMac = ownMac;
      if (ownMac != null && ownMac.isNotEmpty) {
        debugPrint(
          '[MESH] Own BLE MAC: $ownMac (will filter from scan results)',
        );
      }
      await _attachNativeIncomingSync();
      await _discovery.startScanning(
        myNodeId: myId,
        ownMac: ownMac,
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
      _meshSessionReady = true;
      _flushPendingLocalDatabaseWrite();
    } catch (e, st) {
      debugPrint('🔥 [MESH] _startMeshSession FAILED: $e\n$st');
      _meshSessionActive = false;
      _meshSessionReady = false;
      await _discovery.stopAll();
      await _nativeMesh.resetServer();
      await _nativeMesh.stopMeshForegroundService();
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

  Future<void> _stopMeshSession({bool stopForegroundService = true}) async {
    debugPrint(
      '[MESH] Stopping mesh session stopForegroundService=$stopForegroundService',
    );
    _meshSessionActive = false;
    _meshSessionReady = false;
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
    await _nativeMesh.resetServer();
    if (stopForegroundService) {
      await _nativeMesh.stopMeshForegroundService();
    } else {
      await _nativeMesh.setMeshForegroundServiceActive(false);
    }
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
      bluetoothHardwareEnabled:
          FlutterBluePlus.adapterStateNow == BluetoothAdapterState.on,
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
      _meshSessionReady = false;
      await _nativeMesh.resetServer();
      await _nativeMesh.stopMeshForegroundService();
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

  /// Stops only peer discovery while keeping the app's mesh session active.
  /// The stress runner uses this to pause every selected scanner before it
  /// resets their GATT servers, then resumes scanning after all servers are ready.
  Future<void> stopScanning() async {
    await _discovery.stopScanning();
    _publishRadioFlags();
  }

  /// Stops scan + peripheral advertising.
  Future<void> stopNetwork() async {
    _meshSessionActive = false;
    _meshSessionReady = false;
    await _nativePayloadSub?.cancel();
    _nativePayloadSub = null;
    await _localMessagesSub?.cancel();
    _localMessagesSub = null;
    await _localProfilesSub?.cancel();
    _localProfilesSub = null;
    await _discovery.stopAll();
    await _nativeMesh.resetServer();
    await _nativeMesh.stopMeshForegroundService();
    _publishRadioFlags();
  }

  @override
  void dispose() {
    _meshSessionActive = false;
    _meshSessionReady = false;
    if (identical(onLocalCrdtWrite, _localWriteHook)) {
      onLocalCrdtWrite = null;
    }
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
    this.rssiDbm,
    this.rssiSeenAt,
    this.isTalking = false,
    this.meshCaughtUp,
    this.routeViaId,
    this.routeViaName,
  });

  final String id;
  final String name;
  final String? macAddress;
  final PeerStatus status;
  final DateTime lastSeen;
  final int? rssiDbm;
  final DateTime? rssiSeenAt;
  final bool isTalking;

  /// `true` when advertised/synced CRDT hash last matched ours, `false` when
  /// known behind, `null` before the first trustworthy observation.
  final bool? meshCaughtUp;
  final String? routeViaId;
  final String? routeViaName;
}

final activePeersProvider = StreamProvider<List<MeshNodeState>>((ref) async* {
  final notifier = ref.watch(bleNetworkProvider.notifier);
  yield* notifier.watchActivePeers();
});

enum PeerStatus { direct, indirect, disconnected }
