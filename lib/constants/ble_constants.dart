import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// App-wide GATT service UUID advertised by mesh nodes (v4, project-specific).
final Guid meshServiceUuid =
    Guid('a4c89f32-7f1e-4d3b-8c6a-5e9d2b7f18c3');

/// Writable mesh control characteristic on [meshServiceUuid] (v4, project-specific).
final Guid meshCharacteristicUuid =
    Guid('e7c29b4f-82d1-4f3a-9c6e-a4b8d1f70392');

/// Bluetooth SIG company identifier for manufacturer-specific scan/ad payload.
const int meshManufacturerId = 0xFFE0;
