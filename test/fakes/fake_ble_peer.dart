import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:bluetooth_app/services/native_ble_radio.dart';

import 'package:bluetooth_app/constants/ble_constants.dart';

/// A deterministic peer that emits the same advertisement and GATT event
/// shapes consumed by the production BLE boundary.
class FakeBlePeer {
  FakeBlePeer({
    required this.nodeId,
    required this.macAddress,
    this.databaseHash = 0x10203040,
    this.rssi = -45,
    String? connectionId,
  }) : connectionId = connectionId ?? 'connection-$nodeId';

  final String nodeId;
  final String macAddress;
  final int databaseHash;
  final int rssi;
  final String connectionId;

  final StreamController<Object?> _events = StreamController<Object?>.broadcast(
    sync: true,
  );

  Stream<Object?> get events => _events.stream;

  MeshScanResult get advertisement => MeshScanResult(
    macAddress: macAddress,
    manufacturerData: <int, List<int>>{
      meshManufacturerId: <int>[
        0x4D,
        0x45,
        0x53,
        0x48,
        for (var shift = 56; shift >= 0; shift -= 8)
          (databaseHash >> shift) & 0xFF,
        ...utf8.encode(
          nodeId.length >= 4 ? nodeId.substring(0, 4) : nodeId.padRight(4),
        ),
      ],
    },
    serviceUuids: [meshServiceUuid],
    rssi: rssi,
    seenAt: DateTime.now(),
  );

  void connect() => _emit('server_connect');

  void markReady() => _emit('server_ready');

  void disconnect() => _emit('server_disconnect');

  void sendBytes(Uint8List bytes, {int chunkSize = 20, String? attemptId}) {
    if (chunkSize <= 0) throw ArgumentError.value(chunkSize, 'chunkSize');
    final effectiveAttemptId = attemptId ?? 'attempt-$nodeId';
    for (var offset = 0; offset < bytes.length; offset += chunkSize) {
      final end = offset + chunkSize < bytes.length
          ? offset + chunkSize
          : bytes.length;
      _events.add(<String, Object?>{
        'mac': macAddress,
        'bytes': Uint8List.sublistView(bytes, offset, end),
        'attemptId': effectiveAttemptId,
        'connectionId': connectionId,
      });
    }
  }

  void endTransfer() {
    sendBytes(Uint8List.fromList('||EOF||'.codeUnits), chunkSize: 20);
  }

  Future<void> close() => _events.close();

  void _emit(String event) {
    _events.add(<String, Object?>{
      'event': event,
      'mac': macAddress,
      'connectionId': connectionId,
    });
  }
}
