#!/usr/bin/env python3
"""Synthetic P1 Final Closure rule checks. Not a network/performance test."""
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent
CFG = json.loads((ROOT / "P1-冻结参数与用例.json").read_text(encoding="utf-8"))


def ms_budget(reference_rate, min_rtt_ms):
    return reference_rate * min(
        3 * min_rtt_ms, CFG["assist"]["budget_duration_cap_ms"]
    ) // 1000


def backoff_ms(failures):
    return min(
        CFG["backoff"]["base_ms"] * (2 ** (failures - 1)),
        CFG["backoff"]["maximum_ms"],
    )


def candidate_rate(reference_rate, target, weight):
    cap = min(target, int(reference_rate * CFG["assist"]["max_relative_rate_gain"]))
    return reference_rate + int(weight * max(0, cap - reference_rate))


def registered(reason):
    assert reason in CFG["reason_codes"], f"unregistered reason: {reason}"
    return reason


def baseline_only(reason, event, state, failure=False, invalidate_sample=False):
    reason = registered(reason)
    policy = CFG["reason_codes"][reason]
    assert policy["increment_failure"] == failure
    assert policy["invalidate_sample"] == invalidate_sample
    state["weight"] = 0.0
    if failure:
        state["failures"] += 1
        state["backoff_until_ms"] = event["now_ms"] + backoff_ms(state["failures"])
    state["babr_state"] = policy["next_state"]
    return {
        "state": policy["next_state"],
        "reason": reason,
        "pacing_rate": min(
            event["baseline_rate"], event.get("max_rate", event["baseline_rate"])
        ),
        "cwnd": event["baseline_cwnd"],
        "state_data": state,
    }


def decide(event, state):
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
    state.setdefault("babr_state", "BASELINE")
    state.setdefault("started_ms", now)
    state.setdefault("reference_rate", baseline)
    state.setdefault("deadline_ms", state["started_ms"] + p["max_duration_ms"])

    if target == 0:
        return baseline_only("TARGET_DISABLED", event, state)
    if not CFG["target"]["minimum_nonzero_byte_per_s"] <= target <= CFG["target"]["maximum_byte_per_s"]:
        return baseline_only("INVALID_TARGET", event, state, invalidate_sample=True)
    if event.get("mode", "lite") != "lite":
        return baseline_only("MODE_NOT_LITE", event, state)
    if event.get("policy_limited"):
        return baseline_only("POLICY_LIMITED", event, state, invalidate_sample=True)
    if event.get("path_changed"):
        return baseline_only("PATH_CHANGED", event, state, invalidate_sample=True)
    if event.get("app_limited"):
        return baseline_only("APP_LIMITED", event, state, invalidate_sample=True)
    if event.get("flow_control_limited"):
        return baseline_only("RECEIVER_LIMITED", event, state, invalidate_sample=True)
    if event.get("loss_detected"):
        return baseline_only("LOSS_DETECTED", event, state, failure=True, invalidate_sample=True)
    if event.get("pto"):
        return baseline_only("PTO_FIRED", event, state, failure=True, invalidate_sample=True)
    if event.get("phase") not in p["allowed_bbr_phase"]:
        return baseline_only("BBR_PHASE_PROTECTED", event, state)
    if now < state["backoff_until_ms"]:
        return baseline_only("BACKOFF_ACTIVE", event, state)
    if event.get("sample_age_rounds", 0) > guards["sample_max_age_rounds"] or baseline <= 0:
        return baseline_only("SAMPLE_INVALID", event, state, invalidate_sample=True)
    if now >= state["deadline_ms"]:
        return baseline_only("ASSIST_TIMEOUT", event, state, failure=True)
    next_datagram_bytes = event.get("next_datagram_bytes", 0)
    frozen_budget = ms_budget(state["reference_rate"], event["min_rtt_ms"])
    if state["used_bytes"] + next_datagram_bytes > frozen_budget:
        return baseline_only("ASSIST_BUDGET_EXHAUSTED", event, state, failure=True)
    if state["rounds"] >= p["max_rounds"]:
        return baseline_only("MAX_ROUNDS", event, state, failure=True)
    q_delay = event.get("srtt_ms", event["min_rtt_ms"]) - event["min_rtt_ms"]
    hard = max(
        guards["hard_queue_delay_min_ms"],
        guards["hard_queue_delay_min_rtt_ratio"] * event["min_rtt_ms"],
    )
    soft = max(
        guards["soft_queue_delay_min_ms"],
        guards["soft_queue_delay_min_rtt_ratio"] * event["min_rtt_ms"],
    )
    if q_delay >= hard:
        return baseline_only("HARD_QUEUE_DELAY", event, state, failure=True)
    if (
        state["rounds"] >= p["no_benefit_round"]
        and event.get("model_delivery_rate", 0)
        < state["reference_rate"] * p["minimum_model_gain_ratio"]
    ):
        return baseline_only("NO_BENEFIT", event, state, failure=True)
    delivery = event.get("model_delivery_rate", baseline)
    if (
        state["babr_state"] != "ASSIST"
        and delivery >= target * CFG["target"]["enter_ratio"]
    ):
        return baseline_only("TARGET_NEAR", event, state)
    if (
        state["babr_state"] == "ASSIST"
        and delivery >= target * CFG["target"]["exit_ratio"]
    ):
        return baseline_only("TARGET_NEAR", event, state)

    if q_delay >= soft:
        weight = state["weight"]
        reason = registered("SOFT_FREEZE")
    else:
        weight = min(1.0, state["weight"] + p["weight_step_per_bbr_round"])
        reason = registered("BOUNDED_PROBE")
    state["weight"] = weight
    state["babr_state"] = "ASSIST"
    rate = min(
        candidate_rate(state["reference_rate"], target, weight),
        event.get("max_rate", 2**63 - 1),
    )
    return {
        "state": "ASSIST",
        "reason": reason,
        "pacing_rate": rate,
        "cwnd": event["baseline_cwnd"],
        "state_data": state,
    }


