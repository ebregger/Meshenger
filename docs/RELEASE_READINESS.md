# First-release readiness

No public release has been posted. The permanent Android application ID is `com.bregger.edison.meshenger`; Meshenger's own source remains unlicensed. The current candidate version is `1.0.0+1`.

## Changes prepared

- Android package identity and development tooling use the permanent ID. Prior development installs are separate apps; their data is not automatically migrated.
- Release lint now fails on Android errors. API 26/33 guards, Bluetooth write return constants, permission declarations and the debug wake-lock tag have been corrected. Only `PropertyEscape` is excluded, for Flutter-generated local Windows SDK paths that are not packaged.
- Identity seeds are encrypted with an Android Keystore AES-GCM wrapping key and stored in `noBackupFilesDir`. Legacy preference seeds migrate only after a successful protected write. Storage errors do not silently generate replacement identities. Android cloud backup and device transfer explicitly exclude app data.
- Peer keys are pinned when first used for private chats or verification. Changed keys block sending until the user compares and confirms the new fingerprint. Settings and private chats expose full fingerprints.
- Flutter owns the Android BLE permission prompt. Interrupted/partial permission results do not authorize startup, and the native foreground service checks actual grants and handles revocation races. This fixes the fresh-install Android 15 crash caused by competing native and Flutter prompts.
- The public room and relay metadata are explained in the UI. **Relayed** tracks the specific local message IDs in a successful transfer to a known peer; it does not mean recipient/read acknowledgement.
- Untrusted inbound transfers have byte, chunk, concurrency and time limits. Decompression is bounded before JSON/CRDT merge; unknown tables/columns and oversized records are rejected. Large outbound history pushes are trimmed to fit the receiver's compressed and expanded byte limits, and only included message IDs count as relayed. User text is capped at 2,000 characters/2 KB and groups at 16 people.
- Settings exposes dependency licenses. FlutterBluePlus and its notice asset have since been removed with the native discovery replacement; earlier candidate APKs retain the notices required by their packaged dependencies. No project source license is granted by dependency notices.
- CI runs Flutter analysis/tests, Python tooling tests, Kotlin unit tests and full Android release lint. Flutter is pinned to 3.47.5.
- The release workflow validates the tag against `pubspec.yaml`, restores signing files from secrets, builds universal/split APKs, verifies signatures, and uploads APKs with SHA-256 checksums as temporary workflow artifacts. Its GitHub permission is `contents: read`; it has no release-publishing step.

## Signing and candidate build

Use the same keystore for every upgrade. Keep a secure offline backup of the keystore, alias and passwords; losing the signing key can prevent existing installs from updating. Do not commit signing files.

The repository's **Release Candidate** workflow expects these GitHub Actions secrets:

- `ANDROID_KEYSTORE_BASE64`: base64 of the existing `android/app/upload-keystore.jks`.
- `ANDROID_STORE_PASSWORD`: existing store password.
- `ANDROID_KEY_PASSWORD`: existing key password.
- `ANDROID_KEY_ALIAS`: existing key alias.

All four secrets were configured in `ebregger/Meshenger` from the existing local release key during this preparation session. Secret values and keystore contents were not logged or committed.

After merging/pushing the prepared changes, use manual workflow dispatch to build a candidate. A blank tag uses the pubspec version; an explicit tag must match it. The current workflow also accepts `v*` tag pushes but builds artifacts only. Do not push a first-release tag or publish a GitHub release until the remaining gates have been reviewed.

Local validation:

```text
flutter pub get
flutter analyze
flutter test
python -m unittest discover -s tools -p "test_*.py"
flutter build apk --release
cd android
./gradlew :app:testDebugUnitTest :app:lintRelease --console=plain
```

On Windows use `gradlew.bat` and Android Studio's JBR when Java is not on the path. Check each APK with Android SDK `apksigner verify --verbose --print-certs`, and verify its package ID/version with `aapt dump badging`. Debug tests alone do not exercise release-build behavior.

## Remaining publication gates

- Review the final diff and run the updated workflow on a clean GitHub runner. Local builds do not establish that the hosted workflow has passed.
- Confirm the signing key has a secure offline backup.
- Expand testing of the [native discovery replacement](FLUTTER_BLUE_PLUS_REMOVAL.md) to the additional Android/OEM/background cases below.
- Profile large unequal-history and three-phone catch-up. The supplemental final-build run delivered all 1,000 messages with zero send API errors, but took 771.84 seconds and logged connection failures; it is not a clean performance result.
- Review the completed [signed public/direct/group, key-change and three-phone forwarding checks](RELIABILITY_VALIDATION.md) on the exact artifacts selected for publication.
- Test Android 7/8 compatibility, Android 9–11 location requirements, Android 12/12L Nearby Devices/location behavior, Android 13+ notification permission, and a current Android version. Include at least one non-Pixel OEM.
- Repeat Android 9 screen-off delivery after the Activity cleanup fix, and expand locked-screen/background and battery-restriction coverage. Denied-permission recovery, Android 9 Bluetooth recovery, signed updates/reopen, Android 9 Home/background delivery and Android 15 short screen-off delivery have been checked. Record actual OEM restrictions rather than promising always-on delivery.
- Check privacy text, bundled dependency notices, APK checksums/signing certificate and release notes on the exact artifacts selected for publication.

