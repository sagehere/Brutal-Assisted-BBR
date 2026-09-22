#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/common.sh"

require_root
require_cmds

for cmd in ss stat python3 date taskset; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    exit 93
  fi
done

HOST="$P2_ROOT/third_party/quiche-0.29.3"
SERVER_BIN="${BABR_P2_SERVER_BIN:-$HOST/target/release/examples/async_http3_server}"
CLIENT_BIN="${BABR_P2_CLIENT_BIN:-$HOST/target/release/quiche-client}"
PAIR_COUNT="${BABR_P2_CPU_PAIRS:-20}"
CONNECTIONS_PER_SAMPLE="${BABR_P2_CPU_CONNECTIONS_PER_SAMPLE:-4}"
FLOW_BYTES="${BABR_P2_CPU_FLOW_BYTES:-268435456}"
WARMUP_BYTES="${BABR_P2_CPU_WARMUP_BYTES:-67108864}"
OFF_PORT="${BABR_P2_CPU_OFF_PORT:-4433}"
OBSERVE_PORT="${BABR_P2_CPU_OBSERVE_PORT:-4434}"
DATA_DIRECTION="${BABR_DATA_DIRECTION:-receiver_to_sender}"
OUT="${BABR_P2_CPU_ARTIFACT_DIR:-$P2_ROOT/阶段任务书/p2-observe-cpu-artifacts}"
CPU_LIMIT_RATIO="${BABR_P2_CPU_LIMIT_RATIO:-0.02}"

CPU_PROFILE_PAIR="${BABR_P2_CPU_PROFILE_PAIR:-0}"
CPU_PROFILE_MODE="${BABR_P2_CPU_PROFILE_MODE:-observe}"

read_allowed_cpus() {
  python3 - <<'PY'
from pathlib import Path

allowed = None
for line in Path("/proc/self/status").read_text(encoding="utf-8").splitlines():
    if line.startswith("Cpus_allowed_list:"):
        allowed = line.split(":", 1)[1].strip()
        break
if not allowed:
    raise SystemExit("unable to read Cpus_allowed_list")

cpus = []
for part in allowed.split(","):
    if "-" in part:
        start, end = map(int, part.split("-", 1))
        cpus.extend(range(start, end + 1))
    else:
        cpus.append(int(part))
print(" ".join(map(str, cpus)))
PY
}

