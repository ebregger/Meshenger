import 'package:flutter/material.dart';

/// Compact “connected device” tile for the horizontal strip.
class DeviceChip extends StatelessWidget {
  const DeviceChip({
    super.key,
    required this.label,
    this.accentColor,
    this.faded = false,
    this.talking = false,
    this.meshCaughtUp,
  });

  final String label;
  final Color? accentColor;
  final bool faded;
  final bool talking;

  /// `true` = in sync, `false` = behind, `null` = unknown.
  final bool? meshCaughtUp;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final useMaterialYouHighlight =
        talking && theme.platform == TargetPlatform.android;
    final backgroundColor = useMaterialYouHighlight
        ? scheme.secondaryContainer.withValues(alpha: 0.72)
        : scheme.surfaceContainerHigh.withValues(alpha: 0.95);
    // Connection status color (green / yellow / grey) — same as the old BT icon.
    final iconColor = accentColor ?? scheme.primary;
    final textColor = useMaterialYouHighlight
        ? scheme.onSecondaryContainer
        : scheme.onSurface;
    final opacity = faded ? 0.55 : 1.0;
    final IconData statusIcon;
    if (meshCaughtUp == true) {
      statusIcon = Icons.check_circle_rounded;
    } else if (meshCaughtUp == false) {
      statusIcon = Icons.sync_problem_rounded;
    } else {
      statusIcon = Icons.help_outline_rounded;
    }

    return Opacity(
      opacity: opacity,
      child: Material(
        elevation: 0,
        color: backgroundColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(
            color: useMaterialYouHighlight
                ? scheme.secondary.withValues(alpha: 0.2)
                : scheme.outlineVariant.withValues(alpha: 0.45),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(statusIcon, size: 18, color: iconColor),
              const SizedBox(width: 8),
              Text(
                label,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: textColor,
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
