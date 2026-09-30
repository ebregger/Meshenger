/// Conversation ids stored on each message row.
///
/// The empty id is the shared public room. Direct chats use a stable id both
/// participants can derive without an extra handshake.
class ConversationIds {
  const ConversationIds._();

  static const String room = '';

  static bool isDirect(String conversationId) =>
      conversationId.startsWith('dm:');

  static String direct(String nodeA, String nodeB) {
    final pair = <String>[nodeA, nodeB]..sort();
    return 'dm:${pair[0]}:${pair[1]}';
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
