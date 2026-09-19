#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${ROOT}/阶段任务书/p1-artifacts"
mkdir -p "${LOG_DIR}"

{
  echo "== system =="
  uname -a
  echo
  echo "== toolchain =="
  rustc --version
  cargo --version
  cmake --version | head -n 1
  clang --version | head -n 1
  pkg-config --version
  python3 --version
  git --version
} | tee "${LOG_DIR}/toolchain.txt"

EXPECTED_QUICHE_SHA="55886df3be579579207104c8e645825b6347a209"
ACTUAL_QUICHE_SHA="$(git -C "${ROOT}/third_party/quiche-0.29.3" rev-parse HEAD)"
printf '%s\n' "${ACTUAL_QUICHE_SHA}" | tee "${LOG_DIR}/quiche-head.txt"
if [[ "${ACTUAL_QUICHE_SHA}" != "${EXPECTED_QUICHE_SHA}" ]]; then
  echo "quiche SHA mismatch: expected ${EXPECTED_QUICHE_SHA}, got ${ACTUAL_QUICHE_SHA}" >&2
  exit 2
fi

python3 "${ROOT}/阶段任务书/check_p1_rules.py" 2>&1 | tee "${LOG_DIR}/check-p1-rules.log"

cargo test   --manifest-path "${ROOT}/third_party/quiche-0.29.3/Cargo.toml"   -p quiche   --lib   --features gcongestion   2>&1 | tee "${LOG_DIR}/quiche-test.log"

(
  cd "${ROOT}"
  sha256sum     "阶段任务书/check_p1_rules.py"     "阶段任务书/P1-冻结参数与用例.json"     "阶段任务书/P1-修订规格与冻结基线.md"     "阶段任务书/P1-恢复与IO事件桥接设计.md"     "third_party/quiche-0.29.3/quiche/src/recovery/gcongestion/bbr2.rs"     "third_party/quiche-0.29.3/quiche/src/recovery/gcongestion/recovery.rs"     "third_party/quiche-0.29.3/tokio-quiche/src/quic/io/worker.rs"
) | tee "${LOG_DIR}/sha256.txt"

echo "P1 verification PASS" | tee "${LOG_DIR}/result.txt"
