#!/usr/bin/env python3
"""Synthetic P1 rule checks. They are not a network or performance test."""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent
CFG = json.loads((ROOT / "P1-冻结参数与用例.json").read_text(encoding="utf-8"))


def ms_budget(reference_rate, min_rtt_ms):
    return reference_rate * min(3 * min_rtt_ms, CFG["assist"]["budget_duration_cap_ms"]) // 1000


def backoff_ms(failures):
    return min(CFG["backoff"]["base_ms"] * (2 ** (failures - 1)), CFG["backoff"]["maximum_ms"])


def candidate_rate(reference_rate, target, weight):
    cap = min(target, int(reference_rate * CFG["assist"]["max_relative_rate_gain"]))
    return reference_rate + int(weight * max(0, cap - reference_rate))


def decide(event, state):
    """Return a deterministic decision for one already-established QUIC path."""
    p = CFG["assist"]
    guards = CFG["guards"]
    target = event["target"]
    baseline = event["baseline_rate"]
    now = event["now_ms"]
    state = dict(state)
    state.setdefault("weight", 0.0)
    state.setdefault("failures", 0)
    state.setdefault("backoff_until_ms", 0)
    state.setdefault("used_bytes", 0)
    state.setdefault("rounds", 0)
    state.setdefault("started_ms", now)
    state.setdefault("reference_rate", baseline)

    def baseline_only(reason, failure=False):
        state["weight"] = 0.0
        if failure:
            state["failures"] += 1
            state["backoff_until_ms"] = now + backoff_ms(state["failures"])
        return {"state": "BACKOFF" if failure else "BASELINE", "reason": reason,
                "pacing_rate": min(baseline, event.get("max_rate", baseline)),
                "cwnd": event["baseline_cwnd"], "state_data": state}

    if target == 0:
        return baseline_only("target_disabled")
    if not CFG["target"]["minimum_nonzero_byte_per_s"] <= target <= CFG["target"]["maximum_byte_per_s"]:
        return baseline_only("invalid_target")
    if event.get("mode", "lite") != "lite":
        return baseline_only("mode_not_lite")
    if event.get("path_changed") or event.get("app_limited") or event.get("flow_control_limited") or event.get("policy_limited"):
        return baseline_only("non_network_or_path_event")
    if event.get("phase") not in p["allowed_bbr_phase"]:
        return baseline_only("baseline_phase_protected")
    if event.get("loss_detected") or event.get("pto"):
        return baseline_only("transport_guard", True)
    if event.get("persistent_congestion") or event.get("ecn_ce"):
        return baseline_only("future_host_guard", True)
    if now < state["backoff_until_ms"]:
        return baseline_only("backoff_active")
    if event.get("sample_age_rounds", 0) > guards["sample_max_age_rounds"] or baseline <= 0:
        return baseline_only("sample_invalid")
    if baseline >= target * CFG["target"]["exit_ratio"]:
        return baseline_only("target_near")
    if now - state["started_ms"] >= p["max_duration_ms"]:
        return baseline_only("assist_timeout", True)
    if state["rounds"] >= p["max_rounds"] or state["used_bytes"] >= ms_budget(state["reference_rate"], event["min_rtt_ms"]):
        return baseline_only("assist_budget_exhausted", True)
    q_delay = event.get("srtt_ms", event["min_rtt_ms"]) - event["min_rtt_ms"]
    hard = max(guards["hard_queue_delay_min_ms"], guards["hard_queue_delay_min_rtt_ratio"] * event["min_rtt_ms"])
    soft = max(guards["soft_queue_delay_min_ms"], guards["soft_queue_delay_min_rtt_ratio"] * event["min_rtt_ms"])
    if q_delay >= hard:
        return baseline_only("hard_queue_delay", True)
    if state["rounds"] >= p["no_benefit_round"] and event.get("model_delivery_rate", 0) < state["reference_rate"] * p["minimum_model_gain_ratio"]:
        return baseline_only("no_benefit", True)

    weight = state["weight"] if q_delay >= soft else min(1.0, state["weight"] + p["weight_step_per_bbr_round"])
    state["weight"] = weight
    rate = candidate_rate(state["reference_rate"], target, weight)
    rate = min(rate, event.get("max_rate", rate))
    return {"state": "ASSIST", "reason": "bounded_probe" if q_delay < soft else "soft_freeze",
            "pacing_rate": rate, "cwnd": event["baseline_cwnd"], "state_data": state}


