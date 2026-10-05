# Reliability validation, October 4, 2026

The CRDT clock race, catch-up pagination, stale legacy advertising busy bit and Activity-owned GATT server cleanup are fixed. No release or tag has been published. Original app identities and chats were preserved; disposable test data uses `com.bregger.edison.meshenger.benchmark`.

## Clock publication

Concurrent local writes and remote merges could complete SQL before publishing their CRDT clocks. An older operation could then publish after a newer operation and fail `hlc >= canonicalTime`, even though its row had persisted. DatabaseService now queues complete mutations, including clock publication and dataset notifications. A failed mutation reaches its caller without blocking later queued mutations. Version-vector caching records the actual published clock instead of predicting an increment before the write.

The regression test withholds one real SQL completion, then overlaps a second write and a remote merge. It reproduced the assertion before the fix and now completes with all three rows and the correct vector. A second test checks recovery after a rejected SQL operation and 20 queued writes.

## Retained history

The held inbound connection requested 80 repair rows, advancing the database cursor by 80, then truncated the response to 25. When peer fingerprints stayed unchanged, this skipped rows that were never sent. The repair request now uses the actual 25-row inbound budget, including deep repair.

The regression test seeds both real databases with the same 1,000 tombstones, creates 160 new live messages, and gives the receiver only the newest message. Its vector therefore matches while older rows are missing. With frozen peer fingerprints, the original 80/25 control skips gaps; the fixed pages deliver every missing message and converge to the same database hash.

Two physical debug runs used the same Android 9/15 Pixel 3 phones, alternating senders, a 100 ms minimum send interval, and two-second receive polling:

| Measurement | Fresh disposable database | Same database with retained history |
| --- | ---: | ---: |
| Delivered | 1,000/1,000 | 1,000/1,000 |
| Send errors | 0 | 0 |
| Connection failures/rejections | 0/0 | 0/0 |
| Scanner errors | 0 | 0 |
| Elapsed | 174.30 s | 168.46 s |
| Mean observed latency | 1.600 s | 1.797 s |
| p95 | 3.032 s | 3.530 s |
| Maximum | 4.589 s | 20.988 s |

The second run keeps the first run's identities/database; the runner's message clear retains 1,000 tombstones on each phone. Other Meshenger apps were force-stopped, and the third phone had no Meshenger process during either timed run. [The compact record](benchmarks/reliability-20261004.json) includes measurements, APK hashes and raw-summary hashes. Full local traces are in `build/reliability-20261004/`.

These runs resolve the observed send errors and demonstrate delivery with retained history. The second run still has a 21-second outlier. They are sequential single runs, with polling and correlated BLE samples, and do not establish a causal performance gain from removing FlutterBluePlus. The earlier unequal-history trial averaging 97.9 seconds is not a controlled comparison against these results.

A supplemental run of the final native recovery build sent between Android 9 and Android 17 after the signed checks and an aborted trial. Android 15 remained an active test relay initially and was force-stopped during catch-up when USB debugging recovered. The two sending phones retained unequal history; the normal runner clear removed their live messages and kept tombstones, while the relay still held older traffic. This is a delivery/recovery observation, not another paired performance comparison:

| Measurement | Supplemental Android 9/17 run |
| --- | ---: |
| Delivered | 1,000/1,000 |
| Send API errors | 0 |
| Connection failures/rejections | 3/1 |
| Scanner errors | 0 |
| Elapsed | 771.84 s |
| Mean observed latency | 155.22 s |
| p95 / maximum | 445.18 s / 757.95 s |

Complete delivery does not make this acceptable catch-up latency. Profiling large unequal histories and three-node repair scheduling remains release work. The compact record includes this run's separate setup and relay-stop timestamp; raw details are `final-history-9-17.log/json`. The Android 9/15 attempts before it stopped in preflight when Android 15's USB debugging/API was unavailable. A `--preserve-messages` attempt was aborted because it left the UI on its bounded recent page; that attempt cannot account for every rendered receipt. No incomplete trial is presented as a successful 1,000-message run.

## Signed device checks

Signed release APKs were installed on Pixel 3 Android 9/API 28, Pixel 3 Android 15/API 35, and Pixel 9 Pro XL Android 17/API 37. The test release uses the benchmark suffix to preserve production data; its release mode and signing key match the production candidate. The debug HTTP API is disabled in release mode, so signed checks use the actual UI and native transport acknowledgements.

