import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'services/api_service.dart';

// Run the local stress-test API only in debug builds.
const bool ENABLE_STRESS_TEST_API = kDebugMode;

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
