import base64
import socket
import struct
import tempfile
import unittest
import zlib
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
import zipfile

from tools.bluetooth_diagnostics import (
    BTSNOOP_HEADER,
    LiveBtsnoopSocketCapture,
    capture_bluetooth_diagnostics,
    count_btsnoop_records,
    decode_btsnooz,
    extract_btsnooz,
    inspect_bluetooth_snoop,
    parse_snoop_mode,
    parse_snoop_setting,
)


def make_btsnooz(version=2, packet_type=0x21):
    packet_payload = b"\x34\x12"
    last_timestamp = 1_700_000_000_000_000
    if version == 1:
        records = struct.pack("=HIb", len(packet_payload) + 1, 100, packet_type)
        records += packet_payload
    else:
        records = struct.pack(
            "=HHIb",
            len(packet_payload) + 1,
            len(packet_payload) + 1,
            100,
            packet_type,
        )
        records += packet_payload
    header = struct.pack("=bQ", version, last_timestamp)
    return header + zlib.compress(records)


class BluetoothSnoopParsingTests(unittest.TestCase):
    def test_reads_full_snoop_setting_and_unknown_state(self):
        self.assertTrue(
            parse_snoop_setting("mSnoopLogSettingAtEnable = true")
        )
        self.assertFalse(
            parse_snoop_setting("mSnoopLogSettingAtEnable = false")
        )
        self.assertTrue(
            parse_snoop_setting("sSnoopLogSettingAtEnable = FULL")
        )
        self.assertFalse(
            parse_snoop_setting("sSnoopLogSettingAtEnable = FILTERED")
        )
        self.assertFalse(
            parse_snoop_setting("sSnoopLogSettingAtEnable = EMPTY")
        )
        self.assertIsNone(parse_snoop_setting("setting unavailable"))
        self.assertEqual(
            parse_snoop_mode("sSnoopLogSettingAtEnable = EMPTY"), "empty"
        )

    def test_extracts_marked_btsnooz_block(self):
        encoded = base64.b64encode(make_btsnooz()).decode("ascii")
        report = (
            "before\n--- BEGIN:BTSNOOP_LOG_SUMMARY\n"
            + encoded
            + "\n--- END:BTSNOOP_LOG_SUMMARY\nafter\n"
        )
        self.assertEqual(extract_btsnooz(report), make_btsnooz())

    def test_decodes_v1_and_v2_to_standard_btsnoop(self):
        for version in (1, 2):
            with self.subTest(version=version):
                snoop = decode_btsnooz(make_btsnooz(version=version))
                self.assertTrue(snoop.startswith(BTSNOOP_HEADER))
                self.assertEqual(count_btsnoop_records(snoop), 1)
                self.assertEqual(snoop[-3:], b"\x02\x34\x12")

    def test_marks_received_packets_as_inbound(self):
        snoop = decode_btsnooz(make_btsnooz(packet_type=0x11))
        flags = struct.unpack_from(">I", snoop, len(BTSNOOP_HEADER) + 8)[0]
        self.assertEqual(flags, 1)

    def test_rejects_malformed_btsnooz(self):
        with self.assertRaisesRegex(ValueError, "no BTSNOOP_LOG_SUMMARY"):
            extract_btsnooz("no snoop section")
        with self.assertRaisesRegex(ValueError, "truncated"):
            decode_btsnooz(b"short")

    def test_preflight_records_full_snoop_and_root_status(self):
        outputs = [
            SimpleNamespace(
                returncode=0,
                stdout="mSnoopLogSettingAtEnable = true\n",
                stderr="",
            ),
            SimpleNamespace(returncode=0, stdout="0\n", stderr=""),
        ]
        with patch(
            "tools.bluetooth_diagnostics.subprocess.run",
            side_effect=outputs,
        ):
            state = inspect_bluetooth_snoop("rooted-pixel")

        self.assertIs(state["full_hci_snoop_enabled"], True)
        self.assertEqual(state["root_access"], "granted")
        self.assertEqual(state["setting_source"], "dumpsys")

    def test_preflight_falls_back_to_android_17_snoop_property(self):
        outputs = [
            SimpleNamespace(returncode=1, stdout="", stderr=""),
            SimpleNamespace(returncode=0, stdout="full\n", stderr=""),
            SimpleNamespace(returncode=0, stdout="0\n", stderr=""),
        ]
        with patch(
            "tools.bluetooth_diagnostics.subprocess.run",
            side_effect=outputs,
        ):
            state = inspect_bluetooth_snoop("android-17-pixel")

        self.assertIs(state["full_hci_snoop_enabled"], True)
        self.assertEqual(state["hci_snoop_mode_at_enable"], "full")
        self.assertEqual(state["setting_source"], "system_property")
        self.assertIsNone(state["setting_error"])
        self.assertEqual(state["root_access"], "granted")

    def test_preflight_recognizes_android_17_live_socket_when_mode_is_hidden(self):
        outputs = [
            SimpleNamespace(returncode=1, stdout="", stderr=""),
            SimpleNamespace(returncode=0, stdout="", stderr=""),
            SimpleNamespace(returncode=1, stdout="", stderr="permission denied"),
        ]
        with (
            patch("tools.bluetooth_diagnostics.subprocess.run", side_effect=outputs),
            patch(
                "tools.bluetooth_diagnostics.probe_bluetooth_snoop_socket",
                return_value={
                    "available": True,
                    "header_valid": True,
                    "local_port": 12345,
                    "error": None,
                },
            ),
        ):
            state = inspect_bluetooth_snoop("android-17-pixel")

        self.assertIsNone(state["full_hci_snoop_enabled"])
        self.assertTrue(state["hci_snoop_socket_available"])
        self.assertTrue(state["hci_snoop_socket_header_valid"])
        self.assertEqual(state["root_access"], "denied_or_unavailable")


