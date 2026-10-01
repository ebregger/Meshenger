import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/conversation.dart';

/// Whether the Messages tab is showing the chat list or an open thread.
class ChatLocation {
  const ChatLocation.list()
    : showingList = true,
      conversationId = ConversationIds.room;

  const ChatLocation.thread(this.conversationId) : showingList = false;

  final bool showingList;
  final String conversationId;
}

class ChatLocationNotifier extends Notifier<ChatLocation> {
  @override
  ChatLocation build() => const ChatLocation.list();

  void showList() => state = const ChatLocation.list();

  void open(String conversationId) {
    state = ChatLocation.thread(conversationId);
  }
}

final chatLocationProvider =
    NotifierProvider<ChatLocationNotifier, ChatLocation>(
      ChatLocationNotifier.new,
    );

/// Conversation open in the thread view. The list keeps this on the shared room.
final selectedConversationIdProvider = Provider<String>((ref) {
  return ref.watch(chatLocationProvider).conversationId;
});

/// Private threads opened before they contain a message.
class PinnedConversationNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => <String>{};

  void pin(String conversationId) {
    if (!ConversationIds.isPrivate(conversationId) ||
        state.contains(conversationId)) {
      return;
    }
    state = {...state, conversationId};
  }

  void unpin(String conversationId) {
    if (!state.contains(conversationId)) return;
    state = {...state}..remove(conversationId);
  }
}

final pinnedConversationIdsProvider =
    NotifierProvider<PinnedConversationNotifier, Set<String>>(
      PinnedConversationNotifier.new,
    );

/// Opens [conversationId], pinning a private or group thread so it stays in
/// the list. The same member set always produces the same id, so this returns
/// to a chat that already exists.
void openConversation(WidgetRef ref, String conversationId) {
  if (ConversationIds.isPrivate(conversationId)) {
    ref.read(pinnedConversationIdsProvider.notifier).pin(conversationId);
  }
  ref.read(chatLocationProvider.notifier).open(conversationId);
}
