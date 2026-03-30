import 'package:flutter/material.dart';

import '../home/message_compose_row.dart';

/// Bottom-anchored chrome: hairline divider + subtle fill so the composer reads
/// like mainstream chat apps (iMessage / Signal-style dock).
class ChatInputDock extends StatelessWidget {
  const ChatInputDock({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Material(
      color: scheme.surface.withValues(alpha: 0.92),
      elevation: 0,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(
              color: scheme.outlineVariant.withValues(alpha: 0.35),
            ),
          ),
          boxShadow: [
            BoxShadow(
              color: scheme.shadow.withValues(alpha: 0.05),
              blurRadius: 16,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: SafeArea(
          top: false,
          minimum: const EdgeInsets.only(bottom: 8),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: const MessageComposeRow(),
          ),
        ),
      ),
    );
  }
}
