# FlutterBluePlus removal

The Android implementation now uses Meshenger's own platform channel for discovery and Bluetooth adapter control. FlutterBluePlus, its platform/interface packages, and now-unused transitive dependencies have been removed from `pubspec.yaml` and `pubspec.lock`. Meshenger's own source remains unlicensed.

## Implementation

- `NativeBleRadio.kt` uses `BluetoothLeScanner` with the Meshenger service UUID filter, low-latency mode, all repeated observations and immediate reporting. API 26+ enables extended advertisements and supported PHYs; Android 7 keeps compatible settings.
- The radio event channel carries only the current callback's observations, including address, RSSI, service UUIDs, manufacturer bytes and the original observation time converted from Android's monotonic clock. It does not build a growing historical result list.
- Dart uses application-owned `MeshScanResult` and `MeshAdapterState` types. GATT destinations are address strings and UUID constants are canonical strings. Fake-peer tests use the same observation shape.
- Adapter queries and an `ACTION_STATE_CHANGED` receiver report state; `ACTION_REQUEST_ENABLE` opens Android's Bluetooth-enable UI. Receiver registration uses `RECEIVER_EXPORTED` on API 33+ because Bluetooth system broadcasts can come from a privileged non-system UID; the receiver queries actual adapter state rather than trusting broadcast extras.
- Immediate registration failures complete the scan-start method with an error for the existing three-attempt retry loop. Later failures become scan-stream errors. Permission checks and revocation handling, explicit stop, stale callback suppression and activity teardown prevent leaked scanner registrations.
- Discovery subscribes before commanding the scan. Existing freshness, self-filtering, rotating-address, handshake throttle, dial election, watchdog and recovery behavior is retained. Advertising, GATT transfer, framing, held-link reuse and CRDT merge remain on the existing transport.

The former plugin-owned Bluetooth/device/UUID types and all FlutterBluePlus imports are gone. Its extra notice asset was removed for new builds after dependency removal; earlier candidate APKs retain their bundled notices and terms.

## Validation

Flutter analysis passes. All 149 Flutter tests and 9 Kotlin unit tests pass, and full Android release lint reports no errors. New radio tests exercise observation timestamps/binary data, callback batches without historical accumulation, asynchronous errors alongside adapter events, and native method dispatch. The connected Android 9 and Android 15 Pixel 3 phones are used for matching 1,000-message before/after runs; see the performance record added alongside these changes.

Further Android versions, a non-Pixel OEM, three-phone forwarding and extended background/Doze behavior remain first-release gates. These two-phone foreground results do not establish radio equivalence on every supported device.

## Platform references

- [Android BluetoothLeScanner](https://developer.android.com/reference/android/bluetooth/le/BluetoothLeScanner): service-filtered scans avoid Android's unfiltered screen-off scan suspension.
- [ScanSettings.Builder](https://developer.android.com/reference/android/bluetooth/le/ScanSettings.Builder): API 26 guards for extended advertisements and PHY settings.
- [ScanResult](https://developer.android.com/reference/android/bluetooth/le/ScanResult): observation timestamps are measured since boot.
- [Broadcast receiver guidance](https://developer.android.com/develop/background-work/background-tasks/broadcasts): Bluetooth's privileged sender may require an exported receiver.
