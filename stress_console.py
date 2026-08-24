import sys
import time
import shutil
from collections import defaultdict


class DetailLog:
    """Redirect verbose benchmark output while preserving a clean console."""

    def __init__(self, path):
        self.path = path
        self.console = sys.stdout
        self._file = None

    def __enter__(self):
        self._file = open(self.path, "w", encoding="utf-8", buffering=1)
        sys.stdout = self._file
        return self

    def __exit__(self, exc_type, exc, traceback):
        sys.stdout = self.console
        if self._file is not None:
            self._file.close()


class ProgressDisplay:
    def __init__(self, stream=None, width=28):
        self.stream = stream or sys.__stdout__
        self.max_bar_width = width
        self._visible = False
        self._last_length = 0

    def message(self, text):
        self._write(text)

    def render(self, phase, current, total, status):
        avg_ms = status.get("average_latency_ms")
        latency = "—" if avg_ms is None else f"{avg_ms / 1000:.2f}s"
        elapsed = max(status.get("elapsed_s", 0.0), 0.001)
        message_rate = status.get("propagated", 0) / elapsed
        data_rate = format_data_rate(
            status.get("transferred_bytes", 0) / elapsed
        )
        lag = status.get("behind_by_path", {})
        total_behind = sum(count for count in lag.values() if count > 0)
        metrics = (
            f"{current}/{total} | lat {latency} | {message_rate:.2f} msg/s "
            f"| {data_rate}"
        )
        if total_behind:
            metrics += f" | behind {total_behind}"

        columns = max(40, shutil.get_terminal_size((100, 20)).columns - 1)
        fixed_width = len(phase[:4]) + len(metrics) + 4
        bar_width = max(4, min(self.max_bar_width, columns - fixed_width))
        ratio = min(1.0, current / total) if total else 1.0
        filled = round(bar_width * ratio)
        bar = "█" * filled + "░" * (bar_width - filled)
        text = f"{phase[:4]:<4} [{bar}] {metrics}"
        self._write(text)

    def finish(self, text):
        self._write(text)
        self.stream.write("\n")
        self.stream.flush()
        self._visible = False
        self._last_length = 0

    def _write(self, text):
        columns = max(40, shutil.get_terminal_size((100, 20)).columns - 1)
        text = text[:columns]
        padding = " " * max(0, self._last_length - len(text))
        self.stream.write(f"\r{text}{padding}")
        self.stream.flush()
        self._visible = True
        self._last_length = len(text)


def format_data_rate(bytes_per_second):
    units = ("B/s", "KB/s", "MB/s", "GB/s")
    value = float(bytes_per_second)
    for unit in units:
        if value < 1024 or unit == units[-1]:
            return f"{value:.2f} {unit}"
        value /= 1024


def poll_ui_status(
    request,
    ports,
    port_to_device,
    sent_messages,
    receipt_matrix,
    completed_at,
    started_at,
):
    device_messages = {}
    total_bytes = 0
    for port in ports:
        result = request(port, "/ui")
        if not isinstance(result, dict):
            continue
        messages = result.get("messages") or []
        total_bytes += len(str(messages).encode("utf-8"))
        device_messages[port_to_device.get(port, str(port))] = {
            (m.get("textContent") or m.get("text") or m.get("body") or "")
            for m in messages
            if isinstance(m, dict)
        }

    fully_propagated = 0
    sent_count = defaultdict(int)
    for sent in sent_messages:
        sender = sent["sender_device"]
        sent_count[sender] += 1
        receivers = 0
        for device, texts in device_messages.items():
            if device != sender and sent["tag"] in texts:
                receipt_matrix[sender][device].add(sent["tag"])
                receivers += 1
        if receivers >= len(ports) - 1:
            fully_propagated += 1
            completed_at.setdefault(sent["tag"], time.time())

    behind = {}
    devices = sorted(port_to_device.values())
    for sender in devices:
        for receiver in devices:
            if sender == receiver:
                continue
            count = sent_count[sender] - len(receipt_matrix[sender][receiver])
            if count > 0:
                behind[f"{sender[-6:]}→{receiver[-6:]}"] = count

    latencies = [
        completed_at[sent["tag"]] - sent["sent_at"]
        for sent in sent_messages
        if sent["tag"] in completed_at
    ]
    return {
        "propagated": fully_propagated,
        "average_latency_ms": (
            sum(latencies) * 1000 / len(latencies) if latencies else None
        ),
        "elapsed_s": time.time() - started_at,
        "behind_by_path": behind,
        "total_kb": total_bytes / 1024,
    }
