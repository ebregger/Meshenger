import subprocess
import os
import re

APP_PACKAGE = "com.example.bluetooth_app"
APP_ACTIVITY = ".MainActivity"
BASE_PORT = 18081
# Flutter stable requires API 24+ (Android 7). Older tablets (e.g. Nexus 7 @ API 18)
# cannot install or run this APK — skip them instead of hanging on install.
MIN_SDK = 24


def run_cmd(cmd, check=True, shell=True, timeout=None):
    print(f"Running: {cmd}")
    return subprocess.run(
        cmd, check=check, shell=shell, text=True, capture_output=True, timeout=timeout
    )


def get_devices():
    result = run_cmd("adb devices", check=False)
    devices = []
    for line in result.stdout.strip().split("\n")[1:]:
        if "\tdevice" in line:
            devices.append(line.split("\t")[0])
    return devices


def device_sdk(serial):
    result = run_cmd(
        f"adb -s {serial} shell getprop ro.build.version.sdk",
        check=False,
        timeout=10,
    )
    text = (result.stdout or "").strip()
    m = re.search(r"\d+", text)
    return int(m.group(0)) if m else None


def device_model(serial: str) -> str:
    result = run_cmd(
        f"adb -s {serial} shell getprop ro.product.model",
        check=False,
        timeout=10,
    )
    return (result.stdout or "").strip() or serial


def clear_stale_forwards():
    """Drop previous 18081+ forwards so port map matches this deploy."""
    listed = run_cmd("adb forward --list", check=False)
    for line in (listed.stdout or "").splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[1].startswith("tcp:"):
            try:
                port = int(parts[1].split(":", 1)[1])
            except ValueError:
                continue
            if BASE_PORT <= port < BASE_PORT + 20:
                run_cmd(f"adb forward --remove tcp:{port}", check=False)


def deploy_and_launch():
    print("--- 1. Building APK ---")
    run_cmd("flutter build apk --debug", shell=True)
    apk_path = os.path.join(
        "build", "app", "outputs", "flutter-apk", "app-debug.apk"
    )

    devices = get_devices()
    if not devices:
        print("No devices found!")
        return

    print(f"--- 2. Found {len(devices)} adb device(s): {devices} ---")
    clear_stale_forwards()

    deployed = []
    skipped = []
    port_idx = 0

    for device in devices:
        model = device_model(device)
        sdk = device_sdk(device)
        print(f"\n--- 3. {device} ({model}, SDK {sdk}) ---")

        if sdk is None:
            print(f"SKIP: could not read SDK for {device}")
            skipped.append((device, model, "unknown SDK"))
            continue
        if sdk < MIN_SDK:
            print(
                f"SKIP: {model} is API {sdk}; Flutter app requires API {MIN_SDK}+. "
                f"Upgrade the OS (custom ROM) or use another phone."
            )
            skipped.append((device, model, f"API {sdk} < {MIN_SDK}"))
            continue

        try:
            run_cmd(f"adb -s {device} install -r {apk_path}", timeout=90)
        except subprocess.TimeoutExpired:
            print(f"FAILED: adb install timed out on {device}")
            skipped.append((device, model, "install timeout"))
            continue

        local_port = BASE_PORT + port_idx
        run_cmd(f"adb -s {device} forward tcp:{local_port} tcp:8080")
        run_cmd(f"adb -s {device} shell am force-stop {APP_PACKAGE}", check=False)
        run_cmd(f"adb -s {device} shell am start -n {APP_PACKAGE}/{APP_ACTIVITY}")
        print(f"Launched - API http://127.0.0.1:{local_port}")
        deployed.append((device, model, local_port))
        port_idx += 1

    print("\n--- DEPLOYMENT COMPLETE ---")
    if deployed:
        print("Ready nodes:")
        for serial, model, port in deployed:
            print(f"  {model} ({serial}) -> 127.0.0.1:{port}")
    if skipped:
        print("Skipped:")
        for serial, model, reason in skipped:
            print(f"  {model} ({serial}): {reason}")
    if len(deployed) < 2:
        print(
            "WARNING: need at least 2 API-capable devices for mesh stress tests."
        )


if __name__ == "__main__":
    deploy_and_launch()
