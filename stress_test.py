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

class Telemetry:
    def __init__(self):
        self.lock = threading.Lock()
        self.created = {}  # msg_id -> { device, t }
        self.scan_hit = [] # { device, mac, t }
        self.offer_sent = [] # { device, mac, t }
        self.gatt_connected = [] # { device, mac, t }
        self.delta_received = [] # { device, mac, bytes, t }
        self.merged = defaultdict(dict)  # msg_id -> { device: t }
        self.displayed = defaultdict(dict)  # msg_id -> { device: t }

telemetry = Telemetry()

def request(port, path, method='GET', body=None):
    url = f'http://127.0.0.1:{port}{path}'
    try:
        req = urllib.request.Request(url, method=method)
        if body is not None:
            req.add_header('Content-Type', 'application/json')
            data = json.dumps(body).encode('utf-8')
            with urllib.request.urlopen(req, data=data, timeout=5) as response:
                return json.loads(response.read().decode())
        else:
            with urllib.request.urlopen(req, timeout=5) as response:
                return json.loads(response.read().decode())
    except Exception as e:
        return None

def check_devices():
    infos = {}
    print(f"{Colors.OKCYAN}Checking device APIs...{Colors.ENDC}")
    for p in PORTS:
        res = request(p, '/info')
        if res and 'nodeId' in res:
            infos[p] = res['nodeId']
            print(f"  Device at port {p}: OK  nodeId={res['nodeId']}")
        else:
            print(f"  Device at port {p}: UNREACHABLE")
    return infos

def get_adb_devices():
    result = subprocess.run(["adb", "devices"], capture_output=True, text=True)
    devices = []
    for line in result.stdout.strip().split("\n")[1:]:
        if "\tdevice" in line:
            devices.append(line.split("\t")[0].strip())
    return devices

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
        
    print(f"\n{Colors.OKCYAN}Starting adb logcat streams for devices: {adb_devices}{Colors.ENDC}")
    stop_event = threading.Event()
    threads = []
    for d in adb_devices:
        t = threading.Thread(target=logcat_worker, args=(d, stop_event), daemon=True)
        t.start()
        threads.append(t)
        
    time.sleep(2)

    sender_port = list(infos.keys())[0]
    expected_merges_per_msg = len(infos) - 1

    print(f"\n{Colors.HEADER}--- BENCHMARK: Sending {num_messages} messages across All Devices ---{Colors.ENDC}")
    all_ports = list(infos.keys())
    for i in range(num_messages):
        sender_port = all_ports[i % len(all_ports)]
        tag = f"BenchMsg#{i:03d}@{int(time.time()*1000)}"
        res = request(sender_port, '/send', 'POST', {'text': tag})
        time.sleep(0.3)
        sys.stdout.write(f"\rSending: {i+1}/{num_messages} (from port {sender_port})")
        sys.stdout.flush()
    print()

    print(f"\n{Colors.OKBLUE}Waiting for propagation ({expected_merges_per_msg} merges per message)...{Colors.ENDC}")
    poll_start = time.time()
    max_wait = max(90, num_messages * 3)

    while time.time() - poll_start < max_wait:
        with telemetry.lock:
            fully_propagated = 0
            for msg_id, creation_info in telemetry.created.items():
                if msg_id in telemetry.displayed and len(telemetry.displayed[msg_id]) >= expected_merges_per_msg:
                    fully_propagated += 1
            
            sys.stdout.write(f"\rPropagated and Displayed fully: {fully_propagated}/{num_messages} messages")
            sys.stdout.flush()
            
            if fully_propagated >= num_messages:
                print(f"\n{Colors.OKGREEN}[SUCCESS] All messages merged!{Colors.ENDC}\n")
                break
        time.sleep(1)
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
            agg_bw = total_kb / total_time_s if total_time_s > 0 else 0
            print(f"  Total Data Recevied: {Colors.OKGREEN}{total_kb:.2f} KB{Colors.ENDC}")
            print(f"  Average Bandwidth:   {Colors.OKGREEN}{agg_bw:.2f} KB/s{Colors.ENDC}")
        else:
            print(f"  {Colors.WARNING}No valid Transfer data{Colors.ENDC}")

        print(f"\n{Colors.BOLD}--- Absolute Propagation Latency ---{Colors.ENDC}")
        if abs_lats:
            print(f"  Best Case:  {Colors.OKGREEN}{min(abs_lats)/1000.0:.3f}s{Colors.ENDC}")
            print(f"  Worst Case: {Colors.FAIL}{max(abs_lats)/1000.0:.3f}s{Colors.ENDC}")
            print(f"  Average:    {Colors.OKCYAN}{(sum(abs_lats)/len(abs_lats))/1000.0:.3f}s{Colors.ENDC}")
        else:
            print(f"  {Colors.WARNING}No valid Merges{Colors.ENDC}")

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument("--messages", type=int, default=10, help="Messages to burst")
    args = parser.parse_args()
    try:
        run_benchmark(args.messages)
    except KeyboardInterrupt:
        print("\nAborted.")
