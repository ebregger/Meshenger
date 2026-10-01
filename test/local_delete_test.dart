import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_crdt/sqlite_crdt.dart';

import 'package:bluetooth_app/models/generated/mesh_data.pb.dart';
import 'package:bluetooth_app/models/text_message_with_author.dart';
import 'package:bluetooth_app/services/database_service.dart';

const _alice = 'alice';
const _bob = 'bob';
const _dm = 'dm:alice:bob';
const _group = 'gc:alice|bob|carol';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DatabaseService aliceDb;
  late DatabaseService bobDb;
  late DatabaseService carolDb;

  setUp(() async {
    aliceDb = DatabaseService.forTesting(await SqliteCrdt.openInMemory());
    bobDb = DatabaseService.forTesting(await SqliteCrdt.openInMemory());
    carolDb = DatabaseService.forTesting(await SqliteCrdt.openInMemory());
    await aliceDb.init();
    await bobDb.init();
    await carolDb.init();
  });

  tearDown(() async {
    await aliceDb.dispose();
    await bobDb.dispose();
    await carolDb.dispose();
  });

  Future<void> say(
    DatabaseService db,
    String id,
    String from,
    String text, {
    String conversation = _dm,
  }) async {
    await db.upsertTextMessage(
      TextMessage(
        msgId: id,
        originNodeId: from,
        textContent: text,
        timestamp: Int64(DateTime.now().millisecondsSinceEpoch),
      ),
      conversationId: conversation,
    );
    // Keep hlc order stable between phones in the same millisecond.
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }

  Future<void> pull(DatabaseService from, DatabaseService to) async {
    final changes = await from.getDeltaChangeset(
      await to.getVersionVector(),
      maxRows: 500,
    );
    if (changes.isNotEmpty) {
      await to.mergeSyncChangeset(Map<String, dynamic>.from(changes));
    }
  }

  Future<void> syncBoth() async {
    await pull(aliceDb, bobDb);
    await pull(bobDb, aliceDb);
  }

  Future<List<TextMessageWithAuthor>> view(
    DatabaseService db,
    String viewer, {
    String conversation = _dm,
  }) {
    return db
        .watchTextMessagesWithAuthors(
          conversationId: conversation,
          viewerNodeId: viewer,
        )
        .first;
  }

  test(
    'deleting a chat keeps the other phone\'s copy and grays it out',
    () async {
      await say(aliceDb, 'm1', _alice, 'hi bob');
      await say(aliceDb, 'm2', _alice, 'you there?');
      await syncBoth();
      await say(bobDb, 'm3', _bob, 'yes!');
      await syncBoth();
      expect(await view(bobDb, _bob), hasLength(3));

      final noticeId = await aliceDb.deleteConversationLocally(
        conversationId: _dm,
        myNodeId: _alice,
        grayOutForOthers: true,
      );
      expect(noticeId, isNotNull);

      // Alice's chat is gone from her phone.
      expect(await view(aliceDb, _alice), isEmpty);
      expect(await aliceDb.watchPrivateConversationIds(_alice).first, isEmpty);

      // Until the notice travels, Bob sees nothing different.
      expect((await view(bobDb, _bob)).any((m) => m.retired), isFalse);

      await syncBoth();
      final bobView = await view(bobDb, _bob);
      expect(bobView.map((m) => m.textContent), [
        'hi bob',
        'you there?',
        'yes!',
      ]);
      expect(bobView.every((m) => m.retired && m.retiredBy == _alice), isTrue);

      // Neither phone removed the other's data; hashes agree again.
      expect(await aliceDb.getDatabaseHash(), await bobDb.getDatabaseHash());
      expect(await bobDb.watchPrivateConversationIds(_bob).first, [_dm]);
    },
  );

  test(
    'messages after a delete start a fresh chat; old ones stay gray',
    () async {
      await say(aliceDb, 'm1', _alice, 'old hello');
      await syncBoth();
      await aliceDb.deleteConversationLocally(
        conversationId: _dm,
        myNodeId: _alice,
        grayOutForOthers: true,
      );
      await syncBoth();

      await say(bobDb, 'm2', _bob, 'new start');
      await syncBoth();

      final alice = await view(aliceDb, _alice);
      expect(alice.map((m) => m.textContent), ['new start']);
      expect(alice.single.retired, isFalse);

      final bob = await view(bobDb, _bob);
      expect(bob.map((m) => m.textContent), ['old hello', 'new start']);
      expect(bob.map((m) => m.retired), [true, false]);
    },
  );

  test(
    'old messages that arrive after a delete are dropped on arrival',
    () async {
      // Bob wrote this before Alice deleted, but it had not reached her yet.
      await say(bobDb, 'late', _bob, 'sent before the delete');
      await say(aliceDb, 'm1', _alice, 'hello');

      await aliceDb.deleteConversationLocally(
        conversationId: _dm,
        myNodeId: _alice,
        grayOutForOthers: true,
      );
      await syncBoth();

      expect(await view(aliceDb, _alice), isEmpty);
      // Bob still has his own copy, now grayed.
      final bob = await view(bobDb, _bob);
      expect(bob.map((m) => m.textContent), contains('sent before the delete'));
      expect(bob.every((m) => m.retired), isTrue);
    },
  );

  test('the other person can delete their grayed copy', () async {
    await say(aliceDb, 'm1', _alice, 'hello');
    await syncBoth();
    await aliceDb.deleteConversationLocally(
      conversationId: _dm,
      myNodeId: _alice,
      grayOutForOthers: true,
    );
    await syncBoth();
    expect(await view(bobDb, _bob), hasLength(1));

    await bobDb.deleteRetiredMessagesLocally(_dm);

    expect(await view(bobDb, _bob), isEmpty);
    expect(await bobDb.watchPrivateConversationIds(_bob).first, isEmpty);
    // Deleting locally must not come back through sync either.
    await syncBoth();
    expect(await view(bobDb, _bob), isEmpty);
    expect(await view(aliceDb, _alice), isEmpty);
  });

  test(
    'deleting a group chat does not gray it out for other members',
    () async {
      await say(aliceDb, 'g1', _alice, 'team lunch?', conversation: _group);
      await syncBoth();

      final noticeId = await aliceDb.deleteConversationLocally(
        conversationId: _group,
        myNodeId: _alice,
        grayOutForOthers: false,
      );
      // Groups send nothing at all; the deletion stays on Alice's phone.
      expect(noticeId, isNull);
      await syncBoth();

      expect(await view(aliceDb, _alice, conversation: _group), isEmpty);
      final bob = await view(bobDb, _bob, conversation: _group);
      expect(bob.map((m) => m.textContent), ['team lunch?']);
      expect(bob.single.retired, isFalse);

      // New group messages reach Alice again.
      await say(bobDb, 'g2', _bob, 'noon works', conversation: _group);
      await syncBoth();
      final alice = await view(aliceDb, _alice, conversation: _group);
      expect(alice.map((m) => m.textContent), ['noon works']);
    },
  );

  test(
    'deleting an empty or already-deleted chat writes no extra notice',
    () async {
      expect(
        await aliceDb.deleteConversationLocally(
          conversationId: _dm,
          myNodeId: _alice,
          grayOutForOthers: true,
        ),
        isNull,
      );
      await say(aliceDb, 'm1', _alice, 'hello');
      expect(
        await aliceDb.deleteConversationLocally(
          conversationId: _dm,
          myNodeId: _alice,
          grayOutForOthers: true,
        ),
        isNotNull,
      );
      expect(
        await aliceDb.deleteConversationLocally(
          conversationId: _dm,
          myNodeId: _alice,
          grayOutForOthers: true,
        ),
        isNull,
      );
    },
  );

  test(
    'blanked copies are never passed on; others fill in the real messages',
    () async {
      await say(aliceDb, 'm1', _alice, 'hello');
      await pull(aliceDb, bobDb);
      await aliceDb.deleteConversationLocally(
        conversationId: _dm,
        myNodeId: _alice,
        grayOutForOthers: true,
      );

      // Carol has an incomplete picture and meets Alice first.
      await pull(aliceDb, carolDb);
      final fromAlice = await carolDb.fetchTextMessages();
      expect(fromAlice.where((m) => m.msgId == 'm1'), isEmpty);

      // Later she meets Bob, who still has the real message. Alice's blank
      // never stood in the way.
      final buckets = DatabaseService.decodeBucketFingerprints(
        await carolDb.getBucketFingerprintBlob(),
      );
      final repair = await bobDb.getRowsForMismatchedBuckets(buckets);
      await carolDb.mergeSyncChangeset(Map<String, dynamic>.from(repair));
      final carolRows = await carolDb.fetchTextMessages();
      expect(
        carolRows.singleWhere((m) => m.msgId == 'm1').textContent,
        'hello',
      );

      // Alice's own copy is still gone.
      expect(await view(aliceDb, _alice), isEmpty);
    },
  );

  test('a blank message from another phone is never accepted', () async {
    await say(bobDb, 'm1', _bob, 'real text');
    final changes = await bobDb.getDeltaChangeset(const {});
    final forged = {
      'messages': [
        for (final row in (changes['messages'] as List))
          {...(row as Map).cast<String, Object?>(), 'text_content': ''},
      ],
    };

    await carolDb.mergeSyncChangeset(forged);

    expect(await carolDb.fetchTextMessages(), isEmpty);
  });

  test('deletion notices from outside the chat are ignored', () async {
    await say(bobDb, 'm1', _bob, 'keep me');
    await bobDb.upsertTextMessage(
      TextMessage(
        msgId: 'forged',
        originNodeId: 'mallory',
        textContent: '{"v":1}',
        timestamp: Int64(DateTime.now().millisecondsSinceEpoch),
      ),
      conversationId: _dm,
      contentEncoding: DatabaseService.retireEncoding,
    );

    final shown = await view(bobDb, _bob);
    expect(shown.single.retired, isFalse);
    expect(await bobDb.deleteRetiredMessagesLocally(_dm), 0);
    expect((await view(bobDb, _bob)).single.textContent, 'keep me');
  });

  test('the chat list asks for one newest row per conversation', () async {
    await say(aliceDb, 'r1', _alice, 'room old', conversation: '');
    await say(aliceDb, 'r2', _alice, 'room new', conversation: '');
    await say(aliceDb, 'd1', _alice, 'dm old');
    await say(aliceDb, 'd2', _bob, 'dm new');

    final rows = await aliceDb.watchVisibleConversationRows(_alice).first;

    expect(rows, hasLength(2));
    final byConversation = {
      for (final row in rows)
        row['conversation_id'].toString(): row['text_content'].toString(),
    };
    expect(byConversation, {'': 'room new', _dm: 'dm new'});
  });

  test('clearing the shared room only clears this phone', () async {
    await say(aliceDb, 'r1', _alice, 'hi room', conversation: '');
    await pull(aliceDb, bobDb);
    await say(aliceDb, 'r2', _alice, 'still in flight', conversation: '');

    await bobDb.clearRoomLocally();
    await pull(aliceDb, bobDb);
    await pull(bobDb, aliceDb);

    // Bob's phone shows nothing, including the message that arrived late.
    expect(await view(bobDb, _bob, conversation: ''), isEmpty);
    // Alice keeps everything and is not told to hide it.
    final alice = await view(aliceDb, _alice, conversation: '');
    expect(alice.map((m) => m.textContent), ['hi room', 'still in flight']);
  });
}
