import 'package:flutter/material.dart';

/// Shown under grayed-out messages: the other person deleted the chat on their
/// phone, but this phone keeps the old messages until the user removes them.
class RetiredChatNotice extends StatelessWidget {
  const RetiredChatNotice({
    super.key,
    required this.deletedBy,
    required this.onDelete,
  });

  final String deletedBy;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Column(
        children: [
          Text(
            '$deletedBy deleted this chat',
            textAlign: TextAlign.center,
            style: theme.textTheme.labelMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          Text(
            'These messages are only on this phone now.',
            textAlign: TextAlign.center,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
            ),
          ),
          TextButton(
            key: const Key('delete_grayed_messages'),
            onPressed: onDelete,
            child: const Text('Remove from this phone'),
          ),
        ],
      ),
    );
  }
}

/// Confirms removing grayed-out messages from this phone.
Future<bool> confirmDeleteGrayedMessages(
  BuildContext context, {
  required String deletedBy,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Remove old messages?'),
      content: Text(
        '$deletedBy deleted this chat on their phone. This removes the '
        'grayed-out messages from this phone only.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const Key('confirm_delete_grayed'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Remove'),
        ),
      ],
    ),
  );
  return confirmed == true;
}
