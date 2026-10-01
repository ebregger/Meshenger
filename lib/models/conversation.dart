/// Conversation ids stored on each message row.
///
/// The empty id is the shared public room. Direct chats and group chats use a
/// stable id anyone in the chat can derive from the member set, so starting a
/// chat with the same people opens the existing thread.
class ConversationIds {
  const ConversationIds._();

  static const String room = '';

  static bool isDirect(String conversationId) =>
      conversationId.startsWith('dm:');

  static bool isGroup(String conversationId) =>
      conversationId.startsWith('gc:');

  static bool isPrivate(String conversationId) =>
      isDirect(conversationId) || isGroup(conversationId);

  static String direct(String nodeA, String nodeB) {
    final pair = <String>[nodeA, nodeB]..sort();
    return 'dm:${pair[0]}:${pair[1]}';
  }

  /// Group id for [memberIds], including the sender. Order does not matter.
  static String group(Iterable<String> memberIds) {
    final ids =
        memberIds
            .map((id) => id.trim())
            .where((id) => id.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    return 'gc:${ids.join('|')}';
  }

  /// One other person is a direct chat. Two or more other people is a group
  /// that also includes [myNodeId].
  static String forMembers({
    required String myNodeId,
    required Iterable<String> otherIds,
  }) {
    final others = otherIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty && id != myNodeId)
        .toSet()
        .toList();
    if (others.isEmpty) return room;
    if (others.length == 1) return direct(myNodeId, others.single);
    return group([myNodeId, ...others]);
  }

  static List<String> members(String conversationId) {
    if (isDirect(conversationId)) {
      final parts = conversationId.split(':');
      if (parts.length != 3) return const [];
      return [parts[1], parts[2]];
    }
    if (!isGroup(conversationId)) return const [];
    return conversationId
        .substring(3)
        .split('|')
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
  }

  /// The other participant in [conversationId], when [myNodeId] is one of them.
  static String? otherParty(String conversationId, String myNodeId) {
    if (!isDirect(conversationId)) return null;
    final parts = conversationId.split(':');
    if (parts.length != 3) return null;
    if (parts[1] == myNodeId) return parts[2];
    if (parts[2] == myNodeId) return parts[1];
    return null;
  }
}
