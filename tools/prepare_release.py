"""Validate release versions and restore signing inputs without logging secrets."""

import argparse
import base64
import os
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]


def release_tag(pubspec: str, requested: str = "") -> str:
    match = re.search(r"^version:\s*([^\s]+)\s*$", pubspec, re.MULTILINE)
    if not match:
        raise ValueError("pubspec.yaml must contain a version")
    version = match.group(1)
    if not re.fullmatch(r"\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?\+[1-9]\d*", version):
        raise ValueError("Use a semantic version and a positive Android build number")
    expected = "v" + version.split("+", 1)[0]
    if requested and requested != expected:
        raise ValueError(f"Release tag must match pubspec.yaml: expected {expected}")
    return expected


def java_property(value: str) -> str:
    return (value.replace("\\", "\\\\").replace("\n", "\\n")
            .replace("\r", "\\r").replace("\t", "\\t")
            .replace(" ", "\\ ").replace("=", "\\=").replace(":", "\\:"))


def restore_signing(root: Path, environment: dict[str, str]) -> None:
    names = ("ANDROID_KEYSTORE_BASE64", "ANDROID_STORE_PASSWORD",
             "ANDROID_KEY_PASSWORD", "ANDROID_KEY_ALIAS")
    if any(not environment.get(name) for name in names):
        raise ValueError("Configure all four Android signing secrets before building candidates")
    key_path = root / "android/app/upload-keystore.jks"
    properties_path = root / "android/key.properties"
    if key_path.exists() or properties_path.exists():
        raise ValueError("Refusing to overwrite existing release signing files")
    key = base64.b64decode(environment[names[0]], validate=True)
    if not key:
        raise ValueError("The signing keystore must not be empty")
    key_path.parent.mkdir(parents=True, exist_ok=True)
    key_path.write_bytes(key)
    key_path.chmod(0o600)
    values = {
        "storePassword": environment[names[1]],
        "keyPassword": environment[names[2]],
        "keyAlias": environment[names[3]],
        "storeFile": "upload-keystore.jks",
    }
    properties_path.write_text("".join(f"{k}={java_property(v)}\n" for k, v in values.items()), encoding="utf-8")
    properties_path.chmod(0o600)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("version", "signing"))
    args = parser.parse_args()
    if args.action == "signing":
        restore_signing(ROOT, dict(os.environ))
        print("Release signing files restored")
        return
    tag = release_tag((ROOT / "pubspec.yaml").read_text(encoding="utf-8"), os.environ.get("REQUESTED_TAG", ""))
    for variable, text in (("GITHUB_ENV", f"TAG_NAME={tag}\n"), ("GITHUB_OUTPUT", f"tag={tag}\n")):
        if os.environ.get(variable):
            with open(os.environ[variable], "a", encoding="utf-8") as output:
                output.write(text)
    print(f"Validated release candidate {tag}")


if __name__ == "__main__":
    main()
