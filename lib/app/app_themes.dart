import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Fixed brand seed for light/dark [ColorScheme]s (no Material You / dynamic color).
const Color kBrandSeed = Color(0xFF1E3A8A);

final ColorScheme kLightColorScheme = ColorScheme.fromSeed(
  seedColor: kBrandSeed,
  brightness: Brightness.light,
);

final ColorScheme kDarkColorScheme = ColorScheme.fromSeed(
  seedColor: kBrandSeed,
  brightness: Brightness.dark,
);

ThemeData themeDataFromColorScheme(ColorScheme colorScheme) {
  return ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    inputDecorationTheme: const InputDecorationTheme(
      filled: false,
    ),
  );
}

/// True on physical iOS devices/simulator (Liquid Glass chrome applies here only).
bool get defaultTargetPlatformIsIos {
  return !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
}
