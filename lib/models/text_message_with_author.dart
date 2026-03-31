import 'package:fixnum/fixnum.dart';

/// UI-friendly wrapper that includes the author's display name.
class TextMessageWithAuthor {
  const TextMessageWithAuthor({
    required this.msgId,
    required this.originNodeId,
    required this.textContent,
    required this.timestamp,
    required this.authorName,
  });

  final String msgId;
  final String originNodeId;
  final String textContent;
  final Int64 timestamp;
  final String authorName;
}

