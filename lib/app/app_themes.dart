import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Fallback seed when [dynamic_color] cannot supply system palettes (older OS, etc.).
const Color kFallbackSeedDeepBlue = Color(0xFF1E3A8A);

/// Resolves Material You light scheme, or a deep-blue [ColorScheme.fromSeed] fallback.
ColorScheme resolveLightColorScheme(ColorScheme? lightDynamic) {
  return lightDynamic ??
      ColorScheme.fromSeed(
        seedColor: kFallbackSeedDeepBlue,
        brightness: Brightness.light,
      );
}

/// Resolves Material You dark scheme, or a deep-blue [ColorScheme.fromSeed] fallback.
ColorScheme resolveDarkColorScheme(ColorScheme? darkDynamic) {
  return darkDynamic ??
      ColorScheme.fromSeed(
        seedColor: kFallbackSeedDeepBlue,
        brightness: Brightness.dark,
      );
}

/// Material 3 theme driven by a fully resolved [ColorScheme] (dynamic or fallback).
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
