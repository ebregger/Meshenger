# Third-party notices

This document concerns dependencies only. It does not grant a license to Meshenger's own source, which is currently unlicensed.

Flutter collects package `LICENSE`/`NOTICES` files into the application's license bundle. Open **Settings → Third-party licenses** to read them in the app. The build also includes [FlutterBluePlus's additional BSD notices](third_party/flutter_blue_plus/NOTICE.txt) through `flutter.licenses`, because Flutter's collector does not automatically read `NOTICE.md`.

The installed FlutterBluePlus 2.2.1 package uses the FlutterBluePlus License 1.3. Its commercial-use requirement applies separately from any future Meshenger license; including a notice does not purchase or replace a commercial license. Consult the [upstream terms](https://github.com/chipweinberger/flutter_blue_plus/blob/master/packages/flutter_blue_plus/LICENSE.md) before commercial use.

When changing dependencies, review the exact resolved versions in `pubspec.lock`, preserve any additional notices, and inspect the license bundle in the resulting APK. The Flutter framework/engine and Android native libraries also keep their own terms. This file is a guide to the bundled notices, not a declaration that all dependency terms are identical.
