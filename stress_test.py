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
from collections import defaultdict

PORTS = [18081, 18082, 18083]


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
        self.penalty_box = []  # { device, mac, duration }
        self.app_state_changes = []  # { device, state, t }


telemetry = Telemetry()


def request(port, path, method='GET', body=None):
    url = f'http://127.0.0.1:{port}{path}'
    try:
        req = urllib.request.Request(url, method=method)
        if body is not None:
            req.add_header('Content-Type', 'application/json')
            data = json.dumps(body).encode('utf-8')
            with urllib.request.urlopen(req, data=data, timeout=10) as response:
                return json.loads(response.read().decode())
        else:
            with urllib.request.urlopen(req, timeout=10) as response:
                return json.loads(response.read().decode())
    except Exception:
        return None


def get_adb_devices():
    result = subprocess.run(["adb", "devices"], capture_output=True, text=True)
    devices = []
    for line in result.stdout.strip().split("\n")[1:]:
        if "\tdevice" in line:
            devices.append(line.split("\t")[0].strip())
    return devices


def get_port_to_device():
    """Map host forward ports → serial via `adb forward --list` (not adb device order)."""
    result = subprocess.run(["adb", "forward", "--list"], capture_output=True, text=True)
    mapping = {}
    for line in result.stdout.strip().split("\n"):
        parts = line.split()
        # e.g. "46071FDAS009EH tcp:18081 tcp:8080"
        if len(parts) >= 2 and parts[1].startswith("tcp:"):
            try:
                port = int(parts[1].split(":", 1)[1])
                mapping[port] = parts[0]
            except ValueError:
                pass
    return mapping


def discover_ports():
    """Use forwarded ports that actually answer /info (any device count ≥1)."""
    forward_map = get_port_to_device()
    candidates = sorted(p for p in forward_map if 18081 <= p <= 18099) or list(PORTS)
    # One port per serial (duplicate forwards from remaps).
    seen_serial = set()
    live = []
    for p in candidates:
        serial = forward_map.get(p)
        if serial in seen_serial:
            continue
        res = request(p, '/info')
        if res and 'nodeId' in res:
            live.append(p)
            if serial:
                seen_serial.add(serial)
    if live:
        return live
    return [p for p in PORTS if request(p, '/info')]


def check_devices(ports=None):
    infos = {}
    ports = ports or discover_ports()
    print(f"{Colors.OKCYAN}Checking device APIs on ports {ports}...{Colors.ENDC}")
    for p in ports:
        res = request(p, '/info')
        if res and 'nodeId' in res:
            infos[p] = res['nodeId']
            print(f"  Device at port {p}: OK  nodeId={res['nodeId']}")
            kick = request(p, '/reset_ble', method='POST')
            if kick:
                print(f"  Device at port {p}: BLE restarted")
            else:
                print(f"  Device at port {p}: BLE kick failed (may already be running)")
        else:
            print(f"  Device at port {p}: UNREACHABLE")
    return infos

def logcat_worker(device_id, stop_event):
    cmd = ["adb", "-s", device_id, "logcat", "-v", "raw", "-s", "flutter,NativeMeshService"]
    subprocess.run(["adb", "-s", device_id, "logcat", "-c"])
    process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8", errors="replace")
    
    while not stop_event.is_set():
        line = process.stdout.readline()
        if not line:
            if process.poll() is not None:
                break
            time.sleep(0.1)
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

