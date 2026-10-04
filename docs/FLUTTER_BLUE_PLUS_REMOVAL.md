# FlutterBluePlus removal assessment

Assessment of the current Android implementation, October 3, 2026. FlutterBluePlus is still present in `pubspec.yaml`/`pubspec.lock`; the release preparation did not replace the scanner.

## What it does now

| Responsibility | Current owner |
| --- | --- |
| Start/stop service-filtered BLE scans and stream advertisements | FlutterBluePlus in `ble_discovery_service.dart` |
| Adapter state stream/current state and the Bluetooth-enable prompt | FlutterBluePlus in `ble_network_provider.dart` |
| MAC addresses, RSSI, advertisement timestamps, manufacturer data and service UUIDs | FlutterBluePlus scan result/device types, parsed by `mesh_advertisement.dart` |
| UUID constants and fake scan results in tests | FlutterBluePlus `Guid`, `ScanResult`, `BluetoothDevice` types |
| Advertising, GATT server/client, writes, notifications, framing and connection reuse | Meshenger's Kotlin implementation in `MainActivity.kt`, accessed through `NativeMeshService` |

The old FlutterBluePlus connection-state subscription contained empty callbacks and has been removed. Meshenger does not use FlutterBluePlus's GATT connection or characteristic APIs for message transfers.

## Recommended replacement

Extend the existing Android platform channel with a small native scanner and adapter events, rather than introducing another general Bluetooth plugin. Use Android's `BluetoothLeScanner`, an adapter-state broadcast receiver, and `ACTION_REQUEST_ENABLE`. Keep the current Kotlin advertising/GATT transport.

1. Introduce application-owned scan and adapter types. Advertisement observations need address, RSSI, timestamp, service UUIDs, manufacturer bytes, and any address metadata required by the existing dial policy. Pass observations through the existing advertisement parser and keep fake-peer tests independent of a plugin.
2. Implement filtered scans for the Meshenger service UUID, low-latency mode, repeated observations, and extended advertisements where supported. Android 7 must use supported scan settings; do not call API 26 or 33 methods below their API level.
3. Report asynchronous `onScanFailed` errors, scanning lifecycle and adapter state. Preserve registration retries, the scan watchdog, freshness filtering, self-filtering, rotating-address handling, and stop/recovery behavior. Native scan callbacks are individual/batched observations rather than FlutterBluePlus's growing cached list; make that change explicit in discovery policy.
4. Replace `BluetoothDevice` wrappers with addresses where they are only passed to the native transport. Replace `Guid` constants with canonical UUID strings. Remove all FlutterBluePlus imports, including test fixtures and permission comments.
5. Remove the dependency, regenerate the lockfile/plugin registration through `flutter pub get`, and remove its additional notice only once no FlutterBluePlus code is packaged. Rebuild all supported Android artifacts.
6. Re-run the advertisement/parser and scheduling tests, two-phone live sync and history catch-up, three-phone relay, radio-toggle/permission recovery, and screen-off tests across the Android test matrix before publishing.

## Why assess removal before release

The native transport already owns the most complex BLE behavior, so the replacement scope is limited to discovery and adapter control. It is still a meaningful radio behavior change: scan filtering, duplicate observations, stale addresses, and OEM background limits can affect every connection attempt. It should be implemented and measured as a separate change, with the existing hardware results as a baseline.

The resolved `flutter_blue_plus` 2.2.1 package contains FlutterBluePlus License 1.3. Personal/nonprofit/educational use is permitted under its open-use terms; use by or for a for-profit organization, including commercial use by individuals, requires its commercial license. See [the publisher's license](https://github.com/chipweinberger/flutter_blue_plus/blob/master/packages/flutter_blue_plus/LICENSE.md). Changing Meshenger's source license does not remove that requirement.

This assessment does not claim a dependency removal or radio equivalence test has already happened.
