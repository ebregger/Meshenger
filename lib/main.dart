import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    ProviderScope(
      child: DynamicColorBuilder(
        builder: (lightDynamic, darkDynamic) {
          return BluetoothApp(
            lightColorScheme: lightDynamic,
            darkColorScheme: darkDynamic,
          );
        },
      ),
    ),
  );
}
