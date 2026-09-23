#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/common.sh"

RUNS="${BABR_P2_L05_RUNS:-3}"
OUT_ROOT="${BABR_P2_L05_ARTIFACT_ROOT:-$P2_ROOT/阶段任务书/p2-l05-artifacts}"
if (( RUNS < 1 )); then
  echo "L05 requires at least one independent run" >&2
  exit 93
fi

python3 - "$P2_ROOT" "$OUT_ROOT" <<'PY'
from pathlib import Path
import shutil
import sys

root, output = map(Path, sys.argv[1:])
root = root.resolve()
output = output.resolve()
if output == root or not output.is_relative_to(root):
    raise SystemExit(f"refusing to clear artifact path outside the repository: {output}")
shutil.rmtree(output, ignore_errors=True)
output.mkdir(parents=True)
PY

for run in $(seq -w 1 "$RUNS"); do
  echo "L05 independent ACK-suppression run $run/$RUNS"
  BABR_P2_L05_ARTIFACT_DIR="$OUT_ROOT/run-$run" \
    bash "$HERE/run-lite-l05-ack-suppression-once.sh"
done

python3 "$P2_ROOT/tools/p2/replay/aggregate_l05_runs.py" \
  "$OUT_ROOT" --summary "$OUT_ROOT/summary.json"
