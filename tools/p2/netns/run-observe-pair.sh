#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/common.sh"

require_root
require_cmds

for cmd in ss sha256sum stat timeout; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    exit 93
  fi
done
if [[ ! -x /usr/bin/time ]]; then
  echo "Missing required /usr/bin/time" >&2
  exit 94
fi

HOST="$P2_ROOT/third_party/quiche-0.29.3"
SERVER_BIN="${BABR_P2_SERVER_BIN:-$HOST/target/debug/examples/async_http3_server}"
CLIENT_BIN="${BABR_P2_CLIENT_BIN:-$HOST/target/debug/quiche-client}"
FLOW_BYTES="${BABR_P2_FLOW_BYTES:-67108864}"
PORT="${BABR_P2_QUIC_PORT:-4433}"
OUT="${BABR_P2_OBSERVE_ARTIFACT_DIR:-$P2_ROOT/阶段任务书/p2-observe-network-artifacts}"

for bin in "$SERVER_BIN" "$CLIENT_BIN"; do
  if [[ ! -x "$bin" ]]; then
    echo "Required binary is missing or not executable: $bin" >&2
    exit 95
  fi
done

rm -rf "$OUT"
mkdir -p "$OUT"

SERVER_PID=""

cleanup_all() {
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    kill -TERM "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  SERVER_PID=""
  bash "$HERE/cleanup.sh" >/dev/null 2>&1 || true
}
trap cleanup_all EXIT

wait_for_server() {
  for _ in $(seq 1 80); do
    if ip netns exec "$NS_D" ss -lun | grep -Fq "$D_IP:$PORT"; then
      return 0
    fi
    if [[ -n "$SERVER_PID" ]] && ! kill -0 "$SERVER_PID" >/dev/null 2>&1; then
      echo "QUIC server exited before listening" >&2
      return 1
    fi
    sleep 0.1
  done
  echo "Timed out waiting for QUIC server to listen" >&2
  return 1
}

