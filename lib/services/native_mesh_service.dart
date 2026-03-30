import 'dart:async';

import 'package:flutter/services.dart';

class NativeMeshService {
  NativeMeshService()
      : _incomingPayloads = _bleEventsChannel
            .receiveBroadcastStream()
            .map(_coerceToUint8List)
            .asBroadcastStream();

  static const MethodChannel _bleMethodChannel =
      MethodChannel('com.featherfawks.mesh/ble');

  static const EventChannel _bleEventsChannel =
      EventChannel('com.featherfawks.mesh/ble_events');

  final Stream<Uint8List> _incomingPayloads;

  Stream<Uint8List> get incomingPayloads => _incomingPayloads;

  Future<void> startNativeServer() async {
    await _bleMethodChannel.invokeMethod<void>('start_server');
  }

  Future<void> sendPayload(String macAddress, Uint8List payload) async {
    await _bleMethodChannel.invokeMethod<void>('send_payload', <String, Object?>{
      'macAddress': macAddress,
      'payload': payload,
    });
  }

  static Uint8List _coerceToUint8List(Object? event) {
    if (event is Uint8List) return event;
    if (event is List<int>) return Uint8List.fromList(event);
    throw ArgumentError('Unsupported event type from native BLE channel: $event');
  }
}

