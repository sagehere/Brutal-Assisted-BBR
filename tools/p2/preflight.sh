#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOST="$ROOT/third_party/quiche-0.29.3"
PATCH_DIR="$ROOT/patches/p2"
EXPECTED_SHA="55886df3be579579207104c8e645825b6347a209"

if [[ ! -d "$HOST" ]]; then
  echo "Missing frozen host submodule: $HOST" >&2
  exit 2
fi

actual_sha="$(git -C "$HOST" rev-parse HEAD)"
if [[ "$actual_sha" != "$EXPECTED_SHA" ]]; then
  echo "P2 preflight refused: expected host $EXPECTED_SHA, got $actual_sha" >&2
  exit 3
fi

echo "[preflight] shell syntax"
while IFS= read -r -d '' script; do
  bash -n "$script"
done < <(find "$ROOT/tools/p2" -type f -name '*.sh' -print0 | sort -z)

echo "[preflight] python syntax"
python3 - "$ROOT/tools/p2" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
for path in sorted(root.rglob("*.py")):
    source = path.read_text(encoding="utf-8")
    compile(source, str(path), "exec")
print(f"checked {sum(1 for _ in root.rglob('*.py'))} python files")
PY

tmp="$(mktemp -d)"
cleanup() {
  git -C "$HOST" worktree remove --force "$tmp" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT

echo "[preflight] create isolated frozen-host worktree"
git -C "$HOST" worktree add --quiet --detach "$tmp" "$EXPECTED_SHA"

mapfile -t patches < <(find "$PATCH_DIR" -maxdepth 1 -type f -name '*.patch' | sort)
if (( ${#patches[@]} == 0 )); then
  echo "No P2 patches found in $PATCH_DIR" >&2
  exit 4
fi

for patch in "${patches[@]}"; do
  name="$(basename "$patch")"
  echo "[preflight] check $name"
  git -C "$tmp" apply --check "$patch"
  echo "[preflight] apply $name"
  git -C "$tmp" apply "$patch"
done

echo "[preflight] diff integrity"
git -C "$tmp" diff --check

echo "[preflight] patch stack PASS (${#patches[@]} patches)"