def base_event(**changes):
    event = {"now_ms": 0, "target": 25_000_000, "baseline_rate": 20_000_000,
             "baseline_cwnd": 12_000, "min_rtt_ms": 50, "srtt_ms": 50,
             "phase": "ProbeBW.Cruise", "mode": "lite", "model_delivery_rate": 21_000_000}
    event.update(changes)
    return event


def check(name, fn):
    try:
        fn()
        print(f"PASS {name}")
    except AssertionError as exc:
        print(f"FAIL {name}: {exc}")
        raise


def run():
    check("C01 unreachable target exits without RTT growth", lambda: _unreachable())
    check("C02 huge target respects relative gain", lambda: _huge_target())
    check("C03 W=0 keeps baseline cwnd", lambda: _baseline_return())
    check("C04 protected phases and transport guards withdraw", lambda: _protected())
    check("C05 timeout, byte budget, and queued overshoot", lambda: _limits())
    check("C06 configuration and path changes do not bypass backoff", lambda: _changes())
    check("C07 invalid efficiency inputs do not accelerate", lambda: _invalid_inputs())
    check("C08 valid baseline learning remains available", lambda: _learning())
    check("C09 frozen host capability contract", lambda: _capabilities())


def _unreachable():
    result = decide(base_event(target=25_000_000, baseline_rate=18_750_000, srtt_ms=52),
                    {"rounds": 2, "reference_rate": 18_750_000})
    assert result["reason"] == "no_benefit" and result["state"] == "BACKOFF"


def _huge_target():
    result = decide(base_event(target=125_000_000), {})
    assert result["pacing_rate"] <= 20_100_000
    assert result["pacing_rate"] != 33_125_000


def _baseline_return():
    result = decide(base_event(target=0, baseline_cwnd=4000, baseline_rate=7_000_000), {"weight": 1})
    assert result["pacing_rate"] == 7_000_000 and result["cwnd"] == 4000


def _protected():
    for phase in ("Startup", "Drain", "ProbeRTT", "ProbeBW.Down"):
        assert decide(base_event(phase=phase), {})["state"] == "BASELINE"
    assert decide(base_event(loss_detected=True), {})["state"] == "BACKOFF"
    assert decide(base_event(pto=True), {})["state"] == "BACKOFF"


def _limits():
    assert decide(base_event(now_ms=301), {"started_ms": 0})["reason"] == "assist_timeout"
    assert decide(base_event(), {"used_bytes": ms_budget(20_000_000, 50)})["reason"] == "assist_budget_exhausted"
    assert CFG["assist"]["max_unrevocable_queue_bytes"] == 2400


def _changes():
    state = {"backoff_until_ms": 1000, "failures": 1}
    for event in (base_event(now_ms=1, target=0), base_event(now_ms=1, path_changed=True), base_event(now_ms=1, mode="off")):
        result = decide(event, state)
        assert result["state_data"]["backoff_until_ms"] == 1000


def _invalid_inputs():
    assert decide(base_event(sample_age_rounds=2), {})["reason"] == "sample_invalid"
    assert decide(base_event(baseline_rate=0), {})["reason"] == "sample_invalid"


def _learning():
    result = decide(base_event(model_delivery_rate=30_000_000), {"rounds": 2, "reference_rate": 20_000_000})
    assert result["state"] == "ASSIST" and result["cwnd"] == 12_000


def _capabilities():
    assert CFG["schema_version"] == "p1-baseline-v2"
    assert CFG["capabilities"]["bbr_is_in_recovery"] == "not_used"
    assert CFG["capabilities"]["persistent_congestion_signal"].startswith("unsupported")
    assert CFG["capabilities"]["ecn_ce_signal"].startswith("unsupported")
    assert "pre-debit" in CFG["assist"]["budget_accounting"]
    assert "socket/GSO" in CFG["telemetry"]["actual_sent_accounting"]


if __name__ == "__main__":
    run()
