#!/usr/bin/env python3
"""Fail-closed validator for P2 Lite JSONL evidence.

The validator deliberately treats missing evidence as BLOCKED.  It does not
infer admission, deadline safety, or protected-phase coverage from pacing.
"""

from __future__ import annotations

import argparse
import json
import math
import statistics
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


SCHEMA = "p2-lite-v2"
REASONS = {
    "TARGET_DISABLED", "INVALID_TARGET", "MODE_NOT_LITE", "PATH_CHANGED",
    "APP_LIMITED", "RECEIVER_LIMITED", "POLICY_LIMITED",
    "BBR_PHASE_PROTECTED", "LOSS_DETECTED", "PTO_FIRED", "BACKOFF_ACTIVE",
    "SAMPLE_INVALID", "TARGET_NEAR", "ASSIST_TIMEOUT",
    "ASSIST_BUDGET_EXHAUSTED", "MAX_ROUNDS", "HARD_QUEUE_DELAY",
    "NO_BENEFIT", "SOFT_FREEZE", "BOUNDED_PROBE",
}
PROTECTED = {"Startup", "Drain", "ProbeRTT", "ProbeBW.Down"}
ASSIST_EXITS = {
    "ASSIST_TIMEOUT", "ASSIST_BUDGET_EXHAUSTED", "MAX_ROUNDS",
    "HARD_QUEUE_DELAY", "NO_BENEFIT", "LOSS_DETECTED", "PTO_FIRED",
}
REQUIRED = {
    "schema", "configuration_version", "seq", "t_us", "connection_tag",
    "path_id", "phase", "state", "reason", "W_steps",
    "rounds", "target_Bps", "B_ref_Bps", "budget_bytes",
    "budget_debit_bytes", "unrevocable_queue_bytes", "failure_count",
    "control_applied", "actual_socket_sent_bytes", "model_delivery_Bps",
    "dropped_records",
    "inflight_bytes", "srtt_us", "min_rtt_us", "sample_valid",
    "sample_age_rounds", "assist_deadline_monotonic_us",
    "assist_deadline_remaining_us", "backoff_remaining_us",
}


@dataclass
class Verdict:
    scenario: str
    errors: list[str] = field(default_factory=list)
    blocked: list[str] = field(default_factory=list)
    facts: dict[str, Any] = field(default_factory=dict)

    @property
    def status(self) -> str:
        if self.errors:
            return "FAIL"
        if self.blocked:
            return "BLOCKED"
        return "PASS"

    def require(self, condition: bool, message: str) -> None:
        if not condition:
            self.errors.append(message)

    def evidence(self, condition: bool, message: str) -> None:
        if not condition:
            self.blocked.append(message)


