import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/chat_provider.dart';
import '../../providers/message_draft_provider.dart';

/// Multiline composer + Send; styled for a bottom chat bar.
class MessageComposeRow extends ConsumerStatefulWidget {
  const MessageComposeRow({super.key});

  @override
  ConsumerState<MessageComposeRow> createState() => _MessageComposeRowState();
}

class _MessageComposeRowState extends ConsumerState<MessageComposeRow> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final draft = ref.watch(messageDraftProvider);

    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.65),
      borderRadius: BorderRadius.circular(24),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.only(left: 4, right: 6, top: 4, bottom: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                key: const Key('message_input'),
                controller: _controller,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.send,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: 'Message',
                  filled: true,
                  fillColor: scheme.surface.withValues(alpha: 0.55),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  hintStyle: theme.textTheme.bodyLarge?.copyWith(
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.65),
                  ),
                  isDense: true,
                ),
                style: theme.textTheme.bodyLarge,
                onChanged: ref.read(messageDraftProvider.notifier).setText,
                onSubmitted: (_) => _onSend(draft),
              ),
            ),
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: FilledButton(
                key: const Key('send_button'),
                onPressed: draft.trim().isEmpty ? null : () => _onSend(draft),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(52, 44),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  shape: const StadiumBorder(),
                ),
                child: const Text('Send'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _onSend(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    await ref.read(chatActionsProvider.notifier).sendMessage(trimmed);
    ref.read(messageDraftProvider.notifier).clear();
    _controller.clear();
  }
}
