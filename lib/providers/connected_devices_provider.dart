import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Mock paired / connected peripherals until Bluetooth discovery is implemented.
final connectedDevicesProvider = Provider<List<String>>((ref) {
  return const [
    'Device A',
    'Pixel 8',
    'Studio Display',
    'Friend’s Phone',
  ];
});
