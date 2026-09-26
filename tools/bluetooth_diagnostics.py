"""Capture Android Bluetooth snoop diagnostics for a stress run.

The BTSnooz decoder follows the AOSP btsnooz.py format and packet mappings:
https://android.googlesource.com/platform/packages/modules/Bluetooth/+/refs/heads/main/system/tools/scripts/btsnooz.py
"""

import base64
import binascii
import re
import socket
import struct
import subprocess
import threading
import tempfile
import zlib
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import zipfile


BTSNOOP_MAGIC = b"btsnoop\x00"
BTSNOOP_HEADER = b"btsnoop\x00\x00\x00\x00\x01\x00\x00\x03\xea"
BTSNOOP_LOG_BEGIN = "--- BEGIN:BTSNOOP_LOG_SUMMARY"
BTSNOOP_LOG_END = "--- END:BTSNOOP_LOG_SUMMARY"
UNIX_EPOCH_DELTA_US = 0x00DCDDB30F2F8000

_SNOOP_SETTING = re.compile(
    r"[ms]SnoopLogSettingAtEnable\s*=\s*(true|false|empty|disabled|filtered|full)",
    re.IGNORECASE,
)
_SNOOP_TYPES_TO_HCI = {
    0x20: b"\x01",  # outbound command
    0x11: b"\x02",  # inbound ACL
    0x21: b"\x02",  # outbound ACL
    0x12: b"\x03",  # inbound SCO
    0x22: b"\x03",  # outbound SCO
    0x10: b"\x04",  # inbound event
    0x17: b"\x05",  # inbound ISO
    0x2D: b"\x05",  # outbound ISO
}
_INBOUND_TYPES = {0x10, 0x11, 0x12, 0x17}


def parse_snoop_setting(output):
    """Return whether full HCI snoop was active at Bluetooth startup."""
    match = _SNOOP_SETTING.search(output or "")
    if not match:
        return None
    return match.group(1).lower() in ("true", "full")


def parse_snoop_mode(output):
    """Return the reported snoop mode, mapping legacy booleans to modes."""
    match = _SNOOP_SETTING.search(output or "")
    if not match:
        return None
    value = match.group(1).lower()
    if value == "true":
        return "full"
    if value == "false":
        return "disabled"
    return value


def extract_btsnooz(text):
    """Extract the base64 payload between BTSNOOP_LOG_SUMMARY markers."""
    start = (text or "").find(BTSNOOP_LOG_BEGIN)
    if start < 0:
        raise ValueError("bugreport has no BTSNOOP_LOG_SUMMARY block")
    start = text.find("\n", start)
    if start < 0:
        raise ValueError("BTSNOOP_LOG_SUMMARY start marker has no payload")
    end = text.find(BTSNOOP_LOG_END, start + 1)
    if end < 0:
        raise ValueError("BTSNOOP_LOG_SUMMARY end marker is missing")
    encoded = "".join(text[start + 1 : end].split())
    try:
        return base64.b64decode(encoded, validate=True)
    except (ValueError, binascii.Error) as error:
        raise ValueError(f"invalid BTSNOOP_LOG_SUMMARY base64: {error}") from error


def decode_btsnooz(payload):
    """Decode an Android BTSnooz v1/v2 stream into a standard btsnoop file."""
    if len(payload) < 9:
        raise ValueError("BTSnooz header is truncated")
    version, last_timestamp = struct.unpack_from("=bQ", payload)
    if version not in (1, 2):
        raise ValueError(f"unsupported BTSnooz version {version}")
    try:
        records = zlib.decompress(payload[9:])
    except zlib.error as error:
        raise ValueError(f"invalid BTSnooz compressed records: {error}") from error

    if version == 1:
        parsed = _parse_v1_records(records)
    else:
        parsed = _parse_v2_records(records)

    timestamp = last_timestamp + UNIX_EPOCH_DELTA_US
    for record in parsed:
        timestamp -= record["delta"]

    result = bytearray(BTSNOOP_HEADER)
    for record in parsed:
        timestamp += record["delta"]
        packet_type = record["type"]
        flags = 1 if packet_type in _INBOUND_TYPES else 0
        packet = _SNOOP_TYPES_TO_HCI.get(packet_type)
        if packet is None:
            raise ValueError(f"unsupported BTSnooz packet type 0x{packet_type:02x}")
        original_length = record["original_length"]
        included_length = len(record["payload"]) + 1
        result.extend(
            struct.pack(
                ">IIIIQ",
                original_length,
                included_length,
                flags,
                0,
                timestamp,
            )
        )
        result.extend(packet)
        result.extend(record["payload"])
    return bytes(result)


