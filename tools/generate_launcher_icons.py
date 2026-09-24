"""Export all Android branding from the Flutter logo painter."""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RES = ROOT / "android" / "app" / "src" / "main" / "res"
ASSETS = ROOT / "assets" / "branding"
BLUE = "#7189A6"


def main() -> None:
    # The Flutter painter is the single geometry source for app, launcher and splash.
    flutter = shutil.which("flutter") or str(
        Path.home() / "tools" / "flutter" / "bin" / "flutter.bat"
    )
    subprocess.run(
        [flutter, "test", "test/export_branding_pngs_test.dart"],
        cwd=ROOT,
        check=True,
    )

    (RES / "values" / "colors.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n'
        f'    <color name="ic_launcher_background">{BLUE}</color>\n'
        '    <color name="splash_background">#FFFFFF</color>\n'
        '</resources>\n',
        encoding="utf-8",
    )
    anydpi = RES / "mipmap-anydpi-v26"
    anydpi.mkdir(parents=True, exist_ok=True)
    (anydpi / "ic_launcher.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@color/ic_launcher_background"/>\n'
        '    <foreground android:drawable="@drawable/ic_launcher_foreground"/>\n'
        '</adaptive-icon>\n',
        encoding="utf-8",
    )
    shutil.copyfile(
        RES / "drawable-xxhdpi" / "ic_launcher_foreground.png",
        RES / "drawable" / "ic_launcher_foreground.png",
    )
    for name in (
        "splash_icon_dark.png",
        "splash_icon_system.png",
        "splash_icon_system_dark.png",
    ):
        for directory in (ASSETS, RES):
            for path in directory.rglob(name):
                path.unlink()
    print(f"Wrote launcher and splash icons from {ASSETS / 'mesh_logo_1024.png'}")


if __name__ == "__main__":
    main()