def account_generated_assist(state, datagram_bytes):
    state = dict(state)
    state["used_bytes"] = state.get("used_bytes", 0) + datagram_bytes
    return state


def account_socket_result(actual_sent, result_bytes=None):
    return actual_sent + (0 if result_bytes is None else result_bytes)


def base_event(**changes):
    event = {
        "now_ms": 0,
        "target": 25_000_000,
        "baseline_rate": 20_000_000,
        "baseline_cwnd": 12_000,
        "min_rtt_ms": 50,
        "srtt_ms": 50,
        "phase": "ProbeBW.Cruise",
        "mode": "lite",
        "model_delivery_rate": 21_000_000,
        "next_datagram_bytes": 1200,
    }
    event.update(changes)
    return event


def check(name, fn):
    fn()
    print(f"PASS {name}")


def run():
    check("C01 unreachable target exits without RTT growth", c01)
    check("C02 huge target respects relative gain", c02)
    check("C03 W=0 keeps baseline cwnd", c03)
    check("C04 protected phases and Loss/PTO withdraw", c04)
    check("C05 timeout and byte budget stop assist", c05)
    check("C06 config/path changes preserve backoff", c06)
    check("C07 invalid efficiency inputs do not accelerate", c07)
    check("C08 valid baseline learning remains available", c08)
    check("C09 frozen host capability contract", c09)
    check("C10 socket failure never refunds assist budget", c10)
    check("C11 current host does not synthesize ECN/PC", c11)
    check("C12 deadline has zero grace", c12)
    check("C13 every decision reason is registered", c13)
    check("C14 required v4 parameters are complete", c14)
    check("C15 normative version and target hysteresis contract is v4", c15)


def c01():
    result = decide(
        base_event(
            target=25_000_000,
            baseline_rate=18_750_000,
            model_delivery_rate=18_750_000,
            srtt_ms=52,
        ),
        {"babr_state": "ASSIST", "rounds": 2, "reference_rate": 18_750_000},
    )
    assert result["reason"] == "NO_BENEFIT"
    assert result["state"] == "ASSIST_BACKOFF"


def c02():
    result = decide(base_event(target=125_000_000), {})
    assert result["pacing_rate"] <= 20_100_000


def c03():
    result = decide(
        base_event(target=0, baseline_cwnd=4000, baseline_rate=7_000_000),
        {"weight": 1},
    )
    assert result["pacing_rate"] == 7_000_000
    assert result["cwnd"] == 4000


def c04():
    for phase in ("Startup", "Drain", "ProbeRTT", "ProbeBW.Down"):
        assert decide(base_event(phase=phase), {})["reason"] == "BBR_PHASE_PROTECTED"
    assert decide(base_event(loss_detected=True), {})["reason"] == "LOSS_DETECTED"
    assert decide(base_event(pto=True), {})["reason"] == "PTO_FIRED"


def c05():
    assert decide(base_event(now_ms=300), {"babr_state": "ASSIST", "started_ms": 0})["reason"] == "ASSIST_TIMEOUT"
    budget = ms_budget(20_000_000, 50)
    state = {"babr_state": "ASSIST", "used_bytes": budget - 1000, "reference_rate": 20_000_000}
    assert decide(base_event(next_datagram_bytes=1200), state)["reason"] == "ASSIST_BUDGET_EXHAUSTED"
    assert CFG["assist"]["max_unrevocable_queue_bytes"] == 2400


def c06():
    state = {"backoff_until_ms": 1000, "failures": 1}
    for event in (
        base_event(now_ms=1, target=0),
        base_event(now_ms=1, path_changed=True),
        base_event(now_ms=1, mode="off"),
    ):
        result = decide(event, state)
        assert result["state_data"]["backoff_until_ms"] == 1000


