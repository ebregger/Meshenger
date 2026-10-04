# Reliability validation, October 4, 2026

The CRDT clock race and a catch-up pagination defect are fixed. No release or tag has been published. Original app installations, identities and chats were preserved; physical testing uses the disposable `com.bregger.edison.meshenger.benchmark` package.

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

## Signed device checks

Signed release APKs were installed on Pixel 3 Android 9/API 28, Pixel 3 Android 15/API 35, and Pixel 9 Pro XL Android 17/API 37. The test release uses the benchmark suffix to preserve production data; its release mode and signing key match the production candidate. The debug HTTP API is disabled in release mode, so signed checks use the actual UI and native transport acknowledgements.

- Android 15 location denial leaves the process alive and mesh stopped. Clearing the denial and granting the app's retry prompt starts the mesh without a crash. This exposed stale diagnostics: denied startup showed unqueried hardware and a healthy scanner. Startup now refreshes actual permission/hardware statuses; the scanner tile explains permission blocking and offers a permission request.
- A three-person group was created through the Android 17 UI. Android 17's message decrypted on Android 9, and Android 9's reply decrypted on Android 17.
- Android 9/17 full fingerprints matched and were confirmed through the UI. Verification survived a signed update.
- A deliberate key replacement was prepared in the disposable Android 9 installation only, using a debug APK signed with the same key, then restoring the release APK. The mesh node ID stayed unchanged. Android 17 showed the changed-key warning, blocked sending, and retained the draft. After comparing the new full fingerprint against Android 9 and confirming it, the draft sent and decrypted on Android 9. Old ciphertext for the previous key remained locked on the changed phone.
- A private Android 17-to-15 message was sent while Android 15's test app was force-stopped. Android 17 reported **Relayed** after Android 9 accepted it. The sender was then force-stopped. Recipient decryption after relaunch is pending Android 15 unlocking; this is not yet a completed forwarding check.

The remaining signed checks include Android 15 group UI/decryption, completion of the isolated forwarding test, background/screen-off delivery, Bluetooth recovery with a live peer, local history clearing, and final process/update checks. Long unplugged Doze, battery restrictions, Android 7/8 and 12/12L, and non-Pixel OEM coverage remain publication gates.

## Build validation

Flutter analysis is clean; 152 Flutter tests, 63 Python tooling tests and 9 Kotlin tests pass. Full Android release lint passes. Universal and ARM64/ARMv7/x86-64 production candidates were rebuilt, their signatures verified, and checksums refreshed in `build/release-candidates/`. The production package remains `com.bregger.edison.meshenger`, version `1.0.0+1`, min API 24, target API 36. The release certificate SHA-256 is `d76c6ed68d36b194fbc5f4da300d5e5c4bd86a03e0efcd461bbf304922b7adb5`.
