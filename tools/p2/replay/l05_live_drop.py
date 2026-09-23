#!/usr/bin/env python3
"""Count ACK drops bracketed by fresh records from one live Assist lease."""

import argparse
import json
import re
import subprocess
import time
from pathlib import Path


def latest_live(trace: Path, deadline: int, after_seq: int):
    try:
        if time.time_ns() - trace.stat().st_mtime_ns >= 20_000_000:
            return None
        with trace.open(encoding="utf-8") as stream:
            lines = stream.read().splitlines()
        if not lines:
            return None
        row = json.loads(lines[-1])
        if (row.get("seq", 0) > after_seq and row.get("state") == "ASSIST"
                and row.get("control_applied") is True
                and row.get("assist_deadline_monotonic_us") == deadline):
            return row["seq"]
    except (OSError, ValueError, TypeError, json.JSONDecodeError):
        pass
    return None


def dropped_packets(output: str):
    match = re.search(r"\(dropped\s+(\d+),", output)
    return int(match.group(1)) if match else None


def live_delta(samples):
    """Only compare consecutive samples inside the same live lease."""
    total = 0
    previous = None
    for seq, count in samples:
        if seq is None or count is None:
            previous = None
            continue
        if previous is not None and seq > previous[0] and count >= previous[1]:
            total += count - previous[1]
        previous = seq, count
    return total


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("trace", type=Path)
    parser.add_argument("status", type=Path)
    parser.add_argument("namespace")
    parser.add_argument("interface")
    parser.add_argument("deadline", type=int)
    parser.add_argument("install_seq", type=int)
    args = parser.parse_args()
    samples = []
    until = time.monotonic() + 0.08
    while time.monotonic() < until:
        seq = latest_live(args.trace, args.deadline, args.install_seq)
        if seq is None:
            samples.append((None, None))
            time.sleep(0.003)
            continue
        try:
            output = subprocess.run(
                ["ip", "netns", "exec", args.namespace, "tc", "-s", "filter", "show",
                 "dev", args.interface, "egress"],
                capture_output=True, text=True, check=True,
            ).stdout
        except (OSError, subprocess.CalledProcessError):
            samples.append((None, None))
            time.sleep(0.003)
            continue
        # The lease may end while the counter command runs. A stale or changed
        # telemetry snapshot must not attribute its drops to Assist.
        if latest_live(args.trace, args.deadline, args.install_seq) != seq:
            samples.append((None, None))
        else:
            samples.append((seq, dropped_packets(output)))
        time.sleep(0.003)
    with args.status.open("a", encoding="utf-8") as stream:
        stream.write(f"ack_drop_during_assist_count={live_delta(samples)}\n")


if __name__ == "__main__":
    main()
