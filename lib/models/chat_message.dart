/// UI-friendly message used to render the local chat transcript.
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.body,
    required this.authorName,
    required this.isSent,
    required this.timestamp,
  });

  final String id;
  final String body;
  final String authorName;
  final bool isSent;
  final DateTime timestamp;
}
