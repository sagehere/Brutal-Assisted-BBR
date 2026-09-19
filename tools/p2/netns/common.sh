#!/usr/bin/env bash
set -euo pipefail

P2_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

NS_S="${BABR_NS_SENDER:-babrp2-s}"
NS_R="${BABR_NS_ROUTER:-babrp2-r}"
NS_D="${BABR_NS_RECEIVER:-babrp2-d}"

S_IF="${BABR_S_IF:-p2s0}"
R_S_IF="${BABR_R_S_IF:-p2rs0}"
R_D_IF="${BABR_R_D_IF:-p2rd0}"
D_IF="${BABR_D_IF:-p2d0}"

S_CIDR="${BABR_S_CIDR:-10.203.0.2/24}"
R_S_CIDR="${BABR_R_S_CIDR:-10.203.0.1/24}"
R_D_CIDR="${BABR_R_D_CIDR:-10.204.0.1/24}"
D_CIDR="${BABR_D_CIDR:-10.204.0.2/24}"

S_IP="${BABR_S_IP:-10.203.0.2}"
R_S_IP="${BABR_R_S_IP:-10.203.0.1}"
R_D_IP="${BABR_R_D_IP:-10.204.0.1}"
D_IP="${BABR_D_IP:-10.204.0.2}"

ARTIFACT_DIR="${BABR_P2_NETWORK_ARTIFACT_DIR:-$P2_ROOT/阶段任务书/p2-network-artifacts}"

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "P2 netns harness requires root/CAP_NET_ADMIN. Run with sudo." >&2
    exit 90
  fi
}

require_cmds() {
  local missing=0
  for cmd in ip tc ping iperf3 python3 sysctl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "Missing required command: $cmd" >&2
      missing=1
    fi
  done
  if [[ "$missing" -ne 0 ]]; then
    exit 91
  fi
}

delete_ns_if_present() {
  local ns="$1"
  if ip netns list | awk '{print $1}' | grep -Fxq "$ns"; then
    ip netns del "$ns"
  fi
}

delete_link_if_present() {
  local dev="$1"
  if ip link show "$dev" >/dev/null 2>&1; then
    ip link del "$dev"
  fi
}
