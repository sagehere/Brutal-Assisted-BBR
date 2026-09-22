#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/common.sh"

require_root
require_cmds

HOST="$P2_ROOT/third_party/quiche-0.29.3"
SERVER_BIN="${BABR_P2_SERVER_BIN:-$HOST/target/debug/examples/async_http3_server}"
CLIENT_BIN="${BABR_P2_CLIENT_BIN:-$HOST/target/debug/quiche-client}"
FLOW_BYTES="${BABR_P2_FLOW_BYTES:-8388608}"
PORT="${BABR_P2_QUIC_PORT:-4433}"
TARGET_BPS="${BABR_P2_TARGET_BPS:-25000000}"
MAX_RATE_BPS="${BABR_P2_MAX_RATE_BPS:-2000000}"
OUT="${BABR_P2_LITE_ENTRY_ARTIFACT_DIR:-$P2_ROOT/阶段任务书/p2-lite-entry-artifacts}"

for bin in "$SERVER_BIN" "$CLIENT_BIN"; do
  [[ -x "$bin" ]] || { echo "Required binary missing: $bin" >&2; exit 95; }
done

rm -rf "$OUT"
mkdir -p "$OUT/response"

SERVER_PID=""
cleanup_all() {
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    kill -TERM "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  bash "$HERE/cleanup.sh" >/dev/null 2>&1 || true
}
trap cleanup_all EXIT

bash "$HERE/setup.sh" >/dev/null
BABR_DATA_DIRECTION=receiver_to_sender bash "$HERE/shape.sh" >/dev/null

ip netns exec "$NS_D" env   RUST_LOG=info   BABR_P2_MODE=lite   BABR_P2_TARGET_BPS="$TARGET_BPS"   BABR_P2_MAX_RATE_BPS="$MAX_RATE_BPS"   BABR_P2_LITE_TELEMETRY_FILE="$OUT/lite.jsonl"   "$SERVER_BIN"     --address "$D_IP:$PORT"     --cc-algorithm bbr2     --enable-pacing   > "$OUT/server.log" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 80); do
  if ip netns exec "$NS_D" ss -lun | grep -Fq "$D_IP:$PORT"; then
    break
  fi
  sleep 0.1
done
ip netns exec "$NS_D" ss -lun | grep -Fq "$D_IP:$PORT"

start_ns="$(date +%s%N)"
ip netns exec "$NS_S" env RUST_LOG=info   "$CLIENT_BIN"     "https://test.com/stream-bytes/$FLOW_BYTES"     --no-verify     --connect-to "$D_IP:$PORT"     --http-version HTTP/3     --max-data 268435456     --max-window 268435456     --max-stream-data 268435456     --max-stream-window 268435456     --idle-timeout 30000     --dump-responses "$OUT/response"   > "$OUT/client.log" 2>&1
end_ns="$(date +%s%N)"

sleep 0.3
kill -TERM "$SERVER_PID" >/dev/null 2>&1 || true
wait "$SERVER_PID" >/dev/null 2>&1 || true
SERVER_PID=""

response="$OUT/response/$FLOW_BYTES"
[[ -f "$response" ]]
[[ "$(stat -c %s "$response")" == "$FLOW_BYTES" ]]
[[ -s "$OUT/lite.jsonl" ]]

python3 - "$OUT/lite.jsonl" "$OUT/lite-telemetry-summary.json" <<'PY'
import json
import sys

src, out = sys.argv[1:]
records = []
with open(src, "r", encoding="utf-8") as fh:
    for line_no, raw in enumerate(fh, 1):
        raw = raw.strip()
        if not raw:
            continue
        try:
            record = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise SystemExit(f"invalid Lite telemetry JSON on line {line_no}: {exc}")
        if record.get("schema") != "p2-lite-v1":
            raise SystemExit(
                f"unexpected Lite telemetry schema on line {line_no}: "
                f"{record.get('schema')!r}"
            )
        records.append(record)

if not records:
    raise SystemExit("Lite telemetry file contained no records")

reasons = sorted({str(r.get("reason")) for r in records})
states = sorted({str(r.get("state")) for r in records})
if "POLICY_LIMITED" not in reasons:
    raise SystemExit(
        "policy-limited smoke did not emit POLICY_LIMITED telemetry: "
        + ",".join(reasons)
    )

summary = {
    "schema": "p2-lite-telemetry-smoke-v1",
    "records": len(records),
    "reasons": reasons,
    "states": states,
    "first_seq": records[0].get("seq"),
    "last_seq": records[-1].get("seq"),
    "policy_limited_seen": True,
}
with open(out, "w", encoding="utf-8") as fh:
    json.dump(summary, fh, indent=2, sort_keys=True)
    fh.write("\n")
print(json.dumps(summary, sort_keys=True))
PY

python3 - "$start_ns" "$end_ns" "$FLOW_BYTES" "$TARGET_BPS" "$MAX_RATE_BPS" "$OUT/summary.json" <<'PY'
import json
import sys

start_ns, end_ns, flow_bytes, target_bps, max_rate_bps, out = sys.argv[1:]
elapsed = (int(end_ns) - int(start_ns)) / 1_000_000_000
flow_bytes = int(flow_bytes)
target_bps = int(target_bps)
max_rate_bps = int(max_rate_bps)

# This smoke intentionally uses MaxRate < Target, so the controller is
# policy-limited and cannot enter Assist. The elapsed-time bound only proves
# that the experiment MaxRate reached the real pacer.
minimum_elapsed = flow_bytes / (max_rate_bps * 1.15)
summary = {
    "schema": "p2-lite-entry-smoke-v1",
    "mode": "lite",
    "target_Bps": target_bps,
    "max_rate_Bps": max_rate_bps,
    "flow_bytes": flow_bytes,
    "elapsed_seconds": elapsed,
    "minimum_elapsed_for_115pct_maxrate_seconds": minimum_elapsed,
    "policy_limited_by_construction": max_rate_bps < target_bps,
    "entry_proved_by_maxrate_timing": elapsed >= minimum_elapsed,
    "maxrate_timing_pass": elapsed >= minimum_elapsed,
}
with open(out, "w", encoding="utf-8") as fh:
    json.dump(summary, fh, indent=2, sort_keys=True)
    fh.write("\n")
print(json.dumps(summary, sort_keys=True))
if not summary["policy_limited_by_construction"]:
    raise SystemExit("Lite entry smoke must keep MaxRate < Target")
if not summary["maxrate_timing_pass"]:
    raise SystemExit("experiment MaxRate did not constrain the real sender")
PY

chmod -R a+rX "$OUT"
echo "P2 Lite experiment entry smoke: PASS"
