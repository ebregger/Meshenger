import unittest
import math
import statistics

from tools.stress_summary import (
    _connection_pressure_summary,
    _mtu_attempt_summary,
    ble_trace_summary,
    mean_latency_confidence,
    path_latency_stats,
    summarize_run,
)


class MeanLatencyConfidenceTests(unittest.TestCase):
    def test_estimates_95_percent_mean_interval_and_target_sample_count(self):
        values = [index / 100 for index in range(30)]

        confidence = mean_latency_confidence(values, target_precision_s=0.01)

        self.assertEqual(confidence["n"], 30)
        self.assertAlmostEqual(
            confidence["margin"],
            1.96 * statistics.stdev(values) / math.sqrt(len(values)),
        )
        self.assertEqual(
            confidence["target_samples"],
            math.ceil((1.96 * statistics.stdev(values) / 0.01) ** 2),
        )

    def test_withholds_interval_below_thirty_samples(self):
        self.assertIsNone(mean_latency_confidence([0.1] * 29))

    def test_rejects_nonpositive_or_nonfinite_precision(self):
        for precision in (0, -0.01, float("nan"), float("inf")):
            with self.subTest(precision=precision), self.assertRaises(ValueError):
                mean_latency_confidence([0.1] * 30, precision)


class DirectedPathSummaryTests(unittest.TestCase):
    def test_reports_latency_for_each_directed_sender_receiver_path(self):
        sent_messages = [
            {"tag": "a1", "sender_device": "phoneA", "sent_at": 10.0},
            {"tag": "a2", "sender_device": "phoneA", "sent_at": 20.0},
            {"tag": "b1", "sender_device": "phoneB", "sent_at": 30.0},
        ]
        receipt_at = {
            ("phoneA", "phoneB", "a1"): 11.0,
            ("phoneA", "phoneB", "a2"): 22.0,
            ("phoneA", "phoneC", "a1"): 13.0,
            ("phoneA", "phoneC", "a2"): 23.0,
            ("phoneB", "phoneA", "b1"): 34.0,
        }

        paths = path_latency_stats(sent_messages, receipt_at)

        self.assertEqual(
            [(path["sender"], path["receiver"], path["n"]) for path in paths],
            [("phoneA", "phoneB", 2), ("phoneA", "phoneC", 2), ("phoneB", "phoneA", 1)],
        )
        self.assertEqual(paths[0]["mean"], 1.5)
        self.assertEqual(paths[1]["max"], 3.0)
        self.assertEqual(paths[2]["p50"], 4.0)

    def test_reports_host_timing_stages_and_ui_poll_observation_window(self):
        sent_messages = [
            {
                "tag": "a1",
                "sender_device": "phoneA",
                "sent_at": 10.0,
                "send_api_completed_at": 10.3,
            },
        ]
        result = {
            "success": True,
            "profile": "interactive",
            "send_interval_s": 0.0,
            "sent_messages": sent_messages,
            "completed_at": {"a1": 12.0},
            "receipt_at": {("phoneA", "phoneB", "a1"): 12.0},
            "receipt_windows": {
                ("phoneA", "phoneB", "a1"): {"lower": 11.5, "upper": 12.0}
            },
            "status": {"propagated": 1, "elapsed_s": 2.0},
            "connection_failures": 0,
            "connection_rejections": 0,
            "penalty_entries": 0,
            "send_failures": 0,
        }

        summary = summarize_run(result)

        stages = summary["latency_stages"]
        self.assertAlmostEqual(stages["send_api_submit_s"]["mean"], 0.3)
        self.assertAlmostEqual(
            stages["api_accept_to_all_receivers_ui_s"]["mean"], 1.7
        )
        self.assertAlmostEqual(stages["end_to_end_lower_bound_s"]["mean"], 1.5)
        self.assertAlmostEqual(stages["end_to_end_upper_bound_s"]["mean"], 2.0)
        self.assertAlmostEqual(
            stages["end_to_end_observation_window_width_s"]["mean"], 0.5
        )
        self.assertAlmostEqual(summary["paths"][0]["mean_observation_window_s"], 0.5)

    def test_summary_exposes_machine_readable_overall_and_path_metrics(self):
        sent_messages = [
            {"tag": "a1", "sender_device": "phoneA", "sent_at": 10.0},
        ]
        result = {
            "success": True,
            "profile": "interactive",
            "send_interval_s": 0.0,
            "sent_messages": sent_messages,
            "completed_at": {"a1": 12.0},
            "receipt_at": {("phoneA", "phoneB", "a1"): 11.0},
            "status": {"propagated": 1, "elapsed_s": 2.0},
            "connection_failures": 0,
            "connection_rejections": 1,
            "penalty_entries": 0,
            "send_failures": 1,
            "bluetooth_socket_captures": [
                {"serial": "phoneA", "path": "phoneA.btsnoop", "packets": 12, "bytes": 900}
            ],
            "peer_signal_samples": [
                {
                    "elapsed_s": 0.1,
                    "peers_by_device": {
                        "phoneA": [{"id": "phoneB", "rssi_dbm": -68}]
                    },
                }
            ],
        }

        summary = summarize_run(result)

        self.assertTrue(summary["success"])
        self.assertEqual(summary["messages_delivered"], 1)
        self.assertEqual(summary["latency"]["mean"], 2.0)
        self.assertEqual(summary["paths"][0]["mean"], 1.0)
        self.assertEqual(summary["connection_rejections"], 1)
        self.assertEqual(summary["send_failures"], 1)
        self.assertEqual(summary["bluetooth_socket_captures"][0]["packets"], 12)
        self.assertEqual(
            summary["peer_signal_samples"][0]["peers_by_device"]["phoneA"][0][
                "rssi_dbm"
            ],
            -68,
        )


