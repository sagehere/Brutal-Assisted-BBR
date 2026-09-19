# Brutal-Assisted BBR（BABR）拥塞控制算法设计规格

> **文档状态**：Draft / Experimental  
> **版本**：0.2  
> **算法名称**：Brutal-Assisted BBR  
> **缩写**：BABR  
> **类型**：Target-Assisted Model-Based Congestion Control  
> **目标**：在保留 BBR 自适应带宽探测能力的基础上，引入受控的 Brutal 式目标速率补偿机制，提高目标吞吐达成能力，同时避免固定速率算法在目标不可达时持续制造拥塞。

---

# 1. 摘要

Brutal-Assisted BBR，简称 **BABR**，是一种混合型拥塞控制算法。

BABR 以 **BBR 风格的网络模型**作为底层网络状态估计器，通过持续测量：

- Delivery Rate

- Bottleneck Bandwidth

- Minimum RTT

- Smoothed RTT

- Bytes In Flight

- Loss Rate

- Queue Growth

判断网络当前可用能力。

在此基础上，引入一个用户指定的：

```text
Target Rate
```

当实际有效吞吐明显低于 Target，且网络仍显示存在可利用容量时，BABR 使用类似 Brutal 的主动发送和丢包补偿机制，提高 pacing rate，使连接尽量向 Target 靠近。

当吞吐接近 Target 后，BABR 逐步撤销 Brutal Assist，重新由 BBR 主导主动探测更高可用带宽。

如果发现：

- RTT 持续膨胀；

- 队列明显增长；

- 增大发送速率不能换来有效吞吐增长；

- 网络容量低于目标；

则立即停止 Brutal Assist，并回退到 BBR 模型控制。

核心原则：

> **BBR 负责判断网络能提供多少，Target 代表用户希望获得多少，Brutal Assist 只负责尝试弥补两者之间尚未被利用的部分。**

Target 是性能偏好，不是带宽保证。

---

# 2. 问题定义

传统固定目标速率算法具有一个明显优势：

> 用户可以明确告诉算法，希望获得多少吞吐。

例如：

```text
Target = 200 Mbps
```

算法可以尝试以接近 200 Mbps 的有效交付速率运行。

但它也存在根本性问题：

> 用户并不知道当前网络真正能承载多少。

例如：

```text
Target = 200 Mbps
Actual Capacity = 150 Mbps
```

如果算法仍然持续尝试：

```text
200
220
240
250 Mbps
```

则可能只得到：

```text
150 Mbps Goodput
```

但同时产生：

```text
Queue ↑
RTT ↑
Loss ↑
Retransmission ↑
Efficiency ↓
```

另一方面，纯模型型拥塞控制虽然可以自动探测链路容量，但并不知道：

> 用户希望优先达到怎样的性能目标。

BABR 的目标就是将这两种思想结合。

---

# 3. 核心设计哲学

BABR 不采用：

```text
低于目标 → Brutal
达到目标 → BBR
```

这样的二元切换。

而采用：

```text
                BABR
                  │
       ┌──────────┴──────────┐
       │                     │
 Network Model          Target Model
       │                     │
       └──────────┬──────────┘
                  │
             Assist Logic
                  │
           Congestion Guard
                  │
                  ▼
       Final Pacing / CWND
```

其中：

## Network Model

回答：

> 网络现在允许发多快？

## Target Model

回答：

> 用户希望至少达到多快？

## Assist Logic

回答：

> 当前没有达到目标，但网络是否还有余量可以继续尝试？

---

# 4. 设计目标

BABR SHOULD 满足以下目标。

## 4.1 Target-aware

允许用户设置：

```text
TargetRate = T
```

例如：

```text
T = 200 Mbps
```

该值表示：

> 当网络条件允许时，算法应尽量避免长期低于这一目标。

---

# 5. Target 不是最大速率

如果：

```text
Target = 200 Mbps
Capacity = 500 Mbps
```

BABR 应允许：

```text
200
250
300
400
500 Mbps
```

因此：

```text
Target != Rate Limit
```

Target 是：

```text
Preferred Minimum Performance
```

而不是：

```text
Maximum Rate
```

---

# 6. Target 不是强制保证

如果：

```text
Target = 200 Mbps
Capacity = 150 Mbps
```

BABR 必须最终接受：

```text
≈150 Mbps
```

而不能无限尝试维持：

```text
200 Mbps
```

因此：

> Target 是优化目标，不是物理承诺。

---

# 7. 网络模型

BABR 始终维护一个 BBR 风格的网络模型。

核心变量包括：

```text
BtlBw
MinRTT
SRTT
DeliveryRate
BytesInFlight
PacingRate
CWND
LossRate
```