def _parse_v1_records(data):
    records = []
    offset = 0
    while offset < len(data):
        if len(data) - offset < 7:
            raise ValueError("truncated BTSnooz v1 record header")
        length, delta, packet_type = struct.unpack_from("=HIb", data, offset)
        offset += 7
        payload_length = length - 1
        if payload_length < 0 or offset + payload_length > len(data):
            raise ValueError("invalid BTSnooz v1 record length")
        records.append(
            {
                "original_length": length,
                "delta": delta,
                "type": packet_type & 0xFF,
                "payload": data[offset : offset + payload_length],
            }
        )
        offset += payload_length
    return records


def _parse_v2_records(data):
    records = []
    offset = 0
    while offset < len(data):
        if len(data) - offset < 9:
            raise ValueError("truncated BTSnooz v2 record header")
        included_length, original_length, delta, packet_type = struct.unpack_from(
            "=HHIb", data, offset
        )
        offset += 9
        payload_length = included_length - 1
        if payload_length < 0 or offset + payload_length > len(data):
            raise ValueError("invalid BTSnooz v2 record length")
        records.append(
            {
                "original_length": original_length,
                "delta": delta,
                "type": packet_type & 0xFF,
                "payload": data[offset : offset + payload_length],
            }
        )
        offset += payload_length
    return records


def count_btsnoop_records(data):
    """Count packet records in a validated standard btsnoop file."""
    if not data.startswith(BTSNOOP_HEADER):
        raise ValueError("file does not have the expected HCI btsnoop header")
    offset = len(BTSNOOP_HEADER)
    count = 0
    while offset < len(data):
        if len(data) - offset < 24:
            raise ValueError("truncated btsnoop packet header")
        included_length = struct.unpack_from(">I", data, offset + 4)[0]
        offset += 24 + included_length
        if offset > len(data):
            raise ValueError("truncated btsnoop packet data")
        count += 1
    return count


def _read_exact(connection, byte_count):
    data = bytearray()
    while len(data) < byte_count:
        chunk = connection.recv(byte_count - len(data))
        if not chunk:
            break
        data.extend(chunk)
    return bytes(data)


def _allocate_local_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def probe_bluetooth_snoop_socket(serial, timeout_s=4):
    """Verify Android's live btsnoop socket through a temporary ADB forward."""
    result = {
        "available": False,
        "header_valid": False,
        "local_port": None,
        "error": None,
    }
    local_port = _allocate_local_port()
    result["local_port"] = local_port
    forward_active = False
    try:
        forward = subprocess.run(
            ["adb", "-s", serial, "forward", f"tcp:{local_port}", "tcp:8872"],
            capture_output=True,
            text=True,
            timeout=timeout_s,
            check=False,
        )
        if forward.returncode != 0:
            result["error"] = forward.stderr.strip() or forward.stdout.strip() or "adb forward failed"
            return result
        forward_active = True
        with socket.create_connection(("127.0.0.1", local_port), timeout=timeout_s) as connection:
            connection.settimeout(timeout_s)
            header = _read_exact(connection, len(BTSNOOP_HEADER))
            result["header_valid"] = header == BTSNOOP_HEADER
            result["available"] = result["header_valid"]
            if not result["header_valid"]:
                result["error"] = (
                    f"socket returned {len(header)} bytes that do not match the btsnoop header"
                )
    except (OSError, subprocess.SubprocessError) as error:
        result["error"] = f"{type(error).__name__}: {error}"
    finally:
        if forward_active:
            subprocess.run(
                ["adb", "-s", serial, "forward", "--remove", f"tcp:{local_port}"],
                capture_output=True,
                text=True,
                timeout=timeout_s,
                check=False,
            )
    return result


