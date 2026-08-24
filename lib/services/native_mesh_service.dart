import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class IncomingBleChunk {
  const IncomingBleChunk({
    required this.macAddress,
    required this.bytes,
    this.isServerConnect = false,
    this.isServerReady = false,
  });

  final String macAddress;
  final Uint8List bytes;
  final bool isServerConnect;
  final bool isServerReady;
}

class NativeMeshService {
  NativeMeshService()
    : _incomingPayloads = _bleEventsChannel
          .receiveBroadcastStream()
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
  }) async {
    try {
      await _bleMethodChannel
          .invokeMethod<void>('send_payload', <String, Object?>{
            'macAddress': macAddress,
            'payload': payload,
            'isRandom': isRandom,
            'bypassDeadCache': bypassDeadCache,
          });
    } on PlatformException catch (e) {
      debugPrint(
        '🔥 Native send_payload failed mac=$macAddress code=${e.code} message=${e.message} details=${e.details}',
      );
      rethrow;
    }
  }

  Future<void> replyPayload(String macAddress, Uint8List payload) async {
    try {
      await _bleMethodChannel.invokeMethod<void>(
        'reply_payload',
        <String, Object?>{'macAddress': macAddress, 'payload': payload},
      );
    } on PlatformException catch (e) {
      debugPrint(
        '🔥 Native reply_payload failed mac=$macAddress code=${e.code} message=${e.message} details=${e.details}',
      );
      rethrow;
    }
  }

  static IncomingBleChunk _coerceToIncomingChunk(Object? event) {
    if (event is Map) {
      final map = Map<Object?, Object?>.from(event);
      final eventType = map['event']?.toString();
      final mac = map['mac']?.toString();
      if (eventType == 'server_connect' && mac != null) {
        return IncomingBleChunk(
          macAddress: mac,
          bytes: Uint8List(0),
          isServerConnect: true,
        );
      }
      if (eventType == 'server_ready' && mac != null) {
        return IncomingBleChunk(
          macAddress: mac,
          bytes: Uint8List(0),
          isServerReady: true,
        );
      }
      final rawBytes = map['bytes'];
      if (mac != null) {
        if (rawBytes is Uint8List) {
          return IncomingBleChunk(macAddress: mac, bytes: rawBytes);
        }
        if (rawBytes is List) {
          return IncomingBleChunk(
            macAddress: mac,
            bytes: Uint8List.fromList(rawBytes.cast<int>()),
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
