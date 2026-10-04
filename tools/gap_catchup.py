"""Measure how fast phones heal a gap in their chat history.

The stress test measures live latency. This one measures the other half of
sync: a phone that comes back holding only part of the history (it was off,
out of range, or lost rows) and has to catch up from its neighbours.

For each *lagging* phone the script stops the app, copies the SQLite file off
the phone, deletes some live room messages, pushes it back and restarts the
app. It then polls every phone's `/messages` count until each one is back at
the full history, and reports how long that took.

Two shapes of gap are supported:

* ``oldest``  - the lagging phone is missing the oldest messages. Its newest
  rows are current, so the version vectors see nothing wrong and only the
  fingerprints can find the hole.
* ``scatter`` - random messages are missing, holes below the frontier too.

With three or more phones, pass several ``--lagging`` serials: each gets a
different gap (disjoint blocks in ``oldest`` mode), so the phones also have to
heal each other, and a phone that is already complete must stay complete.

Every phone must already hold the same history. Seed that with
``python stress_test.py --messages N --devices SERIAL_A,SERIAL_B``. The run
fails if a complete phone loses messages, or if any phone is still short of
the starting count when ``--timeout-s`` elapses. ``--summary-json`` writes
the report.

Usage (from the repository root)::

    python -m tools.gap_catchup --devices A,B --lagging B
    python -m tools.gap_catchup --devices A,B,C --lagging B,C --gap 300 --mode scatter --summary-json gap.json

Phones need the debug build running (it serves the local test API).
The choices above are covered by ``python -m unittest tools.test_gap_catchup``.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.request
from dataclasses import dataclass, field

PACKAGE = "com.bregger.edison.meshenger"
DB_PATH = "app_flutter/mesh_network.db"
REMOTE_TMP = "/data/local/tmp/gap_catchup.db"
LIVE_ROOM_MESSAGES = (
    "is_deleted = 0 AND COALESCE(conversation_id, '') = '' "
    "AND text_content != ''"
)


# ---------------------------------------------------------------------------
# Pure logic (unit tested)
# ---------------------------------------------------------------------------


def choose_gap_ids(rows, count, mode, seed=0, block_index=0):
    """Pick which message ids a lagging phone should lose.

    ``rows`` is a list of ``(msg_id, hlc)``. In ``oldest`` mode the lagging
    phone loses a block of the oldest rows; ``block_index`` shifts the block so
    several lagging phones miss different rows. In ``scatter`` mode the rows
    are random but reproducible from ``seed``.
    """
    if count <= 0:
        return []
    ordered = sorted(rows, key=lambda row: (row[1], row[0]))
    if mode == "oldest":
        start = block_index * count
        return [msg_id for msg_id, _ in ordered[start : start + count]]
    if mode == "scatter":
        rng = random.Random(seed + block_index)
        ids = [msg_id for msg_id, _ in ordered]
        return rng.sample(ids, min(count, len(ids)))
    raise ValueError(f"unknown gap mode: {mode}")


def parse_message_count(payload):
    """Number of messages in a `/messages` response (list or {messages: []})."""
    if isinstance(payload, dict):
        payload = payload.get("messages", [])
    return len(payload) if isinstance(payload, list) else 0


@dataclass
class DeviceRun:
    serial: str
    lagging: bool
    start_count: int = 0
    full_at_s: float | None = None
    min_count: int | None = None
    samples: list = field(default_factory=list)  # (seconds, count)

    def record(self, seconds, count, target):
        self.samples.append((round(seconds, 1), count))
        self.min_count = count if self.min_count is None else min(self.min_count, count)
        if self.full_at_s is None and count >= target:
            self.full_at_s = round(seconds, 1)


def summarize(runs, target, timeout_s):
    """Pass/fail verdict plus the numbers worth printing."""
    problems = []
    devices = []
    for run in runs:
        lost = (
            not run.lagging
            and run.min_count is not None
            and run.min_count < target
        )
        if lost:
            problems.append(
                f"{run.serial} was complete but dropped to {run.min_count}"
            )
        if run.full_at_s is None:
            problems.append(f"{run.serial} never reached {target} messages")
        rate = None
        if run.lagging and run.full_at_s:
            rate = round((target - run.start_count) / run.full_at_s, 2)
        devices.append(
            {
                "serial": run.serial,
                "lagging": run.lagging,
                "start_count": run.start_count,
                "full_at_s": run.full_at_s,
                "rows_per_s": rate,
                "min_count": run.min_count,
            }
        )
    done = [r.full_at_s for r in runs if r.full_at_s is not None]
    return {
        "target": target,
        "timeout_s": timeout_s,
        "passed": not problems,
        "problems": problems,
        "all_full_at_s": max(done) if len(done) == len(runs) else None,
        "devices": devices,
    }


# ---------------------------------------------------------------------------
# Device plumbing
# ---------------------------------------------------------------------------


def adb(serial, *args, check=True, stdout=None, timeout=60):
    return subprocess.run(
        ["adb", "-s", serial, *args],
        check=check,
        stdout=stdout if stdout is not None else subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
    )


def api_get(port, path, timeout=20):
    url = f"http://127.0.0.1:{port}{path}"
    with urllib.request.urlopen(url, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def message_count(port):
    try:
        return parse_message_count(api_get(port, "/messages"))
    except Exception:
        return None


def forward_ports(serials):
    ports = {}
    for index, serial in enumerate(serials):
        port = 18101 + index
        adb(serial, "forward", f"tcp:{port}", "tcp:8080")
        ports[serial] = port
    return ports


def wait_for_api(port, timeout_s=45):
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        try:
            api_get(port, "/info", timeout=3)
            return True
        except Exception:
            time.sleep(1)
    return False


def start_app(serial):
    adb(serial, "shell", "am", "start", "-n", f"{PACKAGE}/.MainActivity")


def stop_app(serial):
    adb(serial, "shell", "am", "force-stop", PACKAGE)


def pull_db(serial, local_path):
    with open(local_path, "wb") as handle:
        adb(
            serial, "exec-out", "run-as", PACKAGE, "cat", DB_PATH, stdout=handle
        )
    for sidecar in ("-wal", "-shm"):
        try:
            os.remove(local_path + sidecar)
        except FileNotFoundError:
            pass


def push_db(serial, local_path):
    adb(serial, "push", local_path, REMOTE_TMP)
    adb(
        serial,
        "shell",
        f"run-as {PACKAGE} cp {REMOTE_TMP} {DB_PATH}; "
        f"run-as {PACKAGE} rm -f {DB_PATH}-wal {DB_PATH}-shm",
    )


def punch_gap(local_path, count, mode, seed, block_index):
    """Delete the chosen live room messages from a pulled database copy."""
    connection = sqlite3.connect(local_path)
    try:
        rows = connection.execute(
            f"SELECT msg_id, hlc FROM messages WHERE {LIVE_ROOM_MESSAGES}"
        ).fetchall()
        ids = choose_gap_ids(rows, count, mode, seed, block_index)
        connection.executemany(
            "DELETE FROM messages WHERE msg_id = ?", [(i,) for i in ids]
        )
        connection.commit()
        remaining = connection.execute(
            f"SELECT COUNT(*) FROM messages WHERE {LIVE_ROOM_MESSAGES}"
        ).fetchone()[0]
        return len(ids), remaining
    finally:
        connection.close()


# ---------------------------------------------------------------------------
# The run
# ---------------------------------------------------------------------------


def run_test(args):
    serials = [s.strip() for s in args.devices.split(",") if s.strip()]
    lagging = [s.strip() for s in args.lagging.split(",") if s.strip()]
    if len(serials) < 2:
        raise SystemExit("need at least two devices")
    unknown = [s for s in lagging if s not in serials]
    if unknown or not lagging:
        raise SystemExit("--lagging must name devices from --devices")
    if len(lagging) == len(serials):
        raise SystemExit("keep at least one complete device as the source")

    ports = forward_ports(serials)
    for serial in serials:
        if not wait_for_api(ports[serial], timeout_s=20):
            raise SystemExit(f"{serial}: test API not reachable (debug build?)")

    counts = {s: message_count(ports[s]) for s in serials}
    print("starting counts:", counts)
    target = max(c for c in counts.values() if c is not None)
    if any(c != target for c in counts.values()):
        raise SystemExit(
            "devices must start with identical histories; let them sync or "
            "seed with: python stress_test.py --messages N --devices "
            + ",".join(serials)
        )
    needed = args.gap * len(lagging) + 1
    if args.mode == "oldest" and target < needed:
        raise SystemExit(
            f"history has {target} messages; {len(lagging)} gap(s) of "
            f"{args.gap} need at least {needed}"
        )

    work = tempfile.mkdtemp(prefix="gap_catchup_")
    for index, serial in enumerate(lagging):
        stop_app(serial)
        local = os.path.join(work, f"{serial}.db")
        pull_db(serial, local)
        removed, remaining = punch_gap(
            local, args.gap, args.mode, args.seed, index
        )
        push_db(serial, local)
        print(f"{serial}: removed {removed} messages, {remaining} remain")

    runs = {s: DeviceRun(s, s in lagging) for s in serials}
    for serial in lagging:
        start_app(serial)
    for serial in lagging:
        if not wait_for_api(ports[serial]):
            raise SystemExit(f"{serial}: app did not come back")

    started = time.monotonic()
    for serial in serials:
        count = message_count(ports[serial])
        runs[serial].start_count = count if count is not None else 0

    while time.monotonic() - started < args.timeout_s:
        elapsed = time.monotonic() - started
        for serial in serials:
            count = message_count(ports[serial])
            if count is not None:
                runs[serial].record(elapsed, count, target)
        if all(r.full_at_s is not None for r in runs.values()):
            break
        time.sleep(args.poll_s)

    result = summarize(list(runs.values()), target, args.timeout_s)
    result["mode"] = args.mode
    result["gap"] = args.gap
    result["curves"] = {s: r.samples for s, r in runs.items()}
    print_report(result)
    if args.summary_json:
        with open(args.summary_json, "w", encoding="utf-8") as handle:
            json.dump(result, handle, indent=2)
    return 0 if result["passed"] else 1


def print_report(result):
    print()
    print(
        f"Gap catch-up ({result['mode']}, {result['gap']} rows per lagging "
        f"phone, target {result['target']})"
    )
    for device in result["devices"]:
        role = "lagging" if device["lagging"] else "complete"
        took = (
            f"{device['full_at_s']}s" if device["full_at_s"] is not None else "never"
        )
        rate = f", {device['rows_per_s']} rows/s" if device["rows_per_s"] else ""
        print(
            f"  {device['serial']} ({role}): {device['start_count']} -> "
            f"{result['target']} in {took}{rate}"
        )
    if result["all_full_at_s"] is not None:
        print(f"All phones complete after {result['all_full_at_s']}s")
    for problem in result["problems"]:
        print(f"  PROBLEM: {problem}")
    print("PASS" if result["passed"] else "FAIL")


def build_parser():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--devices", required=True, help="ADB serials, comma separated")
    parser.add_argument("--lagging", required=True, help="serials to punch a gap in")
    parser.add_argument("--gap", type=int, default=300, help="messages removed per lagging phone")
    parser.add_argument("--mode", choices=("oldest", "scatter"), default="oldest")
    parser.add_argument("--seed", type=int, default=1, help="scatter-mode seed")
    parser.add_argument("--timeout-s", type=float, default=300.0)
    parser.add_argument("--poll-s", type=float, default=3.0)
    parser.add_argument("--summary-json", help="write the result here")
    return parser


def main(argv=None):
    return run_test(build_parser().parse_args(argv))


if __name__ == "__main__":
    sys.exit(main())
