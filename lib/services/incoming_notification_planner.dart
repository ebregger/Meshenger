import '../models/text_message_with_author.dart';

/// Decides which newly observed messages should raise a background notification.
///
/// The first snapshot is history already on the phone. Later remote messages
/// notify only while the app is backgrounded, and only after the local node id
/// is known so the phone does not alert for its own sends.
class IncomingNotificationPlanner {
  bool _backgrounded = false;
  bool _seeded = false;
  String? myNodeId;
  final Set<String> _seenMessageIds = <String>{};
  final List<TextMessageWithAuthor> _awaitingIdentity = <TextMessageWithAuthor>[];

  bool get backgrounded => _backgrounded;

  set backgrounded(bool value) {
    _backgrounded = value;
    if (!value) _awaitingIdentity.clear();
  }

  List<String> acceptIdentity(String nodeId) {
    myNodeId = nodeId;
    if (!_backgrounded || _awaitingIdentity.isEmpty) return const [];

    final pending = List<TextMessageWithAuthor>.of(_awaitingIdentity);
    _awaitingIdentity.clear();
    return [
      for (final message in pending)
        if (message.originNodeId != nodeId) message.msgId,
    ];
  }

  List<String> acceptSnapshot(List<TextMessageWithAuthor> messages) {
    if (!_seeded) {
      _seenMessageIds.addAll(messages.map((message) => message.msgId));
      _seeded = true;
      return const [];
    }
    return _collect(messages);
  }

  List<String> acceptDebug(TextMessageWithAuthor message) {
    if (!_seeded) return const [];
    return _collect([message]);
  }

  List<String> _collect(Iterable<TextMessageWithAuthor> messages) {
    final notify = <String>[];
    for (final message in messages) {
      if (message.msgId.isEmpty || !_seenMessageIds.add(message.msgId)) {
        continue;
      }
      if (!_backgrounded) continue;

      final nodeId = myNodeId;
      if (nodeId == null) {
        _awaitingIdentity.add(message);
      } else if (message.originNodeId != nodeId) {
        notify.add(message.msgId);
      }
    }
    return notify;
  }
}
