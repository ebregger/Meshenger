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
SLA_MS = 5000
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


def classify_result(result):
    """Classify a probe result using the SLA and the final catch-up check."""
    if result.get("send_failed"):
        return "SEND FAIL"
    if result.get("ms") is not None:
        return "OK" if result["ms"] <= SLA_MS else "SLOW"
    if result.get("recovered_by_end"):
        return "LATE RECOVERY"
    return "FAIL"


def warm_link(sender, receiver, attempt):
    tag = f"WARMUP_{sender}_{attempt}_{int(time.time() * 1000)}"
    sent = req(sender, "/send", "POST", {"text": tag})
    if not sent or sent.get("error"):
        return False
    deadline = time.time() + MAX_MS / 1000
    while time.time() < deadline:
        if has_tag(receiver, tag):
            return True
        time.sleep(POLL_MS / 1000)
    return False


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else N
    for p in PORTS:
        req(p, "/reset_ble", "POST")
    time.sleep(3)
    # Do not begin measurement until both held-link directions are proven.
    ready = False
    for attempt in range(1, 7):
        clear_ok = warm_link(18081, 18082, attempt)
        red_ok = warm_link(18082, 18081, attempt)
        print(f"  warmup {attempt}: clear={clear_ok} red={red_ok}")
        if clear_ok and red_ok:
            ready = True
            break
        time.sleep(1)
    if not ready:
        print("Warmup failed: bidirectional BLE link never became ready")
        sys.exit(1)
    results = []
    for i in range(n):
        sender = PORTS[i % 2]
        tag = f"Q{i:03d}_{int(time.time() * 1000)}"
        t0 = time.time()
        send = req(sender, "/send", "POST", {"text": tag})
        if not send or send.get("error"):
            results.append({
                "i": i,
                "ok": False,
                "ms": None,
                "sender": sender,
                "tag": tag,
                "send_failed": True,
            })
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
        result = {
            "i": i,
            "ok": ms is not None and ms <= SLA_MS,
            "ms": ms,
            "sender": sender,
            "tag": tag,
            "send_failed": False,
            "recovered_by_end": False,
        }
        results.append(result)
        observed_status = "TIMEOUT" if ms is None else classify_result(result)
        print(f"  [{i + 1}/{n}] {observed_status} sender={sender} ms={ms}")
        time.sleep(GAP_S)

    # The timed window has ended; recheck messages that timed out so a delayed
    # catch-up is reported separately from one that is still unresolved.
    for result in results:
        if result["send_failed"] or result["ms"] is not None:
            continue
        result["recovered_by_end"] = all(
            has_tag(port, result["tag"]) for port in PORTS
        )

    ok_count = sum(1 for r in results if r["ok"])
    slow = [r for r in results if classify_result(r) == "SLOW"]
    late = [r for r in results if classify_result(r) == "LATE RECOVERY"]
    missing = [r for r in results if classify_result(r) == "FAIL"]
    send_failures = [r for r in results if classify_result(r) == "SEND FAIL"]
    measured = [r["ms"] for r in results if r["ms"] is not None]
    clear = [r for r in results if r["sender"] == 18081]
    red = [r for r in results if r["sender"] == 18082]
    print("\n=== SUMMARY ===")
    print(f"OK under 5s: {ok_count}/{n}")
    print(f"Slow (5-8s): {len(slow)}")
    print(f"Recovered after 8s by end of run: {len(late)}")
    print(f"Still missing at end of run: {len(missing)}")
    print(f"Send failures: {len(send_failures)}")
    for result in late:
        print(f"  Late catch-up confirmed on both phones: {result['tag']}")
    for result in missing:
        print(f"  Still missing: {result['tag']}")
    print(f"Clear sends OK: {sum(1 for r in clear if r['ok'])}/{len(clear)}")
    print(f"Red sends OK: {sum(1 for r in red if r['ok'])}/{len(red)}")
    if measured:
        print(
            f"Measured propagation latency: avg={sum(measured) / len(measured):.0f}ms "
            f"min={min(measured)} max={max(measured)}"
        )
    bad = [r for r in results if classify_result(r) != "OK"]
    if bad:
        print("Non-SLA results:", bad)
    sys.exit(0 if ok_count == n else 1)


if __name__ == "__main__":
    main()