The connected phones now include Android 9 and 15 Pixel 3s and an Android 17 Pixel 9 Pro XL. Additional versions and non-Pixel OEM coverage remain separate gates; do not mark signed/background checks passed based on debug benchmarks.

## Validation record

October 3, 2026, local validation:

| Check | Result |
| --- | --- |
| Flutter analysis | No issues |
| Flutter tests | 145 passed |
| Python tooling tests | 63 passed |
| Kotlin app unit tests | 9 passed |
| Full Android release lint | 0 errors, 19 warnings; remaining warnings cover existing dependency versions, icons/resources, hardware IDs and the debug wake lock |
| Universal and ARM64/ARMv7/x86-64 APK builds | Passed; all four signatures verified with the same release certificate |
| Packaged identity/version | `com.bregger.edison.meshenger`, `1.0.0` / build `1`, min API 24, target API 36 |
| Dependency notices | APK `NOTICES.Z` includes FlutterBluePlus's current license and original BSD notices; signed app's Licenses page opens |
| Android 9/15 signed install | Passed on the two connected Pixel 3 phones; old development app/data preserved separately |
| Denied-permission recovery on Android 15 | Location denial left the process alive and the mesh stopped; retry and grant started the foreground service without a crash |
| Public and direct chat | Messages exchanged in both directions; direct text decrypted on each recipient; exact-message **Relayed** status observed |
| Fingerprints | Full fingerprints matched between phones and were confirmed; verification status persisted |
| Signed update/process restart | `adb install -r` on both phones preserved their own fingerprints; Android 9 private history and pending sync survived restart |
| Short screen-off check | Android 15's private test transfer was acknowledged while Android 9 reported `Dozing`, with its charging stay-awake setting disabled; long Doze/unplugged/OEM behavior remains untested |
| Version and configuration checks | Version/tag validation, workflow YAML, backup XML and `git diff --check` passed |

Local candidate APKs and `SHA256SUMS.txt` are in `build/release-candidates/` (gitignored). The signing certificate SHA-256 fingerprint is `d76c6ed68d36b194fbc5f4da300d5e5c4bd86a03e0efcd461bbf304922b7adb5`.

The release-preparation checkpoint was pushed as `db35434` on October 4, 2026. Its first hosted run exposed an overly broad signing guard: lint's resource/JAR packaging tasks were mistaken for APK/AAB packaging. Commit `8062bec` narrows the guard, allowing unsigned CI tests/lint while still rejecting actual release packaging without a key. [The hosted rerun passed](https://github.com/ebregger/Meshenger/actions/runs/37209329724).

No release/tag has been published. At the initial release-preparation checkpoint, physical group/three-phone forwarding and changed-key UI checks remained open; their subsequent results are in the reliability report below. Android 12/12L and non-Pixel OEM tests still remain publication gates. Unit tests cover key-change blocking and confirmation, identity migration/failure handling, decompression and outbound batch limits, and relay progress for exact message IDs. The final outbound batch limit was added after the October 3 phone checks; those checks used the same behavior for ordinary small messages.

## Native discovery validation, October 4, 2026

FlutterBluePlus has been replaced by native filtered discovery and adapter events. Flutter analysis is clean; 149 Flutter tests and 9 Kotlin tests pass. Full release lint reports 0 errors and 19 warnings. Universal and ARM64/ARMv7/x86-64 candidates were rebuilt and verified against the same signing certificate. Their dependency graph, native DEX files and bundled notices contain no FlutterBluePlus plugin/license. The universal APK is 61,833,996 bytes, compared with 62,204,108 bytes before removal.

Matching 1,000-message debug runs on the Android 9/15 phones use an isolated `.benchmark` application ID and start with fresh disposable app data for each variant. Original installations retain their identities and existing data; their data was never cleared. Timing and reliability results are recorded in the [before/after performance report](FLUTTER_BLUE_PLUS_BENCHMARK.md).

The initial removal load tests exposed debug send API assertions in the existing CRDT library when concurrent writes/merges publish their clocks out of order. The database write can persist before the assertion is raised, so API acknowledgement failures and actual message delivery are recorded separately. These failures were subsequently fixed and retested below.

The subsequent [reliability validation](RELIABILITY_VALIDATION.md) fixes the clock race and inbound repair cursor truncation. Two new 1,000-message runs deliver completely with zero send errors. Flutter analysis is clean and 152 Flutter, 63 Python tooling and 9 Kotlin tests pass. It records successful signed three-phone group/decryption, isolated private forwarding, changed-key blocking/confirmation, local history clearing and recovery tests. Further physical testing fixes a stale Android 9 advertising busy bit and leaked GATT servers after Activity destruction. The report distinguishes completed cases, corrected artifact-selection mistakes and remaining screen-off/OEM/Doze coverage. No release has been published.
