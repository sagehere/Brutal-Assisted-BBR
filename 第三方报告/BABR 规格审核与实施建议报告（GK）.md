**结论：值得做，但不能按 v0.2 直接编码。** 问题定义是对的，价值集中在 Brutal 已经大规模使用的受控路径（QUIC 代理 / 隧道 / 专线），不是公网默认 TCP。最大风险不是公式，而是 Assist 把 BBR 的带宽模型污染掉。

完整报告可下载：

displayfile://workspace/artifacts/BABR-规格审核与实施建议报告.md

---

## 1. 实施价值：有，而且很集中

Brutal 的已知失败模式已经被 Hysteria / Xray / tcp-brutal 验证过：

- Target = 200M、容量 = 150M → 持续超发，队列和 RTT 一起坏，goodput 仍停在 ~150
- Target = 200M、容量 = 500M → 能到目标，但 **Brutal 把 Target 当成天花板，不再往上探**

产业界现有解法是硬切换：填了带宽用 Brutal，否则 BBR。BABR 第一次把这件事做成 **连续权重 + 拥塞护栏 + 失败退避**。

相对现有方案的增量只有三句，但这三句成立就够做一个实验系统：

| 对比         | BABR 多出来的东西                                                    |
| ---------- | -------------------------------------------------------------- |
| vs Brutal  | Target 不可达时必须停；有 `G_max`、RTT 护栏、边际效率、冷却                        |
| vs BBR     | 容量明显大于目标、模型暂时偏低时，会主动补                                          |
| vs Xray 硬切 | `W∈[0,1]` 平滑叠加，避免 160→210 的阶跃；Assist **只能加不能减**，所以 Target 不是限速 |

**高价值部署域（建议写成唯一 MVP 目标）：** QUIC 用户态代理、点对点隧道、随机丢包但容量仍高于 Target 的路径。

**不要期待的价值：** 带宽保证、比 BBR 更公平、替代整形。规格把公平性排在 Target 后面——这在受控链路上可接受，在公网默认 TCP 上没有正当理由。BBRv3 至今未进 mainline，核心就是和 Cubic 的公平性；BABR 比它更激进，内核默认这条路现在走不通。

价值是否成立，建议收成 **4 条否决项**（比规格第 100 节的 12 条更可执行）：

1. **不可达必须停**（150M 容量不得把 pacing 长期钉在 200–250M）
2. **可达必须更快到 0.9T**（尤其 5% 随机丢包）
3. **超目标后必须还能探**（不能停在 ~200M）
4. **多发的包必须买到 goodput**（`TE=Delivered/Sent` 明显好于 Brutal）

第 1 条做不到，BABR 就是套壳 Brutal，没有实施价值。

---

## 2. 实施可行性：QUIC 上能做，v0.2 还不是编码规格

单独看第 88 节 14 项 MVP，每一项都不难。真正难的是：

```text
BBR 内部状态机  ×  BABR 外部状态机  ×  采样时钟  ×  真实 ACK
```

### 平台

| 路径                              | 判断                                                                    |
| ------------------------------- | --------------------------------------------------------------------- |
| 用户态 QUIC（quic-go / Hysteria 路径） | **首选。** 接口现成，Brutal 与 BBR 都有对照实现。熟练单人约 3 周可跑 MVP，6–8 周能给出「该不该继续」的实验结论 |
| 先做哑铃仿真再接到 QUIC                  | **应作为门禁**，不是可选项                                                       |
| 内核 TCP 模块                       | v2 再说，和内核 BBR 内部状态耦合太深                                                |
| 公网默认 / IETF 友好                  | 现阶段否                                                                  |

基座必须先冻死：**MVP 用 BBRv1（quic-go 现用版），Assist 只做输出外挂。** 「BBR-style」在 2026 年至少是 v1/v2/v3 三套不可互换的东西；BBRv2/v3 的 `inflight_hi` 和 2% 丢包阈值会和 Assist 对着干。

### 不补就不能开工的三个洞

**A. 模型污染（致命）**

规格 Invariant 1「Assist 不能阻止模型学习」，字面执行会出问题：Assist 把 pacing 从 160 提到 210 后，BBR 的 `BtlBw=max(delivery)` 会把 Assist 打出来的速率记成真实带宽。更危险的是 BBRv1 的 ProbeBW DOWN（`pacing_gain=0.75`）本用来排空队列，Assist 会按 `P_target−P_bbr` 把缺口补回去，**drain 失效**。ProbeRTT 只禁了 W，ProbeBW drain 没禁。

最低规则：

- `pacing_gain<1`、DRAIN、PROBE_RTT：`W` 必须为 0
- Assist 样本可更新 D/A/η，**不得推高 BtlBw max-filter**（只降不升）

否则「网络模型永久在线」会变成 Assist 给自己颁发带宽证书。

**B. η 没有可实现定义**

