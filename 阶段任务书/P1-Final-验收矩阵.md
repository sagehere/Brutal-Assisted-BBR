# P1 Final 验收矩阵

版本：`p1-baseline-v3`；日期：2026-09-19。

本矩阵把 01 任务书 §4 的“输入、事件序列、预期状态、输出及预算变化”转为可复核格式。C01-C09 继承原合成检查；C10-C15 是 Final Closure 新增检查。

| Case | 初始/输入 | 事件序列 | 预期状态/输出 | 预算与失败语义 |
| --- | --- | --- | --- | --- |
| C01 | B_ref=18.75 MB/s, T=25 MB/s, MinRTT=50ms | 进入 Assist；连续 2 round delivery <1.02B_ref | ASSIST_BACKOFF, W=0, reason=NO_BENEFIT, CWND=baseline | budget 不重置；failure+1；30s backoff |
| C02 | B_ref=20 MB/s, T=125 MB/s | 首个有效 round | pacing <=20.1 MB/s，不允许旧公式大跳变 | budget 冻结自 B_ref；failure 不变 |
| C03 | W=1，随后 Target=0；baseline CWND=4000 | 在线关闭 | BASELINE；pacing=baseline；CWND=4000；reason=TARGET_DISABLED | 不新增 Assist debit；已有 backoff 不清除 |
| C04 | 有效连接 | 分别进入 Startup/Drain/ProbeRTT/ProbeBW.Down；触发 LossDetected/PtoFired | phase -> BASELINE；Loss/PTO -> ASSIST_BACKOFF | Loss/PTO failure+1；样本失效 |
| C05 | Assist 已运行 | now>=deadline；或预算不足；或队列达到 2400B 容差 | 立即停止新 Assist；baseline 仍可发送 | timeout/budget failure+1；不得恢复过期额度 |
| C06 | 已有 backoff_until | Target off/on、path change、mode off/observe | backoff 截止保持不变 | 不因配置切换清零失败历史 |
| C07 | 样本过期/基线0/eta分母过小 | 控制决策 | BASELINE；SAMPLE_INVALID；不加码 | failure 不增加；无效 eta !=1 |
| C08 | Assist 期间获得有效 delivery 上升 | 正常 ACK/model update | BBR 基线继续学习；Lite CWND 不变 | Assist 结束后 baseline 可超过 Target |
| C09 | 固定 quiche 0.29.3 | capability 审计 | is_in_recovery=not_used；PC/ECN=unsupported | 不允许伪造未来 guard |
| C10 | remaining budget=3000B | 生成 1200B Assist datagram；socket WouldBlock | actual_socket_sent +=0 | assist_budget_debit +=1200；remaining=1800；不退款 |
| C11 | 固定宿主 | LossDetected 与 PtoFired 分别触发；输入伪 ECN/PC capability | Loss/PTO 有效；当前宿主不得报告 ECN/PC control event | Loss/PTO failure+1；future capability 不能参与当前决策 |
| C12 | deadline=300ms | now=299,300,301ms 分别尝试 admission | 299ms 可继续检查；300/301ms 禁止新 Assist | deadline grace=0；timer lateness 只遥测 |
| C13 | 任意 decide 输出 | 收集所有 reason | 每个 reason 必须存在 reason_codes registry | registry 决定 clear_w/failure/backoff/sample |
| C14 | 读取 machine contract | 检查必需参数与 provenance | 所有冻结参数都有确定值/公式和类别来源 | 缺字段即 Final Gate FAIL |
| C15 | 扫描 normative spec/bridge/JSON | 检查 budget、guard、capability、version 关键词 | 不得存在“socket失败不扣预算”等过时冲突；v3 一致 | 发现冲突即 Final Gate FAIL |

## Final G1 Exit

Final Closure 只有在以下全部成立时通过：

1. C01-C15 全部 PASS。
2. `check_p1_spec_consistency.py` PASS。
3. 固定 quiche SHA 精确匹配并带 `gcongestion` 的库测试通过。
4. 最终 evidence artifact 包含规则日志、一致性日志、quiche 测试、工具链和 SHA-256。
5. 验收记录引用实际 Final Closure run；P2 仍必须先 Observe，再决定是否放行 Lite 实际辅助发送。
