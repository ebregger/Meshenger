import time
import unittest
from unittest.mock import patch

import stress_test


class BenchmarkMessagePreparationTests(unittest.TestCase):
    def test_preserve_messages_does_not_clear_chat_rows(self):
        with patch("stress_test.clear_chat_messages") as clear_messages:
            stress_test.maybe_clear_chat_messages([18081, 18082, 18083], True)

        clear_messages.assert_not_called()

    def test_default_benchmark_still_clears_chat_rows(self):
        with patch("stress_test.clear_chat_messages") as clear_messages:
            stress_test.maybe_clear_chat_messages([18081, 18082])

        clear_messages.assert_called_once_with([18081, 18082])


class BenchmarkProfileSettingsTests(unittest.TestCase):
    def test_interactive_profile_defaults_to_fast_polling_and_no_spacing(self):
        self.assertEqual(
            stress_test.resolve_profile_settings("interactive"),
            (0.0, 0.1),
        )

    def test_burst_profile_keeps_existing_spacing_and_poll_interval(self):
        self.assertEqual(
            stress_test.resolve_profile_settings("burst"),
            (0.3, 2.0),
        )

    def test_rejects_invalid_profile_or_timing(self):
        for args in (
            ("unknown", None, None),
            ("interactive", -0.1, None),
            ("burst", None, 0.0),
            ("burst", float("nan"), None),
            ("interactive", None, float("inf")),
        ):
            with self.subTest(args=args), self.assertRaises(ValueError):
                stress_test.resolve_profile_settings(*args)


class MeshPeerPreflightTests(unittest.TestCase):
    def test_two_selected_phones_form_mesh_when_each_sees_the_other_recently(self):
        node_ids_by_port = {18081: "node-a", 18082: "node-b"}
        port_to_device = {18081: "pixel-3", 18082: "pixel-9"}
        now_ms = int(time.time() * 1000)

        def requester(port, _path):
            peer_id = node_ids_by_port[18082 if port == 18081 else 18081]
            return {
                "peers": [
                    {
                        "id": peer_id,
                        "status": "direct",
                        "lastSeenMs": now_ms,
                        "rssiDbm": -50,
                        "rssiSeenMs": now_ms,
                    }
                ]
            }

        result = stress_test.wait_for_mesh_peer_visibility(
            requester,
            [18081, 18082],
            port_to_device,
            node_ids_by_port,
        )

        self.assertTrue(result["ready"])
        self.assertEqual(result["reason"], "selected_nodes_form_connected_mesh")
        self.assertEqual(result["connected_component_count"], 1)

    def test_reports_scanner_error_before_starting_message_run(self):
        result = stress_test.wait_for_mesh_peer_visibility(
            lambda _port, _path: {"peers": []},
            [18081, 18082],
            {18081: "pixel-3", 18082: "pixel-9"},
            {18081: "node-a", 18082: "node-b"},
            scanner_errors=lambda: [{"device": "pixel-3", "message": "scanner failed"}],
        )

        self.assertFalse(result["ready"])
        self.assertEqual(result["reason"], "scanner_error")
        self.assertEqual(result["scanner_errors"][0]["device"], "pixel-3")

    def test_rejects_nonfinite_message_timeout_before_device_access(self):
        for timeout in (float("nan"), float("inf")):
            with self.subTest(timeout=timeout), self.assertRaises(ValueError):
                stress_test.run_benchmark(message_timeout_s=timeout)

    def test_parses_two_or_more_unique_forward_ports(self):
        self.assertEqual(
            stress_test.parse_ports_arg("18081, 18083"),
            [18081, 18083],
        )
        self.assertIsNone(stress_test.parse_ports_arg(None))

    def test_rejects_duplicate_or_single_port_selection(self):
        for value in ("18081", "18081,18081", "not-a-port"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                stress_test.parse_ports_arg(value)

    def test_parses_two_or_more_unique_adb_serials(self):
        self.assertEqual(
            stress_test.parse_devices_arg("88LX01L45, 8AKX0UCPK"),
            ["88LX01L45", "8AKX0UCPK"],
        )
        self.assertIsNone(stress_test.parse_devices_arg(None))

    def test_rejects_duplicate_or_single_device_selection(self):
        for value in ("88LX01L45", "88LX01L45,88LX01L45", "88LX01L45,"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                stress_test.parse_devices_arg(value)


if __name__ == "__main__":
    unittest.main()
