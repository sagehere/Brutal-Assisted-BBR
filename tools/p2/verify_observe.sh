#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

echo "[P2 Observe] checking frozen P1 contract"
python3 - <<'PY'
import json
from pathlib import Path

p = Path("阶段任务书/P1-冻结参数与用例.json")
d = json.loads(p.read_text(encoding="utf-8"))

assert d["schema_version"] == "p1-baseline-v3"
assert d["scope"]["host"] == "Cloudflare quiche 0.29.3"
assert d["scope"]["host_commit"] == "55886df3be579579207104c8e645825b6347a209"
assert d["capabilities"]["bbr_is_in_recovery"] == "not_used"
assert d["assist"]["allowed_bbr_phase"] == [
    "ProbeBW.Refill",
    "ProbeBW.Up",
    "ProbeBW.Cruise",
]
assert d["assist"]["max_relative_rate_gain"] == 1.1
assert d["assist"]["weight_step_per_bbr_round"] == 0.05
assert d["assist"]["max_duration_ms"] == 300
assert d["assist"]["max_rounds"] == 3
print("P1 frozen contract: OK")
PY

if [[ -d third_party/quiche-0.29.3/.git || -f third_party/quiche-0.29.3/.git ]]; then
    host_sha="$(git -C third_party/quiche-0.29.3 rev-parse HEAD)"
    test "$host_sha" = "55886df3be579579207104c8e645825b6347a209"
    echo "Frozen quiche host SHA: OK ($host_sha)"
else
    echo "Frozen quiche submodule is not initialized; skipping local SHA check"
fi

echo "[P2 Observe] deterministic replay tests"
python3 tools/p2/replay/test_babr_model.py

echo "[P2 Observe] PASS"
