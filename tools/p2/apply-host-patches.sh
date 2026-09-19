#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOST="$ROOT/third_party/quiche-0.29.3"
EXPECTED_SHA="55886df3be579579207104c8e645825b6347a209"
PATCH_DIR="$ROOT/patches/p2"

actual_sha="$(git -C "$HOST" rev-parse HEAD)"
if [[ "$actual_sha" != "$EXPECTED_SHA" ]]; then
  echo "Refusing P2 host patches: expected $EXPECTED_SHA, got $actual_sha" >&2
  exit 2
fi

if ! git -C "$HOST" diff --quiet || ! git -C "$HOST" diff --cached --quiet; then
  echo "Refusing P2 host patches: frozen host worktree is not clean" >&2
  exit 3
fi

for patch in "$PATCH_DIR"/*.patch; do
  echo "Checking $(basename "$patch")"
  git -C "$HOST" apply --check "$patch"
  echo "Applying $(basename "$patch")"
  git -C "$HOST" apply "$patch"
done

git -C "$HOST" diff --check
echo "P2 host patches applied on frozen quiche $EXPECTED_SHA"
