import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:bluetooth_app/services/ble_discovery_service.dart';
import 'package:bluetooth_app/services/native_mesh_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_ble_peer.dart';

void main() {
  test(
    'fake peer advertises Meshenger and streams a chunked transfer',
    () async {
      final peer = FakeBlePeer(
        nodeId: 'node0001',
        macAddress: '02:00:00:00:00:01',
      );
      final nativeMesh = NativeMeshService(incomingEvents: peer.events);
      final received = <IncomingBleChunk>[];
      final subscription = nativeMesh.incomingPayloads.listen(received.add);
      addTearDown(() async {
        await subscription.cancel();
        await peer.close();
      });

      expect(
        BleDiscoveryService.advertisesMeshService(peer.advertisement),
        isTrue,
      );

      peer.connect();
      peer.markReady();
      final payload = Uint8List.fromList(List<int>.generate(47, (i) => i + 1));
      peer.sendBytes(payload, chunkSize: 11);
      peer.endTransfer();
      peer.disconnect();

      expect(received.where((event) => event.isServerConnect), hasLength(1));
      expect(received.where((event) => event.isServerReady), hasLength(1));
      expect(received.last.isServerDisconnect, isTrue);

      final dataEvents = received.where((event) => event.bytes.isNotEmpty);
      final reconstructed = dataEvents.expand((event) => event.bytes).toList();
      expect(reconstructed, <int>[...payload, ...'||EOF||'.codeUnits]);
      expect(
        dataEvents.every((event) => event.macAddress == peer.macAddress),
        isTrue,
      );
      expect(
        dataEvents.every((event) => event.connectionId == peer.connectionId),
        isTrue,
      );
    },
  );

  test('ten fake nodes transfer independently over one inbound slot', () async {
    final peers = List<FakeBlePeer>.generate(10, (index) {
      final number = index + 1;
      final suffix = number.toString().padLeft(3, '0');
      final macSuffix = number.toRadixString(16).padLeft(2, '0');
      return FakeBlePeer(
        nodeId: 'n${suffix}peer',
        macAddress: '02:00:00:00:00:$macSuffix',
        databaseHash: 0x1020304050607000 + number,
      );
    });
    final rawEvents = StreamController<Object?>.broadcast(sync: true);
    final peerSubscriptions = peers
        .map((peer) => peer.events.listen(rawEvents.add))
        .toList();
    final nativeMesh = NativeMeshService(incomingEvents: rawEvents.stream);
    final received = <IncomingBleChunk>[];
    final subscription = nativeMesh.incomingPayloads.listen(received.add);
    addTearDown(() async {
      await subscription.cancel();
      for (final peerSubscription in peerSubscriptions) {
        await peerSubscription.cancel();
      }
      await rawEvents.close();
      for (final peer in peers) {
        await peer.close();
      }
    });

    final expectedBytesByMac = <String, List<int>>{};
    for (final peer in peers) {
      expect(
        BleDiscoveryService.advertisesMeshService(peer.advertisement),
        isTrue,
      );
      peer.connect();
      peer.markReady();
      final payload = Uint8List.fromList(
        utf8.encode('hello from ${peer.nodeId}'),
      );
      peer.sendBytes(payload, chunkSize: 7);
      peer.endTransfer();
      peer.disconnect();
      expectedBytesByMac[peer.macAddress] = <int>[
        ...payload,
        ...'||EOF||'.codeUnits,
      ];
    }

    expect(received.where((event) => event.isServerConnect), hasLength(10));
    expect(received.where((event) => event.isServerReady), hasLength(10));
    expect(received.where((event) => event.isServerDisconnect), hasLength(10));

    for (final peer in peers) {
      final peerEvents = received.where(
        (event) => event.macAddress == peer.macAddress,
      );
      final peerBytes = peerEvents
          .where((event) => event.bytes.isNotEmpty)
          .expand((event) => event.bytes)
          .toList();
      expect(peerBytes, expectedBytesByMac[peer.macAddress]);
      expect(
        peerEvents.every((event) => event.connectionId == peer.connectionId),
        isTrue,
      );
    }
  });
}
