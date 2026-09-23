#!/usr/bin/env python3
"""Aggregate independent real L05 attempts without promoting BLOCKED evidence."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


def aggregate(reports: list[tuple[str, dict[str, Any]]]) -> dict[str, Any]:
    errors: list[str] = []
    if not reports:
        errors.append("no L05 run summaries were collected")

    runs = []
    for name, report in reports:
        status = report.get("status")
        if report.get("scenario") != "l05":
            errors.append(f"{name}: summary scenario is not l05")
        if status not in {"PASS", "BLOCKED", "FAIL"}:
            errors.append(f"{name}: invalid or missing status {status!r}")
            status = "FAIL"
        if report.get("errors"):
            errors.extend(f"{name}: {error}" for error in report["errors"])
        runs.append({
            "run": name,
            "status": status,
            "blocked": report.get("blocked", []),
            "errors": report.get("errors", []),
            "facts": report.get("facts", {}),
        })

    if errors or any(run["status"] == "FAIL" for run in runs):
        status = "FAIL"
    elif any(run["status"] == "PASS" for run in runs):
        status = "PASS"
    else:
        status = "BLOCKED"

    return {
        "schema": "p2-lite-evidence-aggregate-v1",
        "scenario": "l05",
        "status": status,
        "errors": errors,
        "facts": {
            "attempts": len(runs),
            "pass_attempts": sum(run["status"] == "PASS" for run in runs),
            "blocked_attempts": sum(run["status"] == "BLOCKED" for run in runs),
        },
        "runs": runs,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("artifact_root", type=Path)
    parser.add_argument("--summary", type=Path)
    args = parser.parse_args()

    reports: list[tuple[str, dict[str, Any]]] = []
    for path in sorted(args.artifact_root.glob("run-*/summary.json")):
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            value = {"scenario": "l05", "status": "FAIL", "errors": [str(exc)]}
        reports.append((path.parent.name, value))

    result = aggregate(reports)
    rendered = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.summary:
        args.summary.write_text(rendered, encoding="utf-8")
    sys.stdout.write(rendered)
    return 2 if result["status"] == "FAIL" else 0


if __name__ == "__main__":
    raise SystemExit(main())
