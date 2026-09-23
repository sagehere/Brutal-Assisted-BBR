import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


CHECKER = Path(__file__).with_name("check_lite_trace.py")


def row(**updates):
    value = {
        "schema": "p2-lite-v2", "configuration_version": "p1-baseline-v4",
        "seq": 1, "t_us": 0, "connection_tag": 42, "path_id": 0,
        "phase": "ProbeBW.Up",
        "state": "ASSIST", "reason": "BOUNDED_PROBE", "W_steps": 1,
        "rounds": 1, "target_Bps": 25_000_000, "B_ref_Bps": 20_000_000,
        "model_delivery_Bps": 20_000_000,
        "budget_bytes": 3_000_000, "budget_debit_bytes": 1200,
        "unrevocable_queue_bytes": 1200, "failure_count": 0,
        "control_applied": True, "actual_socket_sent_bytes": 1500,
        "dropped_records": 0, "inflight_bytes": 1200, "srtt_us": 10_000,
        "min_rtt_us": 8_000, "sample_valid": True, "sample_age_rounds": 0,
        "assist_deadline_monotonic_us": 300_000,
        "assist_deadline_remaining_us": 300_000,
        "backoff_remaining_us": None,
    }
    value.update(updates)
    return value


class LiteTraceCheckerTest(unittest.TestCase):
    def run_check(self, records, scenario="generic", allow_blocked=False,
                  ack_drop_count=None):
        with tempfile.TemporaryDirectory() as directory:
            trace = Path(directory) / "trace.jsonl"
            trace.write_text("\n".join(json.dumps(r) for r in records) + "\n", encoding="utf-8")
            command = [sys.executable, str(CHECKER), str(trace), "--scenario", scenario]
            if ack_drop_count is not None:
                command.extend(["--ack-drop-count", str(ack_drop_count)])
            if allow_blocked:
                command.append("--allow-blocked")
            return subprocess.run(command, text=True, capture_output=True)

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

    def test_missing_identity_or_sample_evidence_fails(self):
        value = row(); del value["connection_tag"]
        self.assertNotEqual(self.run_check([value]).returncode, 0)

    def test_assist_requires_absolute_future_deadline(self):
        self.assertNotEqual(self.run_check([row(assist_deadline_monotonic_us=0)]).returncode, 0)

    def test_backoff_without_failure_deadline_fails(self):
        self.assertNotEqual(self.run_check([row(state="ASSIST_BACKOFF", reason="BACKOFF_ACTIVE",
                                                  control_applied=False, W_steps=0,
                                                  failure_count=0, backoff_remaining_us=0)]).returncode, 0)

    def test_l03_without_exit_blocks(self):
        self.assertNotEqual(self.run_check([row()], "l03").returncode, 0)

    def test_l03_requires_socket_progress_after_admission(self):
        baseline = row(seq=1, t_us=0, state="BASELINE", reason="TARGET_NEAR",
                       W_steps=0, rounds=0, control_applied=False,
                       budget_debit_bytes=0, actual_socket_sent_bytes=1000,
                       assist_deadline_monotonic_us=None,
                       assist_deadline_remaining_us=None)
        exit_record = row(seq=3, t_us=200_000, state="ASSIST_BACKOFF",
                          reason="NO_BENEFIT", W_steps=0, control_applied=False,
                          actual_socket_sent_bytes=2000,
                          assist_deadline_monotonic_us=None,
                          assist_deadline_remaining_us=None,
                          backoff_remaining_us=1_000_000, failure_count=1)
        self.assertEqual(self.run_check([baseline, row(seq=2, t_us=100_000), exit_record], "l03").returncode, 0)

    def test_blocked_collection_can_complete_without_claiming_pass(self):
        result = self.run_check([row()], "l03", allow_blocked=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn('\"status\": \"BLOCKED\"', result.stdout)

    def test_diagnostics_group_real_delivery_queue_and_phase_inputs(self):
        baseline = row(seq=1, t_us=0, state="BASELINE", reason="TARGET_NEAR",
                       W_steps=0, rounds=0, control_applied=False,
                       budget_debit_bytes=0, model_delivery_Bps=20_000_000,
                       target_Bps=25_000_000, actual_socket_sent_bytes=1000,
                       assist_deadline_monotonic_us=None,
                       assist_deadline_remaining_us=None)
        hard_queue = row(seq=2, t_us=100_000, state="ASSIST_BACKOFF",
                         reason="HARD_QUEUE_DELAY", W_steps=0,
                         control_applied=False, budget_debit_bytes=0,
                         model_delivery_Bps=10_000_000, target_Bps=25_000_000,
                         srtt_us=30_000, min_rtt_us=10_000,
                         backoff_remaining_us=1_000_000, failure_count=1,
                         assist_deadline_monotonic_us=None,
                         assist_deadline_remaining_us=None)
        result = self.run_check([baseline, hard_queue], allow_blocked=True)
        report = json.loads(result.stdout)
        self.assertEqual(report["diagnostics"]["phase_reason_counts"]["ProbeBW.Up"],
                         {"HARD_QUEUE_DELAY": 1, "TARGET_NEAR": 1})
        self.assertEqual(report["diagnostics"]["reason_summary"]["TARGET_NEAR"][
            "model_delivery_to_target_ratio_p50"], 0.8)
        self.assertEqual(report["diagnostics"]["reason_summary"]["HARD_QUEUE_DELAY"][
            "queue_delay_ms_p95"], 20)

    def test_real_protected_phase_can_close_l04_network_check(self):
        self.assertEqual(self.run_check([row(phase="Startup", state="BASELINE",
                                                reason="BBR_PHASE_PROTECTED",
                                                W_steps=0, control_applied=False,
                                                assist_deadline_remaining_us=None)], "l04").returncode, 0)

    def test_l05_requires_external_router_ack_drop_counter(self):
        rows = [
            row(seq=1, t_us=1, assist_deadline_monotonic_us=300_001,
                assist_deadline_remaining_us=300_000),
            row(seq=2, t_us=300_001, state="BASELINE", reason="ASSIST_TIMEOUT",
                W_steps=0, control_applied=False, budget_debit_bytes=0,
                assist_deadline_monotonic_us=None,
                assist_deadline_remaining_us=None),
            row(seq=3, t_us=400_001, state="ASSIST_BACKOFF", reason="PTO_FIRED",
                W_steps=0, control_applied=False, budget_debit_bytes=0,
                actual_socket_sent_bytes=2500,
                assist_deadline_monotonic_us=None,
                assist_deadline_remaining_us=None),
        ]
        self.assertNotEqual(self.run_check(rows, "l05", ack_drop_count=0).returncode, 0)
        result = self.run_check(rows, "l05", ack_drop_count=12)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('"status": "PASS"', result.stdout)

    def test_l05_requires_socket_progress_after_assist_timeout(self):
        rows = [
            row(seq=1, t_us=1),
            row(seq=2, t_us=300_001, state="BASELINE", reason="ASSIST_TIMEOUT",
                W_steps=0, control_applied=False, budget_debit_bytes=0,
                assist_deadline_monotonic_us=None,
                assist_deadline_remaining_us=None),
            row(seq=3, t_us=400_001, state="ASSIST_BACKOFF", reason="PTO_FIRED",
                W_steps=0, control_applied=False, budget_debit_bytes=0,
                actual_socket_sent_bytes=1500,
                assist_deadline_monotonic_us=None,
                assist_deadline_remaining_us=None),
        ]
        result = self.run_check(rows, "l05", ack_drop_count=12, allow_blocked=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn("no socket-send progress after the Assist deadline expired", result.stdout)
        self.assertIn('"status": "BLOCKED"', result.stdout)

    def test_l05_timeout_before_admitted_deadline_is_blocked(self):
        rows = [
            row(seq=1, t_us=1, assist_deadline_monotonic_us=300_001,
                assist_deadline_remaining_us=300_000),
            row(seq=2, t_us=200_000, state="BASELINE", reason="ASSIST_TIMEOUT",
                W_steps=0, control_applied=False, budget_debit_bytes=0,
                assist_deadline_monotonic_us=None,
                assist_deadline_remaining_us=None),
            row(seq=3, t_us=400_001, state="ASSIST_BACKOFF", reason="PTO_FIRED",
                W_steps=0, control_applied=False, budget_debit_bytes=0,
                actual_socket_sent_bytes=2500,
                assist_deadline_monotonic_us=None,
                assist_deadline_remaining_us=None),
        ]
        result = self.run_check(rows, "l05", ack_drop_count=12, allow_blocked=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn("Assist timeout did not occur at or after an admitted deadline", result.stdout)
        self.assertIn('"status": "BLOCKED"', result.stdout)

    def test_l05_without_external_drop_count_is_blocked(self):
        rows = [row(reason="ASSIST_TIMEOUT"), row(seq=2, t_us=10,
                  reason="PTO_FIRED", state="ASSIST_BACKOFF",
                  control_applied=False, W_steps=0, budget_debit_bytes=0,
                  assist_deadline_monotonic_us=None,
                  assist_deadline_remaining_us=None)]
        result = self.run_check(rows, "l05", allow_blocked=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn('"status": "BLOCKED"', result.stdout)
        self.assertIn("no router ACK-drop counter evidence", result.stdout)


if __name__ == "__main__":
    unittest.main()