BABR 即使进入 Assist 状态，也不能停止这些测量。

---

# 8. 为什么网络模型必须永久在线

如果采用：

```text
BBR
↓
切换 Brutal
↓
再切回 BBR
```

则容易失去：

```text
Bandwidth Estimate
MinRTT history
Delivery samples
BDP estimate
Probe state
Recovery state
```

因此 BABR 的原则是：

> Assist 改变实际控制输出，但不停止网络模型学习。

---

# 9. 核心变量

定义：

```text
T = User Target Rate
```

```text
D = Delivery Rate
```

```text
P_bbr = Model-derived Pacing Rate
```

```text
P_final = Final Pacing Rate
```

```text
A = ACK Success Ratio
```

```text
R_min = Minimum RTT
```

```text
R = Smoothed RTT
```

```text
W = Assist Weight
```

其中：

```text
0 <= W <= 1
```

---

# 10. Delivery Rate

BABR 判断速率时必须使用：

```text
ACKed Delivered Bytes / Time
```

即：

```text
Goodput
```

而不能简单使用：

```text
Sender Rate
Socket Write Rate
Application Write Rate
```

原因：

```text
发送 250 Mbps
```

不等于：

```text
接收 250 Mbps
```

---

# 11. ACK Ratio

定义：

```text
A =
AckedPackets /
(AckedPackets + LostPackets)
```

例如：

```text
ACK = 950
Loss = 50
```

则：

```text
A = 0.95
```

---

# 12. Brutal 式补偿

定义最小 ACK Ratio：

```text
A_min
```

默认建议：

```text
A_min = 0.80
```

则目标辅助 pacing：

```text
P_target =
T / max(A, A_min)
```

例如：

```text
T = 200 Mbps
A = 0.95
```

得到：

```text
P_target
≈ 210.5 Mbps
```

---

# 13. 最大 Assist Gain

定义：

```text
G_max
```

默认：

```text
G_max = 1.25
```

限制：

```text
P_target <= T × G_max
```

例如：

```text
T = 200 Mbps
```

则最大：

```text
P_target = 250 Mbps
```

---

# 14. 为什么需要最大增益限制

没有上限时：

```text
ACK Rate ↓
```

可能导致：

```text
Target / ACKRate
```

无限增长。

BABR 必须保证：

> 即使网络状态恶化，Assist 也只能有限增加 pacing。

---

# 15. Target Deficit

定义：

```text
Deficit =
max(0, T - D) / T
```

例如：

```text
T = 200
D = 150
```

则：

```text
Deficit = 0.25
```

即：

```text
距离目标还有 25%
```

---

# 16. Assist 不应该是开关

BABR 不采用：

```text
Assist OFF
Assist ON
```

而定义连续权重：

```text
0 <= W <= 1
```

最终 pacing：

```text
P_final =
P_bbr +
W × max(0, P_target - P_bbr)
```

---

# 17. 示例

假设：

```text
P_bbr = 160 Mbps
P_target = 210 Mbps
```

那么：

```text
W = 0
P_final = 160
```

```text
W = 0.25
P_final = 172.5
```

```text
W = 0.50
P_final = 185
```

```text
W = 0.75
P_final = 197.5
```

```text
W = 1.0
P_final = 210
```

这样避免：

```text
160 → 210 Mbps
```

的瞬时跳变。

---

# 18. BBR 优先原则

如果：

```text
P_bbr >= P_target
```

则：

```text
P_final = P_bbr
```

也就是说：

> Assist 只能提高不足的 pacing，不能降低 BBR 已经发现的更高带宽。

例如：

```text
Target = 200 Mbps
P_bbr = 350 Mbps
```

最终仍然：

```text
350 Mbps
```

---

# 19. 状态机

BABR 定义四个顶层控制状态：

```text
BASELINE
ASSIST
RECOVERY
COOLDOWN
```

关系：

```text
                BASELINE
                    │
          Delivery长期不足
                    │
                    ▼
                 ASSIST
              /         \
     Target接近          Congestion
          │                  │
          ▼                  ▼
      BASELINE           RECOVERY
                             │
                        Queue消退
                             │
                             ▼
                         COOLDOWN
                             │
                        冷却结束
                             │
                             ▼
                         BASELINE
```

---

# 20. BASELINE

正常工作状态。

此时：

```text
W = 0
```

```text
P_final = P_bbr
```

算法完全按照网络模型进行带宽探测。

---

# 21. Assist 进入阈值

定义：

```text
EnterRatio = 0.80
```

当：

```text
D < T × 0.80
```

时，认为吞吐明显低于目标。

例如：

