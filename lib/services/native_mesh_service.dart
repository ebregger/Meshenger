import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class IncomingBleChunk {
  const IncomingBleChunk({
    required this.macAddress,
    required this.bytes,
    this.isServerConnect = false,
    this.isServerReady = false,
    this.isServerNotReady = false,
    this.isServerDisconnect = false,
    this.isMeshServiceStopRequested = false,
    this.isHeldClientAvailable = false,
    this.isHeldClientUnavailable = false,
    this.heldClientReleaseInMs,
    this.attemptId,
    this.connectionId,
    this.replyChunkIndex,
    this.replyTransferId,
    this.replyChunkCount,
    this.replyTotalBytes,
    this.replyCrc32,
    this.isReplyStart = false,
  });

  final String macAddress;
  final Uint8List bytes;
  final bool isServerConnect;
  final bool isServerReady;
  final bool isServerNotReady;
  final bool isServerDisconnect;
  final bool isMeshServiceStopRequested;
  final bool isHeldClientAvailable;
  final bool isHeldClientUnavailable;
  final int? heldClientReleaseInMs;
  final String? attemptId;
  final String? connectionId;
  final int? replyChunkIndex;
  final int? replyTransferId;
  final int? replyChunkCount;
  final int? replyTotalBytes;
  final int? replyCrc32;
  final bool isReplyStart;

  bool get isReplyData => replyChunkIndex != null;
  bool get isReplyEnd => replyTransferId != null && !isReplyStart;
}

class NativeMeshService {
  NativeMeshService({Stream<Object?>? incomingEvents})
    : _incomingPayloads =
          (incomingEvents ?? _bleEventsChannel.receiveBroadcastStream())
              .map(_coerceToIncomingChunk)
              .asBroadcastStream();

  static const MethodChannel _bleMethodChannel = MethodChannel(
    'com.featherfawks.mesh/ble',
  );

  static const EventChannel _bleEventsChannel = EventChannel(
    'com.featherfawks.mesh/ble_events',
  );

  final Stream<IncomingBleChunk> _incomingPayloads;

  Stream<IncomingBleChunk> get incomingPayloads => _incomingPayloads;

  Future<void> startMeshForegroundService() async {
    await _bleMethodChannel.invokeMethod<bool>('start_mesh_foreground_service');
  }

  Future<void> stopMeshForegroundService() async {
    try {
      await _bleMethodChannel.invokeMethod<void>(
        'stop_mesh_foreground_service',
      );
    } on PlatformException catch (e) {
      debugPrint('🔥 Native mesh foreground service stop failed: ${e.message}');
    }
  }

  Future<void> setMeshForegroundServiceActive(bool active) async {
    try {
      await _bleMethodChannel.invokeMethod<bool>(
        'set_mesh_foreground_service_active',
        <String, Object?>{'active': active},
      );
    } on PlatformException catch (e) {
      debugPrint(
        '🔥 Native mesh foreground service update failed: ${e.message}',
      );
    }
  }

  Future<bool> getDebugWakeLockState() async {
    return await _bleMethodChannel.invokeMethod<bool>(
          'get_debug_wake_lock_state',
        ) ??
        false;
  }

  Future<bool> setDebugWakeLockEnabled(bool enabled) async {
    return await _bleMethodChannel.invokeMethod<bool>(
          'set_debug_wake_lock',
          <String, Object?>{'enabled': enabled},
        ) ??
        false;
  }

  Future<String?> startNativeServer(
    Uint8List currentHash,
    String nodeId,
  ) async {
    final ownMac = await _bleMethodChannel.invokeMethod<String>(
      'start_server',
      <String, Object?>{'hash': currentHash, 'nodeId': nodeId},
    );
    return ownMac;
  }

  Future<void> updateAdvertiserHash(Uint8List newHash, String nodeId) async {
    await _bleMethodChannel.invokeMethod<void>('update_hash', <String, Object?>{
      'hash': newHash,
      'nodeId': nodeId,
    });
  }

