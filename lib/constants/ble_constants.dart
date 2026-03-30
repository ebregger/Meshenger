import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// App-wide GATT service UUID advertised by mesh nodes (v4, project-specific).
/// Rotated when OS bond caches for old service UUIDs cause unwanted pairing prompts.
final Guid meshServiceUuid =
    Guid('c7e4f1a2-9b3d-4a8e-a1f6-2d5e8b9c0a4f');

/// Writable mesh control characteristic on [meshServiceUuid] (v4, project-specific).
final Guid meshCharacteristicUuid =
    Guid('6b2e8f1a-4c9d-4e7b-b3a5-9f8e7d6c5b4a');

/// Bluetooth SIG company identifier for manufacturer-specific scan/ad payload.
const int meshManufacturerId = 0xFFE0;