```text
T = 200 Mbps
```

则：

```text
Enter Threshold = 160 Mbps
```

---

# 22. Assist 退出阈值

定义：

```text
ExitRatio = 0.90
```

当：

```text
D >= T × 0.90
```

则认为已经接近目标。

例如：

```text
T = 200 Mbps
```

则：

```text
Exit Threshold = 180 Mbps
```

---

# 23. Hysteresis

因此：

```text
<160 Mbps
→ Eligible for ASSIST
```

```text
160~180 Mbps
→ 保持当前状态
```

```text
>=180 Mbps
→ Exit ASSIST
```

可以避免：

```text
179 → Assist
181 → Baseline
178 → Assist
182 → Baseline
```

不断抖动。

---

# 24. Assist 进入条件

进入 Assist 不能只看：

```text
D < 0.8T
```

还必须满足：

```text
非 Application Limited
```

```text
网络模型已经有可靠样本
```

```text
没有处于 RTT 重新测量状态
```

```text
没有明显 Queue Growth
```

```text
没有明显 Hard Congestion
```

```text
低速持续多个 RTT
```

---

# 25. 连续低速判定

推荐：

```text
EnterRTTs = 3
```

即：

```text
D < 0.8T
```

至少持续：

```text
3 RTT
```

后才进入 Assist。

防止因为瞬时波动误触发。

---

# 26. Application-Limited 保护

如果：

```text
Target = 200 Mbps
```

但应用只提供：

```text
50 Mbps
```

那么：

```text
D = 50 Mbps
```

并不代表网络有问题。

所以：

```text
AppLimited == true
```

时：

```text
Assist MUST NOT activate
```

---

# 27. Startup 保护

模型启动阶段本身通常具有较强的带宽探测行为。

因此：

```text
Startup Phase
```

默认：

```text
W = 0
```

避免：

```text
Startup Gain
+
Assist Gain
```

叠加造成严重 Overshoot。

---

# 28. RTT Probe 保护

当网络模型主动降低 inflight 以重新测量传播 RTT 时：

```text
W = 0
```

Assist 必须暂停。

否则可能导致：

```text
MinRTT Measurement
```

失真。

---

# 29. Assist Ramp

进入 Assist 后，不应直接：

```text
W = 1
```

推荐：

```text
AssistRampRTTs = 4
```

例如：

```text
RTT 1 → W = 0.25
RTT 2 → W = 0.50
RTT 3 → W = 0.75
RTT 4 → W = 1.00
```

---

# 30. 动态 Assist Weight

更高级的实现可以直接根据 Delivery Ratio 计算。

定义：

```text
X = D / T
```

则：

```text
W_target =
clamp(
    (ExitRatio - X)
    /
    (ExitRatio - EnterRatio),
    0,
    1
)
```

例如：

```text
X = 0.90
W = 0
```

```text
X = 0.85
W = 0.5
```

```text
X = 0.80
W = 1
```

---

# 31. 平滑 Assist Weight

避免 W 瞬间变化。

使用：

```text
W_new =
α × W_target
+
(1-α) × W_old
```

建议：

```text
α = 0.25
```

---

# 32. RTT Inflation

定义：

```text
Q_ratio =
SRTT / MinRTT
```

以及：

```text
Q_delay =
SRTT - MinRTT
```

这是判断队列增长的重要信号。

---

# 33. 为什么不能只看 Ratio

例如：

```text
MinRTT = 4 ms
SRTT = 5 ms
```

虽然：

```text
Q_ratio = 1.25
```

但只增加：

```text
1 ms
```

所以必须同时使用：

```text
Q_ratio
```

和：

```text
Q_delay
```

---

# 34. Soft Congestion

初始建议：

```text
Q_ratio >= 1.25
```

且：

```text
Q_delay >= 10 ms
```

则：

```text
SoftCongestion = true
```

行为：

```text
停止增加 W
```

但不一定立刻退出 Assist。

---

# 35. Hard Congestion

建议：

```text
Q_ratio >= 1.50
```

且：

```text
Q_delay >= 20 ms
```

持续：

```text
>= 2 RTT
```

则：

```text
HardCongestion = true
```

立即：

```text
ASSIST → RECOVERY
```

---

# 36. Marginal Efficiency

仅靠 RTT 还不够。

BABR 引入：

```text
η =
ΔDelivery /
ΔPacing
```

即：

> 每多发送 1 Mbps，获得多少 Mbps 有效吞吐。

---

# 37. 高效率示例

```text
Pacing:
160 → 180
```

```text
Delivery:
150 → 169
```

则：

```text
η = 19 / 20
  = 0.95
```

说明增加发送非常有效。

