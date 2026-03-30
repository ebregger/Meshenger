import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:permission_handler/permission_handler.dart';

import 'ble_permission_result.dart';

/// Android API 12 (Snow Cone) — runtime BLE permission split (Scan / Connect / Advertise).
const int _android12ApiLevel = 31;

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
