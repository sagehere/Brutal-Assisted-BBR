import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


CHECKER = Path(__file__).with_name("check_lite_trace.py")


def row(**updates):
    value = {
        "schema": "p2-lite-v2", "seq": 1, "t_us": 0, "phase": "ProbeBW.Up",
        "state": "ASSIST", "reason": "BOUNDED_PROBE", "W_steps": 1,
        "rounds": 1, "target_Bps": 25_000_000, "B_ref_Bps": 20_000_000,
        "budget_bytes": 3_000_000, "budget_debit_bytes": 1200,
        "unrevocable_queue_bytes": 1200, "failure_count": 0,
        "control_applied": True, "actual_socket_sent_bytes": 1500,
        "dropped_records": 0, "assist_deadline_remaining_us": 300_000,
        "backoff_remaining_us": None,
    }
    value.update(updates)
    return value


class LiteTraceCheckerTest(unittest.TestCase):
    def run_check(self, records, scenario="generic"):
        with tempfile.TemporaryDirectory() as directory:
            trace = Path(directory) / "trace.jsonl"
            trace.write_text("\n".join(json.dumps(r) for r in records) + "\n", encoding="utf-8")
            return subprocess.run([sys.executable, str(CHECKER), str(trace), "--scenario", scenario], text=True, capture_output=True)

    def test_valid_generic_trace_passes(self):
        self.assertEqual(self.run_check([row()]).returncode, 0)

    def test_wrong_schema_fails(self):
        self.assertNotEqual(self.run_check([row(schema="p2-lite-v1")]).returncode, 0)

    def test_missing_w_steps_fails(self):
        value = row(); del value["W_steps"]
        self.assertNotEqual(self.run_check([value]).returncode, 0)

    def test_empty_trace_blocks(self):
        self.assertNotEqual(self.run_check([]).returncode, 0)

    def test_protected_assist_fails(self):
        self.assertNotEqual(self.run_check([row(phase="Drain")], "l04").returncode, 0)

    def test_budget_overrun_fails(self):
        self.assertNotEqual(self.run_check([row(budget_debit_bytes=3_000_001)]).returncode, 0)

    def test_expired_assist_authorization_fails(self):
        self.assertNotEqual(self.run_check([row(assist_deadline_remaining_us=0)]).returncode, 0)

    def test_backoff_without_failure_deadline_fails(self):
        self.assertNotEqual(self.run_check([row(state="ASSIST_BACKOFF", reason="BACKOFF_ACTIVE",
                                                  control_applied=False, W_steps=0,
                                                  failure_count=0, backoff_remaining_us=0)]).returncode, 0)

    def test_l03_without_exit_blocks(self):
        self.assertNotEqual(self.run_check([row()], "l03").returncode, 0)


if __name__ == "__main__":
    unittest.main()
