import sys, io, os
if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')

import urllib.request
import urllib.parse
import json
import time
import threading
import subprocess
import re
import argparse
import math
from concurrent.futures import ThreadPoolExecutor
from collections import Counter, defaultdict

from tools.stress_console import DetailLog, ProgressDisplay, poll_ui_status
from tools.stress_summary import print_run_summary
from tools.bluetooth_diagnostics import (
    LiveBtsnoopSocketCapture,
    capture_devices_bluetooth_diagnostics,
    inspect_bluetooth_snoop,
)

PORTS = [18081, 18082, 18083]
STRESS_API_REMOTE = "tcp:8080"
STRESS_API_LOCAL_PORTS = range(18081, 18100)


class Colors:
    HEADER = '\033[95m'
    OKBLUE = '\033[94m'
    OKCYAN = '\033[96m'
    OKGREEN = '\033[92m'
    WARNING = '\033[93m'
    FAIL = '\033[91m'
    ENDC = '\033[0m'
    BOLD = '\033[1m'


BENCHMARK_REGEX = re.compile(r'\[BENCHMARK\] (.*)')
DIAGNOSTIC_REGEX = re.compile(r'\[DIAGNOSTIC\] (.*)')
BLE_TRACE_REGEX = re.compile(r'\[BLE_TRACE\] (.*)')
ANDROID_LOG_REGEX = re.compile(
    r'^\S+\s+\S+\s+\d+\s+\d+\s+([VDIWEFA])\s+([^:]+):\s?(.*)$'
)
ANDROID_BLUETOOTH_LOG_TAGS = {
    "BluetoothGatt",
    "BluetoothGattServer",
    "BluetoothManagerService",
    "AdapterService",
    "BtGatt.GattService",
    "GattService",
    "bt_stack",
    "bt_gatt",
}


class Telemetry:
    def __init__(self):
        self.lock = threading.Lock()
        self.created = {}  # msg_id -> { device, t }
        self.scan_hit = []  # { device, mac, t }
        self.offer_sent = []  # { device, mac, t }
        self.gatt_connected = []  # { device, mac, t }
        self.delta_received = []  # { device, mac, bytes, t }
        self.merged = defaultdict(dict)  # msg_id -> { device: t }
        self.displayed = defaultdict(dict)  # msg_id -> { device: t }
        self.ui_changed = []  # { device, revision, count, t }
        self.connection_failed = []  # { device, mac, reason }
        self.connection_rejected = []  # { device, mac, reason }
        self.penalty_box = []  # { device, mac, duration }
        self.app_state_changes = []  # { device, state, t }
        self.ble_trace_events = []  # device-local monotonic BLE stage events
        self.android_bluetooth_logs = []  # framework/stack logs filtered by tag


telemetry = Telemetry()


def add_transfer_metrics(status):
    with telemetry.lock:
        status["transferred_bytes"] = sum(
            event["bytes"] for event in telemetry.delta_received
        )
    return status


def capture_peer_signal_snapshot(
    requester, ports, port_to_device, selected_node_ids, started_at
):
    """Capture each selected phone's local RSSI reading for every known peer."""
    peers_by_device = {}
    for port in ports:
        result = requester(port, "/peers")
        if not isinstance(result, dict):
            continue
        device = port_to_device.get(port, str(port))
        peers_by_device[device] = [
            {
                "id": peer.get("id"),
                "name": peer.get("name"),
                "status": peer.get("status"),
                "rssi_dbm": peer.get("rssiDbm"),
                "rssi_seen_ms": peer.get("rssiSeenMs"),
            }
            for peer in result.get("peers", [])
            if isinstance(peer, dict) and peer.get("id") in selected_node_ids
        ]
    return {
        "elapsed_s": time.monotonic() - started_at,
        "peers_by_device": peers_by_device,
    }


def request(port, path, method='GET', body=None, timeout=30, error_report=None):
    url = f'http://127.0.0.1:{port}{path}'
    try:
        req = urllib.request.Request(url, method=method)
        if body is not None:
            req.add_header('Content-Type', 'application/json')
            data = json.dumps(body).encode('utf-8')
            with urllib.request.urlopen(req, data=data, timeout=timeout) as response:
                return json.loads(response.read().decode())
        else:
            with urllib.request.urlopen(req, timeout=timeout) as response:
                return json.loads(response.read().decode())
    except Exception as error:
        if error_report is not None:
            error_report["error"] = f"{type(error).__name__}: {error}"
        return None


def get_adb_device_inventory():
    result = subprocess.run(
        ["adb", "devices"], capture_output=True, text=True, timeout=10
    )
    if result.returncode != 0:
        error = result.stderr.strip() or result.stdout.strip() or "unknown adb error"
        raise RuntimeError(f"`adb devices` failed: {error}")
    devices = []
    for line in result.stdout.splitlines():
        if line.lstrip().startswith("*") or line.startswith("List of devices attached"):
            continue
        parts = line.split()
        if len(parts) >= 2:
            devices.append({"serial": parts[0].strip(), "state": parts[1].strip()})
    return devices


def get_adb_devices():
    return [
        device["serial"]
        for device in get_adb_device_inventory()
        if device["state"] == "device"
    ]


def get_adb_device_metadata(serials):
    """Collect model and Android version for the run record."""
    properties = {
        "model": "ro.product.model",
        "manufacturer": "ro.product.manufacturer",
        "android_sdk": "ro.build.version.sdk",
        "android_release": "ro.build.version.release",
    }
    devices = []
    for serial in serials:
        metadata = {"serial": serial}
        for name, prop in properties.items():
            try:
                result = subprocess.run(
                    ["adb", "-s", serial, "shell", "getprop", prop],
                    capture_output=True,
                    text=True,
                    timeout=5,
                    check=False,
                )
                value = result.stdout.strip()
                if result.returncode == 0 and value:
                    metadata[name] = value
            except (OSError, subprocess.TimeoutExpired):
                continue
        devices.append(metadata)
    return devices


