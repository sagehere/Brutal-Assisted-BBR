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
TARGET_BPS="${BABR_P2_TARGET_BPS:-25000000}"
POLICER_MBIT="${BABR_P2_POLICER_MBIT:-150}"
OUT="${BABR_P2_L03_ARTIFACT_DIR:-$P2_ROOT/阶段任务书/p2-l03-artifacts}"

rm -rf "$OUT"
mkdir -p "$OUT/response"

echo "L03 config: target=${TARGET_BPS} byte/s policer=${POLICER_MBIT}mbit" > "$OUT/config.txt"

cleanup() {
  pkill -TERM -f "$SERVER_BIN" 2>/dev/null || true
  "$HERE/cleanup.sh" >/dev/null 2>&1 || true
}
trap cleanup EXIT

bash "$HERE/setup.sh" >/dev/null
BABR_DATA_DIRECTION=receiver_to_sender bash "$HERE/shape.sh" >/dev/null

# L03: bottleneck is deliberately below BABR target. This is a safety proof,
# not a throughput benchmark. Keep policer units explicit in mbit.
ip netns exec "$NS_D" tc qdisc replace dev "$D_IF" root tbf rate "${POLICER_MBIT}mbit" burst 32kb latency 50ms

ip netns exec "$NS_D" env \
  BABR_P2_MODE=lite \
  BABR_P2_TARGET_BPS="$TARGET_BPS" \
  BABR_P2_LITE_TELEMETRY_FILE="$OUT/lite.jsonl" \
  "$SERVER_BIN" --address "$D_IP:$PORT" --cc-algorithm bbr2 --enable-pacing \
  > "$OUT/server.log" 2>&1 &

sleep 1
ip netns exec "$NS_S" "$CLIENT_BIN" \
  "https://test.com/stream-bytes/$FLOW_BYTES" \
  --no-verify --connect-to "$D_IP:$PORT" \
  --http-version HTTP/3 \
  --dump-responses "$OUT/response" \
  > "$OUT/client.log" 2>&1

python3 - "$OUT/lite.jsonl" "$OUT/summary.json" <<'PY'
import json,sys
src,out=sys.argv[1:]
records=[json.loads(x) for x in open(src,encoding='utf-8') if x.strip()]
if not records:
    raise SystemExit('no Lite telemetry')

reasons={r.get('reason') for r in records}
allowed={
    'HARD_QUEUE_DELAY',
    'ASSIST_TIMEOUT',
    'ASSIST_BUDGET_EXHAUSTED',
    'MAX_ROUNDS',
    'NO_BENEFIT',
    'POLICY_LIMITED',
}
if not reasons & allowed:
    raise SystemExit(f'no L03 exit/control evidence: {reasons}')

states=[r.get('state') for r in records]
summary={
    'schema':'p2-l03-v2',
    'records':len(records),
    'reasons':sorted(reasons),
    'states':sorted(set(states)),
    'hard_exit_or_control_seen':bool(reasons & allowed),
}
json.dump(summary,open(out,'w'),indent=2)
PY

echo 'P2 L03 policer safety smoke: PASS'