- Android 15 location denial leaves the process alive and mesh stopped. Clearing the denial and granting the app's retry prompt starts the mesh without a crash. This exposed stale diagnostics: denied startup showed unqueried hardware and a healthy scanner. Startup now refreshes actual permission/hardware statuses; the scanner tile explains permission blocking and offers a permission request.
- A three-person group was created through the Android 17 UI. With verified release APKs on all three phones, each sent a new group message and decrypted the other two messages.
- Android 9/17 full fingerprints matched and were confirmed through the UI. Verification survived a signed update.
- A deliberate key replacement was prepared in the disposable Android 9 installation only, using a debug APK signed with the same key. Before the final warning/confirmation exchange, Android 9 was restored to a package-verified, non-debuggable release APK. The mesh node ID stayed unchanged. Android 17 showed the changed-key warning, blocked sending, and retained `FinalKeyChangeDraft17`. After comparing every group of the new full fingerprint against Android 9's own screen and confirming it, that draft sent and decrypted on signed Android 9. Old ciphertext for the previous key remained locked.
- In the isolated forwarding repeat, Android 15's location permission was denied and its mesh was stopped. Android 17 sent `CleanSignedRelay17To15`; Android 9 accepted it and the sender showed **Relayed**. Android 17 was then force-stopped. After Android 15 granted its retry prompt, the exact private text decrypted there while the sender remained stopped. Android 9 had no private conversation for Android 17/15. Android 15's direct reply decrypted on Android 17 after its relaunch. All other Meshenger installations were force-stopped for this repeat.
- Signed public messages exchanged between Android 9/17. Clearing the shared room on Android 9 and restarting it hid the existing public history on that phone while Android 17 retained its copies. `AfterFinalClear17` subsequently arrived without resurrecting the cleared messages.
- Android 9 Bluetooth was toggled through Android's actual quick-settings tile, with `dumpsys` confirming OFF and then ON. After recovery, `FinalBluetoothRecovery17` decrypted on signed Android 9 without a process restart.
- In the one-minute screen-off check, both Pixel 3s reported `Dozing` and Android 9's display reported OFF while the signed sender showed successful relays. Android 15 subsequently displayed `FinalScreenOffPrivate17To15`. Android 9 did not initially receive its private text: the sender's acknowledgement was for another relay, not proof of recipient delivery. Investigation exposed the Activity cleanup defect below. Its fix was checked with signed close/reopen and Home/background delivery on Android 9. In a final isolated repeat with the corrected native build, Android 15 was stopped, Android 17 saw only Android 9 as a peer, and `FinalNativeScreenOffTo9` was relayed while Android 9 remained Dozing with its display OFF. Native transport acknowledgements were recorded. The recipient remains PIN-locked, so confirmation of decrypted text through its UI remains open.

The charging stay-awake settings and display timeouts were restored to their saved values. The Pixel 3s return to the debug build in the foreground, which keeps their screens awake without changing those preferences. Long unplugged Doze, battery restrictions, Android 7/8 and 12/12L, and non-Pixel OEM coverage remain publication gates.

### Native recovery fixes

Android 9's legacy AdvertisingSet mirrors the busy bit in manufacturer data in the scan response. Connection/disconnection updated only the primary advertisement, leaving the mirror busy until another database hash update. Both copies now refresh when the inbound slot changes.

MainActivity also owns the GATT callbacks and Flutter payload stream. Its destruction previously closed discovery only; old GATT servers could survive and deliver writes into a detached event sink after another Activity opened a new server. Destruction now closes its GATT/advertising/client resources, cancels the inbound idle sweep and stops its foreground service. A pending service-registration callback cannot restart advertising after destruction. Home/background operation preserves the Activity and continues to receive; exiting with Back tears down its resources. Signed Android 9 received and decrypted `AfterSignedReopen17` after exit/reopen and `FinalBackgroundPrivate17To9` after a Home/background transfer.

### Artifact selection correction

An environment-variable attempt to request the benchmark suffix did not select it in later Flutter builds. Those APKs updated the permanent installation without clearing its data, while Android 9's benchmark installation still contained the temporary signed debug build. These preliminary mixed-build observations were excluded and the permission, group, forwarding, local-clear and recovery checks repeated using explicitly selected and verified test APKs. The final changed-key exchange likewise restored the correct release package before confirmation.

Build the disposable signed package with an explicit Gradle argument, then inspect it before installing:

```text
flutter build apk --release
cd android
./gradlew :app:assembleRelease -PmeshengerBenchmark=true --console=plain
aapt dump badging ../build/app/outputs/flutter-apk/app-release.apk
apksigner verify --print-certs ../build/app/outputs/flutter-apk/app-release.apk
```

The expected test package is `com.bregger.edison.meshenger.benchmark`; `dumpsys package` must omit `DEBUGGABLE`. Production candidates must instead report `com.bregger.edison.meshenger`. Debug benchmark APKs can use the release certificate with both `-PmeshengerBenchmark=true` and `-PmeshengerSignedDeviceTest=true`; they are still debug builds and do not establish release-mode behavior.

## Build validation

Flutter analysis is clean; 152 Flutter tests, 63 Python tooling tests and 9 Kotlin tests pass. Full Android release lint passes. Universal and ARM64/ARMv7/x86-64 production candidates were rebuilt, their signatures verified, and checksums refreshed in `build/release-candidates/`. The production package remains `com.bregger.edison.meshenger`, version `1.0.0+1`, min API 24, target API 36. The release certificate SHA-256 is `d76c6ed68d36b194fbc5f4da300d5e5c4bd86a03e0efcd461bbf304922b7adb5`.
