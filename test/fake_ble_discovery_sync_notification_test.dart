import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_crdt/sqlite_crdt.dart';

import 'package:bluetooth_app/models/generated/mesh_data.pb.dart';
import 'package:bluetooth_app/models/text_message_with_author.dart';
import 'package:bluetooth_app/services/ble_discovery_service.dart';
import 'package:bluetooth_app/services/database_service.dart';
import 'package:bluetooth_app/services/incoming_notification_planner.dart';

import 'fakes/fake_ble_peer.dart';
import 'fakes/fake_mesh_bluetooth.dart';

void main() {
  test(
    'fake peer is discovered, synced, and eligible for a background notification',
    () async {
      const senderNodeId = 'abcd-sender-node';
      const receiverNodeId = 'wxyz-receiver-node';
      final peer = FakeBlePeer(
        nodeId: senderNodeId,
        macAddress: '02:00:00:00:00:2a',
        databaseHash: 0x1122334455667788,
        rssi: -61,
      );
      addTearDown(peer.close);

      final discovered = BleDiscoveryService.inspectAdvertisement(
        peer.advertisement,
      );
      expect(discovered.isMeshPeer, isTrue);
      expect(discovered.advertisesService, isTrue);
      expect(discovered.macAddress, peer.macAddress);
      expect(discovered.rssi, -61);
      expect(discovered.nodeIdPrefix, 'abcd');
      expect(discovered.databaseHash, 0x1122334455667788);
      expect(
        BleDiscoveryService.advertisesMeshService(peer.advertisement),
        isTrue,
      );

      final sender = DatabaseService.forTesting(await SqliteCrdt.openInMemory());
      final receiver = DatabaseService.forTesting(
        await SqliteCrdt.openInMemory(),
      );
      addTearDown(sender.dispose);
      addTearDown(receiver.dispose);
      await sender.init();
      await receiver.init();

      const messageId = 'discovered-sync-message';
      await sender.upsertTextMessage(
        TextMessage(
          msgId: messageId,
          originNodeId: senderNodeId,
          textContent: 'hello from the fake peer',
          timestamp: Int64(42),
        ),
      );

      final radio = FakeMeshBluetooth();
      await _exchange(sender, receiver, radio, senderMac: peer.macAddress);
      expect(radio.connectionCount, greaterThanOrEqualTo(1));
      expect(radio.chunkCount, greaterThan(radio.connectionCount));

      final stored = await receiver.fetchTextMessages();
      expect(stored.map((message) => message.msgId), contains(messageId));
      final synced = stored.firstWhere((message) => message.msgId == messageId);

      final visible = TextMessageWithAuthor(
        msgId: synced.msgId,
        originNodeId: synced.originNodeId,
        textContent: synced.textContent,
        timestamp: synced.timestamp,
        authorName: discovered.nodeIdPrefix ?? 'peer',
      );

      final planner = IncomingNotificationPlanner()..myNodeId = receiverNodeId;
      expect(planner.acceptSnapshot(const []), isEmpty);

      planner.backgrounded = false;
      expect(planner.acceptSnapshot([visible]), isEmpty);

      final whileAway = IncomingNotificationPlanner()
        ..myNodeId = receiverNodeId
        ..backgrounded = true;
      expect(whileAway.acceptSnapshot(const []), isEmpty);
      expect(whileAway.acceptSnapshot([visible]), [messageId]);
      expect(
        whileAway.acceptSnapshot([visible]),
        isEmpty,
        reason: 'the same synced message is not notified twice',
      );

      final waitingForIdentity = IncomingNotificationPlanner()
        ..backgrounded = true;
      expect(waitingForIdentity.acceptSnapshot(const []), isEmpty);
      expect(waitingForIdentity.acceptSnapshot([visible]), isEmpty);
      expect(waitingForIdentity.acceptIdentity(receiverNodeId), [messageId]);

      final ownMessage = IncomingNotificationPlanner()
        ..myNodeId = senderNodeId
        ..backgrounded = true;
      expect(ownMessage.acceptSnapshot(const []), isEmpty);
      expect(ownMessage.acceptSnapshot([visible]), isEmpty);
    },
  );
}

Future<void> _exchange(
  DatabaseService sender,
  DatabaseService receiver,
  FakeMeshBluetooth radio, {
  required String senderMac,
}) async {
  final offer = <String, dynamic>{
    'type': 'offer',
    'sender_id': sender.localNodeId,
    'sender_hash': await sender.getDatabaseHash(),
    'vector': await sender.getVersionVector(),
    'initiator_data': await sender.getDeltaChangeset(
      await receiver.getVersionVector(),
      maxRows: 100,
    ),
  };
  final receivedOffer = await radio.transferFrame(
    senderNodeId: sender.localNodeId,
    senderMac: senderMac,
    senderDatabaseHash: offer['sender_hash'] as int,
    frame: offer,
  );
  final initiatorData = receivedOffer['initiator_data'];
  if (initiatorData is Map && initiatorData.isNotEmpty) {
    await receiver.mergeSyncChangeset(Map<String, dynamic>.from(initiatorData));
  }

  final reply = <String, dynamic>{
    'type': 'delta',
    'sender_id': receiver.localNodeId,
    'sender_hash': await receiver.getDatabaseHash(),
    'data': await receiver.getDeltaChangeset(
      Map<String, dynamic>.from(receivedOffer['vector'] as Map),
      maxRows: 100,
    ),
  };
  final receivedReply = await radio.transferFrame(
    senderNodeId: receiver.localNodeId,
    senderMac: '02:00:00:00:00:2b',
    senderDatabaseHash: reply['sender_hash'] as int,
    frame: reply,
  );
  final responderData = receivedReply['data'];
  if (responderData is Map && responderData.isNotEmpty) {
    await sender.mergeSyncChangeset(Map<String, dynamic>.from(responderData));
  }
}
