import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/ble_network_provider.dart';
import 'app_bootstrap.dart';
import 'app_themes.dart';

class MeshengerApp extends ConsumerWidget {
  const MeshengerApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Eagerly create the BLE notifier so adapter + permission bootstrap runs.
    ref.watch(bleNetworkProvider);

    return MaterialApp(
      title: 'Meshenger',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: themeDataFromColorScheme(kLightColorScheme),
      darkTheme: themeDataFromColorScheme(kDarkColorScheme),
      home: const AppBootstrap(),
    );
  }
}
