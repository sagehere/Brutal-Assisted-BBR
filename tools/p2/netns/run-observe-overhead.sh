#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/common.sh"

require_root
require_cmds

for cmd in ss sha256sum stat date python3 awk grep; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    exit 93
  fi
done

HOST="$P2_ROOT/third_party/quiche-0.29.3"
SERVER_BIN="${BABR_P2_SERVER_BIN:-$HOST/target/release/examples/async_http3_server}"
CLIENT_BIN="${BABR_P2_CLIENT_BIN:-$HOST/target/release/quiche-client}"
PAIR_COUNT="${BABR_P2_OVERHEAD_PAIRS:-20}"
FLOW_BYTES="${BABR_P2_OVERHEAD_FLOW_BYTES:-134217728}"
WARMUP_BYTES="${BABR_P2_OVERHEAD_WARMUP_BYTES:-67108864}"
LOG_FLOW_BYTES="${BABR_P2_LOG_FLOW_BYTES:-805306368}"
PORT="${BABR_P2_QUIC_PORT:-4433}"
DATA_DIRECTION="${BABR_DATA_DIRECTION:-receiver_to_sender}"
OUT="${BABR_P2_OVERHEAD_ARTIFACT_DIR:-$P2_ROOT/阶段任务书/p2-observe-overhead-artifacts}"

CPU_LIMIT_RATIO="0.02"
MEMORY_LIMIT_BYTES="262144"
LOG_LIMIT_BYTES_PER_60S="1048576"

if (( PAIR_COUNT < 10 )); then
  echo "Overhead gate requires at least 10 measured pairs; got $PAIR_COUNT" >&2
  exit 94
fi

for bin in "$SERVER_BIN" "$CLIENT_BIN"; do
  if [[ ! -x "$bin" ]]; then
    echo "Required release binary is missing or not executable: $bin" >&2
    exit 95
  fi
done

rm -rf "$OUT"
mkdir -p "$OUT/pairs"

SERVER_PID=""
SERVER_WRAPPER_PID=""

cleanup_all() {
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    kill -TERM "$SERVER_PID" >/dev/null 2>&1 || true
    sleep 0.1
    kill -KILL "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$SERVER_WRAPPER_PID" ]]; then
    wait "$SERVER_WRAPPER_PID" >/dev/null 2>&1 || true
  fi
  SERVER_PID=""
  SERVER_WRAPPER_PID=""
  bash "$HERE/cleanup.sh" >/dev/null 2>&1 || true
}
trap cleanup_all EXIT

wait_for_pid_file() {
  local pid_file="$1"
  for _ in $(seq 1 100); do
    if [[ -s "$pid_file" ]]; then
      return 0
    fi
    sleep 0.05
  done
  echo "Timed out waiting for measured server PID file: $pid_file" >&2
  return 1
}

wait_for_server() {
  for _ in $(seq 1 100); do
    if ip netns exec "$NS_D" ss -lun | grep -Fq "$D_IP:$PORT"; then
      return 0
    fi
    if [[ -n "$SERVER_PID" ]] && ! kill -0 "$SERVER_PID" >/dev/null 2>&1; then
      echo "Measured QUIC server exited before listening" >&2
      return 1
    fi
    sleep 0.05
  done
  echo "Timed out waiting for measured QUIC server to listen" >&2
  return 1
}

stop_server() {
  local metrics_file="$1"

  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    kill -TERM "$SERVER_PID" >/dev/null 2>&1 || true
  fi

  for _ in $(seq 1 50); do
    if [[ -z "$SERVER_PID" ]] || ! kill -0 "$SERVER_PID" >/dev/null 2>&1; then
      break
    fi
    sleep 0.05
  done

  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    kill -KILL "$SERVER_PID" >/dev/null 2>&1 || true
  fi

  if [[ -n "$SERVER_WRAPPER_PID" ]]; then
    wait "$SERVER_WRAPPER_PID" >/dev/null 2>&1 || true
  fi

  SERVER_PID=""
  SERVER_WRAPPER_PID=""

  if [[ ! -s "$metrics_file" ]]; then
    echo "Measured server produced no rusage file: $metrics_file" >&2
    return 1
  fi
}

