#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/common.sh"

require_root
require_cmds

bash "$HERE/cleanup.sh" >/dev/null

ip netns add "$NS_S"
ip netns add "$NS_R"
ip netns add "$NS_D"

ip link add "$S_IF" type veth peer name "$R_S_IF"
ip link add "$R_D_IF" type veth peer name "$D_IF"

ip link set "$S_IF" netns "$NS_S"
ip link set "$R_S_IF" netns "$NS_R"
ip link set "$R_D_IF" netns "$NS_R"
ip link set "$D_IF" netns "$NS_D"

for ns in "$NS_S" "$NS_R" "$NS_D"; do
  ip -n "$ns" link set lo up
done

ip -n "$NS_S" addr add "$S_CIDR" dev "$S_IF"
ip -n "$NS_R" addr add "$R_S_CIDR" dev "$R_S_IF"
ip -n "$NS_R" addr add "$R_D_CIDR" dev "$R_D_IF"
ip -n "$NS_D" addr add "$D_CIDR" dev "$D_IF"

ip -n "$NS_S" link set "$S_IF" up
ip -n "$NS_R" link set "$R_S_IF" up
ip -n "$NS_R" link set "$R_D_IF" up
ip -n "$NS_D" link set "$D_IF" up

ip -n "$NS_S" route replace default via "$R_S_IP" dev "$S_IF"
ip -n "$NS_D" route replace default via "$R_D_IP" dev "$D_IF"

ip netns exec "$NS_R" sysctl -q -w net.ipv4.ip_forward=1

# Connectivity must work before any shaping is applied.
ip netns exec "$NS_S" ping -n -c 2 -W 1 "$D_IP" >/dev/null

echo "P2 netns topology ready: $NS_S -> $NS_R -> $NS_D"
