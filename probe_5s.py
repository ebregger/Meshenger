#!/usr/bin/env python3
"""Alternating 2-node propagation probe — success = both nodes have msg within 5s."""
import json
import sys
import time
import urllib.request
import urllib.parse

PORTS = [18081, 18082]
POLL_MS = 80
MAX_MS = 8000
GAP_S = 3
N = 20


def req(port, path, method="GET", body=None):
    url = f"http://127.0.0.1:{port}{path}"
    try:
        r = urllib.request.Request(url, method=method)
        if body is not None:
            r.add_header("Content-Type", "application/json")
            data = json.dumps(body).encode()
            with urllib.request.urlopen(r, data=data, timeout=10) as resp:
                return json.loads(resp.read().decode())
        with urllib.request.urlopen(r, timeout=10) as resp:
            return json.loads(resp.read().decode())
    except Exception as e:
        return {"error": str(e)}


def has_tag(port, tag):
    res = req(port, f"/has_message?text={urllib.parse.quote(tag)}")
    return bool(res and res.get("found"))


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else N
    for p in PORTS:
        req(p, "/reset_ble", "POST")
    time.sleep(2)
    # Warmup: establish mesh links before measured probes.
    for wp in range(2):
        p = PORTS[wp % 2]
        req(p, "/send", "POST", {"text": f"WARMUP{wp}"})
        time.sleep(4)
    results = []
    for i in range(n):
        sender = PORTS[i % 2]
        tag = f"Q{i:03d}_{int(time.time() * 1000)}"
        t0 = time.time()
        send = req(sender, "/send", "POST", {"text": tag})
        if not send or send.get("error"):
            results.append({"i": i, "ok": False, "ms": None, "sender": sender})
            print(f"  [{i + 1}/{n}] SEND FAIL port={sender}")
            time.sleep(GAP_S)
            continue
        ms = None
        deadline = t0 + MAX_MS / 1000
        while time.time() < deadline:
            if has_tag(18081, tag) and has_tag(18082, tag):
                ms = int((time.time() - t0) * 1000)
                break
            time.sleep(POLL_MS / 1000)
        ok = ms is not None and ms <= 5000
        results.append({"i": i, "ok": ok, "ms": ms, "sender": sender})
        status = "OK" if ok else ("SLOW" if ms else "FAIL")
        print(f"  [{i + 1}/{n}] {status} sender={sender} ms={ms}")
        time.sleep(GAP_S)

    ok_count = sum(1 for r in results if r["ok"])
    under5 = [r["ms"] for r in results if r["ms"] is not None and r["ms"] <= 5000]
    clear = [r for r in results if r["sender"] == 18081]
    red = [r for r in results if r["sender"] == 18082]
    print("\n=== SUMMARY ===")
    print(f"OK under 5s: {ok_count}/{n}")
    print(f"Clear sends OK: {sum(1 for r in clear if r['ok'])}/{len(clear)}")
    print(f"Red sends OK: {sum(1 for r in red if r['ok'])}/{len(red)}")
    if under5:
        print(
            f"Avg when OK: {sum(under5) / len(under5):.0f}ms "
            f"min={min(under5)} max={max(under5)}"
        )
    bad = [r for r in results if not r["ok"]]
    if bad:
        print("Failures:", bad)
    sys.exit(0 if ok_count == n else 1)


if __name__ == "__main__":
    main()
