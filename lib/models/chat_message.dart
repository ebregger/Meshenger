/// How far an outbound message has progressed on this phone.
enum MessageDeliveryState { none, sent, delivered }

/// UI-friendly message used to render the local chat transcript.
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.body,
    required this.authorName,
    required this.isSent,
    required this.timestamp,
    this.delivery = MessageDeliveryState.none,
    this.deliveredPeerCount = 0,
    this.locked = false,
    this.retired = false,
  });

  final String id;
  final String body;
  final String authorName;
  final bool isSent;
  final DateTime timestamp;
  final MessageDeliveryState delivery;
  final int deliveredPeerCount;
  final bool locked;

  /// The other person deleted this chat; shown grayed out, kept on this phone.
  final bool retired;
}
