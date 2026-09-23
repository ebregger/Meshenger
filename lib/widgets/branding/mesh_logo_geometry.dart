import 'package:flutter/material.dart';

/// Unit-space geometry for the mesh chat mark (0..1 viewBox).
class MeshLogoGeometry {
  MeshLogoGeometry._();

  static const Offset leftNode = Offset(0.28, 0.58);
  static const Offset rightNode = Offset(0.72, 0.48);

  /// Rounded bubble body (no tail — tip is [tailPath] filled separately).
  static Path bubblePath(Size size) {
    final w = size.width;
    final h = size.height;
    final rect = Rect.fromLTRB(w * 0.22, h * 0.20, w * 0.78, h * 0.70);
    final r = Radius.circular(w * 0.14);
    return Path()..addRRect(RRect.fromRectAndRadius(rect, r));
  }

  /// Filled chat tip on the bottom-left (avoids thick-stroke notch blobs).
  static Path tailPath(Size size) {
    final w = size.width;
    final h = size.height;
    // Fat tip — base spans most of the bottom-left, tip stays inside circle crop.
    return Path()
      ..moveTo(w * 0.22, h * 0.64)
      ..lineTo(w * 0.12, h * 0.84)
      ..lineTo(w * 0.52, h * 0.64)
      ..close();
  }

  /// Signal curve through the bubble (left → top-right).
  static Path curvePath(Size size) {
    final w = size.width;
    final h = size.height;
    return Path()
      ..moveTo(w * 0.02, h * 0.52)
      ..cubicTo(
        w * 0.10,
        h * 0.48,
        w * 0.18,
        h * 0.55,
        leftNode.dx * w,
        leftNode.dy * h,
      )
      ..cubicTo(
        w * 0.38,
        h * 0.62,
        w * 0.48,
        h * 0.40,
        rightNode.dx * w,
        rightNode.dy * h,
      )
      ..cubicTo(
        w * 0.82,
        h * 0.38,
        w * 0.90,
        h * 0.18,
        w * 0.98,
        h * 0.08,
      );
  }

  static Offset nodeOn(Size size, Offset unit) =>
      Offset(unit.dx * size.width, unit.dy * size.height);
}
