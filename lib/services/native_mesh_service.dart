import 'dart:async';

import 'package:flutter/services.dart';

class IncomingBleChunk {
  const IncomingBleChunk({
    required this.macAddress,
    required this.bytes,
  });

  final String macAddress;
  final Uint8List bytes;
}

class NativeMeshService {
  NativeMeshService()
      : _incomingPayloads = _bleEventsChannel
            .receiveBroadcastStream()
            .map(_coerceToIncomingChunk)
            .asBroadcastStream();

  static const MethodChannel _bleMethodChannel =
      MethodChannel('com.featherfawks.mesh/ble');

  static const EventChannel _bleEventsChannel =
      EventChannel('com.featherfawks.mesh/ble_events');

  final Stream<IncomingBleChunk> _incomingPayloads;

  Stream<IncomingBleChunk> get incomingPayloads => _incomingPayloads;

  Future<String?> startNativeServer(Uint8List currentHash) async {
    final ownMac = await _bleMethodChannel.invokeMethod<String>('start_server', <String, Object?>{
      'hash': currentHash,
    });
    return ownMac;
  }

  Future<void> updateAdvertiserHash(Uint8List newHash) async {
    await _bleMethodChannel.invokeMethod<void>('update_hash', <String, Object?>{
      'hash': newHash,
    });
  }

  Future<void> resetServer() async {
    try {
      await _bleMethodChannel.invokeMethod<void>('reset_server');
    } on PlatformException catch (e) {
      print('🔥 Native reset_server failed: ${e.message}');
    }
  }

  /// Power-cycles the Bluetooth adapter (Force OFF then ON) on Android 11 and below.
  /// Returns true if the toggle was attempted, false if restricted by OS version.
  Future<bool> forceToggleBluetooth() async {
    final result = await _bleMethodChannel.invokeMethod<bool>('force_toggle_bluetooth');
    return result ?? false;
  }

  Future<void> sendPayload(String macAddress, Uint8List payload, {bool isRandom = false}) async {
    try {
      await _bleMethodChannel.invokeMethod<void>(
        'send_payload',
        <String, Object?>{
          'macAddress': macAddress,
          'payload': payload,
          'isRandom': isRandom,
        },
      );
    } on PlatformException catch (e) {
      // ignore: avoid_print
      // (debugPrint is preferred but services layer doesn't import flutter/foundation.)
      // So we use print here strictly for runtime evidence.
      // ignore: avoid_print
      print(
        '🔥 Native send_payload failed mac=$macAddress code=${e.code} message=${e.message} details=${e.details}',
      );
      rethrow;
    }
  }

  Future<void> replyPayload(String macAddress, Uint8List payload) async {
    try {
      await _bleMethodChannel.invokeMethod<void>(
        'reply_payload',
        <String, Object?>{
          'macAddress': macAddress,
          'payload': payload,
        },
      );
    } on PlatformException catch (e) {
      print(
        '🔥 Native reply_payload failed mac=$macAddress code=${e.code} message=${e.message} details=${e.details}',
      );
      rethrow;
    }
  }

  static IncomingBleChunk _coerceToIncomingChunk(Object? event) {
    // Preferred format (new): { mac: "...", bytes: Uint8List/List<int> }
    if (event is Map) {
      final map = Map<Object?, Object?>.from(event);
      final mac = map['mac']?.toString();
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

    throw ArgumentError('Unsupported event type from native BLE channel: $event');
  }
}

