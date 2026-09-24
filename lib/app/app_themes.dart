import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Muted Material 3 blue seed shared by the app and launcher artwork.
const Color kBrandSeed = Color(0xFF7189A6);

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
