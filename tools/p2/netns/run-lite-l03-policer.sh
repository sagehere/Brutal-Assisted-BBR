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
FLOW_BYTES="${BABR_P2_FLOW_BYTES:-268435456}"
REQUESTS="${BABR_P2_L03_REQUESTS:-4}"
TARGET_BPS="${BABR_P2_TARGET_BPS:-25000000}"
POLICER_MBIT="${BABR_P2_POLICER_MBIT:-150}"
INITIAL_SHAPER_MBIT="${BABR_P2_L03_INITIAL_SHAPER_MBIT:-180}"
PRE_SHAPER_KIND="${BABR_P2_L03_PRE_SHAPER_KIND:-tbf}"
NETEM_LIMIT_PACKETS="${BABR_P2_L03_NETEM_LIMIT_PACKETS:-100}"
TBF_BURST_KB="${BABR_P2_L03_TBF_BURST_KB:-64}"
TBF_LATENCY_MS="${BABR_P2_L03_TBF_LATENCY_MS:-5}"
EXPERIMENT_VERSION="${BABR_P2_L03_EXPERIMENT_VERSION:-l03-policer-v2-low-queue}"
OUT="${BABR_P2_L03_ARTIFACT_DIR:-$P2_ROOT/阶段任务书/p2-l03-artifacts}"

rm -rf "$OUT"
mkdir -p "$OUT/response"

echo "L03 config: version=${EXPERIMENT_VERSION} target=${TARGET_BPS} byte/s pre_shaper=${PRE_SHAPER_KIND}:${INITIAL_SHAPER_MBIT}mbit flow_limit=${NETEM_LIMIT_PACKETS}packets policer=${POLICER_MBIT}mbit tbf_burst=${TBF_BURST_KB}kb tbf_latency=${TBF_LATENCY_MS}ms streams=${REQUESTS} bytes_per_stream=${FLOW_BYTES}" > "$OUT/config.txt"

cleanup() {
  pkill -TERM -f "$SERVER_BIN" 2>/dev/null || true
  "$HERE/cleanup.sh" >/dev/null 2>&1 || true
}
trap cleanup EXIT

bash "$HERE/setup.sh" >/dev/null
# Keep the pre-admission shaper below the 200 Mbps Target but above bounded
# Assist headroom. After admission, open the shaper and add the actual 150 Mbps
# drop policer to prove that later loss revokes already-active assistance.
# The generic netns default (512 KiB / 100 ms) itself creates >20 ms queueing
# at 150 Mbps and makes the frozen hard guard reject every Assist attempt.
# Keep the 5 ms queue cap below the frozen 20 ms hard guard. The L03 workflow
# versions the pre-admission shaper separately from the real drop policer.
BABR_RATE_MBIT="$INITIAL_SHAPER_MBIT" \
  BABR_TBF_BURST_KB="$TBF_BURST_KB" \
BABR_TBF_LATENCY_MS="$TBF_LATENCY_MS" \
BABR_DATA_DIRECTION=receiver_to_sender \
  bash "$HERE/shape.sh" >/dev/null

case "$PRE_SHAPER_KIND" in
  tbf)
    ;;
  netem-rate)
    # Replace the pre-admission TBF token bucket with a packet-rate shaper.
    # Keep its queue bounded to about 8 ms at 150 Mbps (100 MTU packets),
    # below the frozen 20 ms hard queue guard. The experiment verifies actual
    # drops and RTT rather than assuming this queue cannot overflow.
    ip netns exec "$NS_R" tc qdisc replace dev "$R_S_IF" root netem \
      rate "${INITIAL_SHAPER_MBIT}mbit" limit "$NETEM_LIMIT_PACKETS"
    ;;
  fq-maxrate)
    # Pace the locally generated QUIC socket at the 150 Mbps cap, where FQ
    # can use socket pacing, and move the 20 ms data-path propagation delay to
    # the router. Keep the per-socket enqueue limit near an 8 ms queue budget.
    ip netns exec "$NS_D" tc qdisc replace dev "$D_IF" root fq \
      maxrate "${INITIAL_SHAPER_MBIT}mbit" \
      flow_limit "$NETEM_LIMIT_PACKETS" limit 1000
    ip netns exec "$NS_R" tc qdisc replace dev "$R_S_IF" root netem \
      delay 20ms
    ;;
  *)
    echo "Unsupported L03 pre-admission shaper: $PRE_SHAPER_KIND" >&2
    exit 94
    ;;
