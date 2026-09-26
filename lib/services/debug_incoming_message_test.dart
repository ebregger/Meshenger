import 'dart:async';

import 'package:fixnum/fixnum.dart';

import '../models/text_message_with_author.dart';

final _debugIncomingMessages =
    StreamController<TextMessageWithAuthor>.broadcast();

Stream<TextMessageWithAuthor> get debugIncomingMessages =>
    _debugIncomingMessages.stream;

Future<void> scheduleDebugIncomingMessage() async {
  await Future<void>.delayed(const Duration(seconds: 5));
  final now = DateTime.now();
  _debugIncomingMessages.add(
    TextMessageWithAuthor(
      msgId: 'debug-incoming-${now.microsecondsSinceEpoch}',
      originNodeId: 'debug-remote-peer',
      textContent: 'Synthetic test message',
      timestamp: Int64(now.millisecondsSinceEpoch),
      authorName: 'Test peer',
    ),
  );
}