---

# 38. 低效率示例

```text
Pacing:
200 → 220
```

但：

```text
Delivery:
187 → 190
```

则：

```text
η = 3 / 20
  = 0.15
```

如果同时：

```text
RTT ↑
```

则说明：

> 链路已经接近真实容量上限。

---

# 39. Efficiency Floor

默认建议：

```text
EfficiencyFloor = 0.25
```

如果：

```text
η < 0.25
```

同时出现：

```text
Queue Growth
```

则停止 Assist。

---

# 40. 为什么不能只看 Loss

随机丢包：

```text
Loss = 5%
RTT稳定
Delivery随Pacing增长
```

此时 Assist 可能有效。

拥塞丢包：

```text
Loss = 5%
RTT快速增长
Delivery几乎不增长
```

此时 Assist 应停止。

因此：

```text
Loss != Congestion
```

---

# 41. Congestion Guard

建议第一版：

```text
HardCongestion =
    (
        Q_ratio >= 1.50
        AND
        Q_delay >= 20ms
    )
    OR
    (
        η < 0.25
        AND
        Q_ratio >= 1.25
        AND
        Q_delay >= 10ms
    )
```

Soft：

```text
SoftCongestion =
    (
        Q_ratio >= 1.25
        AND
        Q_delay >= 10ms
    )
    OR
    (
        η < 0.50
        AND
        LossTrendIncreasing
    )
```

这些都是初始实验值。

---

# 42. ASSIST 状态行为

ASSIST 状态中：

```text
Network Model
```

继续运行。

BABR 额外计算：

```text
P_target
```

和：

```text
W
```

然后：

```text
P_final =
P_bbr +
W × max(0, P_target - P_bbr)
```

---

# 43. 达到退出阈值

如果：

```text
D >= 0.9T
```

持续：

```text
ExitRTTs = 2
```

则：

```text
W
1.0
↓
0.75
↓
0.5
↓
0.25
↓
0
```

退出 Assist。

---

# 44. 为什么达到 90% 就交回 BBR

假设：

```text
Target = 200 Mbps
```

达到：

```text
180 Mbps
```

后已经证明：

> 网络接近用户目标。

此时继续使用主动 Target Enforcement 的必要性下降。

让模型型算法重新主导，可以：

```text
180
200
230
300
...
```

继续寻找更高带宽。

---

# 45. RECOVERY

一旦检测到 Hard Congestion：

```text
W = 0
```

```text
P_final = P_bbr
```

```text
CWND_final = CWND_bbr
```

BABR 不需要重新发明完整恢复算法。

恢复由模型型拥塞控制负责。

---

# 46. Recovery 退出

推荐条件：

```text
Q_ratio <= 1.15
```

以及：

```text
Q_delay <= 10 ms
```

并且：

```text
Delivery 稳定
```

持续：

```text
>= 2 RTT
```

则：

```text
RECOVERY → COOLDOWN
```

---

# 47. COOLDOWN

Cooldown 是必须的。

否则：

```text
Assist
↓
Congestion
↓
Recovery
↓
Assist
↓
Congestion
```

会不断循环。

---

# 48. Cooldown Duration

建议：

```text
Cooldown =
max(
    1 second,
    8 × MinRTT
)
```

---

# 49. Assist Failure

定义：

```text
Assist已经提高Pacing
```

但：

```text
Delivery仍未达到ExitRatio × Target
```

且：

```text
HardCongestion触发
```

则：

```text
AssistFailure++
```

---

# 50. 指数退避

连续失败时：

```text
Cooldown_n =
CooldownBase × 2^FailureCount
```

例如：

```text
第1次：1s
第2次：2s
第3次：4s
第4次：8s
```

最大例如：

```text
30s
```

---

# 51. Target Infeasible

如果连续多次 Assist Failure：

```text
FailureCount >= N
```

例如：

```text
N = 3
```

可以临时标记：

```text
TargetInfeasible = true
```

在一定时间内：

```text
完全依赖网络模型
```

避免不断追逐不可能达到的 Target。

---

# 52. Capacity < Target 示例

```text
Target = 200 Mbps
Capacity = 150 Mbps
```

初始：

```text
Delivery = 145 Mbps
```

进入 Assist：

```text
Pacing 160
→180
→200
→220
```

但：

```text
Delivery
145
148
150
150
```

同时：

```text
RTT
50
55
72
100ms
```

于是：

```text
η → 0
Q_ratio → 2
```

算法判断：

```text
Target不可达
```

执行：

```text
ASSIST → RECOVERY
```

最终：

```text
≈145~150 Mbps
```

稳定运行。

---

# 53. Capacity > Target 示例

