import 'package:fixnum/fixnum.dart';

/// UI-friendly wrapper that includes the author's display name.
class TextMessageWithAuthor {
  const TextMessageWithAuthor({
    required this.msgId,
    required this.originNodeId,
    required this.textContent,
    required this.timestamp,
    required this.authorName,
    this.conversationId = '',
    this.recipientNodeId = '',
    this.contentEncoding = 'plain',
    this.locked = false,
    this.retiredBy = '',
  });

  final String msgId;
  final String originNodeId;
  final String textContent;
  final Int64 timestamp;
  final String authorName;
  final String conversationId;
  final String recipientNodeId;
  final String contentEncoding;
  final bool locked;

  /// Mesh id of the person who deleted this chat after this message was sent,
  /// or empty. Their phone dropped its copy; ours is kept but shown grayed.
  final String retiredBy;

  bool get retired => retiredBy.isNotEmpty;

  TextMessageWithAuthor copyWith({String? textContent, bool? locked}) {
    return TextMessageWithAuthor(
      msgId: msgId,
      originNodeId: originNodeId,
      textContent: textContent ?? this.textContent,
      timestamp: timestamp,
      authorName: authorName,
      conversationId: conversationId,
      recipientNodeId: recipientNodeId,
      contentEncoding: contentEncoding,
      locked: locked ?? this.locked,
      retiredBy: retiredBy,
    );
  }
}
