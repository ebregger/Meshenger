import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/conversation.dart';
import '../../providers/chat_provider.dart';
import '../../providers/conversation_provider.dart';
import '../../providers/database_provider.dart';
import '../../providers/identity_provider.dart';
import '../../services/chat_history_preferences.dart';

/// Retention window and explicit history clearing for the shared mesh.
class ChatHistorySettings extends ConsumerStatefulWidget {
  const ChatHistorySettings({super.key});

  @override
  ConsumerState<ChatHistorySettings> createState() =>
      _ChatHistorySettingsState();
}

class _ChatHistorySettingsState extends ConsumerState<ChatHistorySettings> {
  final ChatHistoryPreferences _preferences = ChatHistoryPreferences();
  int _days = 0;

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(_load);
  }

  Future<void> _load() async {
    final days = await _preferences.readDays();
    if (!mounted) return;
    setState(() => _days = days);
    await _applyRetention(days);
  }

  Future<void> _applyRetention(int days) async {
    if (days <= 0) return;
    try {
      final database = await ref.read(databaseProvider.future);
      final myId = await ref
          .read(identityServiceProvider)
          .getOrCreateMyNodeId();
      final cutoff = DateTime.now()
          .subtract(Duration(days: days))
          .millisecondsSinceEpoch;
      await database.scrubTextMessages(
        olderThanTimestampMs: cutoff,
        participantNodeId: myId,
      );
    } catch (error) {
      debugPrint('retention cleanup failed: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Messages older than this are removed from this phone only. Other phones keep their copies. Relayed private chats you are not part of are kept so they can still reach their recipients.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 10),
        DropdownButtonFormField<int>(
          key: ValueKey('retention_dropdown_$_days'),
          initialValue: _days,
          decoration: const InputDecoration(
            labelText: 'Keep messages',
            border: OutlineInputBorder(),
          ),
          items: [
            for (final days in ChatHistoryPreferences.options)
              DropdownMenuItem(
                value: days,
                child: Text(ChatHistoryPreferences.labelFor(days)),
              ),
          ],
          onChanged: (days) async {
            if (days == null) return;
            setState(() => _days = days);
            await _preferences.writeDays(days);
            await _applyRetention(days);
          },
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          key: const Key('clear_shared_history'),
          onPressed: () => confirmAndClearConversation(
            context,
            ref,
            conversationId: ConversationIds.room,
          ),
          icon: const Icon(Icons.delete_outline),
          label: const Text('Clear shared room'),
        ),
      ],
    );
  }
}

/// Asks before removing every message in [conversationId] from this phone.
/// Returns whether the messages were removed. Private and group chats also
/// leave the list. Nothing is ever deleted on other phones: a one-to-one chat
/// shows the other person their copy grayed out, and they decide what to do.
Future<bool> confirmAndClearConversation(
  BuildContext context,
  WidgetRef ref, {
  required String conversationId,
}) async {
  final isRoom = conversationId.isEmpty;
  final isDirect = ConversationIds.isDirect(conversationId);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(isRoom ? 'Clear shared room?' : 'Delete chat?'),
      content: Text(
        isRoom
            ? 'This removes the shared room from this phone only. Other phones keep their copies.'
            : isDirect
            ? 'This deletes the chat from this phone. The other person keeps their copy, shown grayed out, and can delete it themselves.'
            : 'This deletes the chat from this phone only. Everyone else in the group keeps theirs.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const Key('confirm_clear_history'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(isRoom ? 'Clear' : 'Delete'),
        ),
      ],
    ),
  );
  if (confirmed != true) return false;
  if (isRoom) {
    final database = await ref.read(databaseProvider.future);
    await database.clearRoomLocally();
  } else {
    await ref
        .read(chatActionsProvider.notifier)
        .deleteConversation(conversationId);
    ref.read(pinnedConversationIdsProvider.notifier).unpin(conversationId);
  }
  return true;
}