def run_benchmark(num_messages=30):
    infos = check_devices()
    if len(infos) < 2:
        print(f"{Colors.FAIL}Need at least 2 responsive devices to test mesh sync.{Colors.ENDC}")
        return

    adb_devices = get_adb_devices()
    if len(adb_devices) < 2:
        print(f"{Colors.FAIL}Ensure at least 2 devices are connected via adb.{Colors.ENDC}")
        return

    forward_map = get_port_to_device()
    # Only stream logcat for devices whose stress API is reachable.
    active_devices = []
    for port in sorted(infos.keys()):
        serial = forward_map.get(port)
        if serial and serial not in active_devices:
            active_devices.append(serial)
    if len(active_devices) < 2:
        # Fallback: old deploy.py ordering assumption
        active_devices = adb_devices[: len(infos)]
        
    print(f"\n{Colors.OKCYAN}Starting adb logcat streams for devices: {active_devices}{Colors.ENDC}")
    stop_event = threading.Event()
    threads = []
    for d in active_devices:
        t = threading.Thread(target=logcat_worker, args=(d, stop_event), daemon=True)
        t.start()
        threads.append(t)
        
    time.sleep(2)

    expected_merges_per_msg = len(infos) - 1
    all_ports = list(infos.keys())
    port_to_device = {port: forward_map.get(port, f'port:{port}') for port in all_ports}
    device_to_port = {v: k for k, v in port_to_device.items()}

    # Ground-truth tracking: store (tag, sender_port) for each sent message
    sent_messages = []  # list of {'tag': str, 'sender_port': int, 'sender_device': str}

    print(f"\n{Colors.HEADER}--- BENCHMARK: Sending {num_messages} messages across All Devices ---{Colors.ENDC}")
    for i in range(num_messages):
        sender_port = all_ports[i % len(all_ports)]
        tag = f"BenchMsg#{i:03d}@{int(time.time()*1000)}"
        res = request(sender_port, '/send', 'POST', {'text': tag})
        sender_device = port_to_device.get(sender_port, '')
        sent_messages.append({'tag': tag, 'sender_port': sender_port, 'sender_device': sender_device})
        time.sleep(0.3)
        sys.stdout.write(f"\rSending: {i+1}/{num_messages} (from port {sender_port})")
        sys.stdout.flush()
    print()

    print(f"\n{Colors.OKBLUE}Waiting for propagation (polling /ui — painted chat list)...{Colors.ENDC}")
    poll_start = time.time()
    max_wait = max(90, num_messages * 4)

    # receipt_matrix[sender_device][receiver_device] = set of received tags
    receipt_matrix = defaultdict(lambda: defaultdict(set))
    # Track per-device UI revisions so we can print when the painted list changes
    last_ui_revision = {port: 0 for port in all_ports}
    total_kb_received = 0.0

    while time.time() - poll_start < max_wait:
        # Poll each device for what the UI has actually rendered
        device_messages = {}  # device -> set of text contents
        for port in all_ports:
            dev = port_to_device.get(port, str(port))
            res = request(port, '/ui')
            if not res or not isinstance(res, dict):
                continue
            rev = int(res.get('revision', 0) or 0)
            msgs = res.get('messages') or []
            if rev != last_ui_revision[port]:
                prev = last_ui_revision[port]
                last_ui_revision[port] = rev
                print(
                    f"\n{Colors.OKCYAN}[UI] port {port} ({dev[-6:]}): "
                    f"revision {prev} → {rev} | count={res.get('count', len(msgs))} "
                    f"| changedAtMs={res.get('changedAtMs', '?')}{Colors.ENDC}"
                )
            device_messages[dev] = {m.get('text', m.get('textContent', '')) for m in msgs}
            total_kb_received = sum(len(str(m)) for m in msgs) / 1024.0

        # Score: for each sent message, check which non-sender devices have painted it
        fully_propagated = 0
        for sent in sent_messages:
            tag = sent['tag']
            sender_dev = sent['sender_device']
            receivers = 0
            for dev, texts in device_messages.items():
                if dev != sender_dev and tag in texts:
                    receipt_matrix[sender_dev][dev].add(tag)
                    receivers += 1
            if receivers >= len(infos) - 1:
                fully_propagated += 1

        elapsed = time.time() - poll_start
        rev_summary = ",".join(f"{p}:{last_ui_revision[p]}" for p in all_ports)
        sys.stdout.write(
            f"\rUI Propagated: {fully_propagated}/{num_messages} | Elapsed: {elapsed:.0f}s "
            f"| revs=[{rev_summary}] | Data: {total_kb_received:.1f}KB"
        )
        sys.stdout.flush()

        if fully_propagated >= num_messages:
            print(f"\n{Colors.OKGREEN}[SUCCESS] All {num_messages} messages painted on all device UIs!{Colors.ENDC}\n")
            break
        time.sleep(2)
    else:
        print(f"\n{Colors.WARNING}[TIMEOUT] Propagation did not finish within {max_wait}s{Colors.ENDC}\n")

    stop_event.set()
    time.sleep(1)

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
        
        # Absolute Propagation & Discovery Base
        abs_lats = []
        base_create_tc = float('inf')
        for msg_id, info in telemetry.created.items():
            base_create_tc = min(base_create_tc, info['t'])
            m_times = telemetry.displayed.get(msg_id, {}).values()
            for t_merge in m_times:
                abs_lats.append(t_merge - info['t'])
                
        # Phase 3: Discovery Latency Heuristic (Simplification for cross-device: First hit after first create)
        scan_hits_after_create = [s['t'] - base_create_tc for s in telemetry.scan_hit if s['t'] >= base_create_tc]
        
        print(f"\n{Colors.BOLD}--- Phase Breakdown (Averages) ---{Colors.ENDC}")
        if scan_hits_after_create:
            print(f"  Discovery Latency:  {Colors.OKCYAN}{(sum(scan_hits_after_create)/len(scan_hits_after_create))/1000.0:.3f}s{Colors.ENDC}")
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

        print(f"\n{Colors.BOLD}--- Absolute Propagation Latency ---{Colors.ENDC}")
        if abs_lats:
            print(f"  Best Case:  {Colors.OKGREEN}{min(abs_lats)/1000.0:.3f}s{Colors.ENDC}")
            print(f"  Worst Case: {Colors.FAIL}{max(abs_lats)/1000.0:.3f}s{Colors.ENDC}")
            print(f"  Average:    {Colors.OKCYAN}{(sum(abs_lats)/len(abs_lats))/1000.0:.3f}s{Colors.ENDC}")
        else:
            print(f"  {Colors.WARNING}No valid Merges{Colors.ENDC}")

        print(f"\n{Colors.BOLD}--- Failure Analytics ---{Colors.ENDC}")
        total_connections = len(telemetry.connection_failed) + len(telemetry.gatt_connected)
        successes = len(telemetry.gatt_connected)
        print(f"  Connection Attempts: {total_connections}")
        print(f"  Connection Success:  {Colors.OKGREEN}{successes}{Colors.ENDC} ({successes/total_connections*100:.1f}%)" if total_connections > 0 else f"  Connection Success:  0")
        print(f"  Penalty Box Entries: {Colors.WARNING}{len(telemetry.penalty_box)}{Colors.ENDC}")
        
        fg_lats = []
        bg_lats = []
        for s in telemetry.scan_hit:
            if s['t'] >= base_create_tc:
                lat = s['t'] - base_create_tc
                device_states = [state for state in telemetry.app_state_changes if state['device'] == s['device'] and state['t'] <= s['t']]
                current_state = device_states[-1]['state'] if device_states else 'FOREGROUND'
                if current_state == 'FOREGROUND':
                    fg_lats.append(lat)
                elif current_state == 'BACKGROUND':
                    bg_lats.append(lat)
                    
        if fg_lats:
            print(f"  Foreground Discovery Target: {Colors.OKCYAN}{(sum(fg_lats)/len(fg_lats))/1000.0:.3f}s{Colors.ENDC}")
        else:
            print(f"  Foreground Discovery Target: {Colors.WARNING}N/A{Colors.ENDC}")
        if bg_lats:
            print(f"  Background Discovery Target: {Colors.OKCYAN}{(sum(bg_lats)/len(bg_lats))/1000.0:.3f}s{Colors.ENDC}")
        else:
            print(f"  Background Discovery Target: {Colors.WARNING}N/A{Colors.ENDC}")

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

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument("--messages", type=int, default=10, help="Messages to burst")
    args = parser.parse_args()
    try:
        run_benchmark(args.messages)
    except KeyboardInterrupt:
        print("\nAborted.")

