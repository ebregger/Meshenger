import statistics
import math

from tools.stress_console import format_data_rate


def mean_latency_confidence(values, target_precision_s=0.01):
    """Return a large-sample 95% CI and iid sample-size estimate for latency."""
    if len(values) < 30:
        return None
    if target_precision_s <= 0:
        raise ValueError("target_precision_s must be positive")

    mean = statistics.mean(values)
    sample_sd = statistics.stdev(values)
    margin = 1.96 * sample_sd / math.sqrt(len(values))
    target_samples = max(
        30,
        math.ceil((1.96 * sample_sd / target_precision_s) ** 2),
    )
    return {
        "n": len(values),
        "mean": mean,
        "sample_sd": sample_sd,
        "margin": margin,
        "low": mean - margin,
        "high": mean + margin,
        "target_precision_s": target_precision_s,
        "target_samples": target_samples,
    }


def print_run_summary(stream, result, details_path):
    sent = result["sent_messages"]
    completed = result["completed_at"]
    status = result["status"]
    latencies = [
        (
            completed[item["tag"]] - item["sent_at"],
            item,
            completed[item["tag"]],
        )
        for item in sent
        if item["tag"] in completed
    ]
    latencies.sort(key=lambda entry: entry[0])
    values = [entry[0] for entry in latencies]
    elapsed = max(status.get("elapsed_s", 0.0), 0.001)
    propagated = status.get("propagated", 0)
    message_rate = propagated / elapsed
    data_rate = format_data_rate(
        status.get("transferred_bytes", 0) / elapsed
    )

    stream.write("\nOverall\n")
    stream.write(
        f"  Messages: {propagated}/{len(sent)} in {elapsed:.2f}s\n"
        f"  Throughput: {message_rate:.2f} msg/s | {data_rate}\n"
    )
    if values:
        mean = statistics.mean(values)
        p50 = _percentile(values, 0.50)
        p95 = _percentile(values, 0.95)
        stream.write(
            f"  Latency: avg {mean:.2f}s | p50 {p50:.2f}s | "
            f"p95 {p95:.2f}s | max {max(values):.2f}s\n"
        )

        if len(values) == len(sent):
            confidence = mean_latency_confidence(values)
            if confidence is not None:
                confidence_text = (
                    "  Mean latency 95% CI (normal approximation): "
                    f"[{confidence['low']:.2f}, {confidence['high']:.2f}]s "
                    f"(n={confidence['n']}, margin ±{confidence['margin']:.2f}s)\n"
                    f"  At observed SD {confidence['sample_sd']:.2f}s, "
                    f"±0.01s would need about {confidence['target_samples']:,} "
                    "independent messages.\n"
                    "  CI is for host-observed completion; 2s UI polling and "
                    "within-run BLE correlation limit its interpretation.\n"
                )
                stream.write(confidence_text)
                with open(details_path, "a", encoding="utf-8") as details:
                    details.write("\nHost-observed latency confidence\n")
                    details.write(confidence_text)
            else:
                stream.write("  Mean latency 95% CI: unavailable (need 30+ samples)\n")
        else:
            stream.write(
                "  Mean latency 95% CI: unavailable (some messages were "
                "unresolved)\n"
            )

        threshold = max(5.0, mean + 3 * statistics.pstdev(values))
        outliers = [entry for entry in latencies if entry[0] > threshold]
        stream.write(
            f"  Reliability: {result['connection_failures']} connection failures | "
            f"{result['penalty_entries']} penalty entries\n"
        )
        if outliers:
            stream.write(
                f"\nOutliers ({len(outliers)} above {threshold:.2f}s)\n"
            )
            for latency, item, completed_time in sorted(
                outliers, key=lambda entry: entry[0], reverse=True
            )[:10]:
                sender = item["sender_device"][-6:]
                receivers = ",".join(
                    device[-6:]
                    for device in result["all_devices"]
                    if device != item["sender_device"]
                )
                if completed_time > result["sending_finished_at"]:
                    tail = completed_time - result["sending_finished_at"]
                    reason = f"recovered by tail catch-up (+{tail:.2f}s)"
                else:
                    reason = "caught up during the live burst"
                short_tag = item["tag"].split("@", 1)[0]
                stream.write(
                    f"  {short_tag} {sender}→{receivers}: "
                    f"{latency:.2f}s — {reason}\n"
                )
            if len(outliers) > 10:
                stream.write(f"  …and {len(outliers) - 10} more\n")
        else:
            stream.write("\nOutliers: none\n")

    unresolved = len(sent) - propagated
    if unresolved:
        stream.write(f"\nUnresolved at timeout: {unresolved}\n")
    stream.write(f"\nDetails: {details_path}\n")
    stream.flush()


def _percentile(values, fraction):
    index = round((len(values) - 1) * fraction)
    return values[index]
