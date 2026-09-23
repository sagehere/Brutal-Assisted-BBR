#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/common.sh"

require_root
require_cmds

HOST="$P2_ROOT/third_party/quiche-0.29.3"
SERVER_BIN="${BABR_P2_SERVER_BIN:-$HOST/target/debug/examples/async_http3_server}"
CLIENT_BIN="${BABR_P2_CLIENT_BIN:-$HOST/target/debug/quiche-client}"
PORT="${BABR_P2_QUIC_PORT:-4433}"
FLOW_BYTES="${BABR_P2_FLOW_BYTES:-67108864}"
REQUESTS="${BABR_P2_L05_REQUESTS:-16}"
TARGET_BPS="${BABR_P2_TARGET_BPS:-25000000}"
PACE_MBIT="${BABR_P2_L05_PACE_MBIT:-150}"
OUT="${BABR_P2_L05_ARTIFACT_DIR:-$P2_ROOT/阶段任务书/p2-l05-artifacts}"

python3 - "$P2_ROOT" "$OUT" <<'PY'
from pathlib import Path
import shutil
import sys

root, output = map(Path, sys.argv[1:])
root = root.resolve()
output = output.resolve()
if output == root or not output.is_relative_to(root):
    raise SystemExit(f"refusing to clear artifact path outside the repository: {output}")
shutil.rmtree(output, ignore_errors=True)
output.mkdir(parents=True)
(output / "response").mkdir()
PY
printf 'scenario=l05-ack-suppression\ntarget_Bps=%s\nflow_bytes=%s\nrequests=%s\nfq_maxrate_mbit=%s\ntelemetry_drain_ms=5\n' \
  "$TARGET_BPS" "$FLOW_BYTES" "$REQUESTS" "$PACE_MBIT" > "$OUT/config.txt"

CLIENT_PID=""
cleanup() {
  if [[ -n "$CLIENT_PID" ]] && kill -0 "$CLIENT_PID" 2>/dev/null; then
    kill -TERM "$CLIENT_PID" 2>/dev/null || true
    wait "$CLIENT_PID" 2>/dev/null || true
  fi
  pkill -TERM -f "$SERVER_BIN" 2>/dev/null || true
  "$HERE/cleanup.sh" >/dev/null 2>&1 || true
}
trap cleanup EXIT

bash "$HERE/setup.sh" >/dev/null
BABR_DATA_DIRECTION=receiver_to_sender bash "$HERE/shape.sh" >/dev/null

# Match the accepted L03 sender-side socket pacing setup while preserving the
# frozen 20 ms path delay. ACK suppression is armed only after real admission.
ip netns exec "$NS_D" tc qdisc replace dev "$D_IF" root fq \
  maxrate "${PACE_MBIT}mbit" flow_limit 100 limit 1000
ip netns exec "$NS_R" tc qdisc replace dev "$R_S_IF" root netem delay 20ms
# Install only the empty ACK-path classifier hook before the connection starts.
# The drop filter itself is installed only after real Assist admission.
ip netns exec "$NS_R" tc qdisc replace dev "$R_D_IF" clsact
ip netns exec "$NS_R" tc -s -d qdisc show dev "$R_S_IF" > "$OUT/router-data-qdisc-before.txt"
ip netns exec "$NS_D" tc -s -d qdisc show dev "$D_IF" > "$OUT/sender-data-qdisc-before.txt"
: > "$OUT/lite.jsonl"

ip netns exec "$NS_D" env \
  BABR_P2_MODE=lite \
  BABR_P2_TARGET_BPS="$TARGET_BPS" \
  BABR_P2_L05_FAST_TELEMETRY=1 \
  BABR_P2_LITE_TELEMETRY_FILE="$OUT/lite.jsonl" \
  "$SERVER_BIN" --address "$D_IP:$PORT" --cc-algorithm bbr2 --enable-pacing \
  > "$OUT/server.log" 2>&1 &

sleep 1
CLIENT_URL="https://test.com/stream-bytes/$FLOW_BYTES"
CLIENT_URLS=()
for _ in $(seq 1 "$REQUESTS"); do
  CLIENT_URLS+=("$CLIENT_URL")
done
ip netns exec "$NS_S" "$CLIENT_BIN" "${CLIENT_URLS[@]}" \
  --no-verify --connect-to "$D_IP:$PORT" \
  --http-version HTTP/3 --dump-responses "$OUT/response" \
  > "$OUT/client.log" 2>&1 &
CLIENT_PID=$!

