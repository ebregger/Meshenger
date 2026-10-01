import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/chat_message.dart';

class ChatBubble extends StatelessWidget {
  const ChatBubble({super.key, required this.message, this.onMessagePrivately});

  final ChatMessage message;

  /// Shown for someone else's message in the shared room.
  final VoidCallback? onMessagePrivately;

  String _deliveryLabel(ChatMessage message) {
    if (message.delivery == MessageDeliveryState.delivered) {
      if (message.deliveredPeerCount > 1) {
        return 'Delivered to ${message.deliveredPeerCount} peers';
      }
      return 'Delivered';
    }
    return 'Sent';
  }

  String _formatTimestamp(BuildContext context) {
    final localizations = MaterialLocalizations.of(context);
    final timestamp = message.timestamp.toLocal();
    final time = localizations.formatTimeOfDay(
      TimeOfDay.fromDateTime(timestamp),
    );

    if (DateUtils.isSameDay(timestamp, DateTime.now())) return time;
    return '${localizations.formatMediumDate(timestamp)} · $time';
  }

  Future<void> _showMessageActions(BuildContext context) async {
    final shouldCopy = await showModalBottomSheet<bool>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const Key('copy_message_action'),
              leading: const Icon(Icons.content_copy_outlined),
              title: const Text('Copy message'),
              onTap: () => Navigator.of(sheetContext).pop(true),
            ),
            if (onMessagePrivately != null)
              ListTile(
                key: const Key('message_privately_action'),
                leading: const Icon(Icons.lock_outline),
                title: const Text('Message privately'),
                onTap: () {
                  Navigator.of(sheetContext).pop(false);
                  onMessagePrivately!();
                },
              ),
          ],
        ),
      ),
    );

    if (shouldCopy != true || !context.mounted) return;

    await Clipboard.setData(ClipboardData(text: message.body));
    if (!context.mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('Message copied'),
          duration: Duration(seconds: 1),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isSent = message.isSent;

    final retired = message.retired;
    final bubbleColor = retired
        ? scheme.surfaceContainerHighest.withValues(alpha: 0.6)
        : isSent
        ? scheme.primary
        : scheme.surfaceContainerHigh.withValues(alpha: 0.98);
    final textColor = retired
        ? scheme.onSurface.withValues(alpha: 0.55)
        : isSent
        ? scheme.onPrimary
        : scheme.onSurface;
    final align = isSent ? Alignment.centerRight : Alignment.centerLeft;

    return Semantics(
      hint: 'Long-press for message actions',
      onLongPress: () => _showMessageActions(context),
      child: GestureDetector(
        excludeFromSemantics: true,
        onLongPress: () => _showMessageActions(context),
        child: Align(
          alignment: align,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width * 0.78,
            ),
            child: DecoratedBox(
              key: Key('chat_bubble_${message.id}'),
              decoration: BoxDecoration(
                color: bubbleColor,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(18),
                  topRight: const Radius.circular(18),
                  bottomLeft: Radius.circular(isSent ? 18 : 4),
                  bottomRight: Radius.circular(isSent ? 4 : 18),
                ),
                boxShadow: [
                  BoxShadow(
                    color: scheme.shadow.withValues(alpha: 0.06),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!isSent && message.authorName.trim().isNotEmpty) ...[
                      Text(
                        message.authorName,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: textColor.withValues(alpha: 0.9),
                          fontWeight: FontWeight.w600,
                          height: 1.1,
                        ),
                      ),
                      const SizedBox(height: 6),
                    ],
                    if (message.locked) ...[
                      Icon(
                        Icons.lock_outline,
                        size: 14,
                        color: textColor.withValues(alpha: 0.8),
                      ),
                      const SizedBox(height: 4),
                    ],
                    Text(
                      message.body,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: textColor,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _formatTimestamp(context),
                      key: Key('message_timestamp_${message.id}'),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: textColor.withValues(alpha: 0.72),
                        height: 1.1,
                      ),
                    ),
                    if (isSent &&
                        !retired &&
                        message.delivery != MessageDeliveryState.none) ...[
                      const SizedBox(height: 2),
                      Text(
                        _deliveryLabel(message),
                        key: Key('message_delivery_${message.id}'),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: textColor.withValues(alpha: 0.72),
                          height: 1.1,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