read -r -a ALLOWED_CPUS <<< "$(read_allowed_cpus)"
if (( ${#ALLOWED_CPUS[@]} == 0 )); then
  echo "No allowed CPUs discovered" >&2
  exit 97
fi

SERVER_CPU="${BABR_P2_SERVER_CPU:-${ALLOWED_CPUS[0]}}"
if (( ${#ALLOWED_CPUS[@]} >= 2 )); then
  DEFAULT_CLIENT_CPU="${ALLOWED_CPUS[1]}"
else
  DEFAULT_CLIENT_CPU="${ALLOWED_CPUS[0]}"
fi
CLIENT_CPU="${BABR_P2_CLIENT_CPU:-$DEFAULT_CLIENT_CPU}"

cpu_is_allowed() {
  local needle="$1"
  local cpu
  for cpu in "${ALLOWED_CPUS[@]}"; do
    if [[ "$cpu" == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}

if ! cpu_is_allowed "$SERVER_CPU"; then
  echo "Requested server CPU $SERVER_CPU is outside allowed set: ${ALLOWED_CPUS[*]}" >&2
  exit 98
fi
if ! cpu_is_allowed "$CLIENT_CPU"; then
  echo "Requested client CPU $CLIENT_CPU is outside allowed set: ${ALLOWED_CPUS[*]}" >&2
  exit 99
fi

if (( PAIR_COUNT < 10 )); then
  echo "Persistent CPU gate requires at least 10 pairs; got $PAIR_COUNT" >&2
  exit 94
fi
if (( CONNECTIONS_PER_SAMPLE < 2 )); then
  echo "Persistent CPU gate requires at least 2 connections per sample" >&2
  exit 95
fi

for bin in "$SERVER_BIN" "$CLIENT_BIN"; do
  if [[ ! -x "$bin" ]]; then
    echo "Required release binary is missing or not executable: $bin" >&2
    exit 96
  fi
done

rm -rf "$OUT"
mkdir -p "$OUT/pairs" "$OUT/servers"

OFF_PID=""
OBSERVE_PID=""
OFF_WRAPPER_PID=""
OBSERVE_WRAPPER_PID=""

cleanup_all() {
  for pid in "$OFF_PID" "$OBSERVE_PID"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
      kill -TERM "$pid" >/dev/null 2>&1 || true
    fi
  done
  sleep 0.1
  for pid in "$OFF_PID" "$OBSERVE_PID"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
      kill -KILL "$pid" >/dev/null 2>&1 || true
    fi
  done
  for pid in "$OFF_WRAPPER_PID" "$OBSERVE_WRAPPER_PID"; do
    if [[ -n "$pid" ]]; then
      wait "$pid" >/dev/null 2>&1 || true
    fi
  done
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
  echo "Timed out waiting for server PID file: $pid_file" >&2
  return 1
}

wait_for_port() {
  local port="$1"
  local pid="$2"
  for _ in $(seq 1 100); do
    if ip netns exec "$NS_D" ss -lun | grep -Fq "$D_IP:$port"; then
      return 0
    fi
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      echo "Persistent server exited before listening on $port" >&2
      return 1
    fi
    sleep 0.05
  done
  echo "Timed out waiting for persistent server on $D_IP:$port" >&2
  return 1
}

process_cpu_runtime_ns() {
  local pid="$1"
  python3 - "$pid" <<'PY'
from pathlib import Path
import sys

pid = sys.argv[1]
task_dir = Path("/proc") / pid / "task"
total = 0
seen = 0
for schedstat in task_dir.glob("*/schedstat"):
    try:
        fields = schedstat.read_text(encoding="utf-8").split()
    except FileNotFoundError:
        continue
    if not fields:
        continue
    total += int(fields[0])
    seen += 1
if seen == 0:
    raise SystemExit(f"no schedstat threads found for pid {pid}")
print(total)
PY
}

process_thread_count() {
  local pid="$1"
  find "/proc/$pid/task" -mindepth 1 -maxdepth 1 -type d | wc -l
}

process_allowed_cpu_list() {
  local pid="$1"
  awk '/^Cpus_allowed_list:/ {print $2}' "/proc/$pid/status"
}

thread_allowed_cpu_list() {
  local pid="$1"
  local tid="$2"
  awk '/^Cpus_allowed_list:/ {print $2}' "/proc/$pid/task/$tid/status"
}

pin_existing_server_threads() {
  local pid="$1"
  local mode="$2"
  local before after task tid affinity

  before="$(process_thread_count "$pid")"
  if (( before < 3 )); then
    echo "$mode server runtime initialized with only $before threads before pinning" >&2
    return 1
  fi

  for task in "/proc/$pid/task"/*; do
    tid="${task##*/}"
    taskset -pc "$SERVER_CPU" "$tid" >/dev/null
  done

  sleep 0.05
  after="$(process_thread_count "$pid")"
  if [[ "$before" != "$after" ]]; then
    echo "$mode server thread topology changed while pinning: $before -> $after" >&2
    return 1
  fi

  for task in "/proc/$pid/task"/*; do
    tid="${task##*/}"
    affinity="$(thread_allowed_cpu_list "$pid" "$tid")"
    if [[ "$affinity" != "$SERVER_CPU" ]]; then
      echo "$mode server thread $tid affinity mismatch: expected $SERVER_CPU got $affinity" >&2
      return 1
    fi
  done

  echo "$before"
}

PROFILE_PID=""
start_profile_if_requested() {
  local mode="$1"
  local pair="$2"
  local pid="$3"

  PROFILE_PID=""
  if [[ "$CPU_PROFILE_PAIR" == "0" || "$pair" != "$CPU_PROFILE_PAIR" ]]; then
    return 0
  fi
  if [[ "$CPU_PROFILE_MODE" != "both" && "$mode" != "$CPU_PROFILE_MODE" ]]; then
    return 0
  fi
  if ! command -v perf >/dev/null 2>&1; then
    echo "CPU profile requested but perf is unavailable" >&2
    return 1
  fi

  mkdir -p "$OUT/profile"
  perf record -q -F 99 -g -p "$pid" \
    -o "$OUT/profile/${mode}-pair-${pair}.data" -- sleep 3600 &
  PROFILE_PID=$!
  sleep 0.2
  if ! kill -0 "$PROFILE_PID" >/dev/null 2>&1; then
    echo "perf failed to attach to $mode server pid $pid" >&2
    wait "$PROFILE_PID" || true
    PROFILE_PID=""
    return 1
  fi
}

stop_profile_if_running() {
  if [[ -z "$PROFILE_PID" ]]; then
    return 0
  fi
  kill -INT "$PROFILE_PID" >/dev/null 2>&1 || true
  wait "$PROFILE_PID" || true
  PROFILE_PID=""
}

start_server() {
  local mode="$1"
  local port="$2"
  local dir="$OUT/servers/$mode"
  mkdir -p "$dir"

  local pid_file="$dir/server.pid"
  local rusage_file="$dir/server-rusage.json"
  local -a server_env=("RUST_LOG=warn")

  if [[ "$mode" == "observe" ]]; then
    # Keep serializer/write CPU in the measurement while removing filesystem
    # cache and backing-store variance. Log-volume correctness is gated
    # separately by the real Log60 experiment.
    server_env+=("BABR_OBSERVE_TELEMETRY_FILE=/dev/null")
  fi

  python3 "$HERE/run_with_rusage.py"     --pid-file "$pid_file"     --metrics-file "$rusage_file"     --     ip netns exec "$NS_D" env "${server_env[@]}"     "$SERVER_BIN"       --address "$D_IP:$port"       --cc-algorithm bbr2       --enable-pacing     > "$dir/server.log" 2>&1 &

  local wrapper_pid=$!
  wait_for_pid_file "$pid_file"
  local server_pid
  server_pid="$(cat "$pid_file")"
  wait_for_port "$port" "$server_pid"

  local runtime_threads
  runtime_threads="$(pin_existing_server_threads "$server_pid" "$mode")"
  printf '%s\n' "$runtime_threads" > "$dir/runtime-threads-before-pin.txt"
  printf '%s\n' "$SERVER_CPU" > "$dir/server-cpu-affinity.txt"

  if [[ "$mode" == "off" ]]; then
    OFF_PID="$server_pid"
    OFF_WRAPPER_PID="$wrapper_pid"
  else
    OBSERVE_PID="$server_pid"
    OBSERVE_WRAPPER_PID="$wrapper_pid"
  fi
}

run_client() {
  local port="$1"
  local bytes="$2"
  local dir="$3"

  rm -rf "$dir"
  mkdir -p "$dir/response"

  ip netns exec "$NS_S" env RUST_LOG=warn     taskset -c "$CLIENT_CPU" "$CLIENT_BIN"       "https://test.com/stream-bytes/$bytes"       --no-verify       --connect-to "$D_IP:$port"       --http-version HTTP/3       --max-data 2147483648       --max-window 2147483648       --max-stream-data 2147483648       --max-stream-window 2147483648       --idle-timeout 120000       --dump-responses "$dir/response"     > "$dir/client.log" 2>&1

  local response="$dir/response/$bytes"
  if [[ ! -f "$response" ]]; then
    echo "Persistent CPU response missing: $response" >&2
    return 1
  fi

  local response_bytes
  response_bytes="$(stat -c %s "$response")"
  if [[ "$response_bytes" != "$bytes" ]]; then
    echo "Persistent CPU response size mismatch: expected $bytes got $response_bytes" >&2
    return 1
  fi

  rm -rf "$dir/response"
}

run_sample() {
  local mode="$1"
  local pair="$2"
  local sample_dir="$OUT/pairs/$(printf '%02d' "$pair")/$mode"
  local pid port

  if [[ "$mode" == "off" ]]; then
    pid="$OFF_PID"
    port="$OFF_PORT"
  else
    pid="$OBSERVE_PID"
    port="$OBSERVE_PORT"
  fi

  mkdir -p "$sample_dir"

  local threads_before threads_after cpu_before cpu_after wall_start wall_end
  threads_before="$(process_thread_count "$pid")"
  cpu_before="$(process_cpu_runtime_ns "$pid")"
  wall_start="$(date +%s%N)"
  start_profile_if_requested "$mode" "$pair" "$pid"

  for n in $(seq 1 "$CONNECTIONS_PER_SAMPLE"); do
    run_client "$port" "$FLOW_BYTES" "$sample_dir/conn-$(printf '%02d' "$n")"
  done

  # Let final per-connection telemetry drains settle before the CPU snapshot.
  sleep 0.25
  stop_profile_if_running
  wall_end="$(date +%s%N)"
  cpu_after="$(process_cpu_runtime_ns "$pid")"
  threads_after="$(process_thread_count "$pid")"

  if [[ "$threads_before" != "$threads_after" ]]; then
    echo "$mode persistent server thread count changed: $threads_before -> $threads_after" >&2
    return 1
  fi
  if (( cpu_after <= cpu_before )); then
    echo "$mode persistent CPU delta is non-positive" >&2
    return 1
  fi

  python3 -     "$mode" "$pair" "$CONNECTIONS_PER_SAMPLE" "$FLOW_BYTES"     "$cpu_before" "$cpu_after" "$wall_start" "$wall_end"     "$threads_before" "$SERVER_CPU" "$CLIENT_CPU" "$sample_dir/metrics.json" <<'PY'
import json
import sys

(
    mode,
    pair_s,
    connections_s,
    flow_bytes_s,
    cpu_before_s,
    cpu_after_s,
    wall_start_s,
    wall_end_s,
    threads_s,
    server_cpu_s,
    client_cpu_s,
    out_path,
) = sys.argv[1:]

connections = int(connections_s)
flow_bytes = int(flow_bytes_s)
cpu_seconds = (int(cpu_after_s) - int(cpu_before_s)) / 1_000_000_000
wall_seconds = (int(wall_end_s) - int(wall_start_s)) / 1_000_000_000

metrics = {
    "schema": "p2-observe-persistent-cpu-sample-v1",
    "mode": mode,
    "pair": int(pair_s),
    "connections": connections,
    "flow_bytes_per_connection": flow_bytes,
    "total_payload_bytes": connections * flow_bytes,
    "server_cpu_seconds": cpu_seconds,
    "wall_seconds": wall_seconds,
    "server_threads": int(threads_s),
    "server_cpu_affinity": int(server_cpu_s),
    "client_cpu_affinity": int(client_cpu_s),
}
with open(out_path, "w", encoding="utf-8") as fh:
    json.dump(metrics, fh, indent=2, sort_keys=True)
    fh.write("\n")
print(json.dumps(metrics, sort_keys=True))
PY

  find "$sample_dir" -type f -name 'client.log' -size 0 -delete
}

bash "$HERE/setup.sh" >/dev/null
BABR_DATA_DIRECTION="$DATA_DIRECTION" bash "$HERE/shape.sh" >/dev/null

echo "Persistent CPU affinity: post-init server-thread pin=$SERVER_CPU client=$CLIENT_CPU allowed=${ALLOWED_CPUS[*]}"

start_server off "$OFF_PORT"
start_server observe "$OBSERVE_PORT"

# Warm both persistent processes after all runtime threads and lazy paths exist.
run_client "$OFF_PORT" "$WARMUP_BYTES" "$OUT/warmup/off"
run_client "$OBSERVE_PORT" "$WARMUP_BYTES" "$OUT/warmup/observe"
sleep 0.25

for i in $(seq 1 "$PAIR_COUNT"); do
  if (( i % 2 == 1 )); then
    run_sample off "$i"
    run_sample observe "$i"
  else
    run_sample observe "$i"
    run_sample off "$i"
  fi
done

python3 - "$OUT/pairs" "$PAIR_COUNT" "$CPU_LIMIT_RATIO" "$OUT/cpu-summary.json" <<'PY'
import json
import math
import os
import statistics
import sys

pairs_root, count_s, limit_s, out_path = sys.argv[1:]
count = int(count_s)
limit = float(limit_s)

rows = []
for i in range(1, count + 1):
    pair_dir = os.path.join(pairs_root, f"{i:02d}")
    with open(os.path.join(pair_dir, "off", "metrics.json"), encoding="utf-8") as fh:
        off = json.load(fh)
    with open(os.path.join(pair_dir, "observe", "metrics.json"), encoding="utf-8") as fh:
        observe = json.load(fh)

    ratio = observe["server_cpu_seconds"] / off["server_cpu_seconds"] - 1.0
    rows.append({
        "pair": i,
        "off_cpu_seconds": off["server_cpu_seconds"],
        "observe_cpu_seconds": observe["server_cpu_seconds"],
        "cpu_overhead_ratio": ratio,
        "off_wall_seconds": off["wall_seconds"],
        "observe_wall_seconds": observe["wall_seconds"],
        "connections_per_sample": off["connections"],
        "total_payload_bytes_per_sample": off["total_payload_bytes"],
        "server_threads": off["server_threads"],
        "server_cpu_affinity": off["server_cpu_affinity"],
        "client_cpu_affinity": off["client_cpu_affinity"],
    })

def nearest_rank_p(values, p):
    ordered = sorted(values)
    rank = max(1, math.ceil(p * len(ordered)))
    return ordered[rank - 1]

values = [r["cpu_overhead_ratio"] for r in rows]
p95 = nearest_rank_p(values, 0.95)
summary = {
    "schema": "p2-observe-persistent-cpu-gate-v1",
    "pairs": count,
    "metric": (
        "paired persistent-server scheduled CPU runtime; ABBA order; "
        "server runtime initialized with the normal thread topology, then all "
        "existing Off/Observe server threads pinned to the same CPU; clients "
        "pinned separately; multiple connections per sample; "
        "startup/shutdown excluded"
    ),
    "p95_method": "nearest-rank",
    "median_cpu_overhead_ratio": statistics.median(values),
    "p95_cpu_overhead_ratio": p95,
    "limit_ratio": limit,
    "cpu_pass": p95 <= limit,
    "rows": rows,
}
with open(out_path, "w", encoding="utf-8") as fh:
    json.dump(summary, fh, indent=2, sort_keys=True)
    fh.write("\n")
print(json.dumps({k: v for k, v in summary.items() if k != "rows"}, sort_keys=True))
if not summary["cpu_pass"]:
    raise SystemExit("Persistent Observe CPU gate failed")
PY

chmod -R a+rX "$OUT"
echo "P2 persistent Observe CPU gate: PASS"
