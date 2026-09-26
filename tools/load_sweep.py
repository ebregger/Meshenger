"""Run the stress benchmark at progressively higher offered message rates.

Run from the repository root with:
    python -m tools.load_sweep --messages 60 --ports 18081,18082
"""

import argparse
import json
import math
from pathlib import Path
import subprocess
import sys
import time

from stress_test import parse_ports_arg


ROOT = Path(__file__).resolve().parents[1]
STRESS_TEST = ROOT / "stress_test.py"


def parse_intervals(value):
    """Parse positive send intervals in seconds, preserving sweep order."""
    try:
        intervals = [float(part.strip()) for part in value.split(",") if part.strip()]
    except ValueError as error:
        raise ValueError("intervals must be comma-separated seconds") from error
    if not intervals or any(not math.isfinite(item) or item <= 0 for item in intervals):
        raise ValueError("provide one or more finite, positive intervals")
    return intervals


def build_stress_command(
    messages,
    interval_s,
    details_path,
    summary_path,
    ports=None,
    message_timeout_s=90.0,
    poll_interval_s=2.0,
    sender_port=None,
):
    """Create the child command for a single independent burst run."""
    command = [
        sys.executable,
        str(STRESS_TEST),
        "--profile",
        "burst",
        "--messages",
        str(messages),
        "--send-interval-s",
        str(interval_s),
        "--message-timeout-s",
        str(message_timeout_s),
        "--poll-interval-s",
        str(poll_interval_s),
        "--details-file",
        str(details_path),
        "--summary-json",
        str(summary_path),
    ]
    if ports:
        command.extend(("--ports", ",".join(str(port) for port in ports)))
    if sender_port is not None:
        command.extend(("--sender-port", str(sender_port)))
    return command


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--messages", type=int, default=60)
    parser.add_argument("--intervals-s", default="1.0,0.5,0.3,0.15")
    parser.add_argument("--ports", help="Comma-separated forwarded API ports.")
    parser.add_argument("--message-timeout-s", type=float, default=90.0)
    parser.add_argument("--poll-interval-s", type=float, default=2.0)
    parser.add_argument("--sender-port", type=int, help="Send every message from this API port.")
    parser.add_argument("--repeats", type=int, default=1, help="Repeated runs per offered rate.")
    parser.add_argument(
        "--min-delivery-ratio",
        type=float,
        default=0.99,
        help="Stop the sweep when a step falls below this full-propagation ratio.",
    )
    parser.add_argument(
        "--continue-on-failure",
        action="store_true",
        help="Keep testing later rates after a step misses the reliability gate.",
    )
    parser.add_argument("--cooldown-s", type=float, default=15.0, help="Idle time between runs.")
    parser.add_argument("--distance-m", type=float, help="Measured phone separation for this sweep.")
    parser.add_argument("--environment-label", help="Short location/interference label for the report.")
    parser.add_argument("--output-dir", default="load_sweep_runs")
    args = parser.parse_args(argv)

    try:
        intervals = parse_intervals(args.intervals_s)
        ports = parse_ports_arg(args.ports)
        if args.sender_port is not None and ports and args.sender_port not in ports:
            raise ValueError("sender port must be included in --ports")
        if args.messages <= 0:
            raise ValueError("message count must be positive")
        if args.repeats <= 0:
            raise ValueError("repeat count must be positive")
        if not math.isfinite(args.min_delivery_ratio) or not 0 < args.min_delivery_ratio <= 1:
            raise ValueError("minimum delivery ratio must be in (0, 1]")
        if not math.isfinite(args.cooldown_s) or args.cooldown_s < 0:
            raise ValueError("cooldown must be finite and nonnegative")
        if args.distance_m is not None and (
            not math.isfinite(args.distance_m) or args.distance_m < 0
        ):
            raise ValueError("distance must be finite and nonnegative")
        if not math.isfinite(args.message_timeout_s) or args.message_timeout_s <= 0:
            raise ValueError("message timeout must be finite and positive")
        if not math.isfinite(args.poll_interval_s) or args.poll_interval_s <= 0:
            raise ValueError("poll interval must be finite and positive")
    except ValueError as error:
        parser.error(str(error))

    output_dir = Path(args.output_dir)
    if not output_dir.is_absolute():
        output_dir = ROOT / output_dir
    run_stamp = time.strftime("%Y%m%d_%H%M%S") + f"_{time.time_ns() % 1_000_000_000:09d}"
    run_dir = output_dir / run_stamp
    run_dir.mkdir(parents=True, exist_ok=True)

    results = []
    stop_reason = None
    planned_runs = [
        (index, interval_s, repeat)
        for index, interval_s in enumerate(intervals, start=1)
        for repeat in range(1, args.repeats + 1)
    ]
    for plan_index, (index, interval_s, repeat) in enumerate(planned_runs):
        if stop_reason is not None and not args.continue_on_failure:
            results.append({
                "interval_s": interval_s,
                "repeat": repeat,
                "success": False,
                "skipped": True,
                "skip_reason": stop_reason,
                "distance_m": args.distance_m,
                "environment_label": args.environment_label,
            })
            continue

        stem = f"load_{index:02d}_{interval_s:g}s_repeat_{repeat:02d}"
        details_path = run_dir / f"{stem}.log"
        summary_path = run_dir / f"{stem}.json"
        command = build_stress_command(
            args.messages,
            interval_s,
            details_path,
            summary_path,
            ports,
            args.message_timeout_s,
            args.poll_interval_s,
            args.sender_port,
        )
        offered_rate = 1.0 / interval_s
        print(
            f"\n=== Load step {index}/{len(intervals)}, repeat {repeat}/{args.repeats}: "
            f"{interval_s:g}s spacing (~{offered_rate:.2f} offered msg/s) ===",
            flush=True,
        )
        completed = subprocess.run(command, cwd=ROOT, check=False)

        if summary_path.exists():
            with summary_path.open(encoding="utf-8") as summary_file:
                summary = json.load(summary_file)
            summary["interval_s"] = interval_s
            summary["repeat"] = repeat
            summary["child_exit_code"] = completed.returncode
            summary["benchmark_success"] = bool(summary.get("success"))
            total = summary.get("messages_sent", args.messages)
            delivered = summary.get("messages_delivered", 0)
            send_failures = summary.get("send_failures", 0)
            delivery_ratio = delivered / total if total else 0.0
            summary["delivery_ratio"] = delivery_ratio
            summary["success"] = (
                delivery_ratio >= args.min_delivery_ratio and send_failures == 0
            )
        else:
            summary = {
                "interval_s": interval_s,
                "repeat": repeat,
                "success": False,
                "delivery_ratio": 0.0,
                "child_exit_code": completed.returncode,
                "error": "stress runner did not write a summary",
            }
        summary["min_delivery_ratio"] = args.min_delivery_ratio
        summary["distance_m"] = args.distance_m
        summary["environment_label"] = args.environment_label
        results.append(summary)

        if not summary["success"]:
            stop_reason = (
                f"step {index} repeat {repeat} achieved "
                f"{summary.get('delivery_ratio', 0.0):.1%} delivery "
                f"(gate {args.min_delivery_ratio:.1%})"
            )
            print(f"\nReliability gate failed: {stop_reason}", flush=True)
        if (
            args.cooldown_s > 0
            and plan_index + 1 < len(planned_runs)
            and (summary["success"] or args.continue_on_failure)
        ):
            print(f"Cooling down for {args.cooldown_s:g}s before the next run.", flush=True)
            time.sleep(args.cooldown_s)

    aggregate_path = run_dir / "sweep_summary.json"
    with aggregate_path.open("w", encoding="utf-8") as summary_file:
        json.dump(results, summary_file, indent=2)
        summary_file.write("\n")

    print("\nLoad sweep summary")
    print("interval  repeat  offered  delivered  achieved  p50      p95      gate")
    for result in results:
        latency = result.get("latency") or {}
        delivered = result.get("messages_delivered", 0)
        total = result.get("messages_sent", args.messages)
        gate = "SKIP" if result.get("skipped") else ("PASS" if result.get("success") else "FAIL")
        print(
            f"{result['interval_s']:>7g}s  "
            f"{result.get('repeat', '-'):>6}  "
            f"{1 / result['interval_s']:>6.2f}/s  "
            f"{delivered:>4}/{total:<4}  "
            f"{result.get('throughput_msg_s', 0):>7.2f}/s  "
            f"{latency.get('p50', float('nan')):>6.2f}s  "
            f"{latency.get('p95', float('nan')):>6.2f}s  "
            f"{gate}"
        )
    print(f"Reliability gate: {args.min_delivery_ratio:.1%}; cooldown: {args.cooldown_s:g}s")
    print(f"\nRun logs and summaries: {run_dir}")
    print(f"Aggregate JSON: {aggregate_path}")
    return 0 if all(result.get("success") for result in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
