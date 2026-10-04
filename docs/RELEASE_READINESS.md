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
- Settings exposes dependency licenses, including FlutterBluePlus's additional BSD notices. No project source license is granted by those notices.
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
- Decide whether to retain FlutterBluePlus under its own terms or implement and test [native discovery replacement](FLUTTER_BLUE_PLUS_REMOVAL.md) before release.
- Check public, direct and group chats on signed APKs, including fingerprint verification and a deliberate changed-key warning, offline/history catch-up, message retention and deletion.
- Exercise three-phone forwarding with the recipient initially absent; confirm relays cannot display private text and that **Relayed** does not claim end-recipient receipt.
- Test Android 7/8 compatibility, Android 9–11 location requirements, Android 12/12L Nearby Devices/location behavior, Android 13+ notification permission, and a current Android version. Include at least one non-Pixel OEM.
- Test denied/revoked permissions, Bluetooth toggles, locked-screen/background operation, battery restrictions, process death/relaunch and signed `adb install -r` updates. Record actual OEM restrictions rather than promising always-on delivery.
- Check privacy text, bundled dependency notices, APK checksums/signing certificate and release notes on the exact artifacts selected for publication.

The connected Pixel 3 phones provide Android 9 and Android 15 coverage only. Additional versions, OEMs and a third relay phone are separate gates; do not mark them passed based on earlier debug benchmarks.

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

These changes have not been pushed or run by the updated hosted workflow, and no release/tag has been published. Physical group/three-phone forwarding, deliberate changed-key UI behavior, Android 12/12L and non-Pixel OEM tests remain publication gates. Unit tests cover key-change blocking and confirmation, identity migration/failure handling, decompression and outbound batch limits, and relay progress for exact message IDs. The final outbound batch limit was added after the phone checks; those checks used the same behavior for ordinary small messages.