validate_observe_trace() {
  local trace="$1"
  local summary="$2"

  python3 - "$trace" "$summary" <<'PY'
import json
import os
import sys

trace_path, summary_path = sys.argv[1:3]
records = []
charged = 0
with open(trace_path, "rb") as fh:
    for line_no, raw in enumerate(fh, 1):
        if not raw.strip():
            continue
        charged += len(raw)
        obj = json.loads(raw)
        assert obj["schema"] == "p2-observe-v1", (line_no, obj)
        assert obj["reason"] == "MODE_NOT_LITE", (line_no, obj)
        records.append(obj)

assert records, "Observe telemetry contains no records"
summary = {
    "records": len(records),
    "serialized_bytes": charged,
    "first_t_us": records[0]["t_us"],
    "last_t_us": records[-1]["t_us"],
    "shadow_reasons": sorted({r["shadow_reason"] for r in records}),
    "transport_reasons": sorted({r["reason"] for r in records}),
}
with open(summary_path, "w", encoding="utf-8") as fh:
    json.dump(summary, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
}

run_transfer() {
  local mode="$1"
  local run_dir="$2"
  local bytes="$3"

  rm -rf "$run_dir"
  mkdir -p "$run_dir/response"

  bash "$HERE/setup.sh" >/dev/null
  BABR_DATA_DIRECTION="$DATA_DIRECTION" bash "$HERE/shape.sh" >/dev/null

  local trace="$run_dir/observe.jsonl"
  local pid_file="$run_dir/server.pid"
  local rusage="$run_dir/server-rusage.json"
  local -a server_env=("RUST_LOG=warn")
  if [[ "$mode" == "observe" ]]; then
    server_env+=("BABR_OBSERVE_TELEMETRY_FILE=$trace")
  fi

  python3 "$HERE/run_with_rusage.py"     --pid-file "$pid_file"     --metrics-file "$rusage"     --     ip netns exec "$NS_D" env "${server_env[@]}"     "$SERVER_BIN"       --address "$D_IP:$PORT"       --cc-algorithm bbr2       --enable-pacing     > "$run_dir/server.log" 2>&1 &
  SERVER_WRAPPER_PID=$!

  wait_for_pid_file "$pid_file"
  SERVER_PID="$(cat "$pid_file")"
  wait_for_server

  local start_ns end_ns
  start_ns="$(date +%s%N)"

  ip netns exec "$NS_S" env RUST_LOG=warn     "$CLIENT_BIN"       "https://test.com/stream-bytes/$bytes"       --no-verify       --connect-to "$D_IP:$PORT"       --http-version HTTP/3       --max-data 2147483648       --max-window 2147483648       --max-stream-data 2147483648       --max-stream-window 2147483648       --idle-timeout 120000       --dump-responses "$run_dir/response"     > "$run_dir/client.log" 2>&1

  end_ns="$(date +%s%N)"
  sleep 0.25

  ip netns exec "$NS_R" tc -s qdisc show dev "$R_S_IF"     > "$run_dir/qdisc-router-to-sender.txt"
  ip netns exec "$NS_R" tc -s qdisc show dev "$R_D_IF"     > "$run_dir/qdisc-router-to-receiver.txt"

  local response="$run_dir/response/$bytes"
  if [[ ! -f "$response" ]]; then
    echo "$mode response file missing: $response" >&2
    exit 96
  fi

  local response_bytes
  response_bytes="$(stat -c %s "$response")"
  if [[ "$response_bytes" != "$bytes" ]]; then
    echo "$mode response size mismatch: expected $bytes got $response_bytes" >&2
    exit 97
  fi
  sha256sum "$response" > "$run_dir/response.sha256"

  local bottleneck_qdisc
  case "$DATA_DIRECTION" in
    receiver_to_sender)
      bottleneck_qdisc="$run_dir/qdisc-router-to-sender.txt"
      ;;
    sender_to_receiver)
      bottleneck_qdisc="$run_dir/qdisc-router-to-receiver.txt"
      ;;
    *)
      echo "Unsupported data direction during overhead verification" >&2
      exit 98
      ;;
  esac

  grep -q "qdisc tbf" "$bottleneck_qdisc"
  local tbf_sent_bytes
  tbf_sent_bytes="$(awk '/ Sent / {print $2; exit}' "$bottleneck_qdisc")"
  if [[ -z "$tbf_sent_bytes" || "$tbf_sent_bytes" -lt "$bytes" ]]; then
    echo "$mode TBF did not carry the bulk response: sent=$tbf_sent_bytes flow=$bytes" >&2
    exit 99
  fi

  if [[ "$mode" == "off" ]]; then
    if [[ -s "$trace" ]]; then
      echo "Off mode unexpectedly produced BABR Observe telemetry" >&2
      exit 100
    fi
  else
    if [[ ! -s "$trace" ]]; then
      echo "Observe mode produced no BABR telemetry" >&2
      exit 101
    fi
    validate_observe_trace "$trace" "$run_dir/observe-summary.json"
  fi

  stop_server "$rusage"

  python3 -     "$start_ns" "$end_ns" "$bytes" "${BABR_RATE_MBIT:-100}"     "$tbf_sent_bytes" "$mode" "$rusage" "$trace" "$run_dir/metrics.json" <<'PY'
