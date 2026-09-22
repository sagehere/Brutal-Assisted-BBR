#!/usr/bin/env python3
"""Static consistency checks for P1 Final Closure."""
import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent
SPEC = (ROOT / "P1-修订规格与冻结基线.md").read_text(encoding="utf-8")
BRIDGE = (ROOT / "P1-恢复与IO事件桥接设计.md").read_text(encoding="utf-8")
PROV = (ROOT / "P1-冻结参数来源表.md").read_text(encoding="utf-8")
MATRIX = (ROOT / "P1-Final-验收矩阵.md").read_text(encoding="utf-8")
CFG = json.loads((ROOT / "P1-冻结参数与用例.json").read_text(encoding="utf-8"))


def ok(name, cond):
    assert cond, name
    print(f"PASS {name}")


def main():
    ok("S01 v4 schema", CFG["schema_version"] == "p1-baseline-v4")
    ok("S02 spec declares v4", "p1-baseline-v4" in SPEC)
    ok("S03 bridge declares v4", "p1-baseline-v4" in BRIDGE)
    ok("S04 no stale socket-no-budget rule", "不扣辅助预算" not in SPEC)
    ok("S05 pre-debit no-refund rule present", "立即预扣且永不退款" in SPEC)
    ok("S06 admission granularity single datagram",
       CFG["assist"]["admission_granularity"] == "single_quic_datagram"
       and "单个 QUIC datagram" in SPEC
       and "单个 QUIC datagram" in BRIDGE)
    ok("S07 deadline zero grace",
       CFG["assist"]["deadline_grace_for_new_assist_ms"] == 0
       and "grace 固定为 0ms" in SPEC)
    ok("S08 timer lateness cannot extend assist",
       "不能延长 Assist 许可" in SPEC
       and "telemetry_only" in CFG["assist"]["timer_lateness_policy"])
    ok("S09 is_in_recovery not used",
       CFG["capabilities"]["bbr_is_in_recovery"] == "not_used"
       and "BABR 不使用" in SPEC)
    ok("S10 persistent congestion unsupported",
       CFG["capabilities"]["persistent_congestion_signal"].startswith("unsupported")
       and "persistent-congestion" in SPEC)
    ok("S11 ECN CE unsupported",
       CFG["capabilities"]["ecn_ce_signal"].startswith("unsupported")
       and "ECN-CE" in SPEC)
    ok("S12 current reason registry excludes unsupported host events",
       "EcnCe" not in CFG["reason_codes"]
       and "PersistentCongestion" not in CFG["reason_codes"])
    ok("S13 required Loss/PTO reasons",
       {"LOSS_DETECTED", "PTO_FIRED"} <= set(CFG["reason_codes"]))
    ok("S14 all reason codes have policy fields",
       all(
           {"next_state", "clear_w", "increment_failure", "enter_backoff", "invalidate_sample"}
           <= set(v)
           for v in CFG["reason_codes"].values()
       ))
    ok("S15 C01-C15 declared",
       CFG["acceptance"]["synthetic_cases"] == [f"C{i:02d}" for i in range(1, 16)]
       and all(f"| C{i:02d} |" in MATRIX for i in range(1, 16)))
    ok("S16 provenance categories present",
       all(x in PROV for x in ("HOST", "SAFETY", "EXPERIMENTAL", "MEASUREMENT", "ACCEPTANCE")))
    ok("S17 provenance covers key frozen parameters",
       all(x in PROV for x in (
           "相对基线上限", "W 单轮增量", "Assist 最长时间", "Admission 粒度",
           "Deadline grace", "不可撤销队列容差", "无收益阈值", "Backoff 初值"
       )))
    ok("S18 normative hierarchy stated",
       "规范层级" in SPEC
       and CFG["normative_authority"]["behavior_spec"] == "P1-修订规格与冻结基线.md")
    ok("S19 no v2 declaration in normative headers",
       not re.search(r"版本：`p1-baseline-v2`", SPEC)
       and not re.search(r"版本：`p1-baseline-v2`", BRIDGE))
    ok("S20 machine contract and prose budget semantics agree",
       "no refund" in CFG["assist"]["budget_accounting"]
       and "socket 失败不退款" in SPEC
       and "不退款" in BRIDGE)
    ok("S21 target hysteresis semantics are explicit",
       CFG["target"]["enter_ratio"] == 0.8
       and CFG["target"]["exit_ratio"] == 0.9
       and CFG["target"]["hysteresis_band_behavior"] == "preserve_current_state"
       and "BASELINE 保持 BASELINE" in SPEC
       and "ASSIST 保持 ASSIST" in SPEC)

    print("P1 spec consistency PASS")


if __name__ == "__main__":
    main()
