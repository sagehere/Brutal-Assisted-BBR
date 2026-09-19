# BABR（Brutal-Assisted BBR）规格审核报告

## 1. 总体结论

BABR 规格整体设计思路清晰，核心原则正确：**以 BBR 风格网络模型为底座，以用户 Target Rate 为优化方向，以受控 Brutal 式补偿为辅助执行器，并由拥塞保护机制决定何时停止追逐目标**。它不是简单拼接 Brutal 与 BBR，而是试图在“目标吞吐”与“网络安全”之间建立闭环控制。

审核结论：

- **设计价值：中高。** 在受控网络、代理/QUIC、跨境高 RTT、随机丢包、用户目标敏感场景中有明显潜力。
- **原型可行性：高。** 公式、状态机、变量定义基本完整，适合做仿真和用户态原型。
- **生产级可行性：中低。** 公平性、参数敏感性、测量噪声、BBR 状态耦合、内核实现复杂度仍是主要障碍。
- **建议定位：实验性/可配置特性。** 默认保守，优先在用户态 QUIC 或代理中实现，不宜直接默认替换公共互联网 TCP CC。

---

## 2. 实施价值

### 2.1 主要价值

1. **比纯 BBR 更贴近用户目标**
   
   - 纯 BBR 回答“网络能跑多快”，但不知道用户希望至少达到多少。
   - BABR 在目标未达成且网络仍有容量迹象时，主动补偿 pacing，可提高 Target Achievement Ratio。

2. **比纯 Brutal 更安全**
   
   - 纯 Brutal 在 Target 高于实际容量时会持续制造队列、RTT 膨胀和丢包。
   - BABR 通过 RTT Inflation、Marginal Efficiency、Hard Congestion、Recovery、Cooldown 限制副作用。

3. **随机丢包场景有优势**
   
   - 规格中 `P_target = T / max(A, A_min)` 和 `G_max` 限制，可在非拥塞丢包下补偿有效吞吐。
   - 相比传统 loss-based CC，BABR 不会因随机丢包过度降速。

4. **适合目标敏感业务**
   
   - 代理加速、跨境传输、QUIC 应用、CDN 回源、游戏更新、大文件分发等，用户或业务方通常有明确目标速率偏好。

5. **可解释、可测试、可回退**
   
   - 状态机、公式、不变量、测试指标较完整，便于仿真和 A/B 验证。
   - 异常时回退 Baseline，符合安全设计原则。

### 2.2 价值边界

- Target 不是带宽保证，不能承诺物理不可达速率。
- 公共互联网多流竞争下，BABR 可能比 BBR 更激进，公平性风险高。
- 如果 Target 设置不合理，BABR 仍可能周期性进入 Assist，造成额外拥塞。
- 收益高度依赖参数调优和实际路径特征。

---

## 3. 实施可行性

### 3.1 算法可行性：高

规格已定义核心变量、公式、状态机、进入/退出条件、拥塞保护、恢复与冷却。算法逻辑可落地：

- `P_final = P_bbr + W × max(0, P_target - P_bbr)`
- `P_target = min(T / max(A, A_min), T × G_max)`
- `W` 连续权重与滞回阈值避免二元抖动
- Hard Congestion 触发 RECOVERY
- App-Limited、Startup、RTT Probe 保护

这些都能在现有 BBR 框架上扩展。

### 3.2 工程可行性

| 实现层          | 可行性 | 说明                                   |
| ------------ | --- | ------------------------------------ |
| 用户态 QUIC     | 高   | 可完整控制 pacing、cwnd、ACK 采样、状态机，最适合原型。  |
| 代理/隧道        | 高   | 已有 Brutal 类实现，可替换为 BABR 控制器。         |
| Linux TCP 内核 | 中   | 需修改 BBR 或使用 TCP struct_ops，调试和部署成本高。 |
| eBPF         | 中低  | 可观测性强，但完整替换 CC 控制仍受限。                |
| 硬件/网卡卸载      | 低   | 依赖具体平台，短期不现实。                        |

### 3.3 部署可行性

- **受控两端：高。** 如自有代理、CDN、专线、QUIC 服务端，可安全实验。
- **公共互联网：中低。** 多流竞争、Bufferbloat、随机丢包、ACK 压缩、延迟 ACK 会显著影响效果。
- **默认开启：不建议。** 应作为可配置 profile，默认 Conservative 或 BABR-Lite。

### 3.4 主要技术难点

1. **Delivery Rate 与 ACK Ratio 测量**
   
   - 需字节加权，避免 ACK 压缩、GRO/GSO、延迟 ACK 干扰。
   - 丢失检测有延迟，窗口选择影响稳定性。

2. **Marginal Efficiency `η = ΔDelivery / ΔPacing`**
   
   - 噪声大，`ΔPacing` 接近 0 时会爆炸。
   - 必须平滑、钳制、设置最小 ΔPacing 阈值。

3. **与 BBR 状态机耦合**
   
   - BBR 的 STARTUP、DRAIN、PROBE_RTT、ProbeBW UP/DOWN 与 Assist 叠加可能造成 Overshoot。
   - 规格已禁 Startup 和 RTT Probe，但 DRAIN 和 ProbeBW DOWN 也建议限制。

4. **CWND 与 Pacing 协调**
   
   - 只提 pacing 不够，`CWND_final` 公式需处理 W=0 边界。
   - `CwndGain = 2.0` 较激进，Soft Congestion 时应降低。

5. **公平性**
   
   - BABR 多流同时追逐 Target 时，总目标可能远超瓶颈容量。
   - 规格虽强调优先级，但缺少具体竞争检测和退让机制。

