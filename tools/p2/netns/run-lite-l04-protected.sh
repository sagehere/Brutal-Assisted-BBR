#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/common.sh"

require_root
require_cmds

HOST="$P2_ROOT/third_party/quiche-0.29.3"
SERVER_BIN="${BABR_P2_SERVER_BIN:-$HOST/target/debug/examples/async_http3_server}"
CLIENT_BIN="${BABR_P2_CLIENT_BIN:-$HOST/target/debug/quiche-client}"
FLOW_BYTES="${BABR_P2_FLOW_BYTES:-16777216}"
TARGET_BPS="${BABR_P2_TARGET_BPS:-25000000}"
OUT="${BABR_P2_L04_ARTIFACT_DIR:-$P2_ROOT/阶段任务书/p2-l04-artifacts}"

rm -rf "$OUT"
mkdir -p "$OUT/response"

cleanup() {
  pkill -TERM -f "$SERVER_BIN" 2>/dev/null || true
  "$HERE/cleanup.sh" >/dev/null 2>&1 || true
}
trap cleanup EXIT

bash "$HERE/setup.sh" >/dev/null
BABR_DATA_DIRECTION=receiver_to_sender bash "$HERE/shape.sh" >/dev/null

ip netns exec "$NS_D" env \
  RUST_LOG=info \
  BABR_P2_MODE=lite \
  BABR_P2_TARGET_BPS="$TARGET_BPS" \
  BABR_P2_LITE_TELEMETRY_FILE="$OUT/lite.jsonl" \
  "$SERVER_BIN" --address "$D_IP:4433" --cc-algorithm bbr2 --enable-pacing \
  > "$OUT/server.log" 2>&1 &

sleep 1

ip netns exec "$NS_S" "$CLIENT_BIN" \
  "https://test.com/stream-bytes/$FLOW_BYTES" \
  --no-verify \
  --connect-to "$D_IP:4433" \
  --http-version HTTP/3 \
  --dump-responses "$OUT/response" \
  > "$OUT/client.log" 2>&1

python3 "$P2_ROOT/tools/p2/replay/check_lite_trace.py" \
  "$OUT/lite.jsonl" --scenario l04 --summary "$OUT/summary.json"

echo 'P2 L04 protected phase safety: PASS'
