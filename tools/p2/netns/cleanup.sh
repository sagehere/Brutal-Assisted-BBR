#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_root

delete_ns_if_present "$NS_S"
delete_ns_if_present "$NS_R"
delete_ns_if_present "$NS_D"

delete_link_if_present "$S_IF"
delete_link_if_present "$R_S_IF"
delete_link_if_present "$R_D_IF"
delete_link_if_present "$D_IF"

echo "P2 netns topology cleaned"
