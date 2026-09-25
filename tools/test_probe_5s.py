import unittest

from probe_5s import classify_result


class ProbeResultClassificationTests(unittest.TestCase):
    def test_latency_within_sla_is_ok(self):
        self.assertEqual(classify_result({"ms": 5000}), "OK")

    def test_latency_after_sla_but_inside_timed_window_is_slow(self):
        self.assertEqual(classify_result({"ms": 5001}), "SLOW")
        self.assertEqual(classify_result({"ms": 8000}), "SLOW")

    def test_timeout_that_converges_in_final_check_is_late_recovery(self):
        self.assertEqual(
            classify_result({"ms": None, "recovered_by_end": True}),
            "LATE RECOVERY",
        )

    def test_timeout_still_missing_at_end_is_failure(self):
        self.assertEqual(
            classify_result({"ms": None, "recovered_by_end": False}),
            "FAIL",
        )

    def test_send_failure_takes_precedence_over_recovery_state(self):
        self.assertEqual(
            classify_result({
                "ms": None,
                "send_failed": True,
                "recovered_by_end": True,
            }),
            "SEND FAIL",
        )


if __name__ == "__main__":
    unittest.main()
