#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOST="$ROOT/third_party/quiche-0.29.3"
cd "$ROOT"

echo "[P2 Lite Host] verify frozen contract and M3 host invariants"

python3 - <<'PY'
import json
from pathlib import Path

root = Path(".")
contract = json.loads(
    (root / "阶段任务书/P1-冻结参数与用例.json").read_text(encoding="utf-8")
)

assert contract["schema_version"] == "p1-baseline-v4"
assert contract["scope"]["host_commit"] == "55886df3be579579207104c8e645825b6347a209"
assert contract["target"]["minimum_nonzero_byte_per_s"] == 1_000_000
assert contract["target"]["maximum_byte_per_s"] == 125_000_000
assert contract["target"]["enter_ratio"] == 0.8
assert contract["target"]["exit_ratio"] == 0.9
assert contract["assist"]["max_relative_rate_gain"] == 1.1
assert contract["assist"]["weight_step_per_bbr_round"] == 0.05
assert contract["assist"]["max_duration_ms"] == 300
assert contract["assist"]["max_rounds"] == 3
assert contract["assist"]["no_benefit_round"] == 2
assert contract["assist"]["max_unrevocable_queue_bytes"] == 2400
assert contract["assist"]["deadline_grace_for_new_assist_ms"] == 0
assert contract["telemetry"]["maximum_serialized_bytes_per_minute"] == 1_048_576
assert contract["telemetry"]["cpu_p95_overhead_ratio"] == 0.02
assert contract["telemetry"]["memory_bytes_per_connection"] == 262_144
assert contract["capabilities"]["bbr_is_in_recovery"] == "not_used"

required_patches = [
    "0010-babr-lite-controller-core.patch",
    "0013-babr-lite-pacer-output-bridge.patch",
    "0014-babr-lite-controller-host-state.patch",
    "0015-babr-lite-real-input-mapping.patch",
    "0016-babr-lite-pacing-release-scheduling.patch",
    "0017-babr-lite-deadline-budget-admission.patch",
    "0018-babr-lite-unrevocable-queue-core.patch",
    "0020-babr-lite-socket-batch-resolve.patch",
    "0021-babr-lite-online-envelope.patch",
    "0022-babr-lite-online-maxrate-pacer-cap.patch",
    "0023-babr-lite-online-policy-refresh.patch",
    "0024-babr-lite-online-policy-refresh-closure.patch",
    "0025-babr-lite-experiment-entry.patch",
    "0026-babr-lite-telemetry-core.patch",
    "0027-babr-lite-telemetry-host-wiring.patch",
    "0028-babr-lite-telemetry-lazy-closure.patch",
    "0029-babr-lite-telemetry-file-sink.patch",
    "0030-babr-lite-evidence-fields.patch",
]
for name in required_patches:
    assert (root / "patches/p2" / name).is_file(), name

lite = (root / "third_party/quiche-0.29.3/quiche/src/recovery/gcongestion/babr_lite.rs").read_text()
recovery = (root / "third_party/quiche-0.29.3/quiche/src/recovery/gcongestion/recovery.rs").read_text()
telemetry = (root / "third_party/quiche-0.29.3/quiche/src/recovery/gcongestion/babr_lite_telemetry.rs").read_text()
driver = (root / "third_party/quiche-0.29.3/tokio-quiche/src/http3/driver/mod.rs").read_text()

for needle in [
    "const TARGET_MIN_BYTES_PER_SECOND: u64 = 1_000_000;",
    "const TARGET_MAX_BYTES_PER_SECOND: u64 = 125_000_000;",
    "const MAX_RELATIVE_RATE_GAIN_NUMERATOR: u64 = 11;",
    "const MAX_RELATIVE_RATE_GAIN_DENOMINATOR: u64 = 10;",
    "const WEIGHT_DENOMINATOR: u8 = 20;",
    "const MAX_ASSIST_ROUNDS: u8 = 3;",
    "const NO_BENEFIT_ROUND: u8 = 2;",
]:
    assert needle in lite, needle

for needle in [
    "const RING_ENTRIES: usize = 128;",
    "const MAX_BYTES_PER_MINUTE: usize = 1_048_576;",
    "const MEMORY_BUDGET_BYTES: usize = 32_768;",
    "p2-lite-v2",
    "configuration_version",
    "dropped_records",
    "connection_tag",
    "inflight_bytes",
    "sample_valid",
    "assist_deadline_monotonic_us",
]:
    assert needle in telemetry, needle

assert "Option<Box<BabrLiteTelemetry>>" in recovery
assert "babr_is_in_recovery" not in lite
assert "babr_is_in_recovery" not in recovery
assert "limit_cwnd(" not in lite

for needle in [
    'BABR_P2_MODE',
    'BABR_P2_TARGET_BPS',
    'BABR_P2_MAX_RATE_BPS',
    'BABR_P2_LITE_TELEMETRY_FILE',
]:
    assert needle in driver, needle

assert "babr_lite_drain" in driver
assert "babr_take_lite_telemetry_json_lines" in driver
print("P2 Lite frozen host invariants: OK")
PY

host_sha="$(git -C "$HOST" rev-parse HEAD)"
test "$host_sha" = "55886df3be579579207104c8e645825b6347a209"

git -C "$HOST" diff --check

echo "[P2 Lite Host] PASS"