import json
import os
import sys

(
    start_ns,
    end_ns,
    flow_bytes,
    rate_mbit,
    tbf_sent_bytes,
    mode,
    rusage_path,
    trace_path,
    out_path,
) = sys.argv[1:]

elapsed = (int(end_ns) - int(start_ns)) / 1_000_000_000
flow_bytes = int(flow_bytes)
rate_mbit = float(rate_mbit)
goodput_mbit = flow_bytes * 8 / elapsed / 1_000_000
min_elapsed = flow_bytes * 8 / (rate_mbit * 1.15 * 1_000_000)

with open(rusage_path, encoding="utf-8") as fh:
    rusage = json.load(fh)

metrics = {
    "schema": "p2-observe-overhead-run-v1",
    "mode": mode,
    "flow_bytes": flow_bytes,
    "elapsed_seconds": elapsed,
    "application_goodput_mbit": goodput_mbit,
    "configured_rate_mbit": rate_mbit,
    "minimum_elapsed_for_115pct_rate_seconds": min_elapsed,
    "bottleneck_timing_pass": elapsed >= min_elapsed,
    "tbf_sent_bytes": int(tbf_sent_bytes),
    "server_cpu_seconds": rusage["cpu_seconds"],
    "server_user_cpu_seconds": rusage["user_cpu_seconds"],
    "server_system_cpu_seconds": rusage["system_cpu_seconds"],
    "server_max_rss_kib": rusage["max_rss_kib"],
    "telemetry_bytes": os.path.getsize(trace_path) if os.path.exists(trace_path) else 0,
}
if not metrics["bottleneck_timing_pass"]:
    raise SystemExit("bulk response bypassed or exceeded configured TBF tolerance")
if metrics["server_cpu_seconds"] <= 0:
    raise SystemExit("measured server CPU time is non-positive")

with open(out_path, "w", encoding="utf-8") as fh:
    json.dump(metrics, fh, indent=2, sort_keys=True)
    fh.write("\n")
print(json.dumps(metrics, sort_keys=True))
PY

  # Keep only hashes/metrics/logs, not hundreds of MiB of response bodies.
  rm -rf "$run_dir/response"

  bash "$HERE/cleanup.sh" >/dev/null
}

# Warm the binary/filesystem/network setup without admitting these samples into
# the frozen p95 decision.
run_transfer off "$OUT/warmup/off" "$WARMUP_BYTES"
run_transfer observe "$OUT/warmup/observe" "$WARMUP_BYTES"

