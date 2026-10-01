import 'package:flutter_test/flutter_test.dart';

import 'package:bluetooth_app/models/conversation.dart';

void main() {
  test('the same people always open the same chat', () {
    const me = '11111111-1111-4111-8111-111111111111';
    const ava = '22222222-2222-4222-8222-222222222222';
    const noah = '33333333-3333-4333-8333-333333333333';

    expect(
      ConversationIds.forMembers(myNodeId: me, otherIds: [ava]),
      ConversationIds.direct(me, ava),
    );
    expect(
      ConversationIds.forMembers(myNodeId: me, otherIds: [ava, ava]),
      ConversationIds.direct(ava, me),
    );

    final group = ConversationIds.forMembers(
      myNodeId: me,
      otherIds: [noah, ava],
    );
    expect(
      group,
      ConversationIds.forMembers(myNodeId: me, otherIds: [ava, noah, ava]),
    );
    expect(group, ConversationIds.group([noah, me, ava]));
    expect(ConversationIds.members(group), [me, ava, noah]);
  });
}
