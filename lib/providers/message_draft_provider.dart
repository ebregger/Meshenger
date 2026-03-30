import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Holds the outgoing message text until Bluetooth send is wired up.
final messageDraftProvider =
    NotifierProvider<MessageDraftNotifier, String>(MessageDraftNotifier.new);

class MessageDraftNotifier extends Notifier<String> {
  @override
  String build() => '';

  void setText(String value) => state = value;

  void clear() => state = '';
}
