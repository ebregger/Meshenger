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