def numeric(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def load(path: Path, verdict: Verdict) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for line_no, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError as exc:
            verdict.errors.append(f"line {line_no}: invalid JSON: {exc.msg}")
            continue
        if not isinstance(row, dict):
            verdict.errors.append(f"line {line_no}: record is not an object")
            continue
        rows.append(row)
    verdict.evidence(bool(rows), "no Lite telemetry records")
    return rows


def validate_rows(rows: list[dict[str, Any]], verdict: Verdict) -> None:
    previous_seq = previous_time = -1
    for index, row in enumerate(rows, 1):
        missing = REQUIRED - row.keys()
        verdict.require(not missing, f"record {index}: missing required fields {sorted(missing)}")
        if missing:
            continue
        verdict.require(row["schema"] == SCHEMA, f"record {index}: schema must be {SCHEMA}")
        verdict.require(row["configuration_version"] == "p1-baseline-v4",
                        f"record {index}: unknown configuration version")
        verdict.require(row["reason"] in REASONS, f"record {index}: unknown reason {row['reason']!r}")
        verdict.require(isinstance(row["phase"], str) and isinstance(row["state"], str),
                        f"record {index}: phase and state must be strings")
        for key in ("seq", "t_us", "connection_tag", "path_id", "W_steps", "rounds", "target_Bps", "model_delivery_Bps", "budget_bytes",
                    "budget_debit_bytes", "unrevocable_queue_bytes", "failure_count",
                    "dropped_records", "inflight_bytes", "srtt_us", "sample_age_rounds"):
            verdict.require(numeric(row[key]) and row[key] >= 0,
                            f"record {index}: {key} must be a finite non-negative number")
        verdict.require(isinstance(row["control_applied"], bool),
                        f"record {index}: control_applied must be boolean")
        verdict.require(isinstance(row["sample_valid"], bool),
                        f"record {index}: sample_valid must be boolean")
        for key in ("B_ref_Bps", "actual_socket_sent_bytes", "min_rtt_us",
                    "assist_deadline_monotonic_us", "assist_deadline_remaining_us",
                    "backoff_remaining_us"):
            verdict.require(row[key] is None or (numeric(row[key]) and row[key] >= 0),
                            f"record {index}: {key} must be null or a finite non-negative number")
        if numeric(row["seq"]):
            verdict.require(row["seq"] > previous_seq, f"record {index}: seq is not strictly monotonic")
            previous_seq = row["seq"]
        if numeric(row["t_us"]):
            verdict.require(row["t_us"] >= previous_time, f"record {index}: t_us regressed")
            previous_time = row["t_us"]
        if numeric(row["budget_debit_bytes"]) and numeric(row["budget_bytes"]):
            verdict.require(row["budget_debit_bytes"] <= row["budget_bytes"],
                            f"record {index}: budget debit exceeds frozen budget")
        if numeric(row["unrevocable_queue_bytes"]):
            verdict.require(row["unrevocable_queue_bytes"] <= 2400,
                            f"record {index}: unrevocable queue exceeds 2400 bytes")
        if row["phase"] in PROTECTED:
            verdict.require(row["W_steps"] == 0 and not row["control_applied"],
                            f"record {index}: protected phase applied Assist")
        if row["state"] == "ASSIST" and row["control_applied"]:
            verdict.require(numeric(row["assist_deadline_remaining_us"]) and
                            row["assist_deadline_remaining_us"] > 0,
                            f"record {index}: Assist authorization is expired or unavailable")
            verdict.require(numeric(row["assist_deadline_monotonic_us"]) and
                            row["assist_deadline_monotonic_us"] > row["t_us"],
                            f"record {index}: Assist authorization has no absolute future deadline")
        if row["reason"] == "BACKOFF_ACTIVE":
            verdict.require(row["failure_count"] > 0 and
                            numeric(row["backoff_remaining_us"]) and
                            row["backoff_remaining_us"] > 0,
                            f"record {index}: backoff is not backed by a live failure deadline")


def scenario_checks(rows: list[dict[str, Any]], verdict: Verdict,
                    ack_drop_count: int | None = None) -> None:
    phases = {str(row.get("phase")) for row in rows}
    reasons = {str(row.get("reason")) for row in rows}
    assist = [row for row in rows if row.get("state") == "ASSIST" and row.get("control_applied")]
    admitted = [row for row in assist if numeric(row.get("budget_debit_bytes")) and row["budget_debit_bytes"] > 0]
    socket = [row for row in rows if numeric(row.get("actual_socket_sent_bytes")) and row["actual_socket_sent_bytes"] > 0]
    socket_after_admission = False
    socket_after_timeout = False
    admission_indices = [index for index, row in enumerate(rows)
                         if row.get("state") == "ASSIST" and
                         row.get("control_applied") and
                         numeric(row.get("budget_debit_bytes")) and
                         row["budget_debit_bytes"] > 0]
    if admission_indices:
        first_admission = admission_indices[0]
        before = [row.get("actual_socket_sent_bytes") for row in rows[:first_admission]
                  if numeric(row.get("actual_socket_sent_bytes"))]
        after = [row.get("actual_socket_sent_bytes") for row in rows[first_admission + 1:]
                 if numeric(row.get("actual_socket_sent_bytes"))]
        socket_after_admission = bool(after) and max(after) > max(before, default=0)
    timeout_indices = [index for index, row in enumerate(rows)
                       if row.get("reason") == "ASSIST_TIMEOUT"]
    admitted_deadlines = [row.get("assist_deadline_monotonic_us") for row in admitted
                         if numeric(row.get("assist_deadline_monotonic_us"))]
    timeout_after_assist_deadline = any(
        numeric(rows[index].get("t_us")) and
        any(deadline <= rows[index]["t_us"] for deadline in admitted_deadlines)
        for index in timeout_indices
    )
    if timeout_indices:
        first_timeout = timeout_indices[0]
        timeout_bytes = rows[first_timeout].get("actual_socket_sent_bytes")
        after_timeout = [row.get("actual_socket_sent_bytes") for row in rows[first_timeout + 1:]
                         if numeric(row.get("actual_socket_sent_bytes"))]
        socket_after_timeout = numeric(timeout_bytes) and bool(after_timeout) and \
            max(after_timeout) > timeout_bytes
    verdict.facts.update(records=len(rows), phases=sorted(phases), reasons=sorted(reasons),
                         assist_records=len(assist), admitted_records=len(admitted),
                         socket_evidence_records=len(socket),
                         socket_progress_after_admission=socket_after_admission,
                         socket_progress_after_timeout=socket_after_timeout,
                         timeout_after_assist_deadline=timeout_after_assist_deadline)

    if verdict.scenario == "l03":
        verdict.evidence(bool(assist), "no real Assist decision observed")
        verdict.evidence(bool(admitted), "no Assist budget pre-debit observed")
        verdict.evidence(bool(socket), "no socket-success evidence observed")
        verdict.evidence(socket_after_admission,
                         "no socket-byte progress after an Assist admission")
        verdict.evidence(bool(reasons & ASSIST_EXITS), "no bounded Assist exit observed")
        verdict.evidence(any(row.get("state") == "ASSIST_BACKOFF" for row in rows),
                         "no backoff state observed")
    elif verdict.scenario == "l04":
        verdict.evidence(bool(PROTECTED & phases),
                         "no real protected BBR phase observed")
    elif verdict.scenario == "l05-network":
        verdict.evidence(bool(admitted), "no real Assist budget pre-debit")
        verdict.evidence(ack_drop_count is not None and ack_drop_count > 0,
                         "no router ACK-drop counter evidence")
        install_seq = verdict.facts.get("ack_filter_install_last_seq")
        verdict.evidence(bool(verdict.facts.get("ack_filter_active_during_assist")) and
                         numeric(install_seq) and any(
                             r.get("seq") == install_seq and r.get("state") == "ASSIST"
                             and r.get("control_applied") for r in rows),
                         "ACK drop was not verified during a live admitted Assist")
        exits = [i for i, r in enumerate(rows)
                 if r.get("reason") in ASSIST_EXITS and
                 r.get("state") == "ASSIST_BACKOFF" and
                 numeric(install_seq) and numeric(r.get("seq")) and
                 r["seq"] > install_seq and any(j < i for j in admission_indices)]
        verdict.evidence(bool(exits), "no bounded safety exit after ACK filter installation")
        if exits:
            first_exit = exits[0]
            verdict.require(all(not (r.get("state") == "ASSIST" and
                                     r.get("control_applied"))
                                for r in rows[first_exit + 1:]),
                            "Assist reapplied after bounded safety exit")
            verdict.evidence(any(r.get("state") == "ASSIST_BACKOFF" and
                                 r.get("W_steps") == 0 and not r.get("control_applied")
                                 for r in rows[first_exit:]),
                             "no safe backoff with zero Assist weight")
    elif verdict.scenario == "l10":
        verdict.evidence(bool(assist), "no real Assist decision observed")
        verdict.evidence("MODE_NOT_LITE" in reasons or "TARGET_DISABLED" in reasons,
                         "no online revocation/close evidence observed")
    elif verdict.scenario == "generic":
        return
    else:
        verdict.errors.append(f"unknown scenario {verdict.scenario!r}")


def nearest_rank(values: list[float], percentile: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    return ordered[max(1, math.ceil(percentile * len(ordered))) - 1]


def diagnostic_summary(rows: list[dict[str, Any]]) -> dict[str, Any]:
    """Summarize the real decision inputs without changing any gate result."""
    grouped: dict[str, list[dict[str, Any]]] = {}
    phase_reason_counts: dict[str, dict[str, int]] = {}
    for row in rows:
        reason = str(row.get("reason", "UNKNOWN"))
        phase = str(row.get("phase", "UNKNOWN"))
        grouped.setdefault(reason, []).append(row)
        by_reason = phase_reason_counts.setdefault(phase, {})
        by_reason[reason] = by_reason.get(reason, 0) + 1

    reason_summary: dict[str, Any] = {}
    for reason, group in sorted(grouped.items()):
        delivery_ratios = [
            row["model_delivery_Bps"] / row["target_Bps"]
            for row in group
            if numeric(row.get("model_delivery_Bps"))
            and numeric(row.get("target_Bps")) and row["target_Bps"] > 0
        ]
        queue_delays_ms = [
            max(0, row["srtt_us"] - row["min_rtt_us"]) / 1000.0
            for row in group
            if numeric(row.get("srtt_us")) and numeric(row.get("min_rtt_us"))
        ]
        sample_ages = [row["sample_age_rounds"] for row in group
                       if numeric(row.get("sample_age_rounds"))]
        inflight = [row["inflight_bytes"] for row in group
                    if numeric(row.get("inflight_bytes"))]
        reason_summary[reason] = {
            "records": len(group),
            "model_delivery_to_target_ratio_p50": statistics.median(delivery_ratios)
            if delivery_ratios else None,
            "model_delivery_to_target_ratio_p95": nearest_rank(delivery_ratios, 0.95),
            "queue_delay_ms_p50": statistics.median(queue_delays_ms)
            if queue_delays_ms else None,
            "queue_delay_ms_p95": nearest_rank(queue_delays_ms, 0.95),
            "sample_age_rounds_p95": nearest_rank(sample_ages, 0.95),
            "inflight_bytes_p95": nearest_rank(inflight, 0.95),
        }
    return {
        "phase_reason_counts": phase_reason_counts,
        "reason_summary": reason_summary,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("trace", type=Path)
    parser.add_argument("--scenario", default="generic", choices=("generic", "l03", "l04", "l05-network", "l10"))
    parser.add_argument("--summary", type=Path)
    parser.add_argument(
        "--ack-drop-count", type=int,
        help="actual packets dropped by the router ACK suppression filter",
    )
    parser.add_argument(
        "--allow-blocked",
        action="store_true",
        help="write a valid BLOCKED evidence record without failing collection",
    )
    parser.add_argument("--ack-filter-active-during-assist", action="store_true")
    parser.add_argument("--ack-filter-install-last-seq", type=int)
    args = parser.parse_args()
    verdict = Verdict(args.scenario)
    rows = load(args.trace, verdict)
    validate_rows(rows, verdict)
    if args.ack_drop_count is not None:
        verdict.require(args.ack_drop_count >= 0,
                        "ACK-drop count must be non-negative")
        verdict.facts["ack_drop_count"] = args.ack_drop_count
    verdict.facts["ack_filter_active_during_assist"] = args.ack_filter_active_during_assist
    verdict.facts["ack_filter_install_last_seq"] = args.ack_filter_install_last_seq
    scenario_checks(rows, verdict, args.ack_drop_count)
    report = {"schema": "p2-lite-evidence-v1", "scenario": verdict.scenario,
              "status": verdict.status, "errors": verdict.errors,
              "blocked": verdict.blocked, "facts": verdict.facts,
              "diagnostics": diagnostic_summary(rows)}
    rendered = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.summary:
        args.summary.write_text(rendered, encoding="utf-8")
    sys.stdout.write(rendered)
    if verdict.status == "PASS" or (
        verdict.status == "BLOCKED" and args.allow_blocked
    ):
        return 0
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
