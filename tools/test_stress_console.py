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

        with patch("tools.stress_console.time.time", return_value=100.0):
            status = poll_ui_status(
                request,
                ports,
                port_to_device,
                sent_messages,
                receipt_matrix,
                completed_at,
                started_at=90.0,
            )

        self.assertEqual(status["propagated"], 0)
        self.assertNotIn(tag, completed_at)
        self.assertIn("phoneA→phoneC", status["behind_by_path"])
        self.assertEqual(receipt_matrix["phoneA"]["phoneB"], {tag})

        # Phone C now paints the message in the chat UI.
        responses[18083] = {"messages": [{"body": tag}]}
        with patch("tools.stress_console.time.time", return_value=101.0):
            status = poll_ui_status(
                request,
                ports,
                port_to_device,
                sent_messages,
                receipt_matrix,
                completed_at,
                started_at=90.0,
            )

        self.assertEqual(status["propagated"], 1)
        self.assertEqual(completed_at[tag], 101.0)
        self.assertEqual(status["average_latency_ms"], 10000.0)
        self.assertEqual(receipt_matrix["phoneA"]["phoneC"], {tag})


if __name__ == "__main__":
    unittest.main()
