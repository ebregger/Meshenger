import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:permission_handler/permission_handler.dart';

import 'ble_permission_result.dart';

/// Android API 12 (Snow Cone) — runtime BLE permission split (Scan / Connect / Advertise).
const int _android12ApiLevel = 31;

class BleHealthReport {
  final bool bluetoothHardwareEnabled;
  final bool locationServicesEnabled;
  final Map<Permission, PermissionStatus> permissions;

  const BleHealthReport({
    required this.bluetoothHardwareEnabled,
    required this.locationServicesEnabled,
    required this.permissions,
  });

  bool get isReady =>
      bluetoothHardwareEnabled &&
      locationServicesEnabled &&
      permissions.values.every((s) => s.isGranted);
}

/// Runtime BLE permission helpers. Android 12+ vs 11- use different permission sets.
class PermissionsHelper {
  PermissionsHelper._();

  static bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Opens the app’s system settings page (e.g. after [permanentlyDenied]).
  static Future<bool> openApplicationSettings() => openAppSettings();

  /// If [result] is [BlePermissionRequestResult.permanentlyDenied], throws
  /// [BlePermissionsPermanentlyDeniedException]; otherwise returns [result].
  static BlePermissionRequestResult throwIfPermanentlyDenied(
    BlePermissionRequestResult result,
  ) {
    if (result == BlePermissionRequestResult.permanentlyDenied) {
      throw const BlePermissionsPermanentlyDeniedException();
    }
    return result;
  }

  /// Returns a full report of hardware and runtime permission states.
  static Future<BleHealthReport> checkMeshHealth() async {
    final Map<Permission, PermissionStatus> permissionsMap = {};
    
    bool btEnabled = false;
    bool locEnabled = false;

    if (_isAndroid) {
      final android = await DeviceInfoPlugin().androidInfo;
      final sdkInt = android.version.sdkInt;

      final List<Permission> toCheck = sdkInt >= _android12ApiLevel
          ? [
              Permission.bluetoothScan,
              Permission.bluetoothAdvertise,
              Permission.bluetoothConnect,
            ]
          : [
              Permission.location,
              Permission.bluetooth,
            ];

      for (final p in toCheck) {
        permissionsMap[p] = await p.status;
      }

      // Check hardware toggles
      locEnabled = await Permission.location.serviceStatus.isEnabled;
      // For BT hardware state, we usually rely on FlutterBluePlus stream, 
      // but we can check initial state here if needed.
      // However, Permission.bluetooth.serviceStatus isn't reliable for "Hardware On".
      // We'll use FlutterBluePlus.adapterStateNow in the provider.
    } else {
      // Non-Android assumed ready (iOS handles via Info.plist dialogs)
      btEnabled = true;
      locEnabled = true;
    }

    return BleHealthReport(
      bluetoothHardwareEnabled: btEnabled, // Will be overridden by Provider
      locationServicesEnabled: locEnabled,
      permissions: permissionsMap,
    );
  }

  /// Requests the correct BLE-related permissions for this Android version.
  /// Non-Android: returns [BlePermissionRequestResult.granted] (OS prompts via Info.plist on iOS).
  static Future<BlePermissionRequestResult> requestAndroidBlePermissions() async {
    if (!_isAndroid) {
      return BlePermissionRequestResult.granted;
    }

    final android = await DeviceInfoPlugin().androidInfo;
    final sdkInt = android.version.sdkInt;

    final List<Permission> permissions = sdkInt >= _android12ApiLevel
        ? const [
            Permission.bluetoothScan,
            Permission.bluetoothAdvertise,
            Permission.bluetoothConnect,
          ]
        : const [
            Permission.location,
            Permission.bluetooth,
          ];

    final statuses = await permissions.request();

    if (statuses.values.any((s) => s.isPermanentlyDenied)) {
      return BlePermissionRequestResult.permanentlyDenied;
    }
    if (statuses.values.every((s) => s.isGranted)) {
      return BlePermissionRequestResult.granted;
    }
    return BlePermissionRequestResult.denied;
  }
}
