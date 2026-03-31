/// Single row in the local chat transcript (Bluetooth transport comes later).
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.body,
    required this.authorName,
    required this.isSent,
  });

  final String id;
  final String body;
  final String authorName;
  final bool isSent;
}
