import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite_crdt/sqlite_crdt.dart';

import 'package:bluetooth_app/models/conversation.dart';
import 'package:bluetooth_app/models/generated/mesh_data.pb.dart';
import 'package:bluetooth_app/models/text_message_with_author.dart';
import 'package:bluetooth_app/services/chat_history_preferences.dart';
import 'package:bluetooth_app/services/database_service.dart';
import 'package:bluetooth_app/services/mesh_crypto.dart';

import 'fakes/fake_mesh_bluetooth.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'direct messages stay sealed for relays and open for participants',
    () async {
      final alice = await MeshIdentity.generate();
      final bob = await MeshIdentity.generate();
      final carol = await MeshIdentity.generate();
      final aliceDb = DatabaseService.forTesting(
        await SqliteCrdt.openInMemory(),
      );
      final bobDb = DatabaseService.forTesting(await SqliteCrdt.openInMemory());
      final carolDb = DatabaseService.forTesting(
        await SqliteCrdt.openInMemory(),
      );
      addTearDown(aliceDb.dispose);
      addTearDown(bobDb.dispose);
      addTearDown(carolDb.dispose);
      await aliceDb.init();
      await bobDb.init();
      await carolDb.init();

      const aliceId = 'alice-node';
      const bobId = 'bob-node';
      const conversationId = 'dm:alice-node:bob-node';
      await aliceDb.setLocalPublicKey(aliceId, alice.publicKeyBase64);
      await bobDb.setLocalPublicKey(bobId, bob.publicKeyBase64);
      await aliceDb.setLocalPublicKey(bobId, bob.publicKeyBase64);
      await bobDb.setLocalPublicKey(aliceId, alice.publicKeyBase64);

      const plaintext = 'meet by the north door';
      final sealed = await MeshCrypto.seal(
        plaintext: plaintext,
        sender: alice,
        recipientPublicKey: bob.publicKeyBase64,
        conversationId: conversationId,
        originNodeId: aliceId,
        recipientNodeId: bobId,
      );
      expect(sealed.contains(plaintext), isFalse);

      await aliceDb.upsertTextMessage(
        TextMessage(
          msgId: 'dm-1',
          originNodeId: aliceId,
          textContent: sealed,
          timestamp: Int64(10),
        ),
        conversationId: conversationId,
        recipientNodeId: bobId,
        contentEncoding: MeshCrypto.contentEncoding,
      );
      await aliceDb.upsertTextMessage(
        TextMessage(
          msgId: 'room-1',
          originNodeId: aliceId,
          textContent: 'public hello',
          timestamp: Int64(11),
        ),
      );

      final radio = FakeMeshBluetooth();
      await _sync(aliceDb, bobDb, radio);
      await _sync(bobDb, carolDb, radio);

      final bobMessages = await _visible(
        bobDb,
        identity: bob,
        myId: bobId,
        conversationId: conversationId,
      );
      expect(bobMessages.single.textContent, plaintext);
      expect(bobMessages.single.locked, isFalse);

      final carolMessages = await _visible(
        carolDb,
        identity: carol,
        myId: 'carol-node',
        conversationId: conversationId,
      );
      expect(carolMessages, isEmpty);

      final carolStored = await carolDb.fetchTextMessages();
      final relayed = carolStored.firstWhere(
        (message) => message.msgId == 'dm-1',
      );
      expect(relayed.textContent.contains(plaintext), isFalse);

      final room = await _visible(
        carolDb,
        identity: carol,
        myId: 'carol-node',
        conversationId: ConversationIds.room,
      );
      expect(room.single.textContent, 'public hello');
    },
  );

  test('group chats reuse one id and stay hidden from relays', () async {
    final alice = await MeshIdentity.generate();
    final bob = await MeshIdentity.generate();
    final carol = await MeshIdentity.generate();
    final dave = await MeshIdentity.generate();
    final db = DatabaseService.forTesting(await SqliteCrdt.openInMemory());
    addTearDown(db.dispose);
    await db.init();

    const aliceId = '11111111-1111-4111-8111-111111111111';
    const bobId = '22222222-2222-4222-8222-222222222222';
    const carolId = '33333333-3333-4333-8333-333333333333';
    const daveId = '44444444-4444-4444-8444-444444444444';
    final conversationId = ConversationIds.forMembers(
      myNodeId: aliceId,
      otherIds: [carolId, bobId],
    );
    expect(
      conversationId,
      ConversationIds.forMembers(myNodeId: aliceId, otherIds: [bobId, carolId]),
    );

    await db.setLocalPublicKey(aliceId, alice.publicKeyBase64);
    await db.setLocalPublicKey(bobId, bob.publicKeyBase64);
    await db.setLocalPublicKey(carolId, carol.publicKeyBase64);

    const plaintext = 'north stair, three minutes';
    final members = ConversationIds.members(conversationId);
    final sealed = await MeshCrypto.sealForMembers(
      plaintext: plaintext,
      sender: alice,
      senderNodeId: aliceId,
      memberIds: members,
      publicKeys: {
        aliceId: alice.publicKeyBase64,
        bobId: bob.publicKeyBase64,
        carolId: carol.publicKeyBase64,
      },
      conversationId: conversationId,
    );
    expect(sealed, isNotNull);
    expect(sealed!.contains(plaintext), isFalse);

    await db.upsertTextMessage(
      TextMessage(
        msgId: 'group-1',
        originNodeId: aliceId,
        textContent: sealed,
        timestamp: Int64(1),
      ),
      conversationId: conversationId,
      contentEncoding: MeshCrypto.contentEncoding,
    );

    final membersToCheck = [
      (identity: alice, id: aliceId),
      (identity: bob, id: bobId),
      (identity: carol, id: carolId),
    ];
    for (final member in membersToCheck) {
      final visible = await _visible(
        db,
        identity: member.identity,
        myId: member.id,
        conversationId: conversationId,
      );
      expect(visible.single.textContent, plaintext);
      expect(visible.single.locked, isFalse);
    }

    expect(
      await _visible(
        db,
        identity: dave,
        myId: daveId,
        conversationId: conversationId,
      ),
      isEmpty,
    );
    expect(
      await MeshCrypto.sealForMembers(
        plaintext: plaintext,
        sender: alice,
        senderNodeId: aliceId,
        memberIds: members,
        publicKeys: {bobId: bob.publicKeyBase64},
        conversationId: conversationId,
      ),
      isNull,
    );
  });

  test('clearing and retention only change this phone', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = ChatHistoryPreferences(
      preferences: await SharedPreferences.getInstance(),
    );
    expect(await preferences.readDays(), 0);
    await preferences.writeDays(7);
    expect(await preferences.readDays(), 7);

    final sender = DatabaseService.forTesting(await SqliteCrdt.openInMemory());
    final receiver = DatabaseService.forTesting(
      await SqliteCrdt.openInMemory(),
    );
    addTearDown(sender.dispose);
    addTearDown(receiver.dispose);
    await sender.init();
    await receiver.init();

    final now = DateTime.now().millisecondsSinceEpoch;
    final old = now - const Duration(days: 10).inMilliseconds;
    await sender.upsertTextMessage(
      TextMessage(
        msgId: 'old-room',
        originNodeId: 'self',
        textContent: 'stale',
        timestamp: Int64(old),
      ),
    );
    await sender.upsertTextMessage(
      TextMessage(
        msgId: 'new-room',
        originNodeId: 'self',
        textContent: 'fresh',
        timestamp: Int64(now),
      ),
    );
    await sender.upsertTextMessage(
      TextMessage(
        msgId: 'dm-old',
        originNodeId: 'self',
        textContent: 'secret',
        timestamp: Int64(old),
      ),
      conversationId: 'dm:other:self',
      recipientNodeId: 'other',
      contentEncoding: MeshCrypto.contentEncoding,
    );

    final radio = FakeMeshBluetooth();
    await _sync(sender, receiver, radio);
    expect(await receiver.fetchTextMessages(), hasLength(3));

    final removed = await sender.scrubTextMessages(
      olderThanTimestampMs: now - const Duration(days: 7).inMilliseconds,
      participantNodeId: 'self',
    );
    expect(removed, 2);
    final hashBefore = await sender.getDatabaseHash();
    await _sync(sender, receiver, radio);

    // The receiver keeps everything; nothing was tombstoned.
    final received = await receiver.fetchTextMessages();
    expect(received.map((message) => message.msgId).toSet(), {
      'old-room',
      'new-room',
      'dm-old',
    });
    expect(received.every((message) => message.textContent.isNotEmpty), isTrue);

    // The sender keeps row stubs so sync state still matches its peers.
    expect(await sender.getDatabaseHash(), hashBefore);
    final readable = await sender
        .watchTextMessagesWithAuthors(conversationId: '')
        .first;
    expect(readable.map((message) => message.msgId).toList(), ['new-room']);

    await sender.scrubTextMessages(conversationId: ConversationIds.room);
    expect(
      await sender.watchTextMessagesWithAuthors(conversationId: '').first,
      isEmpty,
    );
    await _sync(sender, receiver, radio);
    expect(
      (await receiver.fetchTextMessages()).map((m) => m.textContent),
      contains('fresh'),
    );
  });
}

Future<List<TextMessageWithAuthor>> _visible(
  DatabaseService database, {
  required MeshIdentity identity,
  required String myId,
  required String conversationId,
}) async {
  final batch = await database
      .watchTextMessagesWithAuthors(
        conversationId: conversationId,
        viewerNodeId: myId,
      )
      .first;
  return MeshCrypto.openForViewer(
    messages: batch,
    identity: identity,
    publicKeys: await database.fetchPublicKeys(),
    myNodeId: myId,
  );
}

Future<void> _sync(
  DatabaseService sender,
  DatabaseService receiver,
  FakeMeshBluetooth radio,
) async {
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
    senderMac: '02:00:00:00:00:31',
    senderDatabaseHash: offer['sender_hash'] as int,
    frame: offer,
  );
  final initiatorData = receivedOffer['initiator_data'];
  if (initiatorData is Map && initiatorData.isNotEmpty) {
    await receiver.mergeSyncChangeset(Map<String, dynamic>.from(initiatorData));
  }
}
