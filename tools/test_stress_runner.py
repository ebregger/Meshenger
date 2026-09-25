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


if __name__ == "__main__":
    unittest.main()
