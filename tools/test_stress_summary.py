import math
import statistics
import unittest

from tools.stress_summary import (
    mean_latency_confidence,
    message_trace_events_for_id,
)


class MeanLatencyConfidenceTests(unittest.TestCase):
    def test_reports_normal_approximation_and_target_sample_count(self):
        values = [float(value) for value in range(1, 101)]

        result = mean_latency_confidence(values, target_precision_s=0.01)

        expected_mean = statistics.mean(values)
        expected_sd = statistics.stdev(values)
        expected_margin = 1.96 * expected_sd / math.sqrt(len(values))
        expected_target_n = math.ceil((1.96 * expected_sd / 0.01) ** 2)
        self.assertEqual(result["n"], 100)
        self.assertAlmostEqual(result["mean"], expected_mean)
        self.assertAlmostEqual(result["sample_sd"], expected_sd)
        self.assertAlmostEqual(result["margin"], expected_margin)
        self.assertEqual(result["target_samples"], expected_target_n)

    def test_returns_no_interval_for_small_samples(self):
        self.assertIsNone(mean_latency_confidence([1.0] * 29))

    def test_rejects_nonpositive_target_precision(self):
        with self.assertRaises(ValueError):
            mean_latency_confidence([float(value) for value in range(30)], 0)


class MessageTraceCorrelationTests(unittest.TestCase):
    def test_joins_message_boundaries_to_same_device_gatt_attempt_and_connection(self):
        message_id = "message-123"
        message_events = [
            {
                "source": "app",
                "device": "sender",
                "event": "OFFER_INCLUDED",
                "msg_id": message_id,
                "timestamp_ms": 1000,
                "fields": {},
            },
            {
                "source": "ble",
                "device": "sender",
                "event": "client_attempt_started",
                "message_ids": [message_id],
                "timestamp_ms": 1010,
                "attempt_id": "attempt-a",
                "fields": {},
            },
            {
                "source": "app",
                "device": "receiver",
                "event": "PAYLOAD_DECODED",
                "msg_id": message_id,
                "timestamp_ms": 1200,
                "fields": {"CONNECTION_ID": "connection-b"},
            },
            {
                "source": "ble",
                "device": "reply-phone",
                "event": "server_reply_started",
                "message_ids": [message_id],
                "timestamp_ms": 2000,
                "connection_id": "connection-c",
                "fields": {},
            },
        ]
        ble_events = [
            {
                "device": "sender",
                "event": "client_connected",
                "attempt_id": "attempt-a",
                "wall_ms": 1100,
            },
            {
                "device": "sender",
                "event": "client_attempt_complete",
                "attempt_id": "attempt-a",
                "wall_ms": 1110,
            },
            {
                "device": "sender",
                "event": "client_delta_eof_received",
                "attempt_id": "attempt-a",
                "wall_ms": 1120,
            },
            {
                "device": "receiver",
                "event": "server_write_chunk",
                "connection_id": "connection-b",
                "wall_ms": 1000,
                "fields": {"eof": "true"},
            },
            {
                "device": "receiver",
                "event": "server_write_chunk",
                "connection_id": "connection-b",
                "wall_ms": 1180,
                "fields": {"eof": "false"},
            },
            {
                "device": "receiver",
                "event": "server_write_chunk",
                "connection_id": "connection-b",
                "wall_ms": 1190,
                "fields": {"eof": "true"},
            },
            {
                "device": "receiver",
                "event": "server_write_chunk",
                "connection_id": "connection-b",
                "wall_ms": 1205,
                "fields": {"eof": "false"},
            },
            {
                "device": "other-device",
                "event": "client_connected",
                "attempt_id": "attempt-a",
                "wall_ms": 1300,
            },
            {
                "device": "receiver",
                "event": "server_write_chunk",
                "connection_id": "connection-other",
                "wall_ms": 1300,
            },
            {
                "device": "reply-phone",
                "event": "server_notify_callback",
                "connection_id": "connection-c",
                "wall_ms": 2001,
            },
            {
                "device": "reply-phone",
                "event": "server_reply_complete",
                "connection_id": "connection-c",
                "wall_ms": 2003,
            },
            {
                "device": "reply-phone",
                "event": "server_reply_started",
                "connection_id": "connection-c",
                "wall_ms": 2010,
            },
            {
                "device": "reply-phone",
                "event": "server_reply_complete",
                "connection_id": "connection-c",
                "wall_ms": 2013,
            },
        ]

        trace = message_trace_events_for_id(
            message_id,
            message_events,
            ble_events,
        )

        self.assertEqual(
            {(event["device"], event["event"]) for event in trace},
            {
                ("sender", "OFFER_INCLUDED"),
                ("sender", "client_attempt_started"),
                ("sender", "client_connected"),
                ("sender", "client_attempt_complete"),
                ("receiver", "PAYLOAD_DECODED"),
                ("receiver", "server_write_chunk"),
                ("reply-phone", "server_reply_started"),
                ("reply-phone", "server_notify_callback"),
                ("reply-phone", "server_reply_complete"),
            },
        )
        receiver_chunk_times = {
            event.get("wall_ms")
            for event in trace
            if event["device"] == "receiver"
            and event["event"] == "server_write_chunk"
        }
        self.assertEqual(receiver_chunk_times, {1180, 1190})
        reply_times = {
            event.get("timestamp_ms", event.get("wall_ms"))
            for event in trace
            if event["device"] == "reply-phone"
        }
        self.assertEqual(reply_times, {2000, 2001, 2003})


if __name__ == "__main__":
    unittest.main()