class LiveBtsnoopSocketCapture:
    """Stream an Android btsnoop socket to a local standard btsnoop file."""

    def __init__(self, serial, output_path, timeout_s=5):
        self.serial = serial
        self.output_path = Path(output_path)
        self.timeout_s = timeout_s
        self.local_port = None
        self.forward_active = False
        self.connection = None
        self.output = None
        self.stop_event = threading.Event()
        self.thread = None
        self.error = None
        self.byte_count = 0
        self._write_lock = threading.Lock()
        self._stopped = False

    def start(self):
        self.output_path.parent.mkdir(parents=True, exist_ok=True)
        self.local_port = _allocate_local_port()
        forward = subprocess.run(
            ["adb", "-s", self.serial, "forward", f"tcp:{self.local_port}", "tcp:8872"],
            capture_output=True,
            text=True,
            timeout=self.timeout_s,
            check=False,
        )
        if forward.returncode != 0:
            raise RuntimeError(forward.stderr.strip() or forward.stdout.strip() or "adb forward failed")
        self.forward_active = True
        try:
            self.connection = socket.create_connection(
                ("127.0.0.1", self.local_port), timeout=self.timeout_s
            )
            self.connection.settimeout(0.5)
            header = _read_exact(self.connection, len(BTSNOOP_HEADER))
            if header != BTSNOOP_HEADER:
                raise RuntimeError(
                    f"live socket returned an invalid btsnoop header ({len(header)} bytes)"
                )
            self.output = self.output_path.open("wb")
            self.output.write(header)
            self.output.flush()
            self.byte_count = len(header)
            self.thread = threading.Thread(target=self._read_loop, daemon=True)
            self.thread.start()
            return self
        except Exception:
            self.stop()
            raise

    def _read_loop(self):
        while not self.stop_event.is_set():
            try:
                chunk = self.connection.recv(65536)
            except socket.timeout:
                continue
            except OSError as error:
                if not self.stop_event.is_set():
                    self.error = f"{type(error).__name__}: {error}"
                break
            if not chunk:
                self.error = "remote snoop socket closed"
                break
            try:
                with self._write_lock:
                    self.output.write(chunk)
                    self.output.flush()
                    self.byte_count += len(chunk)
            except OSError as error:
                self.error = f"capture write failed: {type(error).__name__}: {error}"
                break

    def stop(self):
        if self._stopped:
            return self.result()
        self._stopped = True
        self.stop_event.set()
        if self.thread is not None:
            self.thread.join(timeout=2)
        if self.connection is not None:
            try:
                self.connection.close()
            except OSError:
                pass
        if self.output is not None:
            self.output.close()
        if self.forward_active:
            try:
                subprocess.run(
                    ["adb", "-s", self.serial, "forward", "--remove", f"tcp:{self.local_port}"],
                    capture_output=True,
                    text=True,
                    timeout=self.timeout_s,
                    check=False,
                )
            except (OSError, subprocess.SubprocessError) as error:
                if self.error is None:
                    self.error = f"ADB forward cleanup failed: {type(error).__name__}: {error}"
            self.forward_active = False
        return self.result()

    def result(self):
        result = {
            "serial": self.serial,
            "path": str(self.output_path),
            "bytes": self.byte_count,
            "packets": None,
            "error": self.error,
        }
        if self.output_path.is_file():
            try:
                data = self.output_path.read_bytes()
                result["bytes"] = len(data)
                result["packets"] = count_btsnoop_records(data)
            except (OSError, ValueError) as error:
                if result["error"] is None:
                    result["error"] = f"invalid live btsnoop capture: {error}"
        else:
            result["error"] = result["error"] or "live btsnoop artifact was not created"
        return result


