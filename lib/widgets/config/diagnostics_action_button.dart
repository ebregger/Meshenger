import 'package:flutter/material.dart';

/// Full-width tonal action with a small tap-local ripple and light press motion.
class DiagnosticsActionButton extends StatefulWidget {
  const DiagnosticsActionButton({
    super.key,
    required this.onPressed,
    required this.icon,
    required this.label,
  });

  final VoidCallback onPressed;
  final IconData icon;
  final String label;

  @override
  State<DiagnosticsActionButton> createState() =>
      _DiagnosticsActionButtonState();
}

class _DiagnosticsActionButtonState extends State<DiagnosticsActionButton> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(20),
    );
    final labelStyle = Theme.of(context).textTheme.labelLarge?.copyWith(
      color: scheme.onSecondaryContainer,
      fontWeight: FontWeight.w600,
    );

    return Material(
      color: scheme.secondaryContainer,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: InkResponse(
        onTap: widget.onPressed,
        onHighlightChanged: _setPressed,
        containedInkWell: true,
        highlightShape: BoxShape.circle,
        // Keep the ripple under the finger instead of filling the full-width row.
        radius: 36,
        splashFactory: InkRipple.splashFactory,
        splashColor: scheme.onSecondaryContainer.withValues(alpha: 0.16),
        highlightColor: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOut,
            style: (labelStyle ?? const TextStyle()).copyWith(
              letterSpacing: _pressed ? 0.35 : 0.0,
            ),
            child: AnimatedScale(
              scale: _pressed ? 0.97 : 1.0,
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOut,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(widget.icon, color: scheme.onSecondaryContainer),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(widget.label, textAlign: TextAlign.center),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
