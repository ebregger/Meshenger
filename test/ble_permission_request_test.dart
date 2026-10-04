import 'package:bluetooth_app/utils/ble_permission_result.dart';
import 'package:bluetooth_app/utils/permissions_helper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  const requested = [Permission.bluetoothScan, Permission.bluetoothConnect];

  test(
    'interrupted or partial permission results never start a mesh session',
    () {
      expect(
        PermissionsHelper.permissionRequestOutcome(requested, {}),
        BlePermissionRequestResult.denied,
      );
      expect(
        PermissionsHelper.permissionRequestOutcome(requested, {
          Permission.bluetoothScan: PermissionStatus.granted,
        }),
        BlePermissionRequestResult.denied,
      );
    },
  );

  test('all requested permissions must be granted', () {
    expect(
      PermissionsHelper.permissionRequestOutcome(requested, {
        Permission.bluetoothScan: PermissionStatus.granted,
        Permission.bluetoothConnect: PermissionStatus.denied,
      }),
      BlePermissionRequestResult.denied,
    );
    expect(
      PermissionsHelper.permissionRequestOutcome(requested, {
        Permission.bluetoothScan: PermissionStatus.granted,
        Permission.bluetoothConnect: PermissionStatus.granted,
      }),
      BlePermissionRequestResult.granted,
    );
  });

  test('permanently denied permission directs the user to Settings', () {
    expect(
      PermissionsHelper.permissionRequestOutcome(requested, {
        Permission.bluetoothScan: PermissionStatus.granted,
        Permission.bluetoothConnect: PermissionStatus.permanentlyDenied,
      }),
      BlePermissionRequestResult.permanentlyDenied,
    );
  });
}
