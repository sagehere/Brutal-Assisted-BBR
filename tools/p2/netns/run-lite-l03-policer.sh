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
# Start at the intended 150 Mbps capacity so the 200 Mbps Target is genuinely
# unreachable yet can enter bounded Assist without packet drops. After an
# Assist record exists, open the shaper and add the real policer to prove that
# a later loss revokes already-active assistance.
BABR_RATE_MBIT="$POLICER_MBIT" BABR_DATA_DIRECTION=receiver_to_sender bash "$HERE/shape.sh" >/dev/null

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
  > "$OUT/client.log" 2>&1 &
CLIENT_PID=$!

ASSIST_SEEN=0
for _ in $(seq 1 120); do
  if [[ -s "$OUT/lite.jsonl" ]] && grep -Fq '"control_applied":true' "$OUT/lite.jsonl"; then
    ASSIST_SEEN=1
    break
  fi
  if ! kill -0 "$CLIENT_PID" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
if [[ "$ASSIST_SEEN" != 1 ]]; then
  wait "$CLIENT_PID" || true
  # This is a valid fail-closed outcome, not permission to weaken admission,
  # CWND, or recovery rules. Preserve the trace and an explicit BLOCKED summary
  # so the G2 aggregator cannot mistake a non-exercised policer for PASS.
  printf '%s\n' 'policer_not_armed=no real Assist admission' > "$OUT/policer-status.txt"
  python3 "$P2_ROOT/tools/p2/replay/check_lite_trace.py" \
    "$OUT/lite.jsonl" --scenario l03 --summary "$OUT/summary.json" --allow-blocked
  echo 'P2 L03 policer safety evidence: BLOCKED (no Assist admission)'
  exit 0
fi

# The initial TBF intentionally permits Assist. The policer is then the only
# loss source: it is installed on the actual QUIC data-sender egress and its
# post-run overlimit counter is mandatory evidence.
ip netns exec "$NS_D" tc qdisc replace dev "$D_IF" root tbf rate 500mbit burst 64kb latency 50ms
ip netns exec "$NS_D" tc qdisc replace dev "$D_IF" clsact
ip netns exec "$NS_D" tc filter replace dev "$D_IF" egress protocol ip pref 100 \
  flower ip_proto udp \
  action police rate "${POLICER_MBIT}mbit" burst 32kb mtu 64kb drop
ip netns exec "$NS_D" tc -s filter show dev "$D_IF" egress > "$OUT/policer-filter-before.txt"
wait "$CLIENT_PID"

ip netns exec "$NS_D" tc -s filter show dev "$D_IF" egress > "$OUT/policer-filter-after.txt"
if ! grep -Eq 'overlimits [1-9][0-9]*' "$OUT/policer-filter-after.txt"; then
  echo "L03 policer did not drop traffic; refusing to treat the shaper as policer evidence" >&2
  exit 94
fi
python3 "$P2_ROOT/tools/p2/replay/check_lite_trace.py" \
  "$OUT/lite.jsonl" --scenario l03 --summary "$OUT/summary.json"

echo 'P2 L03 policer safety smoke: PASS'
