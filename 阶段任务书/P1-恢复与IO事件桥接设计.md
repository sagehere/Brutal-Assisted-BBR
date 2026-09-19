# P1 恢复与 I/O 事件桥接设计

版本：`p1-baseline-v3`；日期：2026-09-19；状态：Final Closure 宿主映射。

## 1. 目的

本文件只负责把 `p1-baseline-v3` 的规范语义映射到固定宿主接口，不得覆盖或创造主规格规则。它闭环 `BBRv2::is_in_recovery()`、PTO、持续拥塞、ECN 和 socket 实际发送边界，但不在 P1 实现 BABR 控制器。

固定宿主仍为 Cloudflare quiche 0.29.3，提交 `55886df3be579579207104c8e645825b6347a209`。源码审计确认：

- `quiche/src/recovery/gcongestion/bbr2.rs` 的 `is_in_recovery()` 含 `TODO(vlad): is this true?`，不得作为 BABR 安全信号。
- `gcongestion/recovery.rs::on_loss_detection_timeout()` 可以明确区分“已有 loss_time 的丢失处理”和真正 PTO 分支；PTO 分支会增加 `pto_count`。
- quiche 0.29.3 没有向 gcongestion/BABR 暴露 RFC 9002 persistent-congestion 布尔事件。
- 该版本接收 ACK frame 时能够解析 ECN counters，但 `Connection` 发送侧明确标注 `sending ECN is not supported at this time`，现有 recovery/gcongestion 路径没有可供 BABR 使用的已验证 CE 事件。
- `Connection::send()/send_on_path()` 在生成 datagram 时已经调用 recovery 的 `on_packet_sent()`；真正 socket 成功发生在宿主应用层。tokio-quiche 的 `IoWorker::flush_buffer_to_socket()` 能得到 socket/GSO 的实际写入结果。

因此 BABR 不建立“影子恢复状态”，也不伪造 persistent-congestion/ECN 支持。

## 2. TransportGuardEvent

阶段 02 在 quiche recovery 与 BABR 之间加入只读事件桥：

```text
TransportGuardEvent {
    LossDetected { lost_bytes, lost_packets }
    PtoFired { pto_count }
    PathChanged { path_id }
    AppLimited
    ReceiverLimited
    PolicyLimited
}

HostCapability {
    EcnCe = Unsupported
    PersistentCongestion = Unsupported
}
```

事件的唯一用途是保护/撤销 Assist；不得用这些事件提高 Target、W、pacing、CWND 或预算。

### 2.1 丢失

当 ACK 或 loss timer 处理得到 `lost_packets > 0` 时发出 `LossDetected`。

P1 冻结规则：**任意 LossDetected 立即原子撤销当前 Assist，并进入 ASSIST_BACKOFF。**

这是保守规则。阶段 02/03 若证明随机非拥塞丢包下该规则过于保守，只能在新的规格修订中放宽，不能在实现里静默改变。

### 2.2 PTO

在 `on_loss_detection_timeout()` 进入真正 PTO 分支、`pto_count += 1` 后发出 `PtoFired`。如果 timeout 只是处理已有 `loss_time`，不标记 PTO。

P1 冻结规则：**任意 PtoFired 立即撤销 Assist、使本轮样本失效并进入 ASSIST_BACKOFF。**

因此 BABR 不依赖 `BBRv2::is_in_recovery()`。

### 2.3 Persistent Congestion

固定 quiche 版本没有可复用的明确 persistent-congestion 控制事件。P1 不新增一套 RFC 9002 persistent-congestion 判定器，也不把 BBR 的 persistent queue / RTT jump 当作 persistent congestion。

能力值固定为：

```text
persistent_congestion_signal = unsupported
```

因为 PTO 与任意丢失事件已经强制撤销 Assist，缺少该信号不会允许 Assist 穿过已观测的传输失败。若未来宿主版本提供明确事件，BABR 必须将其作为 Hard guard 接入。

### 2.4 ECN

