import sys, io
# Force UTF-8 output on Windows to avoid cp1252 encoding errors with unicode chars.
if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')

import urllib.request
import urllib.parse
import json
import time
import sys
import threading

PORTS = [18081, 18082, 18083]

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

def reset_network_limits():
    print("Resetting any artificial network limits...")
    for p in PORTS:
        req = request(p, '/config', 'POST', {'reset': True})
    
    # NOTE: Do NOT reset the BLE GATT server here. Android's BLE stack does not
    # fully recover after close()/reopen() — all subsequent GATT client connections
    # fail silently (no onConnectionStateChange callbacks). The server heals itself
    # naturally via the connection slot cleanup in onConnectionStateChange.

def check_devices():
    infos = {}
    print("Checking device APIs...")
    for p in PORTS:
        res = request(p, '/info')
        if res and 'nodeId' in res:
            infos[p] = res['nodeId']
            print(f"  Device at port {p}: OK  nodeId={res['nodeId']}")
        else:
            print(f"  Device at port {p}: UNREACHABLE")
    return infos

def get_messages(port):
    res = request(port, '/messages')
    if res and 'messages' in res:
        return {m['msgId']: m for m in res['messages']}
    return {}

def print_progress_bar(iteration, total, prefix='', suffix='', decimals=1, length=40):
    if total == 0:
        return
    percent = ("{0:." + str(decimals) + "f}").format(100 * (iteration / float(total)))
    filledLength = int(length * iteration // total)
    bar = '#' * filledLength + '-' * (length - filledLength)
    line = f'\r{prefix} [{bar}] {percent}% {suffix}'
    try:
        sys.stdout.write(line)
        sys.stdout.flush()
    except UnicodeEncodeError:
        sys.stdout.write(line.encode('ascii', 'replace').decode('ascii'))
        sys.stdout.flush()
    if iteration == total:
        print()

def run_longer_test(num_messages=30):
    reset_network_limits()
    infos = check_devices()
    if len(infos) < 2:
        print("Need at least 2 responsive devices to test mesh sync.")
        return

    sender_port = PORTS[0]
    receiver_ports = [p for p in PORTS if p != sender_port and p in infos]
    sender_node_id = infos[sender_port]

    print(f"\nSender:    port {sender_port}  nodeId={sender_node_id}")
    for p in receiver_ports:
        print(f"Receiver:  port {p}  nodeId={infos[p]}")

    # Snapshot existing messages so we only track NEW ones from this run.
    print("\nSnapshotting baseline message IDs...")
    baseline_ids = {p: set(get_messages(p).keys()) for p in PORTS if p in infos}
    print(f"  Baseline counts: { {p: len(ids) for p, ids in baseline_ids.items()} }")

    # Send N messages from Device 1, track their msg IDs.
    sent_msg_ids = []
    send_times = {}

    print(f"\nSending {num_messages} messages from device 1 (port {sender_port})...")
    for i in range(num_messages):
        tag = f"SyncTest#{i:03d}@{int(time.time()*1000)}"
        res = request(sender_port, '/send', 'POST', {'text': tag})
        send_times[tag] = time.time()
        print_progress_bar(i + 1, num_messages, prefix='Sending:', suffix=f'({i+1}/{num_messages})')
        time.sleep(3.0)
    print()

    # Now figure out which message IDs were actually created in this run on Device 1.
    print("Identifying sent message IDs from Device 1...")
    time.sleep(2)
    d1_msgs_now = get_messages(sender_port)
    new_on_d1 = {mid: m for mid, m in d1_msgs_now.items()
                 if mid not in baseline_ids.get(sender_port, set())
                 and m.get('originNodeId') == sender_node_id}
    sent_msg_ids = list(new_on_d1.keys())
    print(f"  Found {len(sent_msg_ids)} new messages from sender on Device 1 (expected {num_messages})")
    if len(sent_msg_ids) < num_messages:
        print(f"  ⚠️  WARNING: Only {len(sent_msg_ids)} messages confirmed on sender device!")

    if not sent_msg_ids:
        print("ERROR: Could not identify any sent messages, aborting.")
        return

    # Poll receivers until all sent messages arrive or timeout.
    print(f"\nWaiting for {len(sent_msg_ids)} messages to propagate to {len(receiver_ports)} receiver(s)...")
    max_wait = max(90, num_messages * 3)
    poll_start = time.time()
    arrival_times = {p: {} for p in receiver_ports}   # port -> {msgId: arrival_time}
    seen_ids = {p: set(baseline_ids.get(p, set())) for p in receiver_ports}

    while time.time() - poll_start < max_wait:
        for p in receiver_ports:
            msgs = get_messages(p)
            for mid in sent_msg_ids:
                if mid in msgs and mid not in arrival_times[p]:
                    arrival_times[p][mid] = time.time()
                seen_ids[p].add(mid)  # track we looked

        total_received = sum(len(v) for v in arrival_times.values())
        total_expected = len(sent_msg_ids) * len(receiver_ports)
        elapsed = time.time() - poll_start
        remaining = max(0, int(max_wait - elapsed))
        print_progress_bar(
            total_received, total_expected,
            prefix='Syncing:',
            suffix=f'{total_received}/{total_expected} delivered [timeout in {remaining}s]'
        )

        if total_received >= total_expected:
            print(f"\n\n✅ [SUCCESS] All {len(sent_msg_ids)} messages reached all {len(receiver_ports)} receivers!")
            break
        time.sleep(1)
    else:
        print(f"\n\n❌ [TIMEOUT] Sync did not complete in {max_wait}s")

    # Per-receiver results.
    print("\n--- RESULTS ---")
    for p in receiver_ports:
        received = len(arrival_times[p])
        missing = [mid for mid in sent_msg_ids if mid not in arrival_times[p]]
        latencies = []
        for mid, t in arrival_times[p].items():
            msg = new_on_d1.get(mid)
            if msg:
                ts_ms = msg.get('timestamp', 0)
                sent_t = ts_ms / 1000.0 if ts_ms > 1e9 else send_times.get(
                    msg.get('textContent', ''), poll_start)
                latencies.append(t - sent_t)

        avg_lat = f"{sum(latencies)/len(latencies):.1f}s" if latencies else "N/A"
        status = "✅" if received == len(sent_msg_ids) else "❌"
        print(f"  {status} Port {p} (nodeId={infos[p]}): "
              f"{received}/{len(sent_msg_ids)} messages received  avg_latency={avg_lat}")
        if missing:
            print(f"     Missing IDs: {missing[:5]}{'...' if len(missing) > 5 else ''}")

    # Also check for any unexpected delivery failures: messages on D1 that didn't originate there.
    print("\n--- CROSS-CHECK: Are receivers' message counts growing? ---")
    for p in receiver_ports:
        msgs = get_messages(p)
        new_count = len({mid for mid in msgs if mid not in baseline_ids.get(p, set())})
        print(f"  Port {p}: {new_count} new messages since baseline (total={len(msgs)})")

    print("\nGathering device logs to android.log...")
    try:
        import os, subprocess
        result = subprocess.run("adb devices", capture_output=True, text=True, shell=True)
        devices = []
        for line in result.stdout.strip().split("\n")[1:]:
            if "\tdevice" in line:
                devices.append(line.split("\t")[0].strip())
        
        print(f"Collecting logs from {len(devices)} device(s): {devices}")
        with open("android.log", "w", encoding="utf-8") as f:
            f.write(f"Test run: {time.strftime('%Y-%m-%d %H:%M:%S')}\n")
            f.write(f"Devices: {devices}\n\n")
            for d in devices:
                f.write(f"\n\n{'='*60}\nLOGS FOR DEVICE {d}\n{'='*60}\n\n")
                r = subprocess.run(
                    ["adb", "-s", d, "logcat", "-d", "-v", "time", "-s", "flutter,NativeMeshService"],
                    capture_output=True, text=True, encoding="utf-8", errors="replace"
                )
                f.write(r.stdout)
                if r.stderr:
                    f.write(f"\n[stderr]: {r.stderr}\n")
        print(f"Logs saved to android.log ({os.path.getsize('android.log')} bytes)")
    except Exception as e:
        print(f"Failed to gather logs: {e}")


if __name__ == '__main__':
    run_longer_test(30)
