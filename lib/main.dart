import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'services/api_service.dart';

// Run the local stress-test API only in debug builds.
// ignore: constant_identifier_names
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
      child: const MeshengerApp(),
    ),
  );
}