固定 quiche 版本不提供可供 gcongestion 控制器使用的已验证 CE 事件，能力值固定为：

```text
ecn_ce_signal = unsupported
```

P1/阶段 02 不实现新的 ECN 控制律。若宿主升级后提供经验证 CE 事件，则 CE 只允许撤销/冻结 Assist，不能提高辅助强度。

## 3. BBR 相位桥

BABR 只读取 BBRv2 的明确模式/ProbeBW cycle phase：

允许：
- ProbeBW.Refill
- ProbeBW.Up
- ProbeBW.Cruise

禁止：
- Startup
- Drain
- ProbeRTT
- ProbeBW.Down

不得由 `pacing_gain` 推断相位。任何未知枚举值按禁止处理。

## 4. 发送预算与 socket 计量

quiche 核心在 datagram 生成阶段就已经把 packet 交给 recovery 的 `on_packet_sent()`，而 socket 成功位于应用 I/O 层。因此 P1 明确分成两个计数器：

```text
assist_budget_debit_bytes
actual_socket_sent_bytes
```

### 4.1 执行预算

为了避免 WouldBlock、GSO、异步队列或应用层重试绕过预算：

- admission 粒度固定为**单个 QUIC datagram**；在调用 `send()/send_on_path()` 生成带辅助增量的新 datagram **之前**检查剩余额度与 hard deadline。
- datagram 一旦由 quiche 成功生成，就按生成字节数保守扣减 `assist_budget_debit_bytes`。
- socket 失败、WouldBlock、部分写入均**不退款**。
- `now >= assist_deadline`、预算不足以覆盖下一 datagram 或达到 2,400 byte 不可撤销队列容差后，后续 datagram 不得携带辅助增量；deadline 对新 Assist 字节的 grace 为 0ms，基线发送仍可继续。
- 这个计数器是安全执行预算，不宣称等于“相对未启用 Assist 的额外网络字节”。

该规则保证预算安全不依赖 socket 回调。

### 4.2 实际发送遥测

`actual_socket_sent_bytes` 只能在真实 I/O 成功后增加：

- 同步 UDP：`socket.send_to()` 返回的成功字节数。
- tokio-quiche：`IoWorker::flush_buffer_to_socket()` 的 `send_res = Ok(n)`。
- GSO：按系统调用成功返回的实际字节数记账。
- `Err` 不增加；部分写入只增加 `n`。

阶段 02 的参考实验运行时固定使用同一提交中的 tokio-quiche I/O worker 或等价、可证明拥有 socket 成功回调的薄宿主；若使用不能提供该回调的调用方，只允许 observe，不允许把其数据用于发送成本验收。

## 5. 原子撤销契约

以下事件必须在下一次发送决策前原子发布：

```text
W = 0
final_pacing = baseline_pacing
final_cwnd = baseline_cwnd
assist_budget_open = false
reason_code = <event>
```

适用事件：LossDetected、PtoFired、禁止 BBR 相位、Hard queue guard、路径变化、应用/接收/策略受限、Target 关闭或无效、deadline/budget/no-benefit。

撤销 Assist 不阻止 quiche 正常 PTO、重传、恢复、网络模型学习或基线 ProbeBW。

## 6. 阶段 02 必须验证

1. 人工触发丢失时，同一次处理周期撤销 Assist。
2. 真正 PTO 与 loss-time timeout 能区分；只有前者记录 `PtoFired`。
3. `is_in_recovery()` 不出现在 BABR 保护判断中。
4. Startup/Drain/ProbeRTT/ProbeBW.Down 无辅助输出。
5. socket WouldBlock/Err 不会恢复已经扣除的辅助预算。
6. socket 成功字节与生成字节分开记录。
7. ECN/persistent-congestion capability 显式为 unsupported，日志不得伪报事件。
8. 运行时关闭 Assist 后，下一发送决策严格返回基线 pacing/CWND。

以上 8 项进入阶段 02 的 L04/L05/L10 及新增桥接回归。
