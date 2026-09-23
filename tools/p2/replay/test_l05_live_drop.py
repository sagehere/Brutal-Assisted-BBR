import unittest
import json
import os
import tempfile
import time
from pathlib import Path

from l05_live_drop import dropped_packets, latest_live, live_delta


class LiveDropTest(unittest.TestCase):
    def test_counts_only_increasing_counters_during_consecutive_live_samples(self):
        self.assertEqual(live_delta([(4, 10), (5, 13), (None, None),
                                     (7, 40), (8, 42)]), 5)

    def test_repeated_record_cannot_claim_counter_growth(self):
        self.assertEqual(live_delta([(4, 10), (4, 30), (5, 31)]), 1)

    def test_parser_fails_closed_without_drop_count(self):
        self.assertIsNone(dropped_packets("Sent 0 bytes"))
        self.assertEqual(dropped_packets("(dropped 14, overlimits 0)"), 14)

    def test_only_fresh_live_record_from_same_authorization_counts(self):
        with tempfile.TemporaryDirectory() as directory:
            trace = Path(directory) / "lite.jsonl"
            record = {"seq": 5, "state": "ASSIST", "control_applied": True,
                      "assist_deadline_monotonic_us": 300000}
            trace.write_text(json.dumps(record) + "\n")
            self.assertEqual(latest_live(trace, 300000, 4), 5)
            self.assertIsNone(latest_live(trace, 300001, 4))
            self.assertIsNone(latest_live(trace, 300000, 5))
            old = time.time_ns() - 100_000_000
            os.utime(trace, ns=(old, old))
            self.assertIsNone(latest_live(trace, 300000, 4))


if __name__ == "__main__":
    unittest.main()
