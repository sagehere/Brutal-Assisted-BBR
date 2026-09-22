#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/common.sh"

require_root
require_cmds

for cmd in ss stat python3 grep; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    exit 93
  fi
done

HOST="$P2_ROOT/third_party/quiche-0.29.3"
SERVER_BIN="${BABR_P2_SERVER_BIN:-$HOST/target/release/examples/async_http3_server}"
CLIENT_BIN="${BABR_P2_CLIENT_BIN:-$HOST/target/release/quiche-client}"
PAIR_COUNT="${BABR_P2_MEMORY_PAIRS:-20}"
CONNECTIONS="${BABR_P2_MEMORY_CONNECTIONS:-32}"
FLOW_BYTES="${BABR_P2_MEMORY_FLOW_BYTES:-2097152}"
PORT="${BABR_P2_QUIC_PORT:-4433}"
DATA_DIRECTION="${BABR_DATA_DIRECTION:-receiver_to_sender}"
OUT="${BABR_P2_MEMORY_ARTIFACT_DIR:-$P2_ROOT/阶段任务书/p2-observe-memory-artifacts}"
MEMORY_LIMIT_BYTES="${BABR_P2_MEMORY_LIMIT_BYTES:-262144}"

if (( PAIR_COUNT < 10 )); then
  echo "Memory slope gate requires at least 10 measured pairs; got $PAIR_COUNT" >&2
  exit 94
fi
if (( CONNECTIONS < 8 )); then
  echo "Memory slope gate requires at least 8 concurrent connections; got $CONNECTIONS" >&2
  exit 95
fi

for bin in "$SERVER_BIN" "$CLIENT_BIN"; do
  if [[ ! -x "$bin" ]]; then
    echo "Required release binary is missing or not executable: $bin" >&2
    exit 96
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

run_batch() {
  local mode="$1"
  local run_dir="$2"

  rm -rf "$run_dir"
  mkdir -p "$run_dir/clients"

  bash "$HERE/setup.sh" >/dev/null
  BABR_DATA_DIRECTION="$DATA_DIRECTION" bash "$HERE/shape.sh" >/dev/null

  local pid_file="$run_dir/server.pid"
  local rusage="$run_dir/server-rusage.json"
  local -a server_env=("RUST_LOG=warn")
  if [[ "$mode" == "observe" ]]; then
    # /dev/null keeps the memory experiment focused on per-connection Observe
    # state rather than filesystem page cache or a shared telemetry artifact.
    server_env+=("BABR_OBSERVE_TELEMETRY_FILE=/dev/null")
  fi

  python3 "$HERE/run_with_rusage.py"     --pid-file "$pid_file"     --metrics-file "$rusage"     --     ip netns exec "$NS_D" env "${server_env[@]}"     "$SERVER_BIN"       --address "$D_IP:$PORT"       --cc-algorithm bbr2       --enable-pacing     > "$run_dir/server.log" 2>&1 &
  SERVER_WRAPPER_PID=$!

  wait_for_pid_file "$pid_file"
  SERVER_PID="$(cat "$pid_file")"
  wait_for_server

  local -a pids=()
  local failed=0
  for i in $(seq 1 "$CONNECTIONS"); do
    local cdir="$run_dir/clients/$(printf '%02d' "$i")"
    mkdir -p "$cdir/response"
    ip netns exec "$NS_S" env RUST_LOG=warn       "$CLIENT_BIN"         "https://test.com/stream-bytes/$FLOW_BYTES"         --no-verify         --connect-to "$D_IP:$PORT"         --http-version HTTP/3         --max-data 2147483648         --max-window 2147483648         --max-stream-data 2147483648         --max-stream-window 2147483648         --idle-timeout 120000         --dump-responses "$cdir/response"       > "$cdir/client.log" 2>&1 &
    pids+=("$!")
  done

  for pid in "${pids[@]}"; do
    if ! wait "$pid"; then
      failed=1
    fi
  done
  if (( failed != 0 )); then
    echo "$mode memory batch had a failed client" >&2
    return 1
  fi

  for i in $(seq 1 "$CONNECTIONS"); do
    local response="$run_dir/clients/$(printf '%02d' "$i")/response/$FLOW_BYTES"
    if [[ ! -f "$response" ]]; then
      echo "$mode memory batch response missing: $response" >&2
      return 1
    fi
    local response_bytes
    response_bytes="$(stat -c %s "$response")"
    if [[ "$response_bytes" != "$FLOW_BYTES" ]]; then
      echo "$mode memory batch response size mismatch: expected $FLOW_BYTES got $response_bytes" >&2
      return 1
    fi
  done

  stop_server "$rusage"

  python3 - "$mode" "$CONNECTIONS" "$FLOW_BYTES" "$rusage" "$run_dir/metrics.json" <<'PY'
import json
import sys

mode, connections_s, flow_bytes_s, rusage_path, out_path = sys.argv[1:]
with open(rusage_path, encoding="utf-8") as fh:
    rusage = json.load(fh)

metrics = {
    "schema": "p2-observe-memory-batch-v1",
    "mode": mode,
    "connections": int(connections_s),
    "flow_bytes_per_connection": int(flow_bytes_s),
    "server_cpu_seconds": rusage["cpu_seconds"],
    "server_max_rss_kib": rusage["max_rss_kib"],
    "minor_faults": rusage["minor_faults"],
    "major_faults": rusage["major_faults"],
    "voluntary_context_switches": rusage["voluntary_context_switches"],
    "involuntary_context_switches": rusage["involuntary_context_switches"],
}
with open(out_path, "w", encoding="utf-8") as fh:
    json.dump(metrics, fh, indent=2, sort_keys=True)
    fh.write("\n")
print(json.dumps(metrics, sort_keys=True))
PY

  rm -rf "$run_dir/clients"
  bash "$HERE/cleanup.sh" >/dev/null
}

