import 'dart:io';
import 'dart:ui' as ui;

import 'package:bluetooth_app/widgets/branding/mesh_logo.dart';
import 'package:bluetooth_app/widgets/branding/mesh_logo_painter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Rasterizes [MeshLogoPainter] at 4× then downsamples for smooth strokes.
///
/// Run: `flutter test test/export_branding_pngs_test.dart`
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('export branding PNGs via Skia', () async {
    final root = Directory.current.path;
    final assets = Directory('$root/assets/branding')..createSync(recursive: true);
    final res = Directory('$root/android/app/src/main/res');

    const ink = Color(0xFF1C1B1F);
    const white = Color(0xFFFFFFFF);
    const black = Color(0xFF000000);

    final splashDark = await _renderLogo(
      size: 1024,
      pad: 0.08,
      bg: null,
      stroke: ink,
      nodes: ink,
    );
    final splashLight = await _renderLogo(
      size: 1024,
      pad: 0.08,
      bg: null,
      stroke: white,
      nodes: white,
    );
    await _writePng(splashDark, '${assets.path}/splash_logo.png');
    await _writePng(splashLight, '${assets.path}/splash_logo_light.png');

    const splashBuckets = {
      'drawable-mdpi': 192,
      'drawable-hdpi': 288,
      'drawable-xhdpi': 384,
      'drawable-xxhdpi': 576,
      'drawable-xxxhdpi': 768,
    };
    for (final e in splashBuckets.entries) {
      final dir = Directory('${res.path}/${e.key}')..createSync(recursive: true);
      await _writePng(
        await _renderLogo(
          size: e.value,
          pad: 0.08,
          bg: null,
          stroke: ink,
          nodes: ink,
        ),
        '${dir.path}/splash_logo.png',
      );
      await _writePng(
        await _renderLogo(
          size: e.value,
          pad: 0.08,
          bg: null,
          stroke: white,
          nodes: white,
        ),
        '${dir.path}/splash_logo_light.png',
      );
    }
    final drawable = Directory('${res.path}/drawable')..createSync(recursive: true);
    await _writePng(splashDark, '${drawable.path}/splash_logo.png');
    await _writePng(splashLight, '${drawable.path}/splash_logo_light.png');

    const mipmaps = {
      'mipmap-mdpi': 48,
      'mipmap-hdpi': 72,
      'mipmap-xhdpi': 96,
      'mipmap-xxhdpi': 144,
      'mipmap-xxxhdpi': 192,
    };
    for (final e in mipmaps.entries) {
      final dir = Directory('${res.path}/${e.key}')..createSync(recursive: true);
      await _writePng(
        await _renderLogo(
          size: e.value,
          pad: 0.10,
          bg: black,
          stroke: white,
          nodes: white,
        ),
        '${dir.path}/ic_launcher.png',
      );
    }
    const foreground = {
      'drawable-mdpi': 108,
      'drawable-hdpi': 162,
      'drawable-xhdpi': 216,
      'drawable-xxhdpi': 324,
      'drawable-xxxhdpi': 432,
    };
    for (final e in foreground.entries) {
      final dir = Directory('${res.path}/${e.key}')..createSync(recursive: true);
      await _writePng(
        await _renderLogo(
          size: e.value,
          pad: 0.18,
          bg: null,
          stroke: white,
          nodes: white,
        ),
        '${dir.path}/ic_launcher_foreground.png',
      );
    }
    await _writePng(
      await _renderLogo(
        size: 1024,
        pad: 0.08,
        bg: black,
        stroke: white,
        nodes: white,
      ),
      '${assets.path}/mesh_logo_1024.png',
    );
  });
}

Future<ui.Image> _renderLogo({
  required int size,
  required double pad,
  required Color? bg,
  required Color stroke,
  required Color nodes,
}) async {
  const scale = 4;
  final big = size * scale;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  if (bg != null) {
    canvas.drawRect(
      Rect.fromLTWH(0, 0, big.toDouble(), big.toDouble()),
      Paint()..color = bg,
    );
  }
  final inner = big * (1 - 2 * pad);
  final origin = big * pad;
  canvas.save();
  canvas.translate(origin, origin);
  final strokeWidth = inner * (MeshLogo.designStroke / MeshLogo.designSize);
  MeshLogoPainter(
    progress: 1,
    bubbleColor: stroke,
    curveColor: stroke,
    nodeColor: nodes,
    strokeWidth: strokeWidth,
  ).paint(canvas, Size(inner, inner));
  canvas.restore();
  final picture = recorder.endRecording();
  final hiRes = await picture.toImage(big, big);
  // Downsample so thin AA fringes become smooth at the target size.
  final png = await hiRes.toByteData(format: ui.ImageByteFormat.png);
  if (png == null) {
    fail('encode failed');
  }
  final codec = await ui.instantiateImageCodec(
    png.buffer.asUint8List(),
    targetWidth: size,
    targetHeight: size,
  );
  final frame = await codec.getNextFrame();
  return frame.image;
}

Future<void> _writePng(ui.Image image, String path) async {
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  if (bytes == null) {
    fail('Failed to encode $path');
  }
  File(path).writeAsBytesSync(bytes.buffer.asUint8List());
}