  /// Whether this Android build uses connectable extended BLE advertising.
  /// Returns null on platforms or older app builds that cannot report it.
  Future<bool?> usesExtendedConnectableAdvertising() async {
    try {
      return await _bleMethodChannel.invokeMethod<bool>(
        'uses_extended_connectable_advertising',
      );
    } on PlatformException catch (e) {
      debugPrint('🔥 Native advertiser capability query failed: ${e.message}');
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  Future<void> resetServer() async {
    try {
      await _bleMethodChannel.invokeMethod<void>('reset_server');
    } on PlatformException catch (e) {
      debugPrint('🔥 Native reset_server failed: ${e.message}');
    }
  }

  /// MACs with an active inbound GATT server connection (peer dialed us).
  Future<List<String>> getConnectedServerMacs() async {
    try {
      final raw = await _bleMethodChannel.invokeMethod<List<Object?>>(
        'connected_server_macs',
      );
      if (raw == null) return const [];
      return [
        for (final m in raw)
          if (m != null) m.toString(),
      ];
    } on PlatformException catch (e) {
      debugPrint('🔥 Native connected_server_macs failed: ${e.message}');
      return const [];
    }
  }

  /// MACs with an active inbound GATT connection, including links whose
  /// notification subscription has not completed yet.
  Future<List<String>> getActiveServerMacs() async {
    try {
      final raw = await _bleMethodChannel.invokeMethod<List<Object?>>(
        'active_server_macs',
      );
      if (raw == null) return const [];
      return [
        for (final mac in raw)
          if (mac != null) mac.toString(),
      ];
    } on PlatformException catch (e) {
      debugPrint('🔥 Native active_server_macs failed: ${e.message}');
      return const [];
    }
  }

  /// Snapshot of current inbound GATT links and the subset ready for NOTIFY.
  /// This is used to seed the event-driven state cache on app startup.
  Future<Map<String, List<String>>?> getInboundServerState() async {
    try {
      final raw = await _bleMethodChannel.invokeMethod<Map<Object?, Object?>>(
        'inbound_server_state',
      );
      if (raw == null) {
        return const <String, List<String>>{
          'active': <String>[],
          'ready': <String>[],
        };
      }
      List<String> stringsFor(String key) => [
        for (final value in raw[key] as List<Object?>? ?? const <Object?>[])
          if (value != null) value.toString(),
      ];
      return <String, List<String>>{
        'active': stringsFor('active'),
        'ready': stringsFor('ready'),
      };
    } on PlatformException catch (e) {
      debugPrint('🔥 Native inbound server state failed: ${e.message}');
      return null;
    }
  }

  /// Whether [macAddress] has an idle outbound GATT link that can accept a
  /// write without another connection attempt.
  Future<bool> hasReusableHeldClientForMac(String macAddress) async {
    try {
      return await _bleMethodChannel.invokeMethod<bool>(
            'has_held_client_for_mac',
            <String, Object?>{'macAddress': macAddress},
          ) ??
          false;
    } on PlatformException catch (e) {
      debugPrint(
        '🔥 Native held-client check failed for $macAddress: ${e.message}',
      );
      return false;
    }
  }

  /// MAC address of the idle held outbound GATT link, if one is reusable.
  /// The peer may have since rotated its advertising address, so callers map
  /// this address back to the stable peer identity before deciding to reuse it.
  Future<String?> getReusableHeldClientMac() async {
    try {
      return await _bleMethodChannel.invokeMethod<String>(
        'get_reusable_held_client_mac',
      );
    } on PlatformException catch (e) {
      debugPrint('🔥 Native held-client lookup failed: ${e.message}');
      return null;
    }
  }

  /// Power-cycles the Bluetooth adapter (Force OFF then ON) on Android 11 and below.
  /// Returns true if the toggle was attempted, false if restricted by OS version.
  Future<bool> forceToggleBluetooth() async {
    final result = await _bleMethodChannel.invokeMethod<bool>(
      'force_toggle_bluetooth',
    );
    return result ?? false;
  }

  Future<void> sendPayload(
    String macAddress,
    Uint8List payload, {
    bool isRandom = false,
    bool bypassDeadCache = false,
    List<String> benchmarkMessageIds = const [],
  }) async {
    try {
      await _bleMethodChannel
          .invokeMethod<void>('send_payload', <String, Object?>{
            'macAddress': macAddress,
            'payload': payload,
            'isRandom': isRandom,
            'bypassDeadCache': bypassDeadCache,
            'benchmarkMessageIds': benchmarkMessageIds,
          });
    } on PlatformException catch (e) {
      debugPrint(
        '🔥 Native send_payload failed mac=$macAddress code=${e.code} message=${e.message} details=${e.details}',
      );
      rethrow;
    }
  }

  Future<void> replyPayload(
    String macAddress,
    Uint8List payload, {
    List<String> benchmarkMessageIds = const [],
  }) async {
    try {
      await _bleMethodChannel
          .invokeMethod<void>('reply_payload', <String, Object?>{
            'macAddress': macAddress,
            'payload': payload,
            'benchmarkMessageIds': benchmarkMessageIds,
          });
    } on PlatformException catch (e) {
      debugPrint(
        '🔥 Native reply_payload failed mac=$macAddress code=${e.code} message=${e.message} details=${e.details}',
      );
      rethrow;
    }
  }

  Future<void> sendReplyFeedback(
    String macAddress, {
    required int transferId,
    required bool accepted,
    List<int> missingIndices = const <int>[],
    bool retryAll = false,
  }) async {
    await _bleMethodChannel
        .invokeMethod<void>('reply_feedback', <String, Object?>{
          'macAddress': macAddress,
          'transferId': transferId,
          'action': accepted ? 'ack' : 'nack',
          'missingIndices': missingIndices,
          'retryAll': retryAll,
        });
  }

  static IncomingBleChunk _coerceToIncomingChunk(Object? event) {
    if (event is Map) {
      final map = Map<Object?, Object?>.from(event);
      final eventType = map['event']?.toString();
      final mac = map['mac']?.toString();
      if (eventType == 'reply_data' && mac != null) {
        final rawBytes = map['bytes'];
        final bytes = rawBytes is Uint8List
            ? rawBytes
            : rawBytes is List
            ? Uint8List.fromList(rawBytes.cast<int>())
            : Uint8List(0);
        return IncomingBleChunk(
          macAddress: mac,
          bytes: bytes,
          attemptId: map['attemptId']?.toString(),
          replyChunkIndex: (map['chunkIndex'] as num?)?.toInt(),
        );
      }
      if ((eventType == 'reply_start' || eventType == 'reply_end') &&
          mac != null) {
        return IncomingBleChunk(
          macAddress: mac,
          bytes: Uint8List(0),
          attemptId: map['attemptId']?.toString(),
          replyTransferId: (map['transferId'] as num?)?.toInt(),
          replyChunkCount: (map['chunkCount'] as num?)?.toInt(),
          replyTotalBytes: (map['totalBytes'] as num?)?.toInt(),
          replyCrc32: (map['crc32'] as num?)?.toInt(),
          isReplyStart: eventType == 'reply_start',
        );
      }
      if (eventType == 'mesh_service_stop_requested') {
        return IncomingBleChunk(
          macAddress: '',
          bytes: Uint8List(0),
          isMeshServiceStopRequested: true,
        );
      }
      if (eventType == 'server_connect' && mac != null) {
        return IncomingBleChunk(
          macAddress: mac,
          bytes: Uint8List(0),
          isServerConnect: true,
          connectionId: map['connectionId']?.toString(),
        );
      }
      if (eventType == 'server_ready' && mac != null) {
        return IncomingBleChunk(
          macAddress: mac,
          bytes: Uint8List(0),
          isServerReady: true,
          connectionId: map['connectionId']?.toString(),
        );
      }
      if (eventType == 'server_not_ready' && mac != null) {
        return IncomingBleChunk(
          macAddress: mac,
          bytes: Uint8List(0),
          isServerNotReady: true,
          connectionId: map['connectionId']?.toString(),
        );
      }
      if (eventType == 'server_disconnect' && mac != null) {
        return IncomingBleChunk(
          macAddress: mac,
          bytes: Uint8List(0),
          isServerDisconnect: true,
          connectionId: map['connectionId']?.toString(),
        );
      }
      if (eventType == 'server_reset') {
        return IncomingBleChunk(
          macAddress: '',
          bytes: Uint8List(0),
          isServerDisconnect: true,
        );
      }
      if (eventType == 'held_link_ready' && mac != null) {
        return IncomingBleChunk(
          macAddress: mac,
          bytes: Uint8List(0),
          isHeldClientAvailable: true,
          heldClientReleaseInMs: (map['releaseInMs'] as num?)?.toInt(),
        );
      }
      if (eventType == 'held_link_busy' ||
          eventType == 'held_link_unavailable') {
        return IncomingBleChunk(
          macAddress: mac ?? '',
          bytes: Uint8List(0),
          isHeldClientUnavailable: true,
        );
      }
      final rawBytes = map['bytes'];
      if (mac != null) {
        if (rawBytes is Uint8List) {
          return IncomingBleChunk(
            macAddress: mac,
            bytes: rawBytes,
            attemptId: map['attemptId']?.toString(),
            connectionId: map['connectionId']?.toString(),
          );
        }
        if (rawBytes is List) {
          return IncomingBleChunk(
            macAddress: mac,
            bytes: Uint8List.fromList(rawBytes.cast<int>()),
            attemptId: map['attemptId']?.toString(),
            connectionId: map['connectionId']?.toString(),
          );
        }
      }
    }

    // Legacy format (old): just the bytes.
    if (event is Uint8List) {
      return IncomingBleChunk(macAddress: '<unknown>', bytes: event);
    }
    if (event is List<int>) {
      return IncomingBleChunk(
        macAddress: '<unknown>',
        bytes: Uint8List.fromList(event),
      );
    }

    throw ArgumentError(
      'Unsupported event type from native BLE channel: $event',
    );
  }
}
