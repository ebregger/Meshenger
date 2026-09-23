import 'package:flutter/material.dart';

import '../screens/home_screen.dart';

/// App entry after [MaterialApp]; native Android splash covers cold start.
class AppBootstrap extends StatelessWidget {
  const AppBootstrap({super.key});

  @override
  Widget build(BuildContext context) => const HomeScreen();
}
