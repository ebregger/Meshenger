import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bluetooth_app/models/conversation.dart';
import 'package:bluetooth_app/models/text_message_with_author.dart';
import 'package:bluetooth_app/services/mesh_crypto.dart';

void main() {
  test('a long private thread opens in one batch, in order', () async {
    final alice = await MeshIdentity.generate();
    final bob = await MeshIdentity.generate();
    final conversation = ConversationIds.direct('alice', 'bob');
    final keys = {'alice': alice.publicKeyBase64, 'bob': bob.publicKeyBase64};

    final sealed = <TextMessageWithAuthor>[];
    for (var i = 0; i < 20; i++) {
      final fromAlice = i.isEven;
      final text = await MeshCrypto.seal(
        plaintext: 'line $i',
        sender: fromAlice ? alice : bob,
        recipientPublicKey: fromAlice
            ? bob.publicKeyBase64
            : alice.publicKeyBase64,
        conversationId: conversation,
        originNodeId: fromAlice ? 'alice' : 'bob',
        recipientNodeId: fromAlice ? 'bob' : 'alice',
      );
      sealed.add(
        TextMessageWithAuthor(
          msgId: 'm$i',
          originNodeId: fromAlice ? 'alice' : 'bob',
          textContent: text,
          timestamp: Int64(i),
          authorName: fromAlice ? 'Alice' : 'Bob',
          conversationId: conversation,
          recipientNodeId: fromAlice ? 'bob' : 'alice',
          contentEncoding: MeshCrypto.contentEncoding,
        ),
      );
    }

    // Bob's phone opens Alice's and his own messages together.
    final opened = await MeshCrypto.openForViewer(
      messages: sealed,
      identity: bob,
      publicKeys: keys,
      myNodeId: 'bob',
    );
    expect(
      [for (final m in opened) m.textContent],
      [for (var i = 0; i < 20; i++) 'line $i'],
    );
    expect(opened.any((m) => m.locked), isFalse);

    // A phone that is not part of the chat cannot read any of it.
    final eve = await MeshIdentity.generate();
    final locked = await MeshCrypto.openForViewer(
      messages: sealed,
      identity: eve,
      publicKeys: keys,
      myNodeId: 'eve',
    );
    expect(locked.every((m) => m.locked), isTrue);
  });
}
