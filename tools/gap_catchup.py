"""Measure how fast phones heal a gap in their chat history.

The stress test measures live latency. This one measures the other half of
sync: a phone that comes back holding only part of the history (it was off,
out of range, or lost rows) and has to catch up from its neighbours.

For each *lagging* phone the script stops the app, copies the SQLite file off
the phone, deletes some live room messages, pushes it back and restarts the
app. It then polls every phone's exact `/messages` IDs until each one is back at
the full history, and reports how long that took.

Two shapes of gap are supported:

* ``oldest``  - the lagging phone is missing the oldest messages. Its newest
  rows are current, so the version vectors see nothing wrong and only the
  fingerprints can find the hole.
* ``scatter`` - random messages are missing, holes below the frontier too.

With three or more phones, pass several ``--lagging`` serials: each gets a
different gap (disjoint blocks in ``oldest`` mode), so the phones also have to
heal each other, and a phone that is already complete must stay complete.

Only the disposable `.benchmark` app is modified. Every phone must already
hold the same history. Seed that with
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
import hashlib
import json
import os
import random
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.request
from dataclasses import dataclass, field

PACKAGE = "com.bregger.edison.meshenger.benchmark"
ACTIVITY = "com.bregger.edison.meshenger.MainActivity"
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


def parse_message_ids(payload):
    """Exact live IDs, so unrelated rows cannot substitute for missing history."""
    messages = payload.get("messages") if isinstance(payload, dict) else payload
    if not isinstance(messages, list):
        raise ValueError("invalid messages response")
    return {
        row["msgId"] for row in messages
        if isinstance(row, dict) and row.get("msgId") and row.get("textContent")
    }


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


def message_ids(port):
    try:
        return parse_message_ids(api_get(port, "/messages"))
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
    adb(serial, "shell", "am", "start", "-n", f"{PACKAGE}/{ACTIVITY}")


def stop_app(serial):
    adb(serial, "shell", "am", "force-stop", PACKAGE)


def pull_db(serial, local_path):
    with open(local_path, "wb") as handle:
        adb(
            serial, "exec-out", "run-as", PACKAGE, "cat", DB_PATH, stdout=handle
        )
    # Force-stop does not guarantee a WAL checkpoint. Copy pending writes too;
    # SQLite will rebuild the shared-memory index when the local copy opens.
    wal_path = local_path + "-wal"
    with open(wal_path, "wb") as handle:
        result = adb(serial, "exec-out", "run-as", PACKAGE, "cat", DB_PATH + "-wal",
                     stdout=handle, check=False)
    if result.returncode:
        os.remove(wal_path)
        if b"No such file" not in result.stderr:
            raise RuntimeError("could not preserve the stopped app's SQLite WAL")
    connection = sqlite3.connect(local_path)
    try:
        if connection.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()[0]:
            raise RuntimeError("local database checkpoint was busy")
    finally:
        connection.close()
    for sidecar in ("-wal", "-shm"):
        try:
            os.remove(local_path + sidecar)
        except FileNotFoundError:
            pass


def push_db(serial, local_path):
    adb(serial, "push", local_path, REMOTE_TMP)
    # Check the copy separately: a succeeding sidecar removal must not mask
    # a failed injection and turn an unchanged database into a false pass.
    adb(serial, "shell", "run-as", PACKAGE, "cp", REMOTE_TMP, DB_PATH)
    adb(serial, "shell", "run-as", PACKAGE, "rm", "-f",
        DB_PATH + "-wal", DB_PATH + "-shm")


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

    histories = {s: message_ids(ports[s]) for s in serials}
    if any(ids is None for ids in histories.values()):
        raise SystemExit("could not read every phone's history")
    expected_ids = histories[serials[0]]
    counts = {s: len(ids) for s, ids in histories.items()}
    print("starting counts:", counts)
    target = max(c for c in counts.values() if c is not None)
    if any(ids != expected_ids for ids in histories.values()):
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
    removed_by_device = {}
    for index, serial in enumerate(lagging):
        stop_app(serial)
        # Wireless ADB serials can be IP:port, which is not a Windows filename.
        local = os.path.join(work, f"device-{index}.db")
        pull_db(serial, local)
        shutil.copyfile(local, local + ".before.db")
        removed, remaining = punch_gap(
            local, args.gap, args.mode, args.seed, index
        )
        push_db(serial, local)
        removed_by_device[serial] = removed
        print(f"{serial}: removed {removed} messages, {remaining} remain")

    runs = {s: DeviceRun(s, s in lagging) for s in serials}
    for serial, run in runs.items():
        run.start_count = target - removed_by_device.get(serial, 0)
        run.record(0, run.start_count, target)
    # Include process startup and discovery instead of starting the timer only
    # after the app's API is reachable (when repair may already be underway).
    started = time.monotonic()
    for serial in lagging:
        start_app(serial)
    for serial in lagging:
        if not wait_for_api(ports[serial]):
            raise SystemExit(f"{serial}: app did not come back")

    while time.monotonic() - started < args.timeout_s:
        for serial in serials:
            ids = message_ids(ports[serial])
            if ids is not None:
                runs[serial].record(time.monotonic() - started,
                                    len(ids & expected_ids), target)
        if all(r.full_at_s is not None for r in runs.values()):
            break
        time.sleep(args.poll_s)

    result = summarize(list(runs.values()), target, args.timeout_s)
    result["mode"] = args.mode
    result["gap"] = args.gap
    result["application_id"] = PACKAGE
    result["receipt_event"] = "exact baseline message IDs present in /messages"
    result["timing_start"] = "before restarting lagging apps"
    result["history_ids_sha256"] = hashlib.sha256(
        "\n".join(sorted(expected_ids)).encode("utf-8")
    ).hexdigest()
    result["database_backups"] = work
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