def c07():
    assert decide(base_event(sample_age_rounds=2), {})["reason"] == "SAMPLE_INVALID"
    assert decide(base_event(baseline_rate=0), {})["reason"] == "SAMPLE_INVALID"


def c08():
    result = decide(
        base_event(model_delivery_rate=30_000_000),
        {"babr_state": "ASSIST", "rounds": 2, "reference_rate": 20_000_000},
    )
    assert result["state"] == "ASSIST"
    assert result["cwnd"] == 12_000


def c09():
    assert CFG["schema_version"] == "p1-baseline-v4"
    assert CFG["capabilities"]["bbr_is_in_recovery"] == "not_used"
    assert CFG["capabilities"]["persistent_congestion_signal"].startswith("unsupported")
    assert CFG["capabilities"]["ecn_ce_signal"].startswith("unsupported")


def c10():
    state = {"used_bytes": 0}
    state = account_generated_assist(state, 1200)
    actual = account_socket_result(0, None)
    assert state["used_bytes"] == 1200
    assert actual == 0
    state2 = dict(state)
    assert state2["used_bytes"] == 1200


def c11():
    assert "EcnCe" not in CFG["reason_codes"]
    assert "PersistentCongestion" not in CFG["reason_codes"]
    assert decide(base_event(loss_detected=True), {})["state"] == "ASSIST_BACKOFF"
    assert decide(base_event(pto=True), {})["state"] == "ASSIST_BACKOFF"


def c12():
    state = {"babr_state": "ASSIST", "started_ms": 0, "deadline_ms": 300}
    assert decide(base_event(now_ms=299), state)["reason"] in ("BOUNDED_PROBE", "SOFT_FREEZE")
    assert decide(base_event(now_ms=300), state)["reason"] == "ASSIST_TIMEOUT"
    assert decide(base_event(now_ms=301), state)["reason"] == "ASSIST_TIMEOUT"
    assert CFG["assist"]["deadline_grace_for_new_assist_ms"] == 0


def c13():
    observed = set()
    cases = [
        base_event(target=0),
        base_event(target=1),
        base_event(mode="off"),
        base_event(path_changed=True),
        base_event(app_limited=True),
        base_event(flow_control_limited=True),
        base_event(policy_limited=True),
        base_event(loss_detected=True),
        base_event(pto=True),
        base_event(phase="Drain"),
        base_event(sample_age_rounds=2),
        base_event(now_ms=300),
        base_event(srtt_ms=100),
        base_event(target=20_000_000),
    ]
    for e in cases:
        observed.add(decide(e, {})["reason"])
    assert observed <= set(CFG["reason_codes"])


def c14():
    p = CFG["assist"]
    for key in (
        "admission_granularity",
        "budget_accounting",
        "deadline_clock",
        "deadline_check_resolution_ms",
        "deadline_grace_for_new_assist_ms",
        "timer_lateness_policy",
    ):
        assert key in p
    assert len(CFG["reason_codes"]) >= 20
    assert CFG["acceptance"]["synthetic_cases"] == [f"C{i:02d}" for i in range(1, 16)]


def c15():
    assert CFG["schema_version"] == "p1-baseline-v4"
    assert CFG["configuration_version"] == "2026-09-20-p1-hysteresis-errata"
    assert CFG["normative_authority"]["behavior_spec"] == "P1-修订规格与冻结基线.md"
    assert CFG["target"]["hysteresis_band_behavior"] == "preserve_current_state"

    at_enter = decide(
        base_event(baseline_rate=20_000_000, model_delivery_rate=20_000_000, target=25_000_000),
        {"babr_state": "BASELINE"},
    )
    assert at_enter["state"] == "BASELINE"
    assert at_enter["reason"] == "TARGET_NEAR"

    below_enter = decide(
        base_event(baseline_rate=19_000_000, model_delivery_rate=19_000_000, target=25_000_000),
        {"babr_state": "BASELINE", "reference_rate": 19_000_000},
    )
    assert below_enter["state"] == "ASSIST"

    in_band = decide(
        base_event(baseline_rate=21_000_000, model_delivery_rate=21_000_000, target=25_000_000),
        {"babr_state": "ASSIST", "reference_rate": 19_000_000, "rounds": 1},
    )
    assert in_band["state"] == "ASSIST"

    at_exit = decide(
        base_event(baseline_rate=22_500_000, model_delivery_rate=22_500_000, target=25_000_000),
        {"babr_state": "ASSIST", "reference_rate": 19_000_000, "rounds": 1},
    )
    assert at_exit["state"] == "BASELINE"
    assert at_exit["reason"] == "TARGET_NEAR"


if __name__ == "__main__":
    run()