```text
Target = 200 Mbps
Capacity = 500 Mbps
```

初始：

```text
Delivery = 120 Mbps
```

过程：

```text
120
↓
Assist
150
↓
170
↓
180
↓
Assist退出
↓
Baseline
↓
220
↓
300
↓
400
↓
500
```

---

# 54. Random Loss 示例

```text
Target = 200 Mbps
Capacity = 500 Mbps
Loss = 5%
```

假设：

```text
D = 150 Mbps
MinRTT = 50ms
SRTT = 53ms
```

Queue 很低。

进入 Assist。

```text
A = 0.95
```

则：

```text
P_target =
200 / 0.95
≈210.5 Mbps
```

如果增加 pacing 后：

```text
Delivery ↑
```

且：

```text
RTT保持稳定
```

则说明 Assist 有效。

---

# 55. CWND 设计

只提高 pacing 不足以保证发送。

BABR 还需要相应调整 congestion window。

定义：

```text
AssistBDP =
P_final × MinRTT
```

然后：

```text
CWND_assist =
AssistBDP × CwndGain
```

---

# 56. Cwnd Gain

建议：

```text
CwndGain = 2.0
```

最终：

```text
CWND_final =
max(
    CWND_bbr,
    AssistBDP ×
    (1 + W × (CwndGain - 1))
)
```

---

# 57. 为什么使用 MinRTT 算 CWND

不要用：

```text
SRTT
```

直接计算 Assist CWND。

否则：

```text
Queue ↑
→ SRTT ↑
→ CWND ↑
→ Queue进一步↑
```

可能形成正反馈。

因此：

```text
MinRTT
```

更适合代表传播路径 BDP。

---

# 58. 采样窗口

建议同时维护：

## Fast Window

用于控制决策：

```text
max(
    4 × MinRTT,
    500ms
)
```

## Slow Window

用于趋势：

```text
3~5 seconds
```

---

# 59. Fast Window 用途

用于：

```text
Delivery Rate
ACK Ratio
Marginal Efficiency
RTT Inflation
Assist Ramp
```

---

# 60. Slow Window 用途

用于：

```text
Loss Trend
Capacity Trend
Repeated Failure
Network Stability
```

---

# 61. 最低样本量

当：

```text
Acked + Lost < MinSamples
```

时，不应该执行激进 Loss Compensation。

建议：

```text
MinSamples = 50 packets
```

样本不足时：

```text
A = 1
```

---

# 62. 空闲连接

如果：

```text
No Data
```

则：

```text
Pause Assist Evaluation
```

建议：

```text
W → 0
```

重新有数据后：

```text
从 BASELINE 开始
```

---

# 63. 路径变化

如果检测到：

```text
MinRTT突然改变
Path migration
Interface change
Route change
```

则：

```text
W = 0
FailureCount = 0
State = BASELINE
```

重新学习路径。

---

# 64. 核心控制器数据结构

伪结构：

```text
BABRController {
    targetRate

    state

    deliveryRate
    bandwidthEstimate

    minRTT
    srtt

    ackRate
    lossRate

    bbrPacingRate
    finalPacingRate

    assistWeight

    marginalEfficiency

    previousPacing
    previousDelivery

    assistFailureCount

    cooldownDeadline

    config
}
```

---

# 65. 配置结构

```text
BABRConfig {
    TargetRate

    EnterRatio
    ExitRatio

    MinAckRate
    MaxAssistGain

    EnterRTTs
    ExitRTTs

    AssistRampRTTs

    RTTSoftRatio
    RTTHardRatio

    RTTSoftDelay
    RTTHardDelay

    EfficiencyFloor

    CwndGain

    CooldownMin
    CooldownMax
}
```

---

# 66. 推荐默认参数

```text
EnterRatio        = 0.80
ExitRatio         = 0.90

MinAckRate        = 0.80
MaxAssistGain     = 1.25

EnterRTTs         = 3
ExitRTTs          = 2
AssistRampRTTs    = 4

RTTSoftRatio      = 1.25
RTTHardRatio      = 1.50

RTTSoftDelay      = 10ms
RTTHardDelay      = 20ms

EfficiencyFloor   = 0.25

CwndGain          = 2.0

CooldownMin       = 1s
CooldownMax       = 30s
```

---

# 67. 主控制循环

伪代码：

