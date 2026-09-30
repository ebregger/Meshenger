import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/conversation.dart';
import '../../providers/chat_provider.dart';
import '../../providers/conversation_provider.dart';
import '../../providers/identity_provider.dart';
import '../../providers/node_profiles_provider.dart';

/// Room and private-thread chips above the transcript.
class ConversationBar extends ConsumerWidget {
  const ConversationBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedConversationIdProvider);
    final pinned = ref.watch(pinnedDirectConversationIdsProvider);
    final stored =
        ref.watch(directConversationIdsProvider).asData?.value ?? const <String>[];
    final myId = ref.watch(myNodeIdProvider).asData?.value;
    final profiles = ref.watch(nodeProfilesProvider).asData?.value ?? const [];
    final names = <String, String>{
      for (final profile in profiles)
        if (profile.displayName.trim().isNotEmpty)
          profile.nodeId: profile.displayName.trim(),
    };
    final conversationIds = <String>{...pinned, ...stored}.toList()..sort();

    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        children: [
          ChoiceChip(
            key: const Key('conversation_everyone'),
            label: const Text('Everyone'),
            selected: selected.isEmpty,
            onSelected: (_) => ref
                .read(selectedConversationIdProvider.notifier)
                .select(ConversationIds.room),
          ),
          for (final conversationId in conversationIds) ...[
            const SizedBox(width: 8),
            ChoiceChip(
              key: Key('conversation_$conversationId'),
              label: Text(
                _label(conversationId, myId, names),
              ),
              selected: selected == conversationId,
              onSelected: (_) => ref
                  .read(selectedConversationIdProvider.notifier)
                  .select(conversationId),
            ),
          ],
        ],
      ),
    );
  }

  String _label(
    String conversationId,
    String? myId,
    Map<String, String> names,
  ) {
    final other = myId == null
        ? null
        : ConversationIds.otherParty(conversationId, myId);
    if (other == null || other.isEmpty) return 'Private';
    final name = names[other];
    if (name != null && name.isNotEmpty) return name;
    return other.length <= 8 ? other : other.substring(0, 8);
  }
}