def inspect_bluetooth_snoop(serial, timeout_s=20):
    """Read the active full-snoop setting and whether adb su access is granted."""
    result = {
        "serial": serial,
        "full_hci_snoop_enabled": None,
        "hci_snoop_mode_at_enable": None,
        "setting_line": None,
        "setting_source": None,
        "setting_error": None,
        "hci_snoop_socket_available": False,
        "hci_snoop_socket_header_valid": False,
        "hci_snoop_socket_error": None,
        "root_access": "not_checked",
        "root_error": None,
    }
    setting_command = (
        "dumpsys bluetooth_manager | grep -m 1 -E "
        "'[ms]SnoopLogSettingAtEnable[[:space:]]*='"
    )
    try:
        setting = subprocess.run(
            ["adb", "-s", serial, "shell", setting_command],
            capture_output=True,
            text=True,
            timeout=timeout_s,
            check=False,
        )
        line = next(
            (item.strip() for item in setting.stdout.splitlines() if _SNOOP_SETTING.search(item)),
            None,
        )
        if line:
            result["setting_line"] = line
            result["setting_source"] = "dumpsys"
            result["full_hci_snoop_enabled"] = parse_snoop_setting(line)
            result["hci_snoop_mode_at_enable"] = parse_snoop_mode(line)
            if setting.returncode != 0:
                result["setting_error"] = (
                    setting.stderr.strip() or setting.stdout.strip() or "dumpsys query failed"
                )
        else:
            # Android 17 no longer exposes the snoop mode in dumpsys
            # bluetooth_manager on some builds. The Developer Options control
            # writes this property directly, so use it as a fallback.
            try:
                property_result = subprocess.run(
                    ["adb", "-s", serial, "shell", "getprop", "persist.bluetooth.btsnooplogmode"],
                    capture_output=True,
                    text=True,
                    timeout=timeout_s,
                    check=False,
                )
                mode = property_result.stdout.strip().lower()
                if property_result.returncode == 0 and mode in {
                    "empty", "disabled", "filtered", "full"
                }:
                    result["setting_line"] = f"persist.bluetooth.btsnooplogmode = {mode}"
                    result["setting_source"] = "system_property"
                    result["full_hci_snoop_enabled"] = mode == "full"
                    result["hci_snoop_mode_at_enable"] = mode
                else:
                    result["setting_error"] = (
                        property_result.stderr.strip()
                        or property_result.stdout.strip()
                        or "Bluetooth service did not report snoop mode and "
                        "persist.bluetooth.btsnooplogmode is empty or unknown"
                    )
                    socket_state = probe_bluetooth_snoop_socket(serial)
                    result["hci_snoop_socket_available"] = socket_state["available"]
                    result["hci_snoop_socket_header_valid"] = socket_state["header_valid"]
                    result["hci_snoop_socket_error"] = socket_state["error"]
            except (OSError, subprocess.TimeoutExpired) as error:
                result["setting_error"] = f"{type(error).__name__}: {error}"
    except (OSError, subprocess.TimeoutExpired) as error:
        result["setting_error"] = f"{type(error).__name__}: {error}"

    try:
        root = subprocess.run(
            ["adb", "-s", serial, "shell", "su", "-c", "id -u"],
            capture_output=True,
            text=True,
            timeout=min(timeout_s, 8),
            check=False,
        )
        if root.returncode == 0 and root.stdout.strip().splitlines()[-1:] == ["0"]:
            result["root_access"] = "granted"
        else:
            result["root_access"] = "denied_or_unavailable"
            result["root_error"] = root.stderr.strip() or root.stdout.strip() or None
    except subprocess.TimeoutExpired:
        result["root_access"] = "timeout"
        result["root_error"] = "su did not respond; check for a root authorization prompt"
    except OSError as error:
        result["root_access"] = "unavailable"
        result["root_error"] = f"{type(error).__name__}: {error}"
    return result


