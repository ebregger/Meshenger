import unittest
from unittest.mock import patch

import stress_test


class StressPreflightTests(unittest.TestCase):
    def test_pauses_all_scans_before_reset_and_resumes_after(self):
        calls = []

        def fake_request(port, path, method="GET", body=None, **kwargs):
            calls.append((path, port))
            if path == "/info":
                return {"nodeId": f"node-{port}"}
            response_by_path = {
                "/pause_scan": {"status": "scan_paused"},
                "/reset_ble": {"status": "ble_reset"},
                "/resume_scan": {"status": "scan_resumed"},
            }
            return response_by_path[path]

        preflight = {}
        with patch.object(stress_test, "request", side_effect=fake_request):
            infos = stress_test.check_devices(
                [18081, 18082],
                ble_reset_responses={},
                ble_preflight=preflight,
            )

        pause_indices = [i for i, (path, _) in enumerate(calls) if path == "/pause_scan"]
        reset_indices = [i for i, (path, _) in enumerate(calls) if path == "/reset_ble"]
        resume_indices = [i for i, (path, _) in enumerate(calls) if path == "/resume_scan"]
        self.assertEqual(set(infos), {18081, 18082})
        self.assertEqual(len(pause_indices), 2)
        self.assertEqual(len(reset_indices), 2)
        self.assertEqual(len(resume_indices), 2)
        self.assertLess(max(pause_indices), min(reset_indices))
        self.assertLess(max(reset_indices), min(resume_indices))
        self.assertTrue(preflight["ready"])

    def test_reset_is_skipped_if_any_peer_scan_cannot_pause(self):
        calls = []

        def fake_request(port, path, method="GET", body=None, error_report=None, **kwargs):
            calls.append((path, port))
            if path == "/info":
                return {"nodeId": f"node-{port}"}
            if path == "/pause_scan" and port == 18082:
                if error_report is not None:
                    error_report["error"] = "scan pause failed"
                return None
            response_by_path = {
                "/pause_scan": {"status": "scan_paused"},
                "/resume_scan": {"status": "scan_resumed"},
            }
            return response_by_path[path]

        preflight = {}
        with patch.object(stress_test, "request", side_effect=fake_request):
            stress_test.check_devices(
                [18081, 18082],
                ble_reset_responses={},
                ble_preflight=preflight,
            )

        self.assertNotIn("/reset_ble", [path for path, _ in calls])
        self.assertEqual(
            [path for path, _ in calls].count("/resume_scan"),
            2,
        )
        self.assertFalse(preflight["ready"])


if __name__ == "__main__":
    unittest.main()