run_mode() {
  local mode="$1"
  local mode_dir="$OUT/$mode"
  local response_dir="$mode_dir/response"
  local trace="$mode_dir/observe.jsonl"

  mkdir -p "$response_dir"

  bash "$HERE/setup.sh" >/dev/null
  bash "$HERE/shape.sh" >/dev/null

  {
    echo "mode=$mode"
    echo "flow_bytes=$FLOW_BYTES"
    echo "server_bin=$SERVER_BIN"
    echo "client_bin=$CLIENT_BIN"
    echo "cc_algorithm=bbr2"
    echo "server_pacing=enabled"
    echo "rate_mbit=${BABR_RATE_MBIT:-100}"
    echo "one_way_delay_ms=${BABR_ONE_WAY_DELAY_MS:-20}"
    echo "loss_pct=${BABR_LOSS_PCT:-0}"
  } > "$mode_dir/run-metadata.txt"

  local -a server_env=("RUST_LOG=info")
  if [[ "$mode" == "observe" ]]; then
    server_env+=("BABR_OBSERVE_TELEMETRY_FILE=$trace")
  fi

  /usr/bin/time -v -o "$mode_dir/server-time.txt" \
    ip netns exec "$NS_D" env "${server_env[@]}" \
    "$SERVER_BIN" \
      --address "$D_IP:$PORT" \
      --cc-algorithm bbr2 \
      --enable-pacing \
    > "$mode_dir/server.log" 2>&1 &
  SERVER_PID=$!

  wait_for_server

  /usr/bin/time -v -o "$mode_dir/client-time.txt" \
    ip netns exec "$NS_S" env RUST_LOG=info \
    "$CLIENT_BIN" \
      "https://test.com/stream-bytes/$FLOW_BYTES" \
      --no-verify \
      --connect-to "$D_IP:$PORT" \
      --http-version HTTP/3 \
      --max-data 268435456 \
      --max-window 268435456 \
      --max-stream-data 268435456 \
      --max-stream-window 268435456 \
      --idle-timeout 30000 \
      --dump-responses "$response_dir" \
    > "$mode_dir/client.log" 2>&1

  # Give the server one ACK interval to process the tail before terminating
  # the long-running listener.
  sleep 0.5
  kill -TERM "$SERVER_PID" >/dev/null 2>&1 || true
  wait "$SERVER_PID" >/dev/null 2>&1 || true
  SERVER_PID=""

  ip netns exec "$NS_S" tc -s qdisc show dev "$S_IF"     > "$mode_dir/qdisc-sender.txt"
  ip netns exec "$NS_R" tc -s qdisc show dev "$R_D_IF"     > "$mode_dir/qdisc-router.txt"
  ip netns exec "$NS_D" tc -s qdisc show dev "$D_IF"     > "$mode_dir/qdisc-receiver.txt"

  local response="$response_dir/$FLOW_BYTES"
  if [[ ! -f "$response" ]]; then
    echo "$mode response file missing: $response" >&2
    exit 96
  fi

  local response_bytes
  response_bytes="$(stat -c %s "$response")"
  if [[ "$response_bytes" != "$FLOW_BYTES" ]]; then
    echo "$mode response size mismatch: expected $FLOW_BYTES got $response_bytes" >&2
    exit 97
  fi

  sha256sum "$response" > "$mode_dir/response.sha256"

  if [[ "$mode" == "off" ]]; then
    if [[ -s "$trace" ]]; then
      echo "Off mode unexpectedly produced BABR Observe telemetry" >&2
      exit 98
    fi
  else
    if [[ ! -s "$trace" ]]; then
      echo "Observe mode produced no BABR telemetry" >&2
      exit 99
    fi

    python3 - "$trace" "$mode_dir/observe-summary.json" <<'PY'
import json
import os
import sys

trace_path, summary_path = sys.argv[1:3]
records = []
with open(trace_path, encoding="utf-8") as fh:
    for line_no, raw in enumerate(fh, 1):
        raw = raw.strip()
        if not raw:
            continue
        obj = json.loads(raw)
        assert obj["schema"] == "p2-observe-v1", (line_no, obj)
        assert obj["reason"] == "MODE_NOT_LITE", (line_no, obj)
        records.append(obj)

assert records, "Observe telemetry contains no records"

for key in ("actual_socket_sent_bytes", "unique_payload_bytes"):
    values = [r[key] for r in records if r[key] is not None]
    assert values, f"{key} never became available"
    assert all(a <= b for a, b in zip(values, values[1:])), (
        key,
        values,
    )

actual = [r["actual_socket_sent_bytes"] for r in records if r["actual_socket_sent_bytes"] is not None]
unique = [r["unique_payload_bytes"] for r in records if r["unique_payload_bytes"] is not None]
assert actual[-1] > 0
assert unique[-1] > 0
assert os.path.getsize(trace_path) <= 1_048_576

summary = {
    "schema": "p2-real-observe-summary-v1",
    "records": len(records),
    "serialized_bytes": os.path.getsize(trace_path),
    "first_seq": records[0]["seq"],
    "last_seq": records[-1]["seq"],
    "last_actual_socket_sent_bytes": actual[-1],
    "last_unique_payload_bytes": unique[-1],
    "last_model_delivery_Bps": records[-1]["model_delivery_Bps"],
    "last_baseline_pacing_Bps": records[-1]["baseline_pacing_Bps"],
    "last_baseline_cwnd_bytes": records[-1]["baseline_cwnd_bytes"],
    "all_transport_reasons": sorted({r["reason"] for r in records}),
    "shadow_reasons": sorted({r["shadow_reason"] for r in records}),
}
with open(summary_path, "w", encoding="utf-8") as fh:
    json.dump(summary, fh, indent=2, sort_keys=True)
    fh.write("\n")
print(json.dumps(summary, sort_keys=True))
PY
  fi

  bash "$HERE/cleanup.sh" >/dev/null
}

run_mode off
run_mode observe

OFF_HASH="$(awk '{print $1}' "$OUT/off/response.sha256")"
OBS_HASH="$(awk '{print $1}' "$OUT/observe/response.sha256")"
if [[ "$OFF_HASH" != "$OBS_HASH" ]]; then
  echo "Off/Observe payload hashes differ" >&2
  exit 100
fi

python3 - "$OUT" "$FLOW_BYTES" "$OFF_HASH" <<'PY'
import json
import os
import sys

root, flow_bytes, response_hash = sys.argv[1:4]
with open(os.path.join(root, "observe", "observe-summary.json"), encoding="utf-8") as fh:
    observe = json.load(fh)

summary = {
    "schema": "p2-real-off-observe-pair-v1",
    "flow_bytes": int(flow_bytes),
    "response_sha256": response_hash,
    "off_payload_verified": True,
    "observe_payload_verified": True,
    "payloads_identical": True,
    "observe_transport_reason": observe["all_transport_reasons"],
    "observe_records": observe["records"],
    "observe_serialized_bytes": observe["serialized_bytes"],
    "observe_last_actual_socket_sent_bytes": observe["last_actual_socket_sent_bytes"],
    "observe_last_unique_payload_bytes": observe["last_unique_payload_bytes"],
}
with open(os.path.join(root, "pair-summary.json"), "w", encoding="utf-8") as fh:
    json.dump(summary, fh, indent=2, sort_keys=True)
    fh.write("\n")
print(json.dumps(summary, sort_keys=True))
PY

chmod -R a+rX "$OUT"
echo "P2 real Off/Observe network pair: PASS"
