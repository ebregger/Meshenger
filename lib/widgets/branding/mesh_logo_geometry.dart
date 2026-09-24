import 'package:flutter/material.dart';

/// Unit-space geometry shared by the in-app mark and exported Android artwork.
class MeshLogoGeometry {
  MeshLogoGeometry._();

  static const nodes = <Offset>[
    Offset(0.34, 0.54),
    Offset(0.50, 0.39),
    Offset(0.66, 0.54),
  ];

  static Path bubblePath(Size size) {
    final w = size.width;
    final h = size.height;
    return Path()
      ..moveTo(w * 0.34, h * 0.20)
      ..lineTo(w * 0.66, h * 0.20)
      ..cubicTo(w * 0.76, h * 0.20, w * 0.83, h * 0.27, w * 0.83, h * 0.37)
      ..lineTo(w * 0.83, h * 0.56)
      ..cubicTo(w * 0.83, h * 0.66, w * 0.76, h * 0.73, w * 0.66, h * 0.73)
      ..lineTo(w * 0.42, h * 0.73)
      ..lineTo(w * 0.22, h * 0.82)
      ..cubicTo(w * 0.20, h * 0.83, w * 0.18, h * 0.81, w * 0.19, h * 0.78)
      ..lineTo(w * 0.23, h * 0.69)
      ..cubicTo(w * 0.19, h * 0.66, w * 0.17, h * 0.61, w * 0.17, h * 0.56)
      ..lineTo(w * 0.17, h * 0.37)
      ..cubicTo(w * 0.17, h * 0.27, w * 0.24, h * 0.20, w * 0.34, h * 0.20)
      ..close();
  }

  static Path linkPath(Size size) => Path()
    ..moveTo(nodes[0].dx * size.width, nodes[0].dy * size.height)
    ..lineTo(nodes[1].dx * size.width, nodes[1].dy * size.height)
    ..lineTo(nodes[2].dx * size.width, nodes[2].dy * size.height);

  static Offset nodeOn(Size size, Offset unit) =>
      Offset(unit.dx * size.width, unit.dy * size.height);
}
