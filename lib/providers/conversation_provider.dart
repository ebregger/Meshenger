import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/conversation.dart';

/// Empty string is the shared public room.
class SelectedConversationNotifier extends Notifier<String> {
  @override
  String build() => ConversationIds.room;

  void select(String conversationId) => state = conversationId;
}

final selectedConversationIdProvider =
    NotifierProvider<SelectedConversationNotifier, String>(
      SelectedConversationNotifier.new,
    );

/// Direct threads opened before they contain a message.
class PinnedDirectConversationsNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => <String>{};

  void pin(String conversationId) {
    if (!ConversationIds.isDirect(conversationId) || state.contains(conversationId)) {
      return;
    }
    state = {...state, conversationId};
  }
}

final pinnedDirectConversationIdsProvider =
    NotifierProvider<PinnedDirectConversationsNotifier, Set<String>>(
      PinnedDirectConversationsNotifier.new,
    );
