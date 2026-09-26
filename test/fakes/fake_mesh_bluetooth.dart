import 'dart:convert';
import 'dart:typed_data';
import 'dart:io' show zlib;

import 'package:bluetooth_app/services/ble_discovery_service.dart';
import 'package:bluetooth_app/services/native_mesh_service.dart';

import 'fake_ble_peer.dart';

/// In-memory, chunked transport that uses the same peer advertisement and
/// native-event decoding boundary as the BLE application.
class FakeMeshBluetooth {
  int connectionCount = 0;
  int chunkCount = 0;
  int bytesTransferred = 0;

  Future<Map<String, dynamic>> transferFrame({
    required String senderNodeId,
    required String senderMac,
    required int senderDatabaseHash,
    required Map<String, dynamic> frame,
  }) async {
    final peer = FakeBlePeer(
      nodeId: senderNodeId,
      macAddress: senderMac,
      databaseHash: senderDatabaseHash,
    );
    if (!BleDiscoveryService.advertisesMeshService(peer.advertisement)) {
      await peer.close();
      throw StateError('Fake peer did not advertise the Meshenger service');
    }

    final nativeMesh = NativeMeshService(incomingEvents: peer.events);
    final incomingFuture = nativeMesh.incomingPayloads.toList();
    final wireBytes = Uint8List.fromList(
      zlib.encode(utf8.encode(jsonEncode(frame))),
    );
    peer.connect();
    peer.markReady();
    peer.sendBytes(wireBytes, chunkSize: 20);
    peer.endTransfer();
    peer.disconnect();
    await peer.close();

    final events = await incomingFuture;
    final dataChunks = events.where((event) => event.bytes.isNotEmpty).toList();
    if (events.where((event) => event.isServerConnect).length != 1 ||
        events.where((event) => event.isServerReady).length != 1 ||
        events.where((event) => event.isServerDisconnect).length != 1) {
      throw StateError('Fake BLE connection lifecycle was not delivered');
    }
    final receivedBytes = Uint8List.fromList(
      dataChunks.expand((event) => event.bytes).toList(),
    );
    final eof = Uint8List.fromList('||EOF||'.codeUnits);
    if (receivedBytes.length < eof.length || !_endsWith(receivedBytes, eof)) {
      throw StateError('Fake BLE transfer did not end with the EOF marker');
    }

    final compressed = receivedBytes.sublist(
      0,
      receivedBytes.length - eof.length,
    );
    final decoded = jsonDecode(utf8.decode(zlib.decode(compressed)));
    if (decoded is! Map) {
      throw FormatException('Fake BLE frame did not contain a JSON object');
    }

    connectionCount++;
    chunkCount += dataChunks.length;
    bytesTransferred += compressed.length;
    return Map<String, dynamic>.from(decoded);
  }

  bool _endsWith(Uint8List value, Uint8List suffix) {
    final start = value.length - suffix.length;
    for (var i = 0; i < suffix.length; i++) {
      if (value[start + i] != suffix[i]) return false;
    }
    return true;
  }
}
