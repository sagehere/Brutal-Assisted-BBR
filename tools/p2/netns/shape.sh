#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/common.sh"

require_root
require_cmds

RATE_MBIT="${BABR_RATE_MBIT:-100}"
ONE_WAY_DELAY_MS="${BABR_ONE_WAY_DELAY_MS:-20}"
LOSS_PCT="${BABR_LOSS_PCT:-0}"
BURST_KB="${BABR_TBF_BURST_KB:-512}"
TBF_LATENCY_MS="${BABR_TBF_LATENCY_MS:-100}"

# Remove prior qdiscs so repeated scenarios are deterministic.
for spec in "$NS_S:$S_IF" "$NS_R:$R_D_IF" "$NS_D:$D_IF"; do
  ns="${spec%%:*}"
  dev="${spec##*:}"
  ip netns exec "$ns" tc qdisc del dev "$dev" root 2>/dev/null || true
done

# Put delay/loss and bottleneck shaping on separate physical egress points so
# netem and tbf do not depend on qdisc nesting behavior.
ip netns exec "$NS_S" tc qdisc replace dev "$S_IF" root handle 10: netem   delay "${ONE_WAY_DELAY_MS}ms" loss "${LOSS_PCT}%"

ip netns exec "$NS_R" tc qdisc replace dev "$R_D_IF" root handle 20: tbf   rate "${RATE_MBIT}mbit" burst "${BURST_KB}kb" latency "${TBF_LATENCY_MS}ms"

# Symmetric propagation delay for the ACK path. Loss is applied only on the
# forward data path unless a later scenario explicitly changes this.
ip netns exec "$NS_D" tc qdisc replace dev "$D_IF" root handle 30: netem   delay "${ONE_WAY_DELAY_MS}ms"

echo "P2 shape applied: rate=${RATE_MBIT}mbit one_way_delay=${ONE_WAY_DELAY_MS}ms loss=${LOSS_PCT}%"