esac

# Retain qdisc counters so any pre-admission loss can be attributed to the
# router rate qdisc or server netem instead of inferred from Lite reasons.
ip netns exec "$NS_R" tc -s -d qdisc show dev "$R_S_IF" > "$OUT/router-data-qdisc-before.txt"
ip netns exec "$NS_D" tc -s -d qdisc show dev "$D_IF" > "$OUT/sender-data-qdisc-before.txt"
echo "Router data qdisc before transfer ($R_S_IF):"
cat "$OUT/router-data-qdisc-before.txt"
echo "Sender data qdisc before transfer ($D_IF):"
cat "$OUT/sender-data-qdisc-before.txt"

ip netns exec "$NS_D" env \
  BABR_P2_MODE=lite \
  BABR_P2_TARGET_BPS="$TARGET_BPS" \
  BABR_P2_LITE_TELEMETRY_FILE="$OUT/lite.jsonl" \
  "$SERVER_BIN" --address "$D_IP:$PORT" --cc-algorithm bbr2 --enable-pacing \
  > "$OUT/server.log" 2>&1 &

sleep 1
# The example server feeds a single response through a bounded channel, which
# can make every sample application-limited. Concurrent real H3 streams
# keep the same connection's sender supplied without changing BBR or Lite.
CLIENT_URL="https://test.com/stream-bytes/$FLOW_BYTES"
CLIENT_URLS=()
for _ in $(seq 1 "$REQUESTS"); do
  CLIENT_URLS+=("$CLIENT_URL")
done
ip netns exec "$NS_S" "$CLIENT_BIN" "${CLIENT_URLS[@]}" \
  --no-verify --connect-to "$D_IP:$PORT" \
  --http-version HTTP/3 \
  --dump-responses "$OUT/response" \
  > "$OUT/client.log" 2>&1 &
CLIENT_PID=$!

ASSIST_SEEN=0
# Startup queue protection may legitimately enter the frozen 30-second
# backoff. Keep this controlled bulk flow alive long enough to observe a later
# real admission, without altering the controller or its recovery rules.
for _ in $(seq 1 600); do
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
  ip netns exec "$NS_R" tc -s -d qdisc show dev "$R_S_IF" > "$OUT/router-data-qdisc-after.txt"
  ip netns exec "$NS_D" tc -s -d qdisc show dev "$D_IF" > "$OUT/sender-data-qdisc-after.txt"
  echo "Router data qdisc after transfer ($R_S_IF):"
  cat "$OUT/router-data-qdisc-after.txt"
  echo "Sender data qdisc after transfer ($D_IF):"
  cat "$OUT/sender-data-qdisc-after.txt"
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
ip netns exec "$NS_D" tc qdisc replace dev "$D_IF" root tbf rate 500mbit burst 64kb latency 5ms
ip netns exec "$NS_D" tc qdisc replace dev "$D_IF" clsact
ip netns exec "$NS_D" tc filter replace dev "$D_IF" egress protocol ip pref 100 \
  flower ip_proto udp \
  action police rate "${POLICER_MBIT}mbit" burst 32kb mtu 64kb drop
ip netns exec "$NS_D" tc -s filter show dev "$D_IF" egress > "$OUT/policer-filter-before.txt"
wait "$CLIENT_PID"

ip netns exec "$NS_R" tc -s -d qdisc show dev "$R_S_IF" > "$OUT/router-data-qdisc-after.txt"
ip netns exec "$NS_D" tc -s -d qdisc show dev "$D_IF" > "$OUT/sender-data-qdisc-after.txt"
echo "Router data qdisc after transfer ($R_S_IF):"
cat "$OUT/router-data-qdisc-after.txt"
echo "Sender data qdisc after transfer ($D_IF):"
cat "$OUT/sender-data-qdisc-after.txt"

ip netns exec "$NS_D" tc -s filter show dev "$D_IF" egress > "$OUT/policer-filter-after.txt"
if ! grep -Eq 'overlimits [1-9][0-9]*' "$OUT/policer-filter-after.txt"; then
  echo "L03 policer did not drop traffic; refusing to treat the shaper as policer evidence" >&2
  exit 94
fi
python3 "$P2_ROOT/tools/p2/replay/check_lite_trace.py" \
  "$OUT/lite.jsonl" --scenario l03 --summary "$OUT/summary.json"

echo 'P2 L03 policer safety smoke: PASS'
