import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/conversation.dart';
import '../../providers/ble_network_provider.dart';
import '../../providers/chat_provider.dart';
import '../../providers/conversation_provider.dart';
import '../../providers/identity_provider.dart';
import '../../providers/node_profiles_provider.dart';
import '../config/chat_history_settings.dart';
import 'chat_people.dart';
import 'person_avatar.dart';

class ConversationList extends ConsumerWidget {
  const ConversationList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final myId = ref.watch(myNodeIdProvider).asData?.value;
    final profiles = ref.watch(nodeProfilesProvider).asData?.value ?? const [];
    final peers = ref.watch(activePeersProvider).asData?.value ?? const [];
    final profileNames = profileNameMap(profiles);
    final peerNames = peerNameMap(peers);
    final pinned = ref.watch(pinnedConversationIdsProvider);
    final stored =
        ref.watch(privateConversationIdsProvider).asData?.value ?? const [];
    final previews =
        ref.watch(conversationPreviewsProvider).asData?.value ?? const [];
    final previewById = {
      for (final preview in previews) preview.conversationId: preview,
    };

    final ids = <String>{
      ConversationIds.room,
      ...pinned,
      ...stored,
      ...previewById.keys.where(ConversationIds.isPrivate),
    };
    final rows = ids.toList()
      ..sort((a, b) {
        if (a.isEmpty) return -1;
        if (b.isEmpty) return 1;
        final left = previewById[a]?.timestampMs ?? 0;
        final right = previewById[b]?.timestampMs ?? 0;
        return right.compareTo(left);
      });

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 88),
      itemCount: rows.length,
      separatorBuilder: (context, index) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final conversationId = rows[index];
        final preview = previewById[conversationId];
        final title = conversationTitle(
          conversationId,
          myNodeId: myId,
          profileNames: profileNames,
          peerNames: peerNames,
        );
        return ListTile(
          key: ValueKey(
            conversationId.isEmpty ? 'conversation_everyone' : conversationId,
          ),
          leading: _avatarFor(context, conversationId, myId, title),
          title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            _subtitleFor(conversationId, preview),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: preview == null || preview.timestampMs <= 0
              ? null
              : Text(
                  _formatTime(context, preview.timestampMs),
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
          onTap: () => openConversation(ref, conversationId),
          onLongPress: () => _showActions(context, ref, conversationId, title),
        );
      },
    );
  }

  Future<void> _showActions(
    BuildContext context,
    WidgetRef ref,
    String conversationId,
    String title,
  ) async {
    final isRoom = conversationId.isEmpty;
    final confirm = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(sheetContext).textTheme.titleMedium,
                ),
              ),
            ),
            ListTile(
              key: const Key('delete_conversation_action'),
              leading: Icon(
                Icons.delete_outline,
                color: Theme.of(sheetContext).colorScheme.error,
              ),
              title: Text(isRoom ? 'Clear messages' : 'Delete chat'),
              onTap: () => Navigator.of(sheetContext).pop(true),
            ),
          ],
        ),
      ),
    );
    if (confirm != true || !context.mounted) return;
    await confirmAndClearConversation(
      context,
      ref,
      conversationId: conversationId,
    );
  }

  Widget _avatarFor(
    BuildContext context,
    String conversationId,
    String? myId,
    String title,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final other = myId == null || !ConversationIds.isDirect(conversationId)
        ? null
        : ConversationIds.otherParty(conversationId, myId);
    if (other != null) return PersonAvatar(id: other, name: title);
    return CircleAvatar(
      backgroundColor: scheme.secondaryContainer,
      foregroundColor: scheme.onSecondaryContainer,
      child: Icon(
        conversationId.isEmpty ? Icons.groups_outlined : Icons.group_outlined,
      ),
    );
  }

  String _subtitleFor(String conversationId, ConversationPreview? preview) {
    final text = preview?.preview.trim() ?? '';
    if (text.isNotEmpty) return text;
    if (conversationId.isEmpty) return 'Public room · shared with nearby phones';
    if (ConversationIds.isGroup(conversationId)) return 'Group chat';
    return 'Private chat';
  }

  String _formatTime(BuildContext context, int timestampMs) {
    final timestamp = DateTime.fromMillisecondsSinceEpoch(timestampMs);
    final localizations = MaterialLocalizations.of(context);
    if (DateUtils.isSameDay(timestamp, DateTime.now())) {
      return localizations.formatTimeOfDay(TimeOfDay.fromDateTime(timestamp));
    }
    return localizations.formatShortDate(timestamp);
  }
}
