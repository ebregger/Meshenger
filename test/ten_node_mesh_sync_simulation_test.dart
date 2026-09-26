import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_crdt/sqlite_crdt.dart';

import 'package:bluetooth_app/models/generated/mesh_data.pb.dart';
import 'package:bluetooth_app/services/database_service.dart';

import 'fakes/fake_mesh_bluetooth.dart';

class _MeshNode {
  const _MeshNode({required this.database, required this.macAddress});

  final DatabaseService database;
  final String macAddress;
}

void main() {
  test(
    'ten-node line mesh converges messages over simulated Bluetooth',
    () async {
      const nodeCount = 10;
      final nodes = <_MeshNode>[];
      addTearDown(() async {
        for (final node in nodes) {
          await node.database.dispose();
        }
      });

      for (var index = 0; index < nodeCount; index++) {
        final database = DatabaseService.forTesting(
          await SqliteCrdt.openInMemory(),
        );
        await database.init();
        final macSuffix = (index + 1).toRadixString(16).padLeft(2, '0');
        nodes.add(
          _MeshNode(
            database: database,
            macAddress: '02:00:00:00:00:$macSuffix',
          ),
        );
        await database.upsertTextMessage(
          TextMessage(
            msgId: 'origin-message-$index',
            originNodeId: database.localNodeId,
            textContent: 'Message originating on node ${index + 1}',
            timestamp: Int64(index + 1),
          ),
        );
      }

      final radio = FakeMeshBluetooth();
      var converged = false;
      for (var round = 0; round < nodeCount; round++) {
        // Nine links form a line. Sweep both ways to relay rows learned in the
        // first direction back toward nodes that already had their turn.
        for (var index = 0; index < nodeCount - 1; index++) {
          await _syncPair(nodes[index], nodes[index + 1], radio);
        }
        for (var index = nodeCount - 2; index >= 0; index--) {
          await _syncPair(nodes[index + 1], nodes[index], radio);
        }

        final hashes = await Future.wait(
          nodes.map((node) => node.database.getDatabaseHash()),
        );
        if (hashes.toSet().length == 1) {
          converged = true;
          break;
        }
      }

      expect(
        converged,
        isTrue,
        reason: 'all ten CRDT databases should converge',
      );
      expect(radio.connectionCount, greaterThanOrEqualTo(nodeCount - 1));
      expect(radio.chunkCount, greaterThan(radio.connectionCount));

      final expectedIds = <String>{
        for (var index = 0; index < nodeCount; index++) 'origin-message-$index',
      };
      for (final node in nodes) {
        final messages = await node.database.fetchTextMessages();
        expect(messages, hasLength(nodeCount));
        expect(messages.map((message) => message.msgId).toSet(), expectedIds);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

Future<void> _syncPair(
  _MeshNode sender,
  _MeshNode receiver,
  FakeMeshBluetooth radio,
) async {
  final senderVector = await sender.database.getVersionVector();
  final receiverVector = await receiver.database.getVersionVector();
  final initiatorData = await sender.database.getDeltaChangeset(
    receiverVector,
    maxRows: 100,
  );
  final offer = <String, dynamic>{
    'type': 'offer',
    'sender_id': sender.database.localNodeId,
    'sender_hash': await sender.database.getDatabaseHash(),
    'vector': senderVector,
    'initiator_data': initiatorData,
  };

  final receivedOffer = await radio.transferFrame(
    senderNodeId: sender.database.localNodeId,
    senderMac: sender.macAddress,
    senderDatabaseHash: offer['sender_hash'] as int,
    frame: offer,
  );
  final receivedInitiatorData = receivedOffer['initiator_data'];
  if (receivedInitiatorData is Map && receivedInitiatorData.isNotEmpty) {
    await receiver.database.mergeSyncChangeset(
      Map<String, dynamic>.from(receivedInitiatorData),
    );
  }

  final offerVector = Map<String, dynamic>.from(receivedOffer['vector'] as Map);
  final responderData = await receiver.database.getDeltaChangeset(
    offerVector,
    maxRows: 100,
  );
  final reply = <String, dynamic>{
    'type': 'delta',
    'sender_id': receiver.database.localNodeId,
    'sender_hash': await receiver.database.getDatabaseHash(),
    'data': responderData,
  };
  final receivedReply = await radio.transferFrame(
    senderNodeId: receiver.database.localNodeId,
    senderMac: receiver.macAddress,
    senderDatabaseHash: reply['sender_hash'] as int,
    frame: reply,
  );
  final receivedResponderData = receivedReply['data'];
  if (receivedResponderData is Map && receivedResponderData.isNotEmpty) {
    await sender.database.mergeSyncChangeset(
      Map<String, dynamic>.from(receivedResponderData),
    );
  }
}