ACK_FILTER_ARMED=0
# Wait for a real pre-debit Assist record, then cut its ACK path immediately so
# the full frozen lease runs without feedback. Missing admission stays BLOCKED.
assist_admission_seen() {
  python3 - "$OUT/lite.jsonl" "$OUT/ack-admission-observed.txt" <<'PY'
import json
import os
import sys
import time

path = sys.argv[1]
# A past admission is not a live authorization. The experiment-only sink
# normally drains every 5 ms, so a file idle for 50 ms is too stale to arm.
if time.time_ns() - os.stat(path).st_mtime_ns > 50_000_000:
    raise SystemExit(2)
rows = []
for line in open(path, encoding="utf-8"):
    try:
        rows.append(json.loads(line))
    except json.JSONDecodeError:
        continue
if not rows or rows[-1].get("state") != "ASSIST":
    raise SystemExit(2)
deadline = rows[-1].get("assist_deadline_monotonic_us")
if not isinstance(deadline, (int, float)) or deadline <= rows[-1].get("t_us", 0):
    raise SystemExit(2)
for row in reversed(rows):
    if row.get("assist_deadline_monotonic_us") != deadline:
        break
    if (row.get("control_applied") is True
            and isinstance(row.get("budget_debit_bytes"), (int, float))
            and row["budget_debit_bytes"] > 0):
        with open(sys.argv[2], "w", encoding="utf-8") as output:
            output.write(f"admission_seq={row['seq']}\n")
            output.write(f"admission_t_us={row['t_us']}\n")
            output.write(f"admission_deadline_t_us={deadline}\n")
            output.write(f"last_seen_t_us={rows[-1]['t_us']}\n")
            output.write(f"admission_detect_monotonic_ns={time.monotonic_ns()}\n")
        raise SystemExit(0)
raise SystemExit(2)
PY
}

for _ in $(seq 1 3600); do
  if [[ -s "$OUT/lite.jsonl" ]]; then
    if assist_admission_seen; then
      ACK_FILTER_ARMED=1
      break
    fi
  fi
  if ! kill -0 "$CLIENT_PID" 2>/dev/null; then
    break
  fi
  sleep 0.005
done

if [[ "$ACK_FILTER_ARMED" == 1 ]]; then
  python3 - "$OUT/ack-suppression-status.txt" <<'PY'
import sys
import time
with open(sys.argv[1], "w", encoding="utf-8") as output:
    output.write(f"ack_filter_install_start_monotonic_ns={time.monotonic_ns()}\n")
PY
  ip netns exec "$NS_R" tc filter replace dev "$R_D_IF" egress protocol ip pref 100 \
    flower ip_proto udp src_ip "$S_IP" dst_ip "$D_IP" action drop
  ip netns exec "$NS_R" tc -s filter show dev "$R_D_IF" egress \
    > "$OUT/ack-drop-filter-before.txt"
  python3 - "$OUT/ack-suppression-status.txt" <<'PY'
import sys
import time
with open(sys.argv[1], "a", encoding="utf-8") as output:
    output.write(f"ack_filter_armed=1\nack_filter_install_end_monotonic_ns={time.monotonic_ns()}\n")
PY
else
  printf 'ack_filter_armed=0\nreason=no real Assist admission with budget pre-debit\n' \
    > "$OUT/ack-suppression-status.txt"
fi

# Keep loss active long enough for the independent Assist deadline and host PTO
# to be observed. Collection remains fail-closed if either event is absent.
sleep 3
if [[ -n "$CLIENT_PID" ]] && kill -0 "$CLIENT_PID" 2>/dev/null; then
  kill -TERM "$CLIENT_PID" 2>/dev/null || true
  wait "$CLIENT_PID" 2>/dev/null || true
  CLIENT_PID=""
fi

ACK_DROP_COUNT=0
if [[ "$ACK_FILTER_ARMED" == 1 ]]; then
  ip netns exec "$NS_R" tc -s filter show dev "$R_D_IF" egress \
    > "$OUT/ack-drop-filter-after.txt"
  ACK_DROP_COUNT="$(python3 - "$OUT/ack-drop-filter-after.txt" <<'PY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
match = re.search(r"\(dropped\s+(\d+),", text)
print(match.group(1) if match else 0)
PY
)"
fi
printf 'router_ack_packets_dropped=%s\n' "$ACK_DROP_COUNT" \
  >> "$OUT/ack-suppression-status.txt"

ip netns exec "$NS_R" tc -s -d qdisc show dev "$R_S_IF" > "$OUT/router-data-qdisc-after.txt"
ip netns exec "$NS_D" tc -s -d qdisc show dev "$D_IF" > "$OUT/sender-data-qdisc-after.txt"
python3 "$P2_ROOT/tools/p2/replay/check_lite_trace.py" \
  "$OUT/lite.jsonl" --scenario l05 --ack-drop-count "$ACK_DROP_COUNT" \
  --summary "$OUT/summary.json" --allow-blocked
if [[ "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["status"])' "$OUT/summary.json")" == PASS ]]; then
  echo 'P2 L05 real ACK suppression safety evidence: PASS'
else
  echo 'P2 L05 real ACK suppression safety evidence: BLOCKED'
fi
