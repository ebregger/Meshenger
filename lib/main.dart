import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'services/api_service.dart';

// Set this to false in production or when not actively running a stress test
const bool ENABLE_STRESS_TEST_API = true;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  
  final container = ProviderContainer();
  
  if (ENABLE_STRESS_TEST_API) {
    ApiService.start(container);
  }

  runApp(
    UncontrolledProviderScope(
      container: container,
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
