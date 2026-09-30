import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/conversation.dart';
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
      final myId = await ref.read(identityServiceProvider).getOrCreateMyNodeId();
      final cutoff = DateTime.now()
          .subtract(Duration(days: days))
          .millisecondsSinceEpoch;
      await database.deleteTextMessages(
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
          'Messages older than this are removed from this phone and the removal syncs to peers. Relayed private chats you are not part of are kept so they can still reach their recipients.',
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

Future<void> confirmAndClearConversation(
  BuildContext context,
  WidgetRef ref, {
  required String conversationId,
}) async {
  final isRoom = conversationId.isEmpty;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(isRoom ? 'Clear shared room?' : 'Clear private chat?'),
      content: Text(
        isRoom
            ? 'This removes the shared room from this phone. Nearby peers delete those messages the next time you sync.'
            : 'This removes the private chat from this phone and syncs the removal to peers.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const Key('confirm_clear_history'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Clear'),
        ),
      ],
    ),
  );
  if (confirmed != true) return;
  final database = await ref.read(databaseProvider.future);
  await database.deleteTextMessages(conversationId: conversationId);
}
