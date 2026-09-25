import math
import statistics
import unittest

from tools.stress_summary import mean_latency_confidence


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


if __name__ == "__main__":
    unittest.main()