`η=ΔD/ΔP` 缺窗口、缺 `ΔP≈0` 和 `ΔP<0` 的定义。ProbeBW 稳态或 drain 时这个数会随机触发 HardCongestion。必须加死区：激励太小或正在降速时视为 `η=1`，不惩罚。

**C. 时钟和阈值不可移植**

- Fast Window 地板 500ms，EnterRTTs=3。5ms RTT 上「连续 15ms 低速」就要进 Assist，但 D 是 500ms 均值——进入条件形同虚设。
- `Q_delay≥10/20ms` 在 MinRTT=0.3ms 已经是严重膨胀，在 600ms 卫星上只是噪声。

这两处不改，LAN 和卫星会调出两种算法。

### 其它会卡住实现的不一致

- **两套 W**：§29 阶梯 ramp、§30 连续 `W_target(D/T)`、§67 又是第三套。MVP 只能留 ramp。
- **两套 CWND**：§55 与 §56 不同，应以 §56 为准。用 MinRTT 而不是 SRTT 算 BDP 是对的——比 Brutal 参考实现更正确（Brutal 用 SRTT，队列↑→CWND↑，正反馈）。
- 默认 `A_min=0.80` 与 `G_max=1.25` **数学上是同一个旋钮**（`1/0.8=1.25`），规格没声明。
- `LossTrendIncreasing`、`Delivery稳定`、`TargetInfeasible` 持续时间、路径变化幅度均无定义。

用 MinRTT 算 Assist BDP、ACK 补偿只加在 pacing 上不在 CWND 上再除一次 A——这两点比 Brutal 干净，应保留。

---

## 3. 补充建议

### 规格 v0.3 必补

1. **冻结范围：** managed path / proxy QUIC，不是 Internet 默认 TCP；基座 BBRv1；BABR 只是输出 overlay。
2. **反污染 MUST：** 见上文 A。
3. **MVP 只留一套 W：** 进入后按 RTT 线性升到 1，Soft 时衰减、Hard 离场，退出线性降到 0。连续 `W_target` 放到 v2。
4. **统一时钟：** 「持续 N 个 RTT」改为 `max(N×SRTT, k×FastWindow)`；FastWindow 改为 `clamp(4×MinRTT, 50ms, 500ms)`；`α=0.25` 必须是每 SRTT 一次，禁止每 ACK。
5. **RTT 阈值缩放：** `SoftDelay=max(10ms, 0.25×MinRTT)`，Hard 用 `0.50×MinRTT`。
6. **Target 与 RateLimit 分离：** 一个是希望不低于，一个才是硬上限。都缺省 = 纯 BBR。
7. **多流语义写死：** v1 的 Target 是每连接的，N 条流会按 N×T 去抢。连接组（tcp-brutal 的 `group_id`）列为 v2。
8. **Telemetry 作为 MUST：** `state, W, T, D, A, P_bbr, P_final, q_ratio, η, bbr_phase, fail_count`。没有这张表，§81 的场景无法复盘。

### 建议砍掉或降级

Adaptive Target、Confidence、ECN、内核 TCP——都对，但都不是 v1。  
**BABR-Lite（`P_target=T`，不做 `T/A`）应作为对照开关保留**：这是判断收益来自「追逐目标」还是「丢包补偿」的最便宜实验。  
对外只暴露 `target_rate` + `profile(standard|lite|off)`，其余 16 个默认值全部锁死。

### 实现结构：装饰器，不要融进 BBR

始终跑完整 BBR，BABR 只改 `P_final/CWND_final`。BBR 不知道 Assist 的存在。这是保住 Invariant 1–2、并能一键关掉 Assist 做对照的唯一结构。

`pacing_gain<1` 时强制 `W=0`，应写成和 ProbeRTT 同级的 MUST。

### 实验门禁（比规格场景表更硬）

每场对照：**BBR / Brutal / BABR / BABR-Lite / Cubic**。  
额外回归，不通过不准接生产：

- ProbeRTT 期间 inflight 是否真的降下去
- Assist 退出后 BtlBw 是否被抬高
- 应用只供 50M、Target=200M 时 W 是否始终为 0
- 1ms 与 400ms RTT 各一场（专门打阈值缩放）
- 容量阶跃 500→100→500

### 推荐顺序

```text
v0.3 规格（反污染 + 互斥 + 唯一 W + 时钟）
  → 哑铃仿真（先打否决项「停得下来」「还能继续探」）
    → quic-go overlay MVP + telemetry
      → 对照跑完再接 Hysteria/Xray 小流量
        → 再谈内核、BBRv3、ECN、Adaptive Target
```

---

**一句话：** 做，但按实验系统做，不要按产品特性铺开。先证明 Assist 是有界可撤销增益；如果实验显示收益只来自「多发」，就停在 Lite 或回到 BBR，而不是继续加预测模型和自适应目标。规格第 89 节的克制，是这份文档最该保住的部分。
