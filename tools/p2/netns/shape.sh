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
DATA_DIRECTION="${BABR_DATA_DIRECTION:-sender_to_receiver}"

# Remove prior qdiscs on every topology egress so changing direction cannot
# leave stale shaping behind.
for spec in   "$NS_S:$S_IF"   "$NS_R:$R_S_IF"   "$NS_R:$R_D_IF"   "$NS_D:$D_IF"
do
  ns="${spec%%:*}"
  dev="${spec##*:}"
  ip netns exec "$ns" tc qdisc del dev "$dev" root 2>/dev/null || true
done

case "$DATA_DIRECTION" in
  sender_to_receiver)
    data_ns="$NS_S"
    data_if="$S_IF"
    bottleneck_if="$R_D_IF"
    ack_ns="$NS_D"
    ack_if="$D_IF"
    ;;

  receiver_to_sender)
    data_ns="$NS_D"
    data_if="$D_IF"
    bottleneck_if="$R_S_IF"
    ack_ns="$NS_S"
    ack_if="$S_IF"
    ;;

  *)
    echo "Unsupported BABR_DATA_DIRECTION: $DATA_DIRECTION" >&2
    exit 94
    ;;
esac

# Delay/loss is placed on the sender-side data egress; the bandwidth bottleneck
# is on the router egress toward the data receiver. This guarantees the bulk
# data path crosses both netem and TBF without classless-qdisc nesting.
ip netns exec "$data_ns" tc qdisc replace dev "$data_if" root handle 10: netem   delay "${ONE_WAY_DELAY_MS}ms" loss "${LOSS_PCT}%"

ip netns exec "$NS_R" tc qdisc replace dev "$bottleneck_if" root handle 20: tbf   rate "${RATE_MBIT}mbit" burst "${BURST_KB}kb" latency "${TBF_LATENCY_MS}ms"

# Symmetric propagation delay for the ACK/request path. Loss remains on the
# bulk-data direction unless a scenario explicitly asks for a different rule.
ip netns exec "$ack_ns" tc qdisc replace dev "$ack_if" root handle 30: netem   delay "${ONE_WAY_DELAY_MS}ms"

echo "P2 shape applied: direction=$DATA_DIRECTION rate=${RATE_MBIT}mbit one_way_delay=${ONE_WAY_DELAY_MS}ms loss=${LOSS_PCT}% bottleneck_if=$bottleneck_if"
