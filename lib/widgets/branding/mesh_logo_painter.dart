import 'package:flutter/material.dart';

import 'mesh_logo_geometry.dart';

/// Draws the chat silhouette, then reveals the connected mesh inside it.
class MeshLogoPainter extends CustomPainter {
  MeshLogoPainter({
    required this.progress,
    required this.bubbleColor,
    required this.curveColor,
    required this.nodeColor,
    this.strokeWidth = 12,
  });

  final double progress;
  final Color bubbleColor;
  final Color curveColor;
  final Color nodeColor;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final bubbleT = (progress / 0.4).clamp(0.0, 1.0);
    if (bubbleT <= 0) return;
    canvas.drawPath(
      MeshLogoGeometry.bubblePath(size),
      Paint()
        ..color = bubbleColor.withValues(alpha: bubbleT)
        ..isAntiAlias = true,
    );

    final linkT = ((progress - 0.25) / 0.55).clamp(0.0, 1.0);
    if (linkT > 0) {
      final path = MeshLogoGeometry.linkPath(size);
      final paint = Paint()
        ..color = curveColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..isAntiAlias = true;
      for (final metric in path.computeMetrics()) {
        canvas.drawPath(metric.extractPath(0, metric.length * linkT), paint);
      }
    }

    for (var i = 0; i < MeshLogoGeometry.nodes.length; i++) {
      final nodeT = ((progress - 0.40 - i * 0.12) / 0.18).clamp(0.0, 1.0);
      if (nodeT <= 0) continue;
      canvas.drawCircle(
        MeshLogoGeometry.nodeOn(size, MeshLogoGeometry.nodes[i]),
        size.width * 0.044 * Curves.easeOut.transform(nodeT),
        Paint()
          ..color = nodeColor
          ..isAntiAlias = true,
      );
    }
  }

  @override
  bool shouldRepaint(covariant MeshLogoPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.bubbleColor != bubbleColor ||
      oldDelegate.curveColor != curveColor ||
      oldDelegate.nodeColor != nodeColor ||
      oldDelegate.strokeWidth != strokeWidth;
}
