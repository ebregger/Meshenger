import 'package:flutter/material.dart';

/// Compact “connected device” tile for the horizontal strip.
class DeviceChip extends StatelessWidget {
  const DeviceChip({
    super.key,
    required this.label,
    this.accentColor,
    this.faded = false,
  });

  final String label;
  final Color? accentColor;
  final bool faded;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final iconColor = accentColor ?? scheme.primary;
    final opacity = faded ? 0.55 : 1.0;

    return Opacity(
      opacity: opacity,
      child: Material(
      elevation: 0,
      color: scheme.surfaceContainerHigh.withValues(alpha: 0.95),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(
          color: scheme.outlineVariant.withValues(alpha: 0.45),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.bluetooth_connected_rounded,
              size: 18,
              color: iconColor,
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w600,
                letterSpacing: -0.1,
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }
}