class BluetoothCaptureTests(unittest.TestCase):
    def test_live_socket_capture_writes_standard_btsnoop_file(self):
        record = struct.pack(">IIIIQ", 3, 3, 0, 0, 1) + b"\x04\x0e\x00"

        class FakeConnection:
            def __init__(self):
                self.data = bytearray(BTSNOOP_HEADER + record)

            def settimeout(self, _timeout):
                pass

            def recv(self, count):
                chunk = bytes(self.data[:count])
                del self.data[:count]
                if not chunk:
                    raise socket.timeout()
                return chunk

            def close(self):
                pass

        with tempfile.TemporaryDirectory() as temp_dir:
            target = Path(temp_dir) / "live.btsnoop"
            with (
                patch("tools.bluetooth_diagnostics._allocate_local_port", return_value=12345),
                patch(
                    "tools.bluetooth_diagnostics.subprocess.run",
                    return_value=SimpleNamespace(returncode=0, stdout="", stderr=""),
                ),
                patch(
                    "tools.bluetooth_diagnostics.socket.create_connection",
                    return_value=FakeConnection(),
                ),
            ):
                capture = LiveBtsnoopSocketCapture("android-17-pixel", target).start()
                result = capture.stop()

        self.assertEqual(result["packets"], 1)
        self.assertEqual(result["bytes"], len(BTSNOOP_HEADER) + len(record))
        self.assertIsNone(result["error"])

    def test_bugreport_capture_saves_only_decoded_snoop_artifact(self):
        snooz = make_btsnooz()
        report_text = (
            "--- BEGIN:BTSNOOP_LOG_SUMMARY\n"
            + base64.b64encode(snooz).decode("ascii")
            + "\n--- END:BTSNOOP_LOG_SUMMARY\n"
        )

        def fake_adb(command, **kwargs):
            bugreport_path = Path(command[-1])
            with zipfile.ZipFile(bugreport_path, "w") as archive:
                archive.writestr("bugreport.txt", report_text)
            return type("Completed", (), {"returncode": 0, "stdout": "", "stderr": ""})()

        with tempfile.TemporaryDirectory() as temp_dir:
            with patch("tools.bluetooth_diagnostics.subprocess.run", side_effect=fake_adb):
                result = capture_bluetooth_diagnostics(
                    "test-device",
                    temp_dir,
                    root_access="denied_or_unavailable",
                )

            self.assertEqual(len(result["artifacts"]), 1)
            artifact = result["artifacts"][0]
            self.assertEqual(artifact["scope"], "in_memory_summary")
            self.assertEqual(artifact["packets"], 1)
            self.assertTrue(Path(artifact["path"]).is_file())
            self.assertEqual(result["errors"], [])


if __name__ == "__main__":
    unittest.main()
