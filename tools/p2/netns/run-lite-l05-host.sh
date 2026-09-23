#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
OUT="${BABR_P2_L05_ARTIFACT_ROOT:-$ROOT/阶段任务书/p2-l05-artifacts}"
mkdir -p "$OUT/host"
NAMES=(l05_no_ack_deadline_rejects_expired_assist_and_keeps_recovery
       deadline_has_zero_grace_at_send_entry
       deadline_timer_expires_without_an_ack_or_round_callback
       babr_true_pto_records_guard_event
       pto_send_on_path_retransmits_without_loss)
for name in "${NAMES[@]}"; do
  if cargo test --manifest-path "$ROOT/third_party/quiche-0.29.3/Cargo.toml" \
      -p quiche --features gcongestion --lib "$name" -- --nocapture \
      > "$OUT/host/$name.log" 2>&1; then
    printf 'exit=0\n' > "$OUT/host/$name.status"
  else
    printf 'exit=1\n' > "$OUT/host/$name.status"
  fi
done
python3 - "$OUT/host" "$(git -C "$ROOT" rev-parse HEAD)" <<'PY'
import json, re, sys
from pathlib import Path
root, commit = Path(sys.argv[1]), sys.argv[2]
tests = {}
for path in root.glob("*.status"):
    output = (root / (path.stem + ".log")).read_text(errors="replace")
    matches = re.findall(r"test result: ok\. (\d+) passed", output)
    tests[path.stem] = {"status": "PASS" if path.read_text().strip() == "exit=0"
                        and matches and int(matches[-1]) >= 1 else "FAIL",
                        "passed": int(matches[-1]) if matches else 0,
                        "log": path.stem + ".log"}
result = {"schema": "l05-split-v1", "scenario": "l05-host",
          "candidate_commit": commit,
          "status": "PASS" if len(tests) == 5 and
          all(x["status"] == "PASS" for x in tests.values()) else "FAIL",
          "tests": tests}
(root / "summary.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
print(json.dumps(result, indent=2, sort_keys=True))
PY