for i in $(seq 1 "$PAIR_COUNT"); do
  pair_dir="$OUT/pairs/$(printf '%02d' "$i")"
  if (( i % 2 == 1 )); then
    run_batch off "$pair_dir/off"
    run_batch observe "$pair_dir/observe"
  else
    run_batch observe "$pair_dir/observe"
    run_batch off "$pair_dir/off"
  fi
done

python3 - "$OUT/pairs" "$PAIR_COUNT" "$CONNECTIONS" "$MEMORY_LIMIT_BYTES" "$OUT/memory-summary.json" <<'PY'
import json
import math
import os
import statistics
import sys

pairs_root, count_s, connections_s, limit_s, out_path = sys.argv[1:]
count = int(count_s)
connections = int(connections_s)
limit = int(limit_s)

rows = []
for i in range(1, count + 1):
    pair_dir = os.path.join(pairs_root, f"{i:02d}")
    with open(os.path.join(pair_dir, "off", "metrics.json"), encoding="utf-8") as fh:
        off = json.load(fh)
    with open(os.path.join(pair_dir, "observe", "metrics.json"), encoding="utf-8") as fh:
        observe = json.load(fh)

    rss_delta_bytes = (observe["server_max_rss_kib"] - off["server_max_rss_kib"]) * 1024
    per_connection = rss_delta_bytes / connections
    rows.append({
        "pair": i,
        "connections": connections,
        "off_max_rss_kib": off["server_max_rss_kib"],
        "observe_max_rss_kib": observe["server_max_rss_kib"],
        "rss_incremental_bytes": rss_delta_bytes,
        "incremental_bytes_per_connection": per_connection,
        "off_minor_faults": off["minor_faults"],
        "observe_minor_faults": observe["minor_faults"],
        "off_voluntary_context_switches": off["voluntary_context_switches"],
        "observe_voluntary_context_switches": observe["voluntary_context_switches"],
        "off_involuntary_context_switches": off["involuntary_context_switches"],
        "observe_involuntary_context_switches": observe["involuntary_context_switches"],
    })

def nearest_rank_p(values, p):
    ordered = sorted(values)
    rank = max(1, math.ceil(p * len(ordered)))
    return ordered[rank - 1]

values = [r["incremental_bytes_per_connection"] for r in rows]
p95 = nearest_rank_p(values, 0.95)
summary = {
    "schema": "p2-observe-memory-slope-v1",
    "pairs": count,
    "connections_per_batch": connections,
    "metric": "paired same-process-batch peak RSS Observe-Off divided by concurrent connection count",
    "p95_method": "nearest-rank",
    "median_incremental_bytes_per_connection": statistics.median(values),
    "p95_incremental_bytes_per_connection": p95,
    "limit_bytes_per_connection": limit,
    "memory_pass": p95 <= limit,
    "rows": rows,
}
with open(out_path, "w", encoding="utf-8") as fh:
    json.dump(summary, fh, indent=2, sort_keys=True)
    fh.write("\n")
print(json.dumps({k: v for k, v in summary.items() if k != "rows"}, sort_keys=True))
if not summary["memory_pass"]:
    raise SystemExit("Observe per-connection memory slope gate failed")
PY

chmod -R a+rX "$OUT"
echo "P2 Observe memory slope gate: PASS"
