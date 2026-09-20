#!/usr/bin/env python3
import json
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parents[2]
sys.path.insert(0, str(HERE))

from babr_model import (
    BabrReferenceController,
    Mode,
    Snapshot,
    load_rules,
    run_accounting_trace,
)

CONTRACT_PATH = REPO_ROOT / "阶段任务书" / "P1-冻结参数与用例.json"


def rules():
    return load_rules(CONTRACT_PATH)


def snap(**kw):
    base = dict(
        now_ms=0,
        baseline_pacing=20_000_000,
        baseline_cwnd=64_000,
        model_delivery_rate=20_000_000,
        srtt_ms=50,
        min_rtt_ms=50,
        bbr_phase="ProbeBW.Cruise",
    )
    base.update(kw)
    return Snapshot(**base)


class P2ObserveTests(unittest.TestCase):
    def test_contract_is_frozen_v4(self):
        contract = json.loads(CONTRACT_PATH.read_text(encoding="utf-8"))
        self.assertEqual(contract["schema_version"], "p1-baseline-v4")
        self.assertEqual(
            set(contract["assist"]["allowed_bbr_phase"]),
            {"ProbeBW.Refill", "ProbeBW.Up", "ProbeBW.Cruise"},
        )

    def test_l01_off_and_observe_keep_final_baseline(self):
        off = BabrReferenceController(rules(), Mode.OFF, target=25_000_000)
        obs = BabrReferenceController(rules(), Mode.OBSERVE, target=25_000_000)
        s = snap()
        d0 = off.on_round(s)
        d1 = obs.on_round(s)
        self.assertEqual(d0.final_pacing, s.baseline_pacing)
        self.assertEqual(d1.final_pacing, s.baseline_pacing)
        self.assertEqual(d0.final_cwnd, s.baseline_cwnd)
        self.assertEqual(d1.final_cwnd, s.baseline_cwnd)
        self.assertFalse(d1.control_applied)
        self.assertGreaterEqual(d1.candidate_pacing, s.baseline_pacing)

    def test_l02_observe_candidate_is_bounded_by_frozen_relative_gain(self):
        obs = BabrReferenceController(
            rules(), Mode.OBSERVE, target=125_000_000
        )
        d = obs.on_round(snap())
        self.assertLessEqual(d.candidate_pacing, 22_000_000)
        self.assertEqual(d.final_pacing, 20_000_000)

    def test_l04_protected_phases_never_create_observe_candidate(self):
        for phase in ["Startup", "Drain", "ProbeRTT", "ProbeBW.Down"]:
            obs = BabrReferenceController(
                rules(), Mode.OBSERVE, target=25_000_000
            )
            d = obs.on_round(snap(bbr_phase=phase))
            self.assertEqual(d.shadow_reason, "BBR_PHASE_PROTECTED")
            self.assertEqual(d.candidate_pacing, 20_000_000)
            self.assertEqual(d.final_pacing, 20_000_000)

    def test_l06_loss_retransmit_late_ack_counts_unique_payload_once(self):
        trace_path = HERE / "traces" / "l06_retransmission_late_ack.json"
        trace = json.loads(trace_path.read_text(encoding="utf-8"))

        snapshots = run_accounting_trace(trace)
        self.assertEqual(len(snapshots), len(trace["events"]))

        # First send is charged immediately but has delivered no payload.
        self.assertEqual(snapshots[0].actual_socket_sent_bytes, 1250)
        self.assertEqual(snapshots[0].unique_payload_delivered_bytes, 0)

        # Loss does not refund send cost or create delivery.
        self.assertEqual(snapshots[1].actual_socket_sent_bytes, 1250)
        self.assertEqual(snapshots[1].unique_payload_delivered_bytes, 0)

        # Retransmission is another successful socket send, so all cost counts.
        self.assertEqual(snapshots[2].actual_socket_sent_bytes, 2500)
        self.assertEqual(snapshots[2].unique_payload_delivered_bytes, 0)

        # Retransmission ACK delivers the STREAM range once.
        self.assertEqual(snapshots[3].unique_payload_delivered_bytes, 1200)

        # Late ACK for the original packet is spurious and must not add payload.
        final = snapshots[4]
        self.assertEqual(final.unique_payload_delivered_bytes, 1200)

        for field, expected in trace["expect"].items():
            self.assertEqual(getattr(final, field), expected, field)

    def test_l07_invalid_sample_cannot_increase_candidate(self):
        obs = BabrReferenceController(
            rules(), Mode.OBSERVE, target=25_000_000
        )
        d = obs.on_round(snap(sample_valid=False))
        self.assertEqual(d.shadow_reason, "SAMPLE_INVALID")
        self.assertEqual(d.candidate_pacing, d.final_pacing)

    def test_l08_maxrate_below_target_is_policy_limited(self):
        obs = BabrReferenceController(
            rules(),
            Mode.OBSERVE,
            target=25_000_000,
            max_rate=24_000_000,
        )
        d = obs.on_round(snap())
        self.assertEqual(d.reason, "POLICY_LIMITED")
        self.assertEqual(d.final_pacing, 20_000_000)

    def test_target_hysteresis_preserves_state_in_band(self):
        c = BabrReferenceController(rules(), Mode.LITE, target=25_000_000)

        at_enter = c.on_round(snap(model_delivery_rate=20_000_000))
        self.assertEqual(at_enter.state.value, "BASELINE")
        self.assertEqual(at_enter.shadow_reason, "TARGET_NEAR")
        self.assertAlmostEqual(at_enter.w, 0.0)

        entered = c.on_round(
            snap(now_ms=1, model_delivery_rate=19_000_000)
        )
        self.assertEqual(entered.state.value, "ASSIST")
        self.assertAlmostEqual(entered.w, 0.05)

        in_band = c.on_round(
            snap(now_ms=20, model_delivery_rate=21_000_000)
        )
        self.assertEqual(in_band.state.value, "ASSIST")

        exited = c.on_round(
            snap(now_ms=40, model_delivery_rate=22_500_000)
        )
        self.assertEqual(exited.state.value, "BASELINE")
        self.assertEqual(exited.shadow_reason, "TARGET_NEAR")
        self.assertAlmostEqual(exited.w, 0.0)

    def test_l11_ack_frequency_does_not_advance_w(self):
        obs = BabrReferenceController(
            rules(), Mode.OBSERVE, target=26_000_000
        )
        for _ in range(1000):
            obs.on_ack()
        self.assertEqual(obs.w, 0.0)

        d = obs.on_round(snap())
        self.assertAlmostEqual(d.w, 0.05)

        for _ in range(1000):
            obs.on_ack()
        self.assertAlmostEqual(obs.w, 0.05)

    def test_observe_mode_change_does_not_leak_shadow_w(self):
        obs = BabrReferenceController(
            rules(), Mode.OBSERVE, target=26_000_000
        )
        obs.on_round(snap())
        self.assertAlmostEqual(obs.w, 0.05)
        obs.set_mode(Mode.OFF)
        self.assertEqual(obs.w, 0.0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