for i in $(seq 1 "$PAIR_COUNT"); do
  pair_dir="$OUT/pairs/$(printf '%02d' "$i")"
  if (( i % 2 == 1 )); then
    run_transfer off "$pair_dir/off" "$FLOW_BYTES"
    run_transfer observe "$pair_dir/observe" "$FLOW_BYTES"
  else
    run_transfer observe "$pair_dir/observe" "$FLOW_BYTES"
    run_transfer off "$pair_dir/off" "$FLOW_BYTES"
  fi
done

python3 - "$OUT/pairs" "$PAIR_COUNT" "$CPU_LIMIT_RATIO" "$MEMORY_LIMIT_BYTES" "$OUT/overhead-summary.json" <<'PY'
import json
import math
import os
import statistics
import sys

pairs_root, count_s, cpu_limit_s, mem_limit_s, out_path = sys.argv[1:]
count = int(count_s)
cpu_limit = float(cpu_limit_s)
mem_limit = int(mem_limit_s)

rows = []
for i in range(1, count + 1):
    pair_dir = os.path.join(pairs_root, f"{i:02d}")
    with open(os.path.join(pair_dir, "off", "metrics.json"), encoding="utf-8") as fh:
        off = json.load(fh)
    with open(os.path.join(pair_dir, "observe", "metrics.json"), encoding="utf-8") as fh:
        observe = json.load(fh)

    cpu_ratio = observe["server_cpu_seconds"] / off["server_cpu_seconds"] - 1.0
    rss_delta_bytes = (
        observe["server_max_rss_kib"] - off["server_max_rss_kib"]
    ) * 1024
    throughput_ratio = (
        observe["application_goodput_mbit"] / off["application_goodput_mbit"] - 1.0
    )
    rows.append({
        "pair": i,
        "off_cpu_seconds": off["server_cpu_seconds"],
        "observe_cpu_seconds": observe["server_cpu_seconds"],
        "cpu_overhead_ratio": cpu_ratio,
        "off_max_rss_kib": off["server_max_rss_kib"],
        "observe_max_rss_kib": observe["server_max_rss_kib"],
        "rss_incremental_bytes": rss_delta_bytes,
        "off_goodput_mbit": off["application_goodput_mbit"],
        "observe_goodput_mbit": observe["application_goodput_mbit"],
        "throughput_ratio": throughput_ratio,
        "observe_telemetry_bytes": observe["telemetry_bytes"],
    })

def nearest_rank_p(values, p):
    ordered = sorted(values)
    rank = max(1, math.ceil(p * len(ordered)))
    return ordered[rank - 1]

cpu_values = [r["cpu_overhead_ratio"] for r in rows]
rss_values = [r["rss_incremental_bytes"] for r in rows]
throughput_values = [r["throughput_ratio"] for r in rows]

summary = {
    "schema": "p2-observe-overhead-summary-v1",
    "pairs": count,
    "cpu_metric": "paired server process (user+sys CPU seconds), same payload",
    "cpu_p95_method": "nearest-rank",
    "cpu_p95_overhead_ratio": nearest_rank_p(cpu_values, 0.95),
    "cpu_median_overhead_ratio": statistics.median(cpu_values),
    "cpu_limit_ratio": cpu_limit,
    "cpu_pass": nearest_rank_p(cpu_values, 0.95) <= cpu_limit,
    "memory_metric": "paired server process peak RSS Observe-Off, one connection",
    "memory_p95_incremental_bytes": nearest_rank_p(rss_values, 0.95),
    "memory_median_incremental_bytes": statistics.median(rss_values),
    "memory_limit_bytes_per_connection": mem_limit,
    "memory_pass": nearest_rank_p(rss_values, 0.95) <= mem_limit,
    "throughput_median_ratio": statistics.median(throughput_values),
    "rows": rows,
}
summary["pair_gate_pass"] = summary["cpu_pass"] and summary["memory_pass"]

with open(out_path, "w", encoding="utf-8") as fh:
    json.dump(summary, fh, indent=2, sort_keys=True)
    fh.write("\n")
print(json.dumps({k: v for k, v in summary.items() if k != "rows"}, sort_keys=True))

