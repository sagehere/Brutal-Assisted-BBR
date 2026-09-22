#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/common.sh"

require_root
require_cmds

RATE_MBIT="${BABR_RATE_MBIT:-100}"
ONE_WAY_DELAY_MS="${BABR_ONE_WAY_DELAY_MS:-20}"
MIN_RATE_RATIO="${BABR_CAL_MIN_RATE_RATIO:-0.70}"
MAX_RATE_RATIO="${BABR_CAL_MAX_RATE_RATIO:-1.15}"

mkdir -p "$ARTIFACT_DIR"
rm -f "$ARTIFACT_DIR"/calibration-* "$ARTIFACT_DIR"/iperf-* "$ARTIFACT_DIR"/ping.txt
date -u +"%Y-%m-%dT%H:%M:%SZ" > "$ARTIFACT_DIR/calibration-started.txt"

cleanup() {
  bash "$HERE/cleanup.sh" >/dev/null 2>&1 || true
}
trap cleanup EXIT

bash "$HERE/setup.sh"
bash "$HERE/shape.sh"

{
  echo "kernel=$(uname -srvm)"
  echo "ip=$(ip -V 2>&1)"
  echo "tc=$(tc -V 2>&1)"
  echo "iperf3=$(iperf3 --version 2>&1 | head -n 1)"
  echo "rate_mbit=$RATE_MBIT"
  echo "one_way_delay_ms=$ONE_WAY_DELAY_MS"
  echo "loss_pct=${BABR_LOSS_PCT:-0}"
  echo "sender_ns=$NS_S"
  echo "router_ns=$NS_R"
  echo "receiver_ns=$NS_D"
} > "$ARTIFACT_DIR/calibration-environment.txt"

ip netns exec "$NS_R" test "$(sysctl -n net.ipv4.ip_forward)" = "1"

ip netns exec "$NS_S" tc -s qdisc show dev "$S_IF"   | tee "$ARTIFACT_DIR/calibration-qdisc-sender.txt" | grep -q "netem"
ip netns exec "$NS_R" tc -s qdisc show dev "$R_D_IF"   | tee "$ARTIFACT_DIR/calibration-qdisc-router.txt" | grep -q "tbf"
ip netns exec "$NS_D" tc -s qdisc show dev "$D_IF"   | tee "$ARTIFACT_DIR/calibration-qdisc-receiver.txt" | grep -q "netem"

ip -n "$NS_S" -details addr show > "$ARTIFACT_DIR/calibration-sender-addresses.txt"
ip -n "$NS_R" -details addr show > "$ARTIFACT_DIR/calibration-router-addresses.txt"
ip -n "$NS_D" -details addr show > "$ARTIFACT_DIR/calibration-receiver-addresses.txt"
ip -n "$NS_S" route show > "$ARTIFACT_DIR/calibration-sender-routes.txt"
ip -n "$NS_R" route show > "$ARTIFACT_DIR/calibration-router-routes.txt"
ip -n "$NS_D" route show > "$ARTIFACT_DIR/calibration-receiver-routes.txt"

ip netns exec "$NS_S" ping -n -c 12 -i 0.1 -W 2 "$D_IP"   | tee "$ARTIFACT_DIR/ping.txt"

AVG_RTT_MS="$(awk -F'/' '/^(rtt|round-trip)/ {print $5}' "$ARTIFACT_DIR/ping.txt")"
if [[ -z "$AVG_RTT_MS" ]]; then
  echo "Unable to parse average RTT" >&2
  exit 92
fi

ip netns exec "$NS_D" iperf3 -s -1 -D   --logfile "$ARTIFACT_DIR/iperf-server.log"
sleep 0.5
ip netns exec "$NS_S" iperf3 -c "$D_IP" -P 4 -t 8 -O 1 -J > "$ARTIFACT_DIR/iperf-client.json"

THROUGHPUT_MBIT="$(python3 - "$ARTIFACT_DIR/iperf-client.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)

end = data.get("end", {})
node = end.get("sum_received") or end.get("sum") or {}
bps = node.get("bits_per_second")
if not isinstance(bps, (int, float)) or bps <= 0:
    raise SystemExit("iperf3 JSON has no positive receiver bits_per_second")
print(f"{bps / 1_000_000:.3f}")
PY
)"

python3 - "$AVG_RTT_MS" "$ONE_WAY_DELAY_MS" "$THROUGHPUT_MBIT" "$RATE_MBIT"   "$MIN_RATE_RATIO" "$MAX_RATE_RATIO" "$ARTIFACT_DIR/calibration-summary.json" <<'PY'
import json
import sys

avg_rtt = float(sys.argv[1])
one_way = float(sys.argv[2])
throughput = float(sys.argv[3])
rate = float(sys.argv[4])
min_ratio = float(sys.argv[5])
max_ratio = float(sys.argv[6])
out = sys.argv[7]

expected_rtt = 2.0 * one_way
rtt_min = max(1.0, expected_rtt * 0.70)
rtt_max = expected_rtt * 2.0 + 5.0
rate_min = rate * min_ratio
rate_max = rate * max_ratio

result = {
    "schema": "p2-network-calibration-v1",
    "configured_rate_mbit": rate,
    "configured_one_way_delay_ms": one_way,
    "measured_avg_rtt_ms": avg_rtt,
    "measured_tcp_receiver_mbit": throughput,
    "acceptance": {
        "rtt_min_ms": rtt_min,
        "rtt_max_ms": rtt_max,
        "throughput_min_mbit": rate_min,
        "throughput_max_mbit": rate_max,
    },
}
result["rtt_pass"] = rtt_min <= avg_rtt <= rtt_max
result["throughput_pass"] = rate_min <= throughput <= rate_max
result["pass"] = result["rtt_pass"] and result["throughput_pass"]

with open(out, "w", encoding="utf-8") as fh:
    json.dump(result, fh, indent=2, sort_keys=True)
    fh.write("\n")

print(json.dumps(result, sort_keys=True))
if not result["pass"]:
    raise SystemExit("P2 network calibration thresholds not met")
PY

chmod -R a+rX "$ARTIFACT_DIR"

echo "P2 network calibration: PASS"