```text
update():

    refreshNetworkModel()
    refreshDeliveryRate()
    refreshRTTMetrics()
    refreshAckLossMetrics()
    refreshEfficiency()

    if appLimited:
        disableAssist()
        return

    if modelInStartup:
        disableAssist()
        return

    if modelInRTTProbe:
        disableAssist()
        return

    switch state:

        BASELINE:

            if shouldEnterAssist():
                enterAssist()

        ASSIST:

            if hardCongestion():
                enterRecovery()
                return

            if targetNearlyReached():
                decreaseAssist()
            else:
                updateAssist()

        RECOVERY:

            assistWeight = 0

            if networkRecovered():
                enterCooldown()

        COOLDOWN:

            assistWeight = 0

            if cooldownExpired():
                state = BASELINE
```

---

# 68. 进入 Assist

```text
shouldEnterAssist():

    if D >= EnterRatio × T:
        return false

    if lowRateDuration < EnterRTTs:
        return false

    if appLimited:
        return false

    if hardCongestion:
        return false

    if cooldownActive:
        return false

    return true
```

---

# 69. Target Pacing

```text
calculateTargetPacing():

    effectiveAck =
        max(A, MinAckRate)

    p =
        T / effectiveAck

    maxP =
        T × MaxAssistGain

    return min(p, maxP)
```

---

# 70. Final Pacing

```text
calculateFinalPacing():

    if W <= 0:
        return P_bbr

    P_assist =
        calculateTargetPacing()

    if P_assist <= P_bbr:
        return P_bbr

    return
        P_bbr
        +
        W × (P_assist - P_bbr)
```

---

# 71. Hard Congestion

```text
hardCongestion():

    rttRatio =
        SRTT / MinRTT

    queueDelay =
        SRTT - MinRTT

    rttHard =
        rttRatio >= 1.50
        AND
        queueDelay >= 20ms

    inefficient =
        η < 0.25

    rttSoft =
        rttRatio >= 1.25
        AND
        queueDelay >= 10ms

    return
        rttHard
        OR
        (
            inefficient
            AND
            rttSoft
        )
```

---

# 72. Fail-safe 原则

发生以下任何情况：

```text
Target <= 0
```

```text
MinRTT invalid
```

```text
Delivery Sample invalid
```

```text
NaN
```

```text
Overflow
```

```text
Model unavailable
```

都应该：

```text
W = 0
```

回退到：

```text
Baseline Model Control
```

---

# 73. 公平性

BABR 比纯模型型控制器更有可能表现得激进。

例如共享 Bottleneck：

```text
BABR Flow
+
Normal Flow
```

如果 BABR 强行追逐 Target，可能抢占其他流量。

因此：

> BABR 必须把 Queue Growth 和 Marginal Efficiency 视为比 Target 更高优先级的信号。

Target 不能成为：

```text
Bandwidth Entitlement
```

---

# 74. 公平性原则

优先级应为：

```text
Network Stability
>
Congestion Safety
>
Fairness
>
Target Achievement
```

而不是：

```text
Target Achievement
>
Everything Else
```

---

# 75. Algorithm Invariants

BABR MUST 始终满足：

### Invariant 1

```text
Assist不能阻止网络模型继续学习
```

### Invariant 2

```text
Assist不能降低模型已经发现的更高Pacing
```

### Invariant 3

```text
Target不可达时必须最终退出Assist
```

### Invariant 4

```text
Assist必须存在明确最大Gain
```

### Invariant 5

```text
App-Limited时禁止Assist
```

### Invariant 6

```text
RTT测量阶段禁止Assist
```

### Invariant 7

```text
HardCongestion优先级高于Target
```

### Invariant 8

```text
异常状态必须回退Baseline
```

---

# 76. 核心性能指标

测试 BABR 时至少记录：

```text
Goodput
```

```text
P50 RTT
P95 RTT
P99 RTT
```

```text
Loss Rate
```

```text
Retransmission Overhead
```

```text
Total Sent Bytes
```

```text
Delivered Bytes
```

```text
Queue Delay
```

```text
Time To Target
```

```text
Time Above Target Threshold
```

```text
Assist State Duration
```

```text
Assist Failure Count
```

```text
State Transition Count
```

---

# 77. Target Achievement Ratio

定义：

```text
TAR =
Time(D >= 0.9T)
/
ActiveTransferTime
```

例如：

```text
TAR = 0.85
```

意味着：

> 85% 的有效传输时间，吞吐达到 Target 的 90% 以上。

---

# 78. Transmission Efficiency

定义：

```text
TE =
DeliveredBytes /
SentBytes
```

用来防止：

```text
Goodput +5%
```

却付出：

```text
Traffic +40%
```

这种伪优化。

---

# 79. Assist Gain Efficiency

定义：

```text
AGE =
GoodputGain /
ExtraSentRate
```

如果：

```text
AGE
```

长期极低，则说明 Brutal Assist 缺乏价值。

---

# 80. RTT Cost

定义：

