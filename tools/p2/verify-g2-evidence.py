#!/usr/bin/env python3
"""Aggregate P2 evidence without allowing mixed revisions or skipped cases."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


REQUIRED = ("l03", "l04", "l05", "l06", "l08_l09", "l10", "observe_resources", "lite_resources")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", type=Path,
                        help="JSON object keyed by required evidence name")
    parser.add_argument("--summary", type=Path)
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    candidate = manifest.get("candidate_commit")
    failures: list[str] = []
    if not isinstance(candidate, str) or len(candidate) < 7:
        failures.append("candidate_commit is required")
    evidence = manifest.get("evidence")
    if not isinstance(evidence, dict):
        failures.append("evidence object is required")
        evidence = {}
    for name in REQUIRED:
        item = evidence.get(name)
        if not isinstance(item, dict):
            failures.append(f"{name}: missing")
            continue
        if item.get("status") != "PASS":
            failures.append(f"{name}: status must be PASS, got {item.get('status')!r}")
        if item.get("commit") != candidate:
            failures.append(f"{name}: commit does not match candidate")
        artifact = item.get("artifact")
        if not isinstance(artifact, str) or not artifact:
            failures.append(f"{name}: artifact reference is required")
    report = {
        "schema": "p2-g2-evidence-v1",
        "candidate_commit": candidate,
        "status": "PASS" if not failures else "BLOCKED",
        "failures": failures,
        "required": list(REQUIRED),
    }
    rendered = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.summary:
        args.summary.write_text(rendered, encoding="utf-8")
    sys.stdout.write(rendered)
    return 0 if not failures else 2


if __name__ == "__main__":
    raise SystemExit(main())
