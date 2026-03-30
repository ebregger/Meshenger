import 'dart:ui';

import 'package:flutter/material.dart';

/// iOS-style translucent bar with blur for top-level chrome (Liquid Glass look).
class LiquidGlassAppBar extends StatelessWidget implements PreferredSizeWidget {
  const LiquidGlassAppBar({
    super.key,
    required this.title,
    required this.statusBarHeight,
    this.trailing,
  });

  final String title;

  /// Top safe inset from [MediaQuery] (typically status bar).
  final double statusBarHeight;

  /// Optional trailing widget (e.g. status indicator).
  final Widget? trailing;

  static const double _toolbarHeight = 56;

  @override
  Size get preferredSize =>
      Size.fromHeight(_toolbarHeight + statusBarHeight);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          height: _toolbarHeight + statusBarHeight,
          padding: EdgeInsets.only(top: statusBarHeight),
          decoration: BoxDecoration(
            color: scheme.surface.withValues(alpha: 0.45),
            border: Border(
              bottom: BorderSide(
                color: scheme.outlineVariant.withValues(alpha: 0.35),
              ),
            ),
          ),
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.2,
                        ),
                  ),
                ),
                ?trailing,
              ],
            ),
          ),
        ),
      ),
    );
  }
}
