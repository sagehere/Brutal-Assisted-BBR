#!/usr/bin/env python3
"""Require both independent L05 subgates on one code revision."""
import argparse
import json
from pathlib import Path


def compose(network, host, commit):
    errors = []
    for name, value, scenario in (("network", network, "l05-network"),
                                  ("host", host, "l05-host")):
        if value.get("scenario") != scenario:
            errors.append(f"{name}: wrong scenario")
        if value.get("candidate_commit") != commit:
            errors.append(f"{name}: code revision mismatch")
        if value.get("status") not in ("PASS", "BLOCKED", "FAIL"):
            errors.append(f"{name}: invalid status")
    if errors or "FAIL" in (network.get("status"), host.get("status")):
        status = "FAIL"
    elif network.get("status") == host.get("status") == "PASS":
        status = "PASS"
    else:
        status = "BLOCKED"
    return {"schema": "l05-split-v1", "scenario": "l05", "status": status,
            "candidate_commit": commit, "errors": errors,
            "subgates": {"network": network.get("status"), "host": host.get("status")}}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("network", type=Path)
    parser.add_argument("host", type=Path)
    parser.add_argument("commit")
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    result = compose(json.loads(args.network.read_text()),
                     json.loads(args.host.read_text()), args.commit)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps(result, indent=2, sort_keys=True))
    return 2 if result["status"] == "FAIL" else 0


if __name__ == "__main__":
    raise SystemExit(main())