def capture_bluetooth_diagnostics(serial, output_dir, root_access="not_checked", timeout_s=120):
    """Save available raw snoop files or decode the snoop section in a bugreport."""
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    safe_serial = re.sub(r"[^A-Za-z0-9_.-]+", "_", serial)
    result = {
        "serial": serial,
        "root_access": root_access,
        "artifacts": [],
        "errors": [],
    }

    if root_access == "granted":
        for remote_path in (
            "/data/misc/bluetooth/logs/btsnoop_hci.log",
            "/data/misc/bluetooth/logs/btsnoop_hci.log.last",
        ):
            try:
                raw = subprocess.run(
                    [
                        "adb", "-s", serial, "exec-out", "su", "-c",
                        f"cat {remote_path}",
                    ],
                    capture_output=True,
                    timeout=15,
                    check=False,
                )
            except (OSError, subprocess.TimeoutExpired) as error:
                result["errors"].append(
                    f"root read {remote_path}: {type(error).__name__}: {error}"
                )
                continue
            if raw.returncode == 0 and raw.stdout.startswith(BTSNOOP_MAGIC):
                target = output_dir / f"{safe_serial}_full_hci.btsnoop"
                try:
                    packet_count = count_btsnoop_records(raw.stdout)
                except ValueError as error:
                    result["errors"].append(f"root read {remote_path}: {error}")
                    continue
                target.write_bytes(raw.stdout)
                result["artifacts"].append(
                    {
                        "path": str(target),
                        "source": f"root:{remote_path}",
                        "scope": "full_hci",
                        "bytes": len(raw.stdout),
                        "packets": packet_count,
                    }
                )
                return result
            if raw.returncode != 0 and raw.stderr:
                result["errors"].append(
                    f"root read {remote_path}: {raw.stderr.decode(errors='replace').strip()}"
                )

    try:
        with tempfile.TemporaryDirectory(prefix="meshenger_bugreport_") as temp_dir:
            bugreport_path = Path(temp_dir) / f"{safe_serial}_bugreport.zip"
            bugreport = subprocess.run(
                ["adb", "-s", serial, "bugreport", str(bugreport_path)],
                capture_output=True,
                text=True,
                timeout=timeout_s,
                check=False,
            )
            if bugreport.returncode != 0 or not bugreport_path.is_file():
                error = bugreport.stderr.strip() or bugreport.stdout.strip()
                result["errors"].append(
                    "adb bugreport failed: " + (error or f"exit {bugreport.returncode}")
                )
            else:
                raw_artifacts, text_reports = _read_bugreport(bugreport_path)
                for name, raw in raw_artifacts:
                    if raw.startswith(BTSNOOP_MAGIC):
                        target = output_dir / f"{safe_serial}_{_safe_stem(name)}.btsnoop"
                        try:
                            packet_count = count_btsnoop_records(raw)
                        except ValueError as error:
                            result["errors"].append(f"bugreport {name}: {error}")
                            continue
                        target.write_bytes(raw)
                        result["artifacts"].append(
                            {
                                "path": str(target),
                                "source": f"bugreport:{name}",
                                "scope": "full_hci",
                                "bytes": len(raw),
                                "packets": packet_count,
                            }
                        )
                for name, report_text in text_reports:
                    try:
                        snooz = extract_btsnooz(report_text)
                        hci = decode_btsnooz(snooz)
                        packet_count = count_btsnoop_records(hci)
                        target = output_dir / f"{safe_serial}_snoop_summary.btsnoop"
                        target.write_bytes(hci)
                        result["artifacts"].append(
                            {
                                "path": str(target),
                                "source": f"bugreport:{name}:BTSNOOP_LOG_SUMMARY",
                                "scope": "in_memory_summary",
                                "bytes": len(hci),
                                "packets": packet_count,
                            }
                        )
                        break
                    except ValueError:
                        continue
                if not result["artifacts"]:
                    result["errors"].append(
                        "bugreport contained no decodable HCI snoop file or summary"
                    )
    except (OSError, subprocess.TimeoutExpired, zipfile.BadZipFile, ValueError) as error:
        result["errors"].append(f"bugreport capture failed: {type(error).__name__}: {error}")

    if not result["artifacts"]:
        try:
            dump = subprocess.run(
                ["adb", "-s", serial, "shell", "dumpsys", "bluetooth_manager"],
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=40,
                check=False,
            )
            if dump.returncode != 0:
                raise RuntimeError(dump.stderr.strip() or "dumpsys failed")
            snooz = extract_btsnooz(dump.stdout)
            hci = decode_btsnooz(snooz)
            packet_count = count_btsnoop_records(hci)
            target = output_dir / f"{safe_serial}_snoop_summary.btsnoop"
            target.write_bytes(hci)
            result["artifacts"].append(
                {
                    "path": str(target),
                    "source": "dumpsys bluetooth_manager:BTSNOOP_LOG_SUMMARY",
                    "scope": "in_memory_summary",
                    "bytes": len(hci),
                    "packets": packet_count,
                }
            )
        except (OSError, subprocess.TimeoutExpired, RuntimeError, ValueError) as error:
            result["errors"].append(
                f"dumpsys snoop fallback failed: {type(error).__name__}: {error}"
            )
    if not result["artifacts"]:
        result["errors"].append("no decodable HCI snoop artifact was captured")
    return result


def _read_bugreport(path):
    raw_artifacts = []
    text_reports = []
    with zipfile.ZipFile(path) as archive:
        for name in archive.namelist():
            lowered = name.lower()
            if "btsnoop" in lowered and not lowered.endswith("/"):
                try:
                    raw_artifacts.append((name, archive.read(name)))
                except (KeyError, OSError, zipfile.BadZipFile):
                    continue
            elif lowered.endswith(".txt") or lowered.endswith("bugreport"):
                try:
                    content = archive.read(name)
                except (KeyError, OSError, zipfile.BadZipFile):
                    continue
                if BTSNOOP_LOG_BEGIN.encode() in content:
                    text_reports.append((name, content.decode("utf-8", errors="replace")))
    return raw_artifacts, text_reports


def _safe_stem(name):
    basename = Path(name).name
    stem = Path(basename).stem
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", stem) or "snoop"


def capture_devices_bluetooth_diagnostics(serials, output_dir, device_states):
    """Capture selected phones concurrently and return per-phone artifact metadata."""
    state_by_serial = {item["serial"]: item for item in device_states}
    with ThreadPoolExecutor(max_workers=max(1, len(serials))) as executor:
        futures = {
            serial: executor.submit(
                capture_bluetooth_diagnostics,
                serial,
                output_dir,
                state_by_serial.get(serial, {}).get("root_access", "not_checked"),
            )
            for serial in serials
        }
        return [futures[serial].result() for serial in serials]
