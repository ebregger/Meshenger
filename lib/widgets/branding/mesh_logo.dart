import 'package:flutter/material.dart';

import 'mesh_logo_painter.dart';

/// Mesh mark. Pass [progress] (0–1) for launch draw-on.
///
/// Colors default to the active light/dark [ColorScheme]; splash passes
/// fixed ink so it matches Android `launch_background`.
class MeshLogo extends StatelessWidget {
  const MeshLogo({
    super.key,
    this.size = 160,
    this.progress = 1,
    this.bubbleColor,
    this.curveColor,
    this.nodeColor,
  });

  /// Canonical canvas — paint large, then [FittedBox] scales down (cleaner AA).
  static const double designSize = 384;
  static const double designStroke = designSize * 0.038;

  /// Display size; the mark is drawn at [designSize] then scaled.
  final double size;

  /// Drawing progress for splash (1 = complete).
  final double progress;

  /// When null, uses [ColorScheme] roles (primary / tertiary / secondary).
  final Color? bubbleColor;
  final Color? curveColor;
  final Color? nodeColor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Semantics(
      label: 'Meshenger logo',
      child: SizedBox(
        width: size,
        height: size,
        child: FittedBox(
          fit: BoxFit.contain,
          child: SizedBox(
            width: designSize,
            height: designSize,
            child: CustomPaint(
              painter: MeshLogoPainter(
                progress: progress.clamp(0.0, 1.0),
                bubbleColor: bubbleColor ?? scheme.primary,
                curveColor: curveColor ?? scheme.tertiary,
                nodeColor: nodeColor ?? scheme.secondary,
                strokeWidth: designStroke,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