6. **Target 不可达循环**
   
   - Cooldown 后回到 BASELINE，若 D 仍低于 EnterRatio，会再次进入 Assist。
   - 需要 EffectiveTarget 或 TargetInfeasible 机制，MVP 就应加入简单版本。

---

## 4. 补充建议

### 4.1 设计层面

1. **明确 Target 粒度**
   
   - 是 per-flow、per-connection 还是 per-host？
   - 多流场景下，每流 Target=200M 可能聚合为 2G，造成过度竞争。
   - 建议增加“聚合目标”或“共享目标”模式。

2. **优先实现 BABR-Lite**
   
   - 公共互联网默认使用 `P_target = T`，不做 `T / ACKRate` 补偿。
   - Standard/Aggressive 仅用于受控环境。

3. **增加 EffectiveTarget**
   
   - 连续失败后临时降低目标：
     
     ```text
     EffectiveTarget = min(UserTarget, LearnedSustainableCapacity)
     ```
   - 避免反复追逐物理不可达 Target。

4. **ECN 尽早接入**
   
   - ECN CE 比丢包更早反映拥塞。
   - 建议 Congestion Guard 优先使用 ECN，再使用 RTT/η。

### 4.2 公式与参数修正

1. **ACK Ratio 字节加权**
   
   ```text
   A = AckedBytes / (AckedBytes + LostBytes)
   ```
   
   并明确重传包是否计入。

2. **Marginal Efficiency 鲁棒化**
   
   ```text
   if ΔPacing < MinPacingDelta:
       η = 1
   else:
       η = clamp(ΔDelivery / ΔPacing, 0, 1)
   ```
   
   再做 EWMA 平滑。

3. **采样窗口自适应**
   
   - Fast Window 建议：
     
     ```text
     clamp(max(4 × MinRTT, 100ms), 100ms, 1s)
     ```
   - 原 500ms 下限在低 RTT 下反应偏慢。

4. **CWND 边界**
   
   - W=0 时直接 `CWND_final = CWND_bbr`，不要用 AssistBDP 重算。
   - Soft Congestion 时降低 `CwndGain` 或 W。

5. **参数建议更保守**
   
   - 默认 Profile 建议：
     
     ```text
     EnterRatio = 0.75
     ExitRatio = 0.85
     MinAckRate = 0.85
     MaxAssistGain = 1.15
     CwndGain = 1.5
     ```
   - 实际值需仿真和测试床确定。

### 4.3 状态机与保护

1. **DRAIN 和 ProbeBW DOWN 禁 Assist 或降 W**
   
   - 避免与 BBR 降速阶段冲突。

2. **Soft Congestion 应降低 W**
   
   - 规格只写“停止增加 W”，建议进一步：
     
     ```text
     W = W × 0.5
     ```
     
     或进入轻量 Cooldown。

3. **失败计数衰减**
   
   - `FailureCount` 应随时间衰减，避免永久惩罚。

4. **路径变化重置**
   
   - 已定义，但需明确 MinRTT 变化阈值。

### 4.4 公平性机制

建议增加：

- **竞争检测**：若 SRTT 上升、η 低、Delivery 不增，即使未 Hard Congestion，也降低 W。
- **多流退让**：检测到多个 BABR 流或 RTT 竞争时，降低 `G_max`。
- **公平模式**：默认 `MaxAssistGain = 1.0`，仅 Target Assist，不 ACK 补偿。
- **Jain 公平指数**纳入测试指标。

### 4.5 遥测与测试

建议记录：

```text
state, W, P_bbr, P_target, P_final
D, T, A, η, Q_ratio, Q_delay
CWND_bbr, CWND_final
FailureCount, CooldownRemaining
```

测试建议：

1. 仿真：ns-3 / Mininet。
2. 用户态原型：QUIC 或代理。
3. 对比：BBR、Brutal、Copa、PCC、BBRv2/v3。
4. 场景：规格第 81 节表格已较好，需补充多流竞争和 ECN。
5. 指标：TAR、TE、AGE、RTTCost、P95 RTT、Jain Fairness。

### 4.6 实施路线

1. **阶段 1：仿真验证**
   
   - 验证公式、参数、状态机稳定性。

2. **阶段 2：用户态 QUIC/代理 MVP**
   
   - 实现 Target、Delivery、ACK 补偿、RTT Guard、Recovery、Cooldown、Telemetry。

3. **阶段 3：小规模测试床**
   
   - 随机丢包、高 RTT、Bufferbloat、动态容量、多流竞争。

4. **阶段 4：灰度**
   
   - 默认关闭，按用户/业务开启。

5. **阶段 5：生产评估**
   
   - 若公平性和 RTT 成本可接受，再考虑默认 Conservative。

---

## 5. 最终建议

**BABR 规格值得进入 MVP 实现，但应定位为实验性、可配置、默认保守的拥塞控制增强方案。**

- **实施价值：高**，尤其在受控网络、目标敏感业务、随机丢包和高 RTT 场景。
- **实施可行性：原型高，生产中等。** 优先用户态 QUIC/代理，内核 TCP 次之。
- **最大风险：公平性、Target 不可达循环、η 噪声、与 BBR 状态耦合。**
- **关键补充：EffectiveTarget、BABR-Lite、ECN、Soft 降 W、多流聚合目标、字节加权 ACK Ratio、η 钳制、遥测与公平性测试。**

建议批准为 **Draft → Experimental MVP**，但不要直接默认部署到公共互联网。先证明三件事：

1. 随机丢包下比 BBR 更快达到 Target；
2. Target 不可达时能及时停止 Assist；
3. 多流竞争下不显著破坏公平性和 RTT 稳定性。

只有这三点同时成立，BABR 才具备从实验规格走向生产可用的价值。
