import subprocess
import time
import os

APP_PACKAGE = "com.example.bluetooth_app"
APP_ACTIVITY = ".MainActivity"
BASE_PORT = 18081

def run_cmd(cmd, check=True, shell=True):
    print(f"Running: {cmd}")
    return subprocess.run(cmd, check=check, shell=shell, text=True, capture_output=True)

def get_devices():
    result = run_cmd("adb devices", check=False)
    devices = []
    for line in result.stdout.strip().split("\n")[1:]:
        if "\tdevice" in line:
            devices.append(line.split("\t")[0])
    return devices

def deploy_and_launch():
    # 1. Compile the APK
    print("--- 1. Building APK ---")
    run_cmd("flutter build apk --debug", shell=True)
    apk_path = os.path.join("build", "app", "outputs", "flutter-apk", "app-debug.apk")
    
    devices = get_devices()
    if not devices:
        print("No devices found!")
        return

    print(f"--- 2. Found {len(devices)} Devices: {devices} ---")
    
    port_idx = 0
    for device in devices:
        print(f"\\n--- 3. Deploying to {device} ---")
        
        # Install APK (replace existing)
        run_cmd(f"adb -s {device} install -r {apk_path}")
        
        # Forward Port
        local_port = BASE_PORT + port_idx
        run_cmd(f"adb -s {device} forward tcp:{local_port} tcp:8080")
        print(f"Forwarded local port {local_port} to device port 8080")
        
        # Launch App
        run_cmd(f"adb -s {device} shell am start -n {APP_PACKAGE}/{APP_ACTIVITY}")
        print(f"Launched on {device}")
        
        port_idx += 1

    print("\\n--- DEPLOYMENT COMPLETE ---")
    print("API ports available:")
    for i in range(len(devices)):
        print(f"Device {i+1} ({devices[i]}) -> 127.0.0.1:{BASE_PORT + i}")

if __name__ == "__main__":
    deploy_and_launch()
