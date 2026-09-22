#!/usr/bin/env python3
"""Run one child command and persist Linux wait4/rusage metrics.

The wrapper is intentionally outside the measured child. The child PID is
published so the harness can terminate the long-running server after one QUIC
connection. CPU and max RSS come from wait4(), avoiding /proc clock-tick
quantization at the frozen 2% CPU threshold.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import signal
import sys
import time


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pid-file", required=True)
    parser.add_argument("--metrics-file", required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()

    cmd = list(args.command)
    if cmd and cmd[0] == "--":
        cmd = cmd[1:]
    if not cmd:
        parser.error("missing child command")

    pid_path = Path(args.pid_file)
    metrics_path = Path(args.metrics_file)
    pid_path.parent.mkdir(parents=True, exist_ok=True)
    metrics_path.parent.mkdir(parents=True, exist_ok=True)

    started = time.monotonic_ns()
    child = os.fork()
    if child == 0:
        try:
            os.execvp(cmd[0], cmd)
        except BaseException as exc:
            print(f"exec failed: {exc}", file=sys.stderr)
            os._exit(127)

    tmp_pid = pid_path.with_suffix(pid_path.suffix + ".tmp")
    tmp_pid.write_text(f"{child}\n", encoding="utf-8")
    os.replace(tmp_pid, pid_path)

    waited_pid, status, usage = os.wait4(child, 0)
    ended = time.monotonic_ns()
    assert waited_pid == child

    exit_code = None
    term_signal = None
    if os.WIFEXITED(status):
        exit_code = os.WEXITSTATUS(status)
    elif os.WIFSIGNALED(status):
        term_signal = os.WTERMSIG(status)

    # Linux ru_maxrss is KiB.
    payload = {
        "schema": "p2-server-rusage-v1",
        "pid": child,
        "wall_seconds": (ended - started) / 1_000_000_000,
        "user_cpu_seconds": usage.ru_utime,
        "system_cpu_seconds": usage.ru_stime,
        "cpu_seconds": usage.ru_utime + usage.ru_stime,
        "max_rss_kib": usage.ru_maxrss,
        "minor_faults": usage.ru_minflt,
        "major_faults": usage.ru_majflt,
        "voluntary_context_switches": usage.ru_nvcsw,
        "involuntary_context_switches": usage.ru_nivcsw,
        "exit_code": exit_code,
        "term_signal": term_signal,
    }
    tmp_metrics = metrics_path.with_suffix(metrics_path.suffix + ".tmp")
    tmp_metrics.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    os.replace(tmp_metrics, metrics_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