```text
RTTCost =
P95RTT_BABR /
P95RTT_Baseline
```

BABR 必须评估：

> 为了获得更高吞吐，付出了多少延迟代价。

---

# 81. 测试场景

必须覆盖：

| 场景              | Capacity  | Target | Loss |
| --------------- | --------- | ------ | ---- |
| 高容量低延迟          | 500M      | 200M   | 0%   |
| 高容量高延迟          | 500M      | 200M   | 0%   |
| 随机轻度丢包          | 500M      | 200M   | 1%   |
| 随机中度丢包          | 500M      | 200M   | 5%   |
| 高 RTT + Loss    | 500M      | 200M   | 5%   |
| Target 不可达      | 150M      | 200M   | 0%   |
| Target 不可达+Loss | 150M      | 200M   | 5%   |
| 高容量大目标          | 1G        | 500M   | 1%   |
| 动态容量            | 100M↔500M | 200M   | 0%   |
| Bufferbloat     | 500M      | 200M   | 0%   |

---

# 82. 竞争测试

至少测试：

```text
BABR + Baseline
```

```text
BABR + BABR
```

```text
BABR + Loss-based CC
```

重点观察：

```text
Fairness
Queue Delay
Loss
Goodput
```

---

# 83. Target 达成测试

例如：

```text
Capacity = 500M
Target = 200M
```

期望：

```text
BABR达到Target附近
```

并且最终：

```text
仍能超过Target
```

---

# 84. Target 不可达测试

例如：

```text
Capacity = 150M
Target = 200M
```

必须满足：

```text
Assist最终停止
```

不得长期维持：

```text
Pacing = 200~250M
```

---

# 85. 随机丢包测试

例如：

```text
Capacity = 500M
Loss = 5%
Target = 200M
```

BABR 的目标是：

```text
比Baseline更快恢复到接近Target
```

但不能：

```text
显著制造Queue Growth
```

---

# 86. 动态容量测试

例如：

```text
500 Mbps
↓
100 Mbps
↓
500 Mbps
```

BABR 应：

```text
高速时Probe
↓
容量下降时Recovery
↓
Cooldown
↓
容量恢复后重新Probe
```

---

# 87. Bufferbloat 测试

使用较大 Bottleneck Buffer。

重点验证：

```text
RTT Guard
```

能否在：

```text
Loss发生之前
```

识别 Queue Growth。

---

# 88. MVP 版本

第一版 BABR 建议只实现：

```text
1. Target Rate
2. Delivery Rate
3. BBR-style network model
4. Enter / Exit hysteresis
5. Assist Weight
6. ACK Compensation
7. Max Assist Gain
8. RTT Inflation Guard
9. Marginal Efficiency Guard
10. Recovery
11. Cooldown
12. App-Limited Protection
13. RTT Probe Protection
14. Telemetry
```

---

# 89. MVP 不建议实现

第一版不要加入：

```text
Machine Learning
```

```text
Neural Prediction
```

```text
Complex Path Classification
```

```text
Per-user Optimization
```

```text
Dynamic Policy Search
```

先确保控制逻辑：

```text
稳定
可解释
可测试
可复现
```

---

# 90. 第二阶段：Adaptive Target

未来可以加入：

```text
EffectiveTarget
```

例如：

```text
EffectiveTarget =
min(
    UserTarget,
    LearnedSustainableCapacity
)
```

如果用户：

```text
Target = 200M
```

而网络长期只能：

```text
160M
```

可以暂时把：

```text
EffectiveTarget ≈160M
```

避免重复失败。

---

# 91. 第三阶段：Confidence Model

定义：

```text
CapacityConfidence
```

根据：

```text
Bandwidth Variance
RTT Variance
Loss Variance
Sample Count
```

计算。

网络越稳定：

```text
Assist越积极
```

网络越不确定：

```text
越依赖Baseline
```

---

# 92. 第四阶段：ECN

如果可获得 Explicit Congestion Notification：

```text
ECN CE Marks
```

则可以作为 Congestion Guard 的高级输入。

BABR 应在可能情况下优先考虑：

```text
Explicit Congestion Signal
```

而不是等到：

```text
Loss
```

才退出 Assist。

---

# 93. BABR-Lite

可以设计一个更加保守的版本：

```text
P_target = T
```

不进行：

```text
T / ACKRate
```

补偿。

即：

```text
BBR
+
Target Assist
+
RTT Guard
```

适用于：

```text
共享网络
公共网络
公平性要求更高场景
```

---

# 94. BABR Profiles

未来可以定义：

## Conservative

```text
EnterRatio = 0.70
ExitRatio = 0.85
MaxAssistGain = 1.10
```

