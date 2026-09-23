import 'package:flutter/material.dart';

import 'mesh_logo_geometry.dart';

/// Draws the mesh mark. [progress] 0→1 drives a left-to-right reveal for launch.
class MeshLogoPainter extends CustomPainter {
  MeshLogoPainter({
    required this.progress,
    required this.bubbleColor,
    required this.curveColor,
    required this.nodeColor,
    this.strokeWidth = 3.5,
  });

  /// 0 = empty, 1 = fully drawn.
  final double progress;
  final Color bubbleColor;
  final Color curveColor;
  final Color nodeColor;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final bubble = MeshLogoGeometry.bubblePath(size);
    final curve = MeshLogoGeometry.curvePath(size);
    final tail = MeshLogoGeometry.tailPath(size);

    // Bubble outline draws first (~0–0.35 of the timeline).
    final bubbleT = (progress / 0.35).clamp(0.0, 1.0);
    final bubblePaint = Paint()
      ..color = bubbleColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true
      ..filterQuality = FilterQuality.high;
    _strokePartial(canvas, bubble, bubblePaint, bubbleT);
    if (bubbleT > 0.85) {
      canvas.drawPath(
        tail,
        Paint()
          ..color = bubbleColor.withValues(alpha: ((bubbleT - 0.85) / 0.15).clamp(0.0, 1.0))
          ..style = PaintingStyle.fill
          ..isAntiAlias = true,
      );
    }

    // Signal curve draws next (~0.20–0.90).
    final curveT = ((progress - 0.20) / 0.70).clamp(0.0, 1.0);
    _strokePartial(
      canvas,
      curve,
      Paint()
        ..color = curveColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..isAntiAlias = true
        ..filterQuality = FilterQuality.high,
      curveT,
    );

    // Nodes pop when the curve reaches their junctions.
    final nodeR = strokeWidth * 1.2;
    _paintNode(
      canvas,
      MeshLogoGeometry.nodeOn(size, MeshLogoGeometry.leftNode),
      nodeR,
      ((curveT - 0.28) / 0.12).clamp(0.0, 1.0),
    );
    _paintNode(
      canvas,
      MeshLogoGeometry.nodeOn(size, MeshLogoGeometry.rightNode),
      nodeR,
      ((curveT - 0.62) / 0.12).clamp(0.0, 1.0),
    );
  }

  void _paintNode(Canvas canvas, Offset c, double r, double t) {
    if (t <= 0) return;
    canvas.drawCircle(
      c,
      r * Curves.easeOutBack.transform(t),
      Paint()..color = nodeColor.withValues(alpha: t.clamp(0.0, 1.0)),
    );
  }

  void _strokePartial(Canvas canvas, Path path, Paint paint, double t) {
    if (t <= 0) return;
    if (t >= 1) {
      canvas.drawPath(path, paint);
      return;
    }
    for (final metric in path.computeMetrics()) {
      canvas.drawPath(metric.extractPath(0, metric.length * t), paint);
    }
  }

  @override
  bool shouldRepaint(covariant MeshLogoPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.bubbleColor != bubbleColor ||
        oldDelegate.curveColor != curveColor ||
        oldDelegate.nodeColor != nodeColor ||
        oldDelegate.strokeWidth != strokeWidth;
  }
}