class ConnectionPhasePressureTests(unittest.TestCase):
    def test_connect_timeout_reports_overlapping_inbound_and_outbound_attempts(self):
        events = [
            {
                "device": "phoneA",
                "event": "client_connect_started",
                "mono_ms": 100,
                "attempt_id": "failed",
                "target_mac": "AA:AA:AA:AA:AA:AA",
            },
            {
                "device": "phoneA",
                "event": "server_connected",
                "mono_ms": 102,
                "connection_id": "inbound-1",
            },
            {
                "device": "phoneA",
                "event": "client_connect_started",
                "mono_ms": 104,
                "attempt_id": "success",
                "target_mac": "BB:BB:BB:BB:BB:BB",
            },
            {
                "device": "phoneA",
                "event": "client_attempt_failed",
                "mono_ms": 110,
                "attempt_id": "failed",
                "fields": {"phase": "connecting", "error_code": "connect_timeout"},
            },
            {
                "device": "phoneA",
                "event": "client_connected",
                "mono_ms": 112,
                "attempt_id": "success",
            },
            {
                "device": "phoneA",
                "event": "server_disconnected",
                "mono_ms": 115,
                "connection_id": "inbound-1",
            },
            {
                "device": "phoneA",
                "event": "client_attempt_failed",
                "mono_ms": 130,
                "attempt_id": "success",
                "fields": {"phase": "writing", "error_code": "transfer_timeout"},
            },
        ]

        pressure = _connection_pressure_summary(events, {"attempts": []})

        self.assertEqual(pressure["connect_phase_failures_by_error"], {"connect_timeout": 1})
        self.assertEqual(pressure["connect_attempts_overlapping_inbound_link"], 2)
        self.assertEqual(pressure["connect_attempts_overlapping_another_outbound_connect"], 2)
        self.assertEqual(pressure["failed_connect_attempts_overlapping_inbound_link"], 1)
        self.assertEqual(
            pressure["failed_connect_attempts_overlapping_another_outbound_connect"],
            1,
        )
        self.assertEqual(
            [row["outcome"] for row in pressure["connect_attempt_activity"]],
            ["failed_before_connected", "connected"],
        )


class MtuFallbackSummaryTests(unittest.TestCase):
    def test_reports_default_mtu_fallback_as_recovery(self):
        events = [
            {
                "device": "phoneA",
                "event": "client_mtu_requested",
                "attempt_id": "fallback-1",
                "target_mac": "AA:BB:CC:DD:EE:FF",
                "mono_ms": 100,
                "fields": {"started": "true", "requested_mtu": "512"},
            },
            {
                "device": "phoneA",
                "event": "client_mtu_fallback",
                "attempt_id": "fallback-1",
                "target_mac": "AA:BB:CC:DD:EE:FF",
                "mono_ms": 1600,
                "fields": {
                    "reason": "callback_timeout",
                    "wait_ms": "1500",
                    "chunk_size": "20",
                },
            },
        ]

        summary = _mtu_attempt_summary(events)

        self.assertEqual(summary["fallbacks"], 1)
        self.assertEqual(summary["pending_at_capture_end"], 0)
        self.assertEqual(summary["attempts"][0]["outcome"], "default_mtu_fallback")
        self.assertEqual(summary["attempts"][0]["fallback_wait_ms"], "1500")
        self.assertEqual(summary["by_device_peer"][0]["fallbacks"], 1)

    def test_reports_debug_mtu_skip_without_counting_a_request(self):
        events = [
            {
                "device": "phoneA",
                "event": "client_mtu_skipped",
                "attempt_id": "skip-1",
                "target_mac": "AA:BB:CC:DD:EE:FF",
                "mono_ms": 100,
                "fields": {"reason": "debug_default_mtu", "chunk_size": "20"},
            }
        ]

        summary = _mtu_attempt_summary(events)

        self.assertEqual(summary["requests"], 0)
        self.assertEqual(summary["skipped"], 1)
        self.assertEqual(summary["attempts"][0]["outcome"], "negotiation_skipped")
        self.assertEqual(summary["attempts"][0]["skipped_reason"], "debug_default_mtu")


class DialAddressMetadataTests(unittest.TestCase):
    def test_preserves_address_source_and_scan_age_in_summary_metadata(self):
        events = [
            {
                "device": "pixel9",
                "event": "urgent_dial_selection",
                "target_mac": "66:3C:D0:DC:75:D3",
                "fields": {
                    "peer_node_id": "peer-123",
                    "target_sources": "nodeIdToMac+macToNodeId",
                    "candidates": "66:3C:D0:DC:75:D3:nodeIdToMac",
                    "last_scan_mac": "66:3C:D0:DC:75:D3",
                    "last_scan_age_ms": "122",
                    "fresh_scan_allowed": "true",
                    "current_neighbor": "true",
                    "dead_remaining_ms": "-1",
                    "wall_ms": "1790366197964",
                },
            }
        ]

        summary = ble_trace_summary(events)

        self.assertEqual(
            summary["urgent_dial_selections"],
            [
                {
                    "device": "pixel9",
                    "peer_node_id": "peer-123",
                    "target_mac": "66:3C:D0:DC:75:D3",
                    "target_sources": "nodeIdToMac+macToNodeId",
                    "candidate_macs": "66:3C:D0:DC:75:D3:nodeIdToMac",
                    "last_scan_mac": "66:3C:D0:DC:75:D3",
                    "last_scan_age_ms": 122,
                    "fresh_scan_allowed": True,
                    "current_neighbor": True,
                    "dead_remaining_ms": -1,
                    "wall_ms": 1790366197964,
                }
            ],
        )


if __name__ == "__main__":
    unittest.main()
