import unittest
from pathlib import Path
from unittest.mock import patch

from tools import load_sweep


class LoadSweepInputTests(unittest.TestCase):
    def test_parses_intervals_in_requested_order(self):
        self.assertEqual(load_sweep.parse_intervals("1, 0.5,0.3"), [1.0, 0.5, 0.3])

    def test_rejects_empty_nonpositive_nonfinite_or_nonnumeric_intervals(self):
        for value in ("", "0.5,0", "nan", "inf", "fast"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                load_sweep.parse_intervals(value)

    def test_builds_one_burst_run_with_ports_and_json_output(self):
        with patch.object(load_sweep, "STRESS_TEST", Path("stress_test.py")):
            command = load_sweep.build_stress_command(
                messages=60,
                interval_s=0.5,
                details_path=Path("out/run.log"),
                summary_path=Path("out/run.json"),
                ports=[18081, 18083],
                message_timeout_s=120,
                poll_interval_s=0.25,
            )

        self.assertIn("--profile", command)
        self.assertEqual(command[command.index("--profile") + 1], "burst")
        self.assertEqual(command[command.index("--send-interval-s") + 1], "0.5")
        self.assertEqual(command[command.index("--poll-interval-s") + 1], "0.25")
        self.assertEqual(command[command.index("--ports") + 1], "18081,18083")
        self.assertEqual(
            command[command.index("--summary-json") + 1],
            str(Path("out/run.json")),
        )


if __name__ == "__main__":
    unittest.main()
