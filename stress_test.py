import urllib.request
import urllib.parse
import json
import time
import sys

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
            print(f"Device at port {p} is responsive. Node ID: {res['nodeId']}")
        else:
            print(f"FAILED to reach device on port {p}")
    return infos

def get_all_messages():
    all_msgs = {}
    for p in PORTS:
        res = request(p, '/messages')
        if res and 'messages' in res:
            all_msgs[p] = res['messages']
    return all_msgs

def run_longer_test(num_messages=50):
    reset_network_limits()
    infos = check_devices()
    if len(infos) < 2:
        print("Need at least 2 responsive devices to test mesh sync.")
        return

    # To track latency:
    # First, let's snapshot the initial messages so we don't count old ones.
    initial_msgs = get_all_messages()
    seen_message_ids = {p: set(m['msgId'] for m in initial_msgs.get(p, [])) for p in PORTS}
    print(f"Baseline message counts: { {p: len(initial_msgs.get(p, [])) for p in PORTS} }")

    send_times = {} # msg_text -> timestamp
    arrival_times = {p: {} for p in PORTS} # port -> {msg_text: timestamp}
    
    print(f"\nStarting VERY SLOW AND LONG stress test: sending {num_messages} messages from device 1 (port {PORTS[0]})...")
    
    start_time = time.time()
    
    import threading
    
    # We will poll aggressively in a background thread to measure latency accurately
    keep_polling = True
    def poll_messages():
        while keep_polling:
            msgs = get_all_messages()
            now = time.time()
            for p, m_list in msgs.items():
                for m in m_list:
                    mid = m['msgId']
                    text = m['textContent']
                    if mid not in seen_message_ids[p]:
                        seen_message_ids[p].add(mid)
                        if text in send_times and text not in arrival_times[p]:
                            arrival_times[p][text] = now
            time.sleep(0.5)

    poller = threading.Thread(target=poll_messages)
    poller.start()
    
    def print_progress_bar(iteration, total, prefix='', suffix='', decimals=1, length=40, fill='█', printEnd="\r"):
        percent = ("{0:." + str(decimals) + "f}").format(100 * (iteration / float(total)))
        filledLength = int(length * iteration // total)
        bar = fill * filledLength + '-' * (length - filledLength)
        sys.stdout.write(f'\r{prefix} |{bar}| {percent}% {suffix}')
        sys.stdout.flush()
        if iteration == total:
            print()

    for i in range(num_messages):
        msg = f"Ultra steady test message {i} @ {int(time.time()*1000)}"
        send_times[msg] = time.time()
        
        # Device 1 is the sender, so it technically "arrives" instantly
        arrival_times[PORTS[0]][msg] = send_times[msg]
        
        request(PORTS[0], '/send', 'POST', {'text': msg})
            
        print_progress_bar(i + 1, num_messages, prefix='Sending:', suffix=f'({i+1}/{num_messages})')
        # Slow down significantly to allow mesh synchronization to finish 
        # before the next message triggers an advertising cycle.
        time.sleep(3.0)
        
    print("\nSend complete. Waiting for final propagation across mesh...")
    
    # Wait for propagation - needs to be longer than the send phase (num_messages * 3s)
    max_wait_secs = max(60, num_messages * 3)
    poll_start = time.time()
    last_counts = {}
    
    while time.time() - poll_start < max_wait_secs:
        counts = {p: len(arrival_times[p]) for p in infos.keys()}
        
        # Display progress based on overall mesh convergence
        total_delivered = sum(counts.values())
        total_expected = num_messages * len(infos)
        
        elapsed_sync = time.time() - poll_start
        remaining = max(0, int(max_wait_secs - elapsed_sync))
        
        print_progress_bar(total_delivered, total_expected, prefix='Syncing:', suffix=f'{total_delivered}/{total_expected} events [Timeout in {remaining}s]')

        if counts != last_counts:
            # We'll print details on a new line if something changed, 
            # then the next loop iteration will redraw the progress bar on a fresh line if we're not careful.
            # Actually, let's just keep the progress bar clean.
            last_counts = counts.copy()
        
        if all(count == num_messages for count in counts.values()):
            print("\n\n[SUCCESS] All messages synced to all devices!")
            break
            
        time.sleep(1)
        
    keep_polling = False
    poller.join()
    
    # Calculate Average Latency
    print("\n--- RESULTS ---")
    for p in PORTS:
        if p == PORTS[0]:
            continue # skip sender
            
        latencies = []
        for text, stime in send_times.items():
            if text in arrival_times[p]:
                latencies.append(arrival_times[p][text] - stime)
                
        if len(latencies) > 0:
            avg = sum(latencies) / len(latencies)
            print(f"Device on port {p}: received {len(latencies)}/{num_messages} messages. Avg Latency: {avg:.2f} seconds.")
        else:
            print(f"Device on port {p}: received 0 messages.")

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