## Standard

```text
EnterRatio = 0.80
ExitRatio = 0.90
MaxAssistGain = 1.25
```

## Aggressive

```text
EnterRatio = 0.90
ExitRatio = 0.95
MaxAssistGain = 1.25
```

实际值需要实验确定。

---

# 95. 算法完整逻辑

最终可以表达为：

```text
                      ┌──────────────┐
                      │ Network Model│
                      └──────┬───────┘
                             │
                             ▼
                   Measure Delivery Rate
                             │
                             ▼
                    D >= ExitRatio*T ?
                       │           │
                      YES          NO
                       │           │
                       ▼           ▼
                   BASELINE   D < EnterRatio*T ?
                                   │
                              NO   │   YES
                              │    │
                              ▼    ▼
                         Keep State
                                   │
                                   ▼
                        Congestion Guard
                             │        │
                           CLEAR    CONGESTED
                             │        │
                             ▼        ▼
                           ASSIST   RECOVERY
                             │
                             ▼
                       Increase W
                             │
                       Measure again
                             │
              ┌──────────────┴──────────────┐
              │                             │
        Target approached             Queue/Loss grows
              │                             │
              ▼                             ▼
         Reduce W                     RECOVERY
              │
              ▼
          BASELINE
```

---

# 96. 最终公式集合

## ACK compensation

```text
A_eff =
max(A, A_min)
```

## Brutal-assisted target pacing

```text
P_target =
min(
    T / A_eff,
    T × G_max
)
```

## Assist weight

```text
0 <= W <= 1
```

## Final pacing

```text
P_final =
P_bbr +
W × max(
    0,
    P_target - P_bbr
)
```

## RTT inflation

```text
Q_ratio =
SRTT / MinRTT
```

```text
Q_delay =
SRTT - MinRTT
```

## Marginal efficiency

```text
η =
ΔDelivery /
ΔPacing
```

## Assist BDP

```text
AssistBDP =
P_final × MinRTT
```

---

# 97. BABR 的本质

BABR 不是：

```text
Brutal + BBR 拼接
```

也不是：

```text
Brutal/BBR 自动切换器
```

其本质应该是：

> **一个以 BBR 风格模型为底座、以用户目标速率为优化方向、以 Brutal 式受控补偿作为辅助执行器、并由拥塞保护机制决定何时放弃追逐目标的闭环控制系统。**

---

# 98. BABR 与纯 Brutal 的根本区别

纯 Brutal 假设：

```text
用户知道线路能力
```

BABR 假设：

```text
用户只知道自己希望获得的性能
```

BABR 自己判断：

```text
这个目标是否合理
```

以及：

```text
什么时候应该停止尝试
```

---

# 99. BABR 与纯 BBR 的根本区别

纯 BBR 主要回答：

```text
网络目前能跑多快？
```

BABR 额外回答：

```text
如果当前低于用户目标，
是否值得更加积极地尝试？
```

---

# 100. 成功标准

BABR 只有同时满足以下条件，才算真正有效：

1. 随机丢包环境下，比基线更容易达到 Target；

2. 高 RTT 环境中能够改善目标吞吐达成率；

3. Target 不可达时能够及时停止 Assist；

4. 不把 Target 变成固定速率上限；

5. 能继续探测超过 Target 的可用带宽；

6. 不因 Loss Compensation 形成持续拥塞；

7. RTT 增长必须受控；

8. Queue Growth 必须受控；

9. Extra Traffic 必须换来实际 Goodput；

10. Assist 与 Baseline 之间不能频繁振荡；

11. 多流竞争时不能长期无条件抢占带宽；

12. 出现异常时能够安全回退 Baseline。

---

# 101. 最终结论

BABR 的核心关系可以归纳为：

```text
BBR-style Model
=
“网络告诉我它现在能给多少”
```

```text
Target
=
“用户告诉我希望得到多少”
```

```text
Brutal Assist
=
“如果网络看起来还有余量，我主动补足差距”
```

```text
Congestion Guard
=
“如果发现这个差距其实来自物理瓶颈，我停止追逐”
```

最终算法原则：

> **低于目标时主动，但不盲目；接近目标时让路；超过目标时继续探测；发现真实拥塞时立即服从网络。**

因此 BABR 可以视为一种：

> **Target-Assisted Model-Based Congestion Control**

它试图同时获得两类算法的优点：

```text
Brutal：
明确目标
积极补偿

BBR：
动态建模
主动探测
拥塞感知
```

并通过：

```text
Hysteresis
Assist Weight
RTT Guard
Marginal Efficiency
Recovery
Cooldown
```

限制两者结合后可能产生的副作用。
