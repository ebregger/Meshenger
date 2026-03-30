import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/ble_network_provider.dart';
import '../screens/home_screen.dart';
import 'app_themes.dart';

class BluetoothApp extends ConsumerWidget {
  const BluetoothApp({
    super.key,
    required this.lightColorScheme,
    required this.darkColorScheme,
  });

  /// From [DynamicColorBuilder]; may be null on unsupported platforms.
  final ColorScheme? lightColorScheme;

  /// From [DynamicColorBuilder]; may be null on unsupported platforms.
  final ColorScheme? darkColorScheme;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Eagerly create the BLE notifier so adapter + permission bootstrap runs.
    ref.watch(bleNetworkProvider);

    final light = resolveLightColorScheme(lightColorScheme);
    final dark = resolveDarkColorScheme(darkColorScheme);

    return MaterialApp(
      title: 'Bluetooth App',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: themeDataFromColorScheme(light),
      darkTheme: themeDataFromColorScheme(dark),
      home: const HomeScreen(),
    );
  }
}
