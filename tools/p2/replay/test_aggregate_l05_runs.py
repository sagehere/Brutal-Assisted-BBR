import unittest

from tools.p2.replay.aggregate_l05_runs import aggregate


class AggregateL05RunsTest(unittest.TestCase):
    def test_any_real_pass_closes_collection(self):
        result = aggregate([
            ("run-01", {"scenario": "l05", "status": "BLOCKED"}),
            ("run-02", {"scenario": "l05", "status": "PASS"}),
        ])
        self.assertEqual(result["status"], "PASS")
        self.assertEqual(result["facts"]["pass_attempts"], 1)

    def test_all_blocked_attempts_remain_blocked(self):
        result = aggregate([
            ("run-01", {"scenario": "l05", "status": "BLOCKED"}),
            ("run-02", {"scenario": "l05", "status": "BLOCKED"}),
        ])
        self.assertEqual(result["status"], "BLOCKED")

    def test_malformed_or_failed_attempt_fails_aggregate(self):
        result = aggregate([
            ("run-01", {"scenario": "l05", "status": "PASS"}),
            ("run-02", {"scenario": "l05", "status": "FAIL", "errors": ["bad evidence"]}),
        ])
        self.assertEqual(result["status"], "FAIL")

    def test_missing_attempts_fail_closed(self):
        self.assertEqual(aggregate([])["status"], "FAIL")


if __name__ == "__main__":
    unittest.main()
