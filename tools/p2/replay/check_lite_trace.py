#!/usr/bin/env python3
"""Fail-closed validator for P2 Lite JSONL evidence.

The validator deliberately treats missing evidence as BLOCKED.  It does not
infer admission, deadline safety, or protected-phase coverage from pacing.
"""

from __future__ import annotations

import argparse
import json
import math
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
    "schema", "seq", "t_us", "phase", "state", "reason", "W_steps",
    "rounds", "target_Bps", "B_ref_Bps", "budget_bytes",
    "budget_debit_bytes", "unrevocable_queue_bytes", "failure_count",
    "control_applied", "actual_socket_sent_bytes", "dropped_records",
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
        verdict.require(row["reason"] in REASONS, f"record {index}: unknown reason {row['reason']!r}")
        for key in ("seq", "t_us", "W_steps", "rounds", "target_Bps", "budget_bytes",
                    "budget_debit_bytes", "unrevocable_queue_bytes", "failure_count",
                    "dropped_records"):
            verdict.require(numeric(row[key]) and row[key] >= 0,
                            f"record {index}: {key} must be a finite non-negative number")
        verdict.require(isinstance(row["control_applied"], bool),
                        f"record {index}: control_applied must be boolean")
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
        if row["reason"] == "BACKOFF_ACTIVE":
            verdict.require(row["failure_count"] > 0 and
                            numeric(row["backoff_remaining_us"]) and
                            row["backoff_remaining_us"] > 0,
                            f"record {index}: backoff is not backed by a live failure deadline")


def scenario_checks(rows: list[dict[str, Any]], verdict: Verdict) -> None:
    phases = {str(row.get("phase")) for row in rows}
    reasons = {str(row.get("reason")) for row in rows}
    assist = [row for row in rows if row.get("state") == "ASSIST" and row.get("control_applied")]
    admitted = [row for row in assist if numeric(row.get("budget_debit_bytes")) and row["budget_debit_bytes"] > 0]
    socket = [row for row in rows if numeric(row.get("actual_socket_sent_bytes")) and row["actual_socket_sent_bytes"] > 0]
    verdict.facts.update(records=len(rows), phases=sorted(phases), reasons=sorted(reasons),
                         assist_records=len(assist), admitted_records=len(admitted),
                         socket_evidence_records=len(socket))

    if verdict.scenario == "l03":
        verdict.evidence(bool(assist), "no real Assist decision observed")
        verdict.evidence(bool(admitted), "no Assist budget pre-debit observed")
        verdict.evidence(bool(socket), "no socket-success evidence observed")
        verdict.evidence(bool(reasons & ASSIST_EXITS), "no bounded Assist exit observed")
        verdict.evidence(any(row.get("reason") == "NO_BENEFIT" for row in rows),
                         "no low-queue NO_BENEFIT exit observed")
        verdict.evidence(any(row.get("state") == "ASSIST_BACKOFF" for row in rows),
                         "no backoff state observed")
    elif verdict.scenario == "l04":
        verdict.evidence(PROTECTED <= phases,
                         "missing protected phase coverage: " + ", ".join(sorted(PROTECTED - phases)))
        verdict.evidence(bool(reasons & {"LOSS_DETECTED", "PTO_FIRED"}),
                         "missing real LossDetected or PtoFired coverage")
    elif verdict.scenario == "l05":
        verdict.evidence(bool(assist), "no Assist before ACK suppression")
        verdict.evidence("ASSIST_TIMEOUT" in reasons, "no ACK-independent timeout observed")
        verdict.evidence("PTO_FIRED" in reasons, "no legal PTO evidence observed")
    elif verdict.scenario == "l10":
        verdict.evidence(bool(assist), "no real Assist decision observed")
        verdict.evidence("MODE_NOT_LITE" in reasons or "TARGET_DISABLED" in reasons,
                         "no online revocation/close evidence observed")
    elif verdict.scenario == "generic":
        return
    else:
        verdict.errors.append(f"unknown scenario {verdict.scenario!r}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("trace", type=Path)
    parser.add_argument("--scenario", default="generic", choices=("generic", "l03", "l04", "l05", "l10"))
    parser.add_argument("--summary", type=Path)
    args = parser.parse_args()
    verdict = Verdict(args.scenario)
    rows = load(args.trace, verdict)
    validate_rows(rows, verdict)
    scenario_checks(rows, verdict)
    report = {"schema": "p2-lite-evidence-v1", "scenario": verdict.scenario,
              "status": verdict.status, "errors": verdict.errors,
              "blocked": verdict.blocked, "facts": verdict.facts}
    rendered = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.summary:
        args.summary.write_text(rendered, encoding="utf-8")
    sys.stdout.write(rendered)
    return 0 if verdict.status == "PASS" else 2


if __name__ == "__main__":
    raise SystemExit(main())
