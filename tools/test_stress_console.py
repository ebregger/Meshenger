import unittest
from collections import defaultdict
from unittest.mock import patch

from tools.stress_console import poll_ui_status


class PollUiStatusTests(unittest.TestCase):
    def test_message_completes_only_after_every_other_device_ui_shows_it(self):
        ports = [18081, 18082, 18083]
        port_to_device = {
            18081: "phoneA",
            18082: "phoneB",
            18083: "phoneC",
        }
        tag = "BenchMsg#001@1000"
        responses = {
            18081: {"messages": [{"textContent": tag}]},
            18082: {"messages": [{"text": tag}]},
            # Phone C has not caught up yet.
            18083: {"messages": []},
        }

        def request(port, path):
            self.assertEqual(path, "/ui")
            return responses[port]

        sent_messages = [{
            "tag": tag,
            "sender_device": "phoneA",
            "sent_at": 91.0,
        }]
        receipt_matrix = defaultdict(lambda: defaultdict(set))
        completed_at = {}
        receipt_at = {}
        receipt_windows = {}
        last_absent_at = {}

        with patch(
            "tools.stress_console.time.monotonic",
            side_effect=[100.0, 100.2, 100.5, 100.6],
        ):
            status = poll_ui_status(
                request,
                ports,
                port_to_device,
                sent_messages,
                receipt_matrix,
                completed_at,
                started_at=90.0,
                receipt_at=receipt_at,
                receipt_windows=receipt_windows,
                last_absent_at=last_absent_at,
            )

        self.assertEqual(status["propagated"], 0)
        self.assertNotIn(tag, completed_at)
        self.assertIn("phoneA→phoneC", status["behind_by_path"])
        self.assertEqual(receipt_matrix["phoneA"]["phoneB"], {tag})
        self.assertEqual(receipt_at[("phoneA", "phoneB", tag)], 100.2)
        self.assertEqual(
            receipt_windows[("phoneA", "phoneB", tag)],
            {"lower": 91.0, "upper": 100.2},
        )

        # Phone C now paints the message in the chat UI.
        responses[18083] = {"messages": [{"body": tag}]}
        with patch(
            "tools.stress_console.time.monotonic",
            side_effect=[101.0, 101.1, 101.4, 101.5],
        ):
            status = poll_ui_status(
                request,
                ports,
                port_to_device,
                sent_messages,
                receipt_matrix,
                completed_at,
                started_at=90.0,
                receipt_at=receipt_at,
                receipt_windows=receipt_windows,
                last_absent_at=last_absent_at,
            )

        self.assertEqual(status["propagated"], 1)
        self.assertEqual(receipt_at[("phoneA", "phoneC", tag)], 101.4)
        self.assertEqual(
            receipt_windows[("phoneA", "phoneC", tag)],
            {"lower": 100.5, "upper": 101.4},
        )
        self.assertEqual(completed_at[tag], 101.4)
        self.assertAlmostEqual(status["average_latency_ms"], 10400.0)
        self.assertEqual(receipt_matrix["phoneA"]["phoneC"], {tag})


if __name__ == "__main__":
    unittest.main()