if not summary["pair_gate_pass"]:\n    print("paired Observe resource gate failed; continuing to collect Log60 evidence", file=sys.stderr)
PY

# Real >=60 s Observe trace for the serialized-log budget. 768 MiB at the
# calibrated 100 Mbit/s path provides ample margin above 60 seconds.
run_transfer observe "$OUT/log60" "$LOG_FLOW_BYTES"

python3 - "$OUT/log60/observe.jsonl" "$LOG_LIMIT_BYTES_PER_60S" "$OUT/log60-summary.json" <<'PY'
import json
import sys

trace_path, limit_s, out_path = sys.argv[1:]
limit = int(limit_s)

records = []
with open(trace_path, "rb") as fh:
    for raw in fh:
        if not raw.strip():
            continue
        obj = json.loads(raw)
        records.append((int(obj["t_us"]), len(raw), obj["reason"]))

assert records, "60-second Observe trace is empty"
assert all(reason == "MODE_NOT_LITE" for _, _, reason in records)

span_us = records[-1][0] - records[0][0]
if span_us < 60_000_000:
    raise SystemExit(f"Observe trace span is below 60 seconds: {span_us / 1e6:.3f}s")

# Stronger than fixed wall-minute buckets: calculate the largest serialized
# byte total in any event-time 60-second rolling interval.
left = 0
running = 0
max_window = 0
max_range = (records[0][0], records[0][0])
for right, (t_us, charged, _) in enumerate(records):
    running += charged
    while records[left][0] < t_us - 60_000_000:
        running -= records[left][1]
        left += 1
    if running > max_window:
        max_window = running
        max_range = (records[left][0], t_us)

summary = {
    "schema": "p2-observe-log60-summary-v1",
    "records": len(records),
    "trace_span_seconds": span_us / 1_000_000,
    "serialized_file_bytes": sum(charged for _, charged, _ in records),
    "max_rolling_60s_serialized_bytes": max_window,
    "max_window_start_us": max_range[0],
    "max_window_end_us": max_range[1],
    "limit_bytes_per_60s": limit,
    "log_pass": max_window <= limit,
}
with open(out_path, "w", encoding="utf-8") as fh:
    json.dump(summary, fh, indent=2, sort_keys=True)
    fh.write("\n")
print(json.dumps(summary, sort_keys=True))
if not summary["log_pass"]:\n    print("real Observe log budget exceeded; continuing to aggregate final gate evidence", file=sys.stderr)
PY

python3 - "$OUT/overhead-summary.json" "$OUT/log60-summary.json" "$OUT/gate-summary.json" <<'PY'
import json
import sys

overhead_path, log_path, out_path = sys.argv[1:]
with open(overhead_path, encoding="utf-8") as fh:
    overhead = json.load(fh)
with open(log_path, encoding="utf-8") as fh:
    log = json.load(fh)

summary = {
    "schema": "p2-observe-resource-gate-v1",
    "cpu_p95_overhead_ratio": overhead["cpu_p95_overhead_ratio"],
    "cpu_limit_ratio": overhead["cpu_limit_ratio"],
    "cpu_pass": overhead["cpu_pass"],
    "memory_p95_incremental_bytes": overhead["memory_p95_incremental_bytes"],
    "memory_limit_bytes_per_connection": overhead["memory_limit_bytes_per_connection"],
    "memory_pass": overhead["memory_pass"],
    "max_rolling_60s_serialized_bytes": log["max_rolling_60s_serialized_bytes"],
    "log_limit_bytes_per_60s": log["limit_bytes_per_60s"],
    "log_pass": log["log_pass"],
}
summary["gate_pass"] = summary["cpu_pass"] and summary["memory_pass"] and summary["log_pass"]
with open(out_path, "w", encoding="utf-8") as fh:
    json.dump(summary, fh, indent=2, sort_keys=True)
    fh.write("\n")
print(json.dumps(summary, sort_keys=True))
if not summary["gate_pass"]:
    raise SystemExit("P2 Observe resource gate failed")
PY

chmod -R a+rX "$OUT"
echo "P2 Observe resource overhead gate: PASS"