def _adb_runtime_state_for_device(serial):
    """Capture lock, display, wakefulness, and adapter state in one ADB call."""
    state = {
        "serial": serial,
        "wakefulness": None,
        "display_power_state": None,
        "device_locked": None,
        "keyguard_showing": None,
        "keyguard_state": "unknown",
        "device_idle_mode": None,
        "focused_window": None,
        "focused_app": None,
        "keyguard_indicators": [],
        "screen_off_timeout_ms": None,
        "bluetooth_enabled": None,
    }
    script = (
        "echo __POWER__; "
        "dumpsys power | grep -E 'mWakefulness=|Display Power: state=|mDeviceIdleMode='; "
        "echo __WINDOW__; "
        "dumpsys window | grep -E 'mCurrentFocus=|mFocusedApp=|mKeyguardShowing=|mShowingLockscreen=|isStatusBarKeyguard=|mKeyguardOccluded='; "
        "echo __TRUST__; "
        "dumpsys trust | grep -E 'deviceLocked='; "
        "echo __SCREEN_TIMEOUT__; settings get system screen_off_timeout; "
        "echo __BLUETOOTH_SETTING__; settings get global bluetooth_on"
    )
    try:
        result = subprocess.run(
            ["adb", "-s", serial, "shell", script],
            capture_output=True,
            text=True,
            timeout=12,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return state

    section = None
    sections = defaultdict(list)
    marker_map = {
        "__POWER__": "power",
        "__WINDOW__": "window",
        "__TRUST__": "trust",
        "__SCREEN_TIMEOUT__": "screen_timeout",
        "__BLUETOOTH_SETTING__": "bluetooth_setting",
    }
    for line in result.stdout.splitlines():
        stripped = line.strip()
        if stripped in marker_map:
            section = marker_map[stripped]
        elif section:
            sections[section].append(stripped)

    power_output = "\n".join(sections["power"])
    wakefulness = re.search(r"\bmWakefulness=(\w+)", power_output)
    display_state = re.search(r"\bDisplay Power: state=(\w+)", power_output)
    idle_state = re.search(r"\bmDeviceIdleMode=(true|false)", power_output, re.I)
    if wakefulness:
        state["wakefulness"] = wakefulness.group(1)
    if display_state:
        state["display_power_state"] = display_state.group(1)
    if idle_state:
        state["device_idle_mode"] = idle_state.group(1).lower() == "true"

    window_output = "\n".join(sections["window"])
    for key, pattern in (
        ("focused_window", r"\bmCurrentFocus=(.*)"),
        ("focused_app", r"\bmFocusedApp=(.*)"),
    ):
        match = re.search(pattern, window_output)
        if match:
            state[key] = match.group(1).strip()
    state["keyguard_indicators"] = sections["window"][:8]
    keyguard = re.search(
        r"(?:isStatusBarKeyguard|mKeyguardShowing|mShowingLockscreen)=(true|false)",
        window_output,
        re.IGNORECASE,
    )
    if keyguard:
        state["keyguard_showing"] = keyguard.group(1).lower() == "true"

    device_locked = re.search(r"\bdeviceLocked=(0|1|true|false)\b", "\n".join(sections["trust"]), re.I)
    if device_locked:
        state["device_locked"] = device_locked.group(1).lower() in ("1", "true")
    if state["device_locked"] is not None:
        state["keyguard_state"] = "locked" if state["device_locked"] else "unlocked"
    elif state["keyguard_showing"] is not None:
        state["keyguard_state"] = (
            "showing" if state["keyguard_showing"] else "not_showing"
        )
    elif state["focused_window"] and any(
        name in state["focused_window"]
        for name in ("StatusBar", "Keyguard", "NotificationShade")
    ):
        state["keyguard_state"] = "system_ui_in_focus"

    timeout_value = next(iter(sections["screen_timeout"]), "")
    if timeout_value.isdigit():
        state["screen_off_timeout_ms"] = int(timeout_value)
    bluetooth_value = next(iter(sections["bluetooth_setting"]), "")
    if bluetooth_value in ("0", "1"):
        state["bluetooth_enabled"] = bluetooth_value == "1"
    return state


def get_adb_device_runtime_state(serials):
    """Capture runtime state concurrently so multi-phone samples are close in time."""
    if not serials:
        return []
    with ThreadPoolExecutor(max_workers=len(serials)) as executor:
        return list(executor.map(_adb_runtime_state_for_device, serials))


def capture_runtime_state_snapshot(serials):
    started = time.monotonic()
    devices = get_adb_device_runtime_state(serials)
    observed = time.monotonic()
    return {
        "started_at_host_monotonic_s": started,
        "observed_at_host_monotonic_s": observed,
        "capture_duration_s": observed - started,
        "devices": devices,
    }


def runtime_state_sampler(serials, stop_event, samples, lock, benchmark_started_at):
    """Sample lock/display state every five seconds during a benchmark."""
    interval_s = 5.0
    while not stop_event.wait(interval_s):
        snapshot = capture_runtime_state_snapshot(serials)
        sample = {
            "elapsed_s": snapshot["observed_at_host_monotonic_s"] - benchmark_started_at,
            **snapshot,
        }
        with lock:
            samples.append(sample)
        print(f"[RUNTIME_STATE] {json.dumps(sample, sort_keys=True)}")


def get_adb_forward_records():
    """Return adb forwards with their serial, local port, and remote endpoint."""
    result = subprocess.run(
        ["adb", "forward", "--list"], capture_output=True, text=True, timeout=10
    )
    if result.returncode != 0:
        error = result.stderr.strip() or result.stdout.strip() or "unknown adb error"
        raise RuntimeError(f"`adb forward --list` failed: {error}")

    records = []
    for line in result.stdout.splitlines():
        parts = line.split()
        # e.g. "46071FDAS009EH tcp:18081 tcp:8080"
        if len(parts) < 3 or not parts[1].startswith("tcp:"):
            continue
        try:
            local_port = int(parts[1].split(":", 1)[1])
        except ValueError:
            continue
        records.append(
            {"serial": parts[0], "port": local_port, "remote": parts[2]}
        )
    return records


def get_port_to_device():
    """Map host forward ports → serial via `adb forward --list` (not adb device order)."""
    return {record["port"]: record["serial"] for record in get_adb_forward_records()}


def ensure_stress_api_forwards(serials):
    """Ensure each selected ADB device has one local forward to its stress API."""
    records = get_adb_forward_records()
    occupied_ports = {record["port"] for record in records}
    assignments = {}
    errors = []

    for serial in serials:
        existing = next(
            (
                record
                for record in records
                if record["serial"] == serial
                and record["remote"] == STRESS_API_REMOTE
            ),
            None,
        )
        if existing:
            assignments[serial] = existing["port"]
            continue

        assigned_port = None
        last_error = ""
        for port in STRESS_API_LOCAL_PORTS:
            if port in occupied_ports:
                continue
            try:
                result = subprocess.run(
                    [
                        "adb", "-s", serial, "forward", "--no-rebind",
                        f"tcp:{port}", STRESS_API_REMOTE,
                    ],
                    capture_output=True,
                    text=True,
                    timeout=10,
                )
            except (OSError, subprocess.TimeoutExpired) as error:
                last_error = str(error)
                break

            if result.returncode == 0:
                assigned_port = port
                occupied_ports.add(port)
                records.append(
                    {"serial": serial, "port": port, "remote": STRESS_API_REMOTE}
                )
                print(
                    f"  ADB forward created: {serial} 127.0.0.1:{port} "
                    f"→ {STRESS_API_REMOTE}"
                )
                break

            last_error = (
                result.stderr.strip() or result.stdout.strip() or "unknown adb error"
            )
            if not any(
                marker in last_error.lower()
                for marker in ("cannot bind", "address already in use", "already in use")
            ):
                break

        if assigned_port is None:
            errors.append(
                f"{serial}: could not forward the stress API "
                f"({last_error or 'no free local ports in 18081-18099'})"
            )
        else:
            assignments[serial] = assigned_port

    return assignments, errors


def discover_ports():
    """Create missing ADB forwards and return one stress port per online device."""
    serials = get_adb_devices()
    assignments, errors = ensure_stress_api_forwards(serials)
    for error in errors:
        print(f"  ADB forward error: {error}")
    return sorted(assignments.values())


def check_devices(
    ports=None,
    api_errors=None,
    ble_reset_responses=None,
    ble_preflight=None,
):
    infos = {}
    api_errors = api_errors if api_errors is not None else {}
    ble_reset_responses = (
        ble_reset_responses if ble_reset_responses is not None else {}
    )
    ble_preflight = ble_preflight if ble_preflight is not None else {}
    ports = ports or discover_ports()
    print(f"{Colors.OKCYAN}Checking device APIs on ports {ports}...{Colors.ENDC}")
    for p in ports:
        error_report = {}
        res = request(p, '/info', timeout=5, error_report=error_report)
        if res and 'nodeId' in res:
            infos[p] = res['nodeId']
            print(f"  Device at port {p}: OK  nodeId={res['nodeId']}")
        else:
            error = error_report.get("error", "invalid /info response")
            api_errors[p] = error
            print(f"  Device at port {p}: UNREACHABLE ({error})")

    ready_ports = sorted(infos)
    if not ready_ports:
        ble_preflight.update({"ready": False, "error": "no stress APIs responded"})
        return infos

    def post_all(path, timeout=10):
        def post_one(port):
            error_report = {}
            response = request(
                port,
                path,
                method="POST",
                body={},
                timeout=timeout,
                error_report=error_report,
            )
            return {
                "response": response,
                "error": error_report.get("error"),
            }

        with ThreadPoolExecutor(max_workers=len(ready_ports)) as executor:
            return dict(zip(ready_ports, executor.map(post_one, ready_ports)))

    def status_of(outcome):
        return ((outcome or {}).get("response") or {}).get("status")

    print(f"{Colors.OKCYAN}Pausing scans on all selected phones before GATT reset...{Colors.ENDC}")
    pause_results = post_all("/pause_scan")
    scans_paused = all(status_of(pause_results.get(port)) == "scan_paused" for port in ready_ports)
    for port in ready_ports:
        outcome = pause_results.get(port, {})
        if status_of(outcome) == "scan_paused":
            print(f"  Device at port {port}: scan paused")
        else:
            print(
                f"  Device at port {port}: scan pause failed "
                f"({outcome.get('error') or outcome.get('response') or 'empty response'})"
            )

    reset_results = {}
    if scans_paused:
        print(f"{Colors.OKCYAN}Resetting GATT servers while scans are paused...{Colors.ENDC}")
        reset_results = post_all("/reset_ble", timeout=20)
        for port in ready_ports:
            outcome = reset_results.get(port, {})
            response = outcome.get("response")
            ble_reset_responses[port] = outcome
            if status_of(outcome) == "ble_reset":
                print(f"  Device at port {port}: GATT service ready")
            else:
                print(
                    f"  Device at port {port}: GATT reset failed "
                    f"({outcome.get('error') or response or 'empty response'})"
                )
    else:
        for port in ready_ports:
            ble_reset_responses[port] = {
                "response": None,
                "error": "skipped because not all peer scans could be paused",
            }

    # Always resume every reachable selected scanner, including a partial-pause
    # failure, so the preflight cannot leave the app's mesh discovery disabled.
    print(f"{Colors.OKCYAN}Resuming scans after GATT reset...{Colors.ENDC}")
    resume_results = post_all("/resume_scan", timeout=15)
    scans_resumed = all(status_of(resume_results.get(port)) == "scan_resumed" for port in ready_ports)
    for port in ready_ports:
        outcome = resume_results.get(port, {})
        if status_of(outcome) == "scan_resumed":
            print(f"  Device at port {port}: scan resumed")
        else:
            print(
                f"  Device at port {port}: scan resume failed "
                f"({outcome.get('error') or outcome.get('response') or 'empty response'})"
            )

    resets_succeeded = scans_paused and all(status_of(reset_results.get(port)) == "ble_reset" for port in ready_ports)
    ble_preflight.update(
        {
            "scan_pause": {str(p): pause_results.get(p) for p in ready_ports},
            "gatt_reset": {str(p): reset_results.get(p) for p in ready_ports},
            "scan_resume": {str(p): resume_results.get(p) for p in ready_ports},
            "ready": scans_paused and resets_succeeded and scans_resumed,
        }
    )
    return infos


def resolve_profile_settings(profile, send_interval_s=None, poll_interval_s=None):
    """Resolve profile defaults and reject timings that cannot be measured."""
    if profile not in {"interactive", "burst"}:
        raise ValueError("profile must be 'interactive' or 'burst'")
    if send_interval_s is None:
        send_interval_s = 0.0 if profile == "interactive" else 0.3
    if poll_interval_s is None:
        poll_interval_s = 0.1 if profile == "interactive" else 2.0
    if not math.isfinite(send_interval_s) or send_interval_s < 0:
        raise ValueError("send interval must be finite and nonnegative")
    if not math.isfinite(poll_interval_s) or poll_interval_s <= 0:
        raise ValueError("poll interval must be finite and positive")
    return send_interval_s, poll_interval_s


def parse_ports_arg(value):
    """Parse comma-separated forwarded API ports; leave discovery to the default."""
    if not value:
        return None
    try:
        ports = [int(part.strip()) for part in value.split(",") if part.strip()]
    except ValueError as error:
        raise ValueError("ports must be comma-separated integers") from error
    if len(ports) < 2 or len(ports) != len(set(ports)):
        raise ValueError("choose at least two unique ports")
    if any(port <= 0 or port > 65535 for port in ports):
        raise ValueError("ports must be between 1 and 65535")
    return ports


def parse_devices_arg(value):
    """Parse comma-separated ADB serials for a deliberate device subset."""
    if not value:
        return None
    devices = [part.strip() for part in value.split(",")]
    if any(not device for device in devices):
        raise ValueError("devices must be comma-separated ADB serials")
    if len(devices) < 2 or len(devices) != len(set(devices)):
        raise ValueError("choose at least two unique ADB serials")
    return devices

def logcat_worker(device_id, stop_event):
    cmd = [
        "adb", "-s", device_id, "logcat", "-v", "threadtime", "-s",
        "flutter:D", "NativeMeshService:D", "BluetoothGatt:D",
        "BluetoothGattServer:D", "BluetoothManagerService:I", "AdapterService:I",
        "BtGatt.GattService:D", "GattService:D", "bt_stack:I", "bt_gatt:I",
    ]
    subprocess.run(["adb", "-s", device_id, "logcat", "-c"])
    process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8", errors="replace")
    
    while not stop_event.is_set():
        line = process.stdout.readline()
        if not line:
            if process.poll() is not None:
                break
            time.sleep(0.1)
            continue

        trace_match = BLE_TRACE_REGEX.search(line)
        if trace_match:
            print(f"[{device_id}] [BLE_TRACE] {trace_match.group(1).strip()}")
            data = {}
            for part in trace_match.group(1).strip().split('|'):
                if ':' not in part:
                    continue
                key, value = part.split(':', 1)
                data[key.strip().lower()] = value.strip()
            try:
                mono_ms = int(data.get('mono_ms', ''))
            except (TypeError, ValueError):
                mono_ms = None
            try:
                rssi = int(data['rssi']) if 'rssi' in data else None
            except (TypeError, ValueError):
                rssi = None
            with telemetry.lock:
                telemetry.ble_trace_events.append({
                    'device': device_id,
                    'event': data.get('event', 'unknown'),
                    'target_mac': data.get('target_mac', ''),
                    'attempt_id': data.get('attempt_id', ''),
                    'connection_id': data.get('connection_id', ''),
                    'mono_ms': mono_ms,
                    'host_observed_at': time.monotonic(),
                    'rssi': rssi,
                    'fields': data,
                })
            continue

        android_log_match = ANDROID_LOG_REGEX.match(line.strip())
        if android_log_match:
            priority, tag, message = android_log_match.groups()
            tag = tag.strip()
            if tag in ANDROID_BLUETOOTH_LOG_TAGS:
                event = {
                    "device": device_id,
                    "host_observed_at": time.monotonic(),
                    "priority": priority,
                    "tag": tag,
                    "message": message.strip(),
                }
                with telemetry.lock:
                    telemetry.android_bluetooth_logs.append(event)
                if priority in {"W", "E", "F", "A"} or re.search(
                    r"mtu|gatt.*(?:connect|disconnect|fail|error|timeout)",
                    event["message"],
                    re.IGNORECASE,
                ):
                    print(
                        f"[{device_id}] [ANDROID_BT] {tag}/{priority}: "
                        f"{event['message']}"
                    )
                continue

        diag_match = DIAGNOSTIC_REGEX.search(line)
        if diag_match:
            payload = diag_match.group(1).strip()
            if "COLLISION" in payload or "CONNECTION_REJECTED" in payload:
                print(f"\n[{device_id}] DIAGNOSTIC: {payload}")
            parts = [p.strip() for p in payload.split('|')]
            data = {}
            for part in parts:
                if ':' in part:
                    k, v = part.split(':', 1)
                    data[k.strip()] = v.strip()
                elif '=' in part:
                    k, v = part.split('=', 1)
                    data[k.strip()] = v.strip()
                
            event = data.get('EVENT')
            t = int(time.time()*1000)
            
            app_state = data.get('APP_STATE')
            if app_state:
                with telemetry.lock:
                    telemetry.app_state_changes.append({'device': device_id, 'state': app_state, 't': t})
                continue
                
            mac = data.get('TARGET_MAC', '')
            if event == 'CONNECTION_FAILED' and mac:
                with telemetry.lock:
                    telemetry.connection_failed.append({'device': device_id, 'mac': mac, 'reason': data.get('REASON', '')})
            elif event == 'CONNECTION_REJECTED' and mac:
                with telemetry.lock:
                    telemetry.connection_rejected.append({'device': device_id, 'mac': mac, 'reason': data.get('REASON', '')})
            elif event == 'PENALTY_BOX_ENTERED' and mac:
                with telemetry.lock:
                    telemetry.penalty_box.append({'device': device_id, 'mac': mac, 'duration': data.get('DURATION', '')})
            continue

        match = BENCHMARK_REGEX.search(line)
        if match:
            payload = match.group(1).strip()
            parts = [p.strip() for p in payload.split('|')]
            data = {}
            for part in parts:
                if ':' in part:
                    k, v = part.split(':', 1)
                    data[k.strip()] = v.strip()
                elif '=' in part:
                    k, v = part.split('=', 1)
                    data[k.strip()] = v.strip()
                
            event = data.get('EVENT')
            t = int(data.get('TIMESTAMP', 0))
            mac = data.get('TARGET_MAC', '')
            msg_id = data.get('MSG_ID', '')
            
            with telemetry.lock:
                if event == 'CREATED' and msg_id:
                    telemetry.created[msg_id] = {'device': device_id, 't': t}
                elif event == 'SCAN_HIT' and mac:
                    telemetry.scan_hit.append({'device': device_id, 'mac': mac, 't': t})
                elif event == 'OFFER_SENT' and mac:
                    telemetry.offer_sent.append({'device': device_id, 'mac': mac, 't': t})
                elif event == 'GATT_CONNECTED' and mac:
                    telemetry.gatt_connected.append({'device': device_id, 'mac': mac, 't': t})
                elif event == 'DELTA_RECEIVED' and mac:
                    telemetry.delta_received.append({'device': device_id, 'mac': mac, 'bytes': int(data.get('BYTES', 0)), 't': t})
                elif event == 'MERGED' and msg_id:
                    telemetry.merged[msg_id][device_id] = t
                elif event == 'DISPLAYED' and msg_id:
                    # Only record the *first* time it was displayed on this device
                    if device_id not in telemetry.displayed[msg_id]:
                        telemetry.displayed[msg_id][device_id] = t
                elif event == 'UI_CHANGED':
                    rev = int(data.get('REVISION', 0) or 0)
                    count = int(data.get('COUNT', 0) or 0)
                    telemetry.ui_changed.append({
                        'device': device_id, 'revision': rev, 'count': count, 't': t
                    })
                    print(f"\n[{device_id}] UI changed → revision={rev} count={count}")
                    
    process.terminate()

def clear_chat_messages(ports):
    """Clear chat rows on each live API; keep display names / users table."""
    print(f"{Colors.OKCYAN}Clearing messages on ports {ports} (keeping display names)...{Colors.ENDC}")
    for p in ports:
        res = request(p, "/clear_messages", "POST")
        if res and res.get("status") == "cleared":
            print(
                f"  port {p}: cleared {res.get('messagesRemoved', '?')} message(s)"
            )
        else:
            print(f"{Colors.WARNING}  port {p}: clear_messages failed{Colors.ENDC}")
    # Brief settle so hash/ADV updates land before the burst.
    time.sleep(1)


def maybe_clear_chat_messages(ports, preserve_messages=False):
    """Prepare a benchmark without deleting existing chats when requested."""
    if preserve_messages:
        print(f"{Colors.OKCYAN}Preserving existing chat messages.{Colors.ENDC}")
        return
    clear_chat_messages(ports)


def wipe_mesh_dbs(serials):
    """Full DB delete (messages + profiles). Prefer [clear_chat_messages] for stress."""
    pkg = "com.example.bluetooth_app"
    for serial in serials:
        subprocess.run(
            ["adb", "-s", serial, "shell", "am", "force-stop", pkg],
            capture_output=True,
        )
        subprocess.run(
            [
                "adb", "-s", serial, "shell", "run-as", pkg, "rm", "-f",
                "app_flutter/mesh_network.db",
                "app_flutter/mesh_network.db-wal",
                "app_flutter/mesh_network.db-shm",
            ],
            capture_output=True,
        )
        subprocess.run(
            [
                "adb", "-s", serial, "shell", "am", "start",
                "-n", "%s/.MainActivity" % pkg,
            ],
            capture_output=True,
        )
    deadline = time.time() + 25
    while time.time() < deadline:
        ok = 0
        for port in PORTS:
            info = request(port, "/info")
            if info and info.get("nodeId"):
                ok += 1
        if ok >= 2:
            time.sleep(8)
            return
        time.sleep(1)
    print(f"{Colors.WARNING}DB wipe: APIs not ready after restart{Colors.ENDC}")


def run_benchmark(
    num_messages=30,
    console=None,
    sender_port=None,
    sender_device=None,
    single_sender=False,
    preserve_messages=False,
    ports=None,
    profile="burst",
    send_interval_s=None,
    poll_interval_s=None,
    message_timeout_s=90.0,
    devices=None,
    hci_diagnostic=False,
    diagnostics_dir=None,
):
    send_interval_s, poll_interval_s = resolve_profile_settings(
        profile, send_interval_s, poll_interval_s
    )
    if num_messages <= 0:
        raise ValueError("message count must be positive")
    if not math.isfinite(message_timeout_s) or message_timeout_s <= 0:
        raise ValueError("message timeout must be finite and positive")

    console = console or ProgressDisplay()
    console.message("Preparing devices…")
    requested_ports = list(ports) if ports is not None else None
    requested_devices = list(devices) if devices is not None else None
    if requested_ports is not None and requested_devices is not None:
        raise ValueError("select devices with either --ports or --devices, not both")
    try:
        adb_inventory = get_adb_device_inventory()
        adb_devices = [
            device["serial"]
            for device in adb_inventory
            if device["state"] == "device"
        ]
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"{Colors.FAIL}Preflight failed: could not query ADB: {error}{Colors.ENDC}")
        return False

    offline_devices = [
        device for device in adb_inventory if device["state"] != "device"
    ]
    print("\nPreflight: ADB device inventory")
    if adb_inventory:
        for device in adb_inventory:
            print(f"  {device['serial']}: {device['state']}")
    else:
        print("  No ADB devices listed")

    if len(adb_devices) < 2:
        print(
            f"{Colors.FAIL}Preflight failed: need at least 2 online ADB devices; "
            f"found {len(adb_devices)}.{Colors.ENDC}"
        )
        return False

    forward_errors = []
    if requested_devices is not None:
        unavailable = sorted(set(requested_devices) - set(adb_devices))
        if unavailable:
            print(
                f"{Colors.FAIL}Preflight failed: selected ADB device(s) are not "
                f"online: {unavailable}{Colors.ENDC}"
            )
            return False
        try:
            device_to_port, forward_errors = ensure_stress_api_forwards(requested_devices)
        except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
            print(
                f"{Colors.FAIL}Preflight failed: could not inspect/create ADB "
                f"forwards: {error}{Colors.ENDC}"
            )
            return False
        ports = sorted(device_to_port.values())
        forward_map = {port: serial for serial, port in device_to_port.items()}
        print("Preflight: selected-device stress API forwarding")
        for serial in requested_devices:
            port = device_to_port.get(serial)
            if port is None:
                print(f"  {serial}: no local forward")
            else:
                print(f"  {serial}: 127.0.0.1:{port} → {STRESS_API_REMOTE}")
        for error in forward_errors:
            print(f"  Forward error: {error}")
    elif requested_ports is None:
        try:
            device_to_port, forward_errors = ensure_stress_api_forwards(adb_devices)
        except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
            print(
                f"{Colors.FAIL}Preflight failed: could not inspect/create ADB "
                f"forwards: {error}{Colors.ENDC}"
            )
            return False
        ports = sorted(device_to_port.values())
        forward_map = {port: serial for serial, port in device_to_port.items()}
        print("Preflight: stress API forwarding")
        for serial in adb_devices:
            port = device_to_port.get(serial)
            if port is None:
                print(f"  {serial}: no local forward")
            else:
                print(f"  {serial}: 127.0.0.1:{port} → {STRESS_API_REMOTE}")
        for error in forward_errors:
            print(f"  Forward error: {error}")
        if offline_devices:
            print(
                f"{Colors.FAIL}Preflight failed: {len(offline_devices)} ADB "
                f"device(s) are offline or unauthorized; reconnect them or pass "
                f"--ports to select a deliberate subset.{Colors.ENDC}"
            )
            return False
    else:
        try:
            forward_map = get_port_to_device()
        except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
            print(
                f"{Colors.FAIL}Preflight failed: could not inspect ADB forwards: "
                f"{error}{Colors.ENDC}"
            )
            return False
        print("Preflight: requested stress API ports")
        for port in ports:
            serial = forward_map.get(port)
            print(f"  127.0.0.1:{port}: {serial or 'not mapped to an ADB device'}")

    if len(ports) < 2:
        print(
            f"{Colors.FAIL}Preflight failed: only {len(ports)} stress API "
            f"forward(s) are available; need at least 2.{Colors.ENDC}"
        )
        return False

    selected_serials_for_run = [
        forward_map[port] for port in ports if port in forward_map
    ]
    if sender_device is not None and sender_device not in selected_serials_for_run:
        print(
            f"{Colors.FAIL}Preflight failed: sender device {sender_device} is "
            f"not selected for this run.{Colors.ENDC}"
        )
        return False
    if sender_port is not None and sender_port not in ports:
        print(
            f"{Colors.FAIL}Preflight failed: sender port {sender_port} is "
            "not selected for this run."
        )
        return False
    if sender_device is not None and sender_port is not None:
        mapped_sender_port = next(
            (port for port, serial in forward_map.items() if serial == sender_device),
            None,
        )
        if sender_port != mapped_sender_port:
            print(
                f"{Colors.FAIL}Preflight failed: sender device and sender port "
                "select different phones."
            )
            return False

    hci_snoop_state = []
    if hci_diagnostic:
        selected_snoop_serials = selected_serials_for_run
        print("Preflight: full Bluetooth HCI snoop logging")
        for serial in selected_snoop_serials:
            state = inspect_bluetooth_snoop(serial)
            hci_snoop_state.append(state)
            print(
                f"  {serial}: enabled={state['full_hci_snoop_enabled']} "
                f"root={state['root_access']} "
                f"mode={state['hci_snoop_mode_at_enable']} "
                f"setting={state['setting_line'] or state['setting_error']}"
            )
        disabled = [
            state for state in hci_snoop_state
            if state["full_hci_snoop_enabled"] is not True
            and not (
                state["full_hci_snoop_enabled"] is None
                and state.get("hci_snoop_socket_available") is True
            )
        ]
        if len(selected_snoop_serials) != len(ports) or disabled:
            print(
                f"{Colors.FAIL}Preflight failed: full HCI snoop logging or a "
                f"verified live HCI socket is required on every selected phone.{Colors.ENDC}"
            )
            for state in disabled:
                status = state["full_hci_snoop_enabled"]
                reason = "disabled" if status is False else "status unknown"
                print(
                    f"  {state['serial']}: {reason}. Enable Developer options → "
                    "Bluetooth HCI snoop log in Full mode, then restart "
                    "Bluetooth (or reboot) and rerun."
                )
            for state in hci_snoop_state:
                if (
                    state["full_hci_snoop_enabled"] is None
                    and state.get("hci_snoop_socket_available") is True
                ):
                    print(
                        f"  {state['serial']}: snoop mode is not exposed by Android, "
                        "but the live socket returned a valid btsnoop header. "
                        "The selected mode remains unverified."
                    )
            if len(selected_snoop_serials) != len(ports):
                print("  One or more selected ports are not mapped to an ADB serial.")
            print(
                "[BLUETOOTH_PREFLIGHT] "
                + json.dumps({"ready": False, "devices": hci_snoop_state}, sort_keys=True)
            )
            return False

    api_errors = {}
    ble_reset_responses = {}
    ble_preflight = {}
    infos = check_devices(
        ports,
        api_errors=api_errors,
        ble_reset_responses=ble_reset_responses,
        ble_preflight=ble_preflight,
    )
    failed_ports = [port for port in ports if port not in infos]
    unmapped_ports = [port for port in ports if port not in forward_map]
    duplicate_nodes = len(set(infos.values())) != len(infos)
    if requested_devices is not None:
        selected_serials = requested_devices
        unselected_devices = [
            serial for serial in adb_devices if serial not in selected_serials
        ]
        missing_devices = []
    elif requested_ports is None:
        missing_devices = [
            serial
            for serial in adb_devices
            if serial not in device_to_port
            or device_to_port[serial] not in infos
        ]
        unselected_devices = []
    else:
        selected_serials = [forward_map[port] for port in ports if port in forward_map]
        unselected_devices = [
            serial for serial in adb_devices if serial not in selected_serials
        ]
        missing_devices = []

    preflight_ready = (
        len(infos) == len(ports)
        and len(infos) >= 2
        and not unmapped_ports
        and not duplicate_nodes
        and not missing_devices
        and not forward_errors
        and ble_preflight.get("ready") is True
    )
    preflight_record = {
        "adb_inventory": adb_inventory,
        "adb_online_serials": adb_devices,
        "adb_offline_devices": offline_devices,
        "unselected_adb_devices": unselected_devices,
        "requested_ports": requested_ports,
        "requested_devices": requested_devices,
        "selected_ports": list(ports),
        "port_to_serial": {str(port): forward_map.get(port) for port in ports},
        "api_node_ids": {str(port): node_id for port, node_id in infos.items()},
        "api_errors": {str(port): error for port, error in api_errors.items()},
        "ble_reset_responses": {
            str(port): response for port, response in ble_reset_responses.items()
        },
        "ble_preflight": ble_preflight,
        "bluetooth_hci_snoop": hci_snoop_state,
        "forward_errors": forward_errors,
        "failed_ports": failed_ports,
        "unmapped_ports": unmapped_ports,
        "ready": preflight_ready,
    }
    print(f"[PREFLIGHT] {json.dumps(preflight_record, sort_keys=True)}")
    if not preflight_ready:
        print(f"{Colors.FAIL}Preflight failed; benchmark was not started.{Colors.ENDC}")
        if failed_ports:
            print(f"  Stress API unreachable on ports: {failed_ports}")
        if unmapped_ports:
            print(f"  Ports not tied to an ADB serial: {unmapped_ports}")
        if missing_devices:
            print(f"  Devices/ports missing from this run: {missing_devices}")
        if duplicate_nodes:
            print("  Multiple selected ports report the same node ID")
        if ble_preflight.get("ready") is not True:
            print("  Coordinated BLE reset did not finish cleanly; see ble_preflight in the diagnostic report.")
        return False

    forward_map = {int(port): serial for port, serial in preflight_record["port_to_serial"].items()}
    # Only stream logcat for devices whose stress API is reachable.
    active_devices = []
    for port in sorted(infos.keys()):
        serial = forward_map.get(port)
        if serial and serial not in active_devices:
            active_devices.append(serial)
    if len(active_devices) != len(infos):
        print(
            f"{Colors.FAIL}Preflight failed: could not map all responsive "
            f"stress APIs to ADB devices.{Colors.ENDC}"
        )
        return False
    device_metadata = get_adb_device_metadata(active_devices)
    device_runtime_state_start = capture_runtime_state_snapshot(active_devices)

    print("\nDevice screen/lock state at test start:")
    for state in device_runtime_state_start["devices"]:
        print(
            f"  {state['serial']}: wakefulness={state['wakefulness'] or 'unknown'} "
            f"display={state['display_power_state'] or 'unknown'} "
            f"locked={state['device_locked']} "
            f"keyguard={state['keyguard_state']} "
            f"focus={state['focused_window'] or 'unknown'}"
        )

    print(f"\n{Colors.OKCYAN}Starting adb logcat streams for devices: {active_devices}{Colors.ENDC}")
    stop_event = threading.Event()
    threads = []
    for d in active_devices:
        t = threading.Thread(target=logcat_worker, args=(d, stop_event), daemon=True)
        t.start()
        threads.append(t)
        
    time.sleep(2)

    expected_merges_per_msg = len(infos) - 1
    all_ports = sorted(infos.keys())
    port_to_device = {port: forward_map.get(port, f'port:{port}') for port in all_ports}
    device_to_port = {v: k for k, v in port_to_device.items()}

    if single_sender and sender_port is None:
        sender_port = sorted(infos.keys())[0]
    if sender_device is not None:
        sender_port = device_to_port[sender_device]
    if sender_port is not None:
        if sender_port not in infos:
            print(
                f"{Colors.FAIL}Sender port {sender_port} is not among live devices "
                f"{sorted(infos.keys())}.{Colors.ENDC}"
            )
            stop_event.set()
            return False
        send_ports = [sender_port]
        print(
            f"{Colors.OKCYAN}Single-sender mode: all messages from port "
            f"{sender_port} ({port_to_device.get(sender_port, '?')}){Colors.ENDC}"
        )
    else:
        send_ports = all_ports

    live_snoop_captures = []
    if hci_diagnostic:
        capture_root = diagnostics_dir or f"stress_test_{time.strftime('%Y%m%d_%H%M%S')}_bluetooth"
        for state in hci_snoop_state:
            if not state.get("hci_snoop_socket_available"):
                continue
            safe_serial = re.sub(r"[^A-Za-z0-9_.-]+", "_", state["serial"])
            capture = LiveBtsnoopSocketCapture(
                state["serial"],
                os.path.join(capture_root, f"{safe_serial}_live_socket.btsnoop"),
            )
            try:
                capture.start()
            except (OSError, RuntimeError, subprocess.SubprocessError) as error:
                for active_capture in live_snoop_captures:
                    active_capture.stop()
                stop_event.set()
                print(
                    f"{Colors.FAIL}Preflight failed: could not start the live HCI "
                    f"socket capture for {state['serial']}: {error}{Colors.ENDC}"
                )
                return False
            live_snoop_captures.append(capture)
            print(
                f"[BLUETOOTH_SOCKET_CAPTURE] {state['serial']}: "
                f"streaming to {capture.output_path}"
            )

    maybe_clear_chat_messages(sorted(infos.keys()), preserve_messages)

    # Ground-truth tracking: store (tag, sender_port) for each sent message
    sent_messages = []  # list of {'tag': str, 'sender_port': int, 'sender_device': str}
    receipt_matrix = defaultdict(lambda: defaultdict(set))
    completed_at = {}
    receipt_at = {}
    receipt_windows = {}
    last_absent_at = {}
    started_at = time.monotonic()
    short_request = lambda port, path: request(port, path, timeout=5)
    peer_signal_samples = [
        capture_peer_signal_snapshot(
            short_request,
            all_ports,
            port_to_device,
            set(infos.values()),
            started_at,
        )
    ]
    print(f"[PEER_RSSI] {json.dumps(peer_signal_samples[-1], sort_keys=True)}")
    peer_signal_samples_lock = threading.Lock()
    status = {
        "propagated": 0,
        "elapsed_s": 0.001,
        "transferred_bytes": 0,
        "behind_by_path": {},
        "total_kb": 0.0,
    }
    runtime_state_samples = []
    runtime_state_samples_lock = threading.Lock()
    runtime_sampler_thread = threading.Thread(
        target=runtime_state_sampler,
        args=(
            active_devices,
            stop_event,
            runtime_state_samples,
            runtime_state_samples_lock,
            started_at,
        ),
        daemon=True,
    )
    runtime_sampler_thread.start()

    sent_messages_lock = threading.Lock()
    ui_monitor_stop = threading.Event()
    ui_monitor_state_lock = threading.Lock()
    ui_monitor_state = {"status": dict(status)}
    ui_monitor_errors = []
    ui_monitor_thread = None

    def latest_ui_status():
        with ui_monitor_state_lock:
            return dict(ui_monitor_state["status"])

    def monitor_burst_ui():
        def monitor_request(port, path):
            return request(port, path, timeout=5)

        next_signal_sample_at = time.monotonic() + 5.0
        while not ui_monitor_stop.is_set():
            with sent_messages_lock:
                sent_snapshot = list(sent_messages)
            if sent_snapshot:
                try:
                    observed_status = add_transfer_metrics(poll_ui_status(
                        monitor_request,
                        all_ports,
                        port_to_device,
                        sent_snapshot,
                        receipt_matrix,
                        completed_at,
                        started_at,
                        receipt_at,
                        receipt_windows,
                        last_absent_at,
                    ))
                    with ui_monitor_state_lock:
                        ui_monitor_state["status"] = observed_status
                except Exception as error:
                    ui_monitor_errors.append(
                        f"{type(error).__name__}: {error}"
                    )
            if time.monotonic() >= next_signal_sample_at:
                signal_sample = capture_peer_signal_snapshot(
                    monitor_request,
                    all_ports,
                    port_to_device,
                    set(infos.values()),
                    started_at,
                )
                with peer_signal_samples_lock:
                    peer_signal_samples.append(signal_sample)
                print(f"[PEER_RSSI] {json.dumps(signal_sample, sort_keys=True)}")
                next_signal_sample_at = time.monotonic() + 5.0
            ui_monitor_stop.wait(poll_interval_s)

    if profile == "burst":
        ui_monitor_thread = threading.Thread(
            target=monitor_burst_ui,
            name="stress-ui-monitor",
            daemon=True,
        )
        ui_monitor_thread.start()

    print(
        f"\n{Colors.HEADER}--- BENCHMARK: {profile} profile, "
        f"{num_messages} messages ---{Colors.ENDC}"
    )
    interactive_timeouts = 0
    for i in range(num_messages):
        sender_port_i = send_ports[i % len(send_ports)]
        tag = f"BenchMsg#{i:03d}@{int(time.time()*1000)}"
        send_started_at = time.monotonic()
        res = request(sender_port_i, '/send', 'POST', {'text': tag})
        send_api_completed_at = time.monotonic()
        sender_device = port_to_device.get(sender_port_i, '')
        with sent_messages_lock:
            sent_messages.append({
                'tag': tag,
                'sender_port': sender_port_i,
                'sender_device': sender_device,
                'sent_at': send_started_at,
                'send_api_completed_at': send_api_completed_at,
                'send_ok': isinstance(res, dict) and res.get('status') == 'sent',
            })

        if profile == "interactive":
            if not sent_messages[-1]['send_ok']:
                print(f"{Colors.FAIL}Send failed for {tag}; ending interactive run.{Colors.ENDC}")
                break
            deadline = time.monotonic() + message_timeout_s
            while tag not in completed_at and time.monotonic() < deadline:
                status = add_transfer_metrics(poll_ui_status(
                    request,
                    all_ports,
                    port_to_device,
                    sent_messages,
                    receipt_matrix,
                    completed_at,
                    started_at,
                    receipt_at,
                    receipt_windows,
                    last_absent_at,
                ))
                console.render("Interactive", i + 1, num_messages, status)
                if tag in completed_at:
                    break
                time.sleep(poll_interval_s)
            if tag not in completed_at:
                interactive_timeouts += 1
                print(
                    f"{Colors.WARNING}Timed out waiting for {tag} "
                    f"after {message_timeout_s:.1f}s; stopping to avoid "
                    f"queueing more messages.{Colors.ENDC}"
                )
                break
            if send_interval_s > 0 and i + 1 < num_messages:
                time.sleep(send_interval_s)
        else:
            if send_interval_s > 0 and i + 1 < num_messages:
                time.sleep(send_interval_s)
            if i % 5 == 0 or i + 1 == num_messages:
                status = latest_ui_status()
                console.render("Sending", i + 1, num_messages, status)
                print(f"Sending {i + 1}/{num_messages}: {status}")
    print()
    sending_finished_at = time.monotonic()

    if profile == "burst":
        print(f"\n{Colors.OKBLUE}Waiting for propagation (polling /ui — painted chat list)...{Colors.ENDC}")
    drain_started_at = time.monotonic()
    last_progress_print_at = drain_started_at
    max_wait = max(message_timeout_s, num_messages * 4) if profile == "burst" else 0

    # Track per-device UI revisions so we can print when the painted list changes
    last_ui_revision = {port: 0 for port in all_ports}
    total_kb_received = 0.0
    status = latest_ui_status() if ui_monitor_thread is not None else status
    fully_propagated = status.get("propagated", 0)

    while profile == "burst" and time.monotonic() - drain_started_at < max_wait:
        status = latest_ui_status()
        fully_propagated = status["propagated"]
        total_kb_received = status["total_kb"]
        if fully_propagated < num_messages:
            console.render("Syncing", fully_propagated, num_messages, status)

        if fully_propagated >= num_messages:
            print(f"\n{Colors.OKGREEN}[SUCCESS] All {num_messages} messages painted on all device UIs!{Colors.ENDC}\n")
            break
        if time.monotonic() - last_progress_print_at >= max(1.0, poll_interval_s):
            print(f"Propagation {fully_propagated}/{num_messages}: {status}")
            last_progress_print_at = time.monotonic()
        time.sleep(min(max(poll_interval_s, 0.05), 0.25))
    else:
        if profile == "burst" and fully_propagated < len(sent_messages):
            print(f"\n{Colors.WARNING}[TIMEOUT] Propagation did not finish within {max_wait:.1f}s{Colors.ENDC}\n")

    if ui_monitor_thread is not None:
        ui_monitor_stop.set()
        ui_monitor_thread.join(timeout=5 * len(all_ports) + 5)
        status = latest_ui_status()
        fully_propagated = status.get("propagated", 0)
        total_kb_received = status.get("total_kb", 0.0)
        if ui_monitor_errors:
            print(
                f"{Colors.WARNING}UI monitor errors: "
                f"{ui_monitor_errors[-1]}{Colors.ENDC}"
            )

    final_peer_signal_sample = capture_peer_signal_snapshot(
        short_request,
        all_ports,
        port_to_device,
        set(infos.values()),
        started_at,
    )
    with peer_signal_samples_lock:
        peer_signal_samples.append(final_peer_signal_sample)
    print(f"[PEER_RSSI] {json.dumps(final_peer_signal_sample, sort_keys=True)}")

    if profile == "interactive" and interactive_timeouts:
        print(f"Interactive messages unresolved at timeout: {interactive_timeouts}")

    stop_event.set()
    time.sleep(1)
    runtime_sampler_thread.join(timeout=14)

    live_snoop_capture_results = []
    for capture in live_snoop_captures:
        capture_result = capture.stop()
        live_snoop_capture_results.append(capture_result)
        print(
            f"[BLUETOOTH_SOCKET_CAPTURE] {capture_result['serial']}: "
            f"{capture_result['packets']} packets, {capture_result['bytes']} bytes, "
            f"error={capture_result['error']}"
        )

    print(f"\n{Colors.HEADER}{'='*40}")
    print(f"          BENCHMARK REPORT")
    print(f"{'='*40}{Colors.ENDC}")
    
    with telemetry.lock:
        # Phase 1: Match Connection Latency
        conn_lats = []
        for c in telemetry.gatt_connected:
            hits = [s['t'] for s in telemetry.scan_hit if s['device'] == c['device'] and s['mac'] == c['mac'] and s['t'] <= c['t']]
            if hits:
                conn_lats.append(c['t'] - max(hits))
                
        # Phase 2: Match Transfer Latency
        transfer_lats = []
        trans_bytes = []
        for d in telemetry.delta_received:
            offers = [o['t'] for o in telemetry.offer_sent if o['device'] == d['device'] and o['mac'] == d['mac'] and o['t'] <= d['t']]
            if offers:
                t_diff = d['t'] - max(offers)
                if t_diff > 0:
                    transfer_lats.append(t_diff)
                    trans_bytes.append(d['bytes'])
        
        # End-to-end timing is measured by the host's monotonic clock when /ui
        # first shows each message. Do not subtract timestamps from different
        # phones here: their wall clocks are not synchronized.
        print(f"\n{Colors.BOLD}--- Per-device phase deltas (same-device log timestamps) ---{Colors.ENDC}")
        print("  Discovery timing omitted: phone wall clocks are unsynchronized.")
        if conn_lats:
            print(f"  Connection Latency: {Colors.OKCYAN}{(sum(conn_lats)/len(conn_lats))/1000.0:.3f}s{Colors.ENDC}")
        if transfer_lats:
            print(f"  Transfer Latency:   {Colors.OKCYAN}{(sum(transfer_lats)/len(transfer_lats))/1000.0:.3f}s{Colors.ENDC}")

        print(f"\n{Colors.BOLD}--- Bandwidth Metrics ---{Colors.ENDC}")
        if transfer_lats and sum(trans_bytes) > 0:
            total_kb = sum(trans_bytes) / 1024.0
            total_time_s = sum(transfer_lats) / 1000.0
            agg_bw_kb = total_kb / total_time_s if total_time_s > 0 else 0
            agg_bw_mb = agg_bw_kb / 1024.0
            agg_bw_gb = agg_bw_mb / 1024.0
            print(f"  Total Data Received: {Colors.OKGREEN}{total_kb:.2f} KB{Colors.ENDC}")
            print(f"  Average Bandwidth:")
            print(f"    {Colors.OKGREEN}{agg_bw_kb:.4f} KB/s{Colors.ENDC}")
            print(f"    {Colors.OKGREEN}{agg_bw_mb:.6f} MB/s{Colors.ENDC}")
            print(f"    {Colors.OKGREEN}{agg_bw_gb:.9f} GB/s{Colors.ENDC}")
        else:
            print(f"  {Colors.WARNING}No valid Transfer data{Colors.ENDC}")

        print(f"\n{Colors.BOLD}--- Failure Analytics ---{Colors.ENDC}")
        total_connections = len(telemetry.connection_failed) + len(telemetry.gatt_connected)
        successes = len(telemetry.gatt_connected)
        print(f"  Tracked outbound attempts: {total_connections}")
        print(f"  Tracked outbound success:  {Colors.OKGREEN}{successes}{Colors.ENDC} ({successes/total_connections*100:.1f}%)" if total_connections > 0 else f"  Tracked outbound success:  0")
        print(f"  Penalty Box Entries: {Colors.WARNING}{len(telemetry.penalty_box)}{Colors.ENDC}")
        failed_by_reason = Counter(event['reason'] or 'unspecified' for event in telemetry.connection_failed)
        if failed_by_reason:
            print("  Connection failures by reason:")
            for reason, count in failed_by_reason.most_common():
                print(f"    {reason}: {count}")
        rejected_by_reason = Counter(
            event['reason'].split('_for_', 1)[0] or 'unspecified'
            for event in telemetry.connection_rejected
        )
        print(f"  Inbound connection rejections: {len(telemetry.connection_rejected)}")
        for reason, count in rejected_by_reason.most_common():
            print(f"    {reason}: {count}")
        if telemetry.app_state_changes:
            state_counts = Counter(event['state'] for event in telemetry.app_state_changes)
            print("  App state events: " + ", ".join(
                f"{state}={count}" for state, count in sorted(state_counts.items())
            ))

        print(f"\n{Colors.BOLD}--- UI Change Events (logcat) ---{Colors.ENDC}")
        if telemetry.ui_changed:
            for ev in telemetry.ui_changed:
                print(
                    f"  {ev['device'][-6:]}  rev={ev['revision']}  "
                    f"count={ev['count']}  t={ev['t']}"
                )
        else:
            print(f"  {Colors.WARNING}No UI_CHANGED logcat events captured{Colors.ENDC}")

        # --- PER-DEVICE RECEIPT MATRIX (sourced from /ui polling — painted list) ---
        print(f"\n{Colors.BOLD}--- Device-to-Device Receipt Matrix (UI) ---{Colors.ENDC}")
        all_devices = sorted(port_to_device.values())
        sent_count = defaultdict(int)
        for sent in sent_messages:
            sent_count[sent['sender_device']] += 1


        # Print header row
        header = f"  {'Sender':<20}" + "".join(f" {'->'+r[-6:]:>12}" for r in all_devices)
        print(header)
        has_blackout = False
        for sender in all_devices:
            row = f"  {sender:<20}"
            for receiver in all_devices:
                if sender == receiver:
                    row += f" {'(self)':>12}"
                else:
                    count = len(receipt_matrix[sender][receiver])
                    total = sent_count[sender]
                    cell = f"{count}/{total}"
                    if total > 0 and count == 0:
                        row += f" {Colors.FAIL}{cell:>12}{Colors.ENDC}"
                        has_blackout = True
                    elif total > 0 and count < total:
                        row += f" {Colors.WARNING}{cell:>12}{Colors.ENDC}"
                    else:
                        row += f" {Colors.OKGREEN}{cell:>12}{Colors.ENDC}"
            print(row)
        if has_blackout:
            print(f"  {Colors.FAIL}*** BLACKOUT DETECTED: One or more sender->receiver paths received 0 messages! ***{Colors.ENDC}")
        else:
            print(f"  {Colors.OKGREEN}All device paths propagated successfully.{Colors.ENDC}")
    device_runtime_state_end = capture_runtime_state_snapshot(active_devices)
    print("\nDevice screen/lock state at test end:")
    for state in device_runtime_state_end["devices"]:
        print(
            f"  {state['serial']}: wakefulness={state['wakefulness'] or 'unknown'} "
            f"display={state['display_power_state'] or 'unknown'} "
            f"locked={state['device_locked']} "
            f"keyguard={state['keyguard_state']} "
            f"focus={state['focused_window'] or 'unknown'}"
        )
    with runtime_state_samples_lock:
        device_runtime_state_samples = list(runtime_state_samples)
    bluetooth_diagnostics = None
    if hci_diagnostic:
        diagnostics_dir = diagnostics_dir or f"{time.strftime('%Y%m%d_%H%M%S')}_bluetooth"
        print(f"\nCapturing Bluetooth snoop diagnostics to {diagnostics_dir}")
        bluetooth_diagnostics = capture_devices_bluetooth_diagnostics(
            active_devices,
            diagnostics_dir,
            hci_snoop_state,
        )
        for capture in bluetooth_diagnostics:
            artifacts = capture["artifacts"]
            print(
                f"[BLUETOOTH_CAPTURE] {capture['serial']}: "
                f"artifacts={len(artifacts)} errors={len(capture['errors'])}"
            )
            for artifact in artifacts:
                print(
                    f"  {artifact['scope']}: {artifact['packets']} packets "
                    f"→ {artifact['path']}"
                )
            for error in capture["errors"]:
                print(f"  Capture error: {error}")
    return {
        "success": fully_propagated >= num_messages,
        "profile": profile,
        "send_interval_s": send_interval_s,
        "poll_interval_s": poll_interval_s,
        "sender_port": sender_port,
        "interactive_timeouts": interactive_timeouts,
        "sent_messages": sent_messages,
        "completed_at": completed_at,
        "receipt_at": receipt_at,
        "receipt_windows": receipt_windows,
        "status": status,
        "sending_finished_at": sending_finished_at,
        "all_devices": sorted(port_to_device.values()),
        "preflight": preflight_record,
        "device_metadata": device_metadata,
        "device_runtime_state": {
            "start": device_runtime_state_start,
            "samples": device_runtime_state_samples,
            "end": device_runtime_state_end,
            "sample_interval_s": 5.0,
            "clock": "host-monotonic",
        },
        "peer_signal_samples": peer_signal_samples,
        "bluetooth_socket_captures": live_snoop_capture_results,
        "bluetooth_diagnostics": bluetooth_diagnostics,
        "connection_failures": len(telemetry.connection_failed),
        "connection_rejections": len(telemetry.connection_rejected),
        "penalty_entries": len(telemetry.penalty_box),
        "send_failures": sum(not item["send_ok"] for item in sent_messages),
        "ble_trace_events": list(telemetry.ble_trace_events),
        "android_bluetooth_logs": list(telemetry.android_bluetooth_logs),
    }

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument("--messages", type=int, default=10, help="Messages to send")
    parser.add_argument(
        "--profile",
        choices=("interactive", "burst"),
        default="burst",
        help="Interactive waits for all peer UIs after each send; burst queues sends.",
    )
    parser.add_argument(
        "--send-interval-s",
        type=float,
        help="Delay after each send (or each completed interactive message).",
    )
    parser.add_argument(
        "--poll-interval-s",
        type=float,
        help="UI polling interval; defaults to 0.1s interactive and 2s burst.",
    )
    parser.add_argument(
        "--message-timeout-s",
        type=float,
        default=90.0,
        help="Per-message interactive timeout and minimum burst drain window.",
    )
    parser.add_argument(
        "--ports",
        help="Comma-separated forwarded API ports; defaults to all discovered devices.",
    )
    parser.add_argument(
        "--devices",
        help=(
            "Comma-separated ADB serials; creates forwards for and tests only "
            "those online devices."
        ),
    )
    parser.add_argument(
        "--sender-port",
        type=int,
        help="Only this API port sends (others only receive). Default: rotate across all.",
    )
    parser.add_argument(
        "--sender-device",
        help="Only this ADB serial sends (others only receive).",
    )
    parser.add_argument(
        "--single-sender",
        action="store_true",
        help="Send all messages from the first live device only.",
    )
    parser.add_argument(
        "--preserve-messages",
        action="store_true",
        help="Keep existing chat rows and measure only messages sent during this run.",
    )
    parser.add_argument(
        "--details-file",
        help="Detailed diagnostics path (default: timestamped .log file)",
    )
    parser.add_argument(
        "--summary-json",
        help="Optional machine-readable summary path for load-sweep tooling.",
    )
    parser.add_argument(
        "--hci-diagnostic",
        action="store_true",
        help=(
            "Require full HCI snoop logging on every selected phone and capture "
            "btsnoop artifacts after the run."
        ),
    )
    args = parser.parse_args()
    try:
        selected_ports = parse_ports_arg(args.ports)
        selected_devices = parse_devices_arg(args.devices)
        if selected_ports is not None and selected_devices is not None:
            raise ValueError("choose either --ports or --devices")
        if args.sender_port is not None and args.sender_device is not None:
            raise ValueError("choose either --sender-port or --sender-device")
        resolve_profile_settings(
            args.profile,
            args.send_interval_s,
            args.poll_interval_s,
        )
        if args.messages <= 0:
            raise ValueError("message count must be positive")
        if not math.isfinite(args.message_timeout_s) or args.message_timeout_s <= 0:
            raise ValueError("message timeout must be finite and positive")
    except ValueError as error:
        parser.error(str(error))

    details_path = args.details_file or time.strftime(
        "stress_test_%Y%m%d_%H%M%S.log"
    )
    console = ProgressDisplay()
    exit_code = 0
    try:
        with DetailLog(details_path):
            diagnostics_dir = None
            if args.hci_diagnostic:
                details_stem, _ = os.path.splitext(details_path)
                diagnostics_dir = details_stem + "_bluetooth"
            result = run_benchmark(
                args.messages,
                console,
                sender_port=args.sender_port,
                sender_device=args.sender_device,
                single_sender=args.single_sender,
                preserve_messages=args.preserve_messages,
                ports=selected_ports,
                devices=selected_devices,
                profile=args.profile,
                send_interval_s=args.send_interval_s,
                poll_interval_s=args.poll_interval_s,
                message_timeout_s=args.message_timeout_s,
                hci_diagnostic=args.hci_diagnostic,
                diagnostics_dir=diagnostics_dir,
            )
        if isinstance(result, dict):
            outcome = "PASS" if result["success"] else "FAIL"
            exit_code = 0 if result["success"] else 1
            console.finish(outcome)
            summary = print_run_summary(console.stream, result, details_path)
            if args.summary_json:
                with open(args.summary_json, "w", encoding="utf-8") as summary_file:
                    json.dump(summary, summary_file, indent=2)
                    summary_file.write("\n")
        else:
            exit_code = 1
            console.finish(f"FAIL: details written to {details_path}")
    except KeyboardInterrupt:
        exit_code = 130
        console.finish(f"Aborted: partial details written to {details_path}")
    raise SystemExit(exit_code)

