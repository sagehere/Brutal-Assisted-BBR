# P2 真实 Observe 网络验证

版本：p2-real-observe-network-v1  
日期：2026-09-19  
状态：**PASS — 真实 Off/Observe 长流与无控制介入证据通过；资源开销 Gate 尚未闭环**

## 1. 目的

在已经校准通过的三节点 Linux network namespace 拓扑中，运行真实 patched quiche/tokio-quiche 流量，验证：

- 发送方真实使用冻结宿主的 BBR2 gcongestion；
- Observe telemetry 只读接入真实连接生命周期；
- 数据真正经过指定的 `netem + TBF` 受控路径；
- Off 与 Observe 都能完成同一长流；
- Observe 不进入 Lite，不把 shadow candidate 应用到发送输出；
- 真实 socket/GSO success、unique STREAM payload 和模型字段能够输出结构化 telemetry。

该验证不是 CPU p95/内存最终开销报告，也不是 Lite 性能验证。

## 2. 实验实现

真实发送方：

- tokio-quiche `async_http3_server`；
- HTTP/3 路径 `/stream-bytes/67108864`；
- `--cc-algorithm bbr2`；
- `--enable-pacing`；
- 所有 socket/GSO 发送继续经过冻结的 `IoWorker::flush_buffer_to_socket(): Ok(n)` 事实边界。

真实接收方：

- 官方 `quiche-client`；
- HTTP/3；
- 关闭证书验证仅用于本地实验；
- 提高 transport/stream flow-control window，避免 64 MiB body 被接收窗口人为限制。

Observe telemetry：

- `0007-babr-real-observe-telemetry-sink.patch`；
- 只有设置 `BABR_OBSERVE_TELEMETRY_FILE` 时才启用；
- Off 不创建/启用 Observe ring；
- H3 connection 建立后绑定真实 active path；
- ACK/H3 read processing 后 drain；
- 关闭前再执行 final drain；
- 输出仍受 recovery telemetry 的 1 MiB/60s serializer hard cap；
- telemetry sink 不参与 pacing、CWND、send permission 或 recovery 判定。

## 3. 方向错误的诊断 run — 不作为最终证据

首次 Real Observe run `35432767361` 虽然应用层 pair 自检通过，但复核 artifact 后发现：

- HTTP/3 bulk response 实际方向是 `receiver namespace → sender namespace`；
- 当时 100M TBF 仍放在校准默认的 `sender → receiver` router egress；
- router TBF 只看到约 0.75–0.81 MB，而响应体为 64 MiB；
- 64 MiB 客户端完成时间约 2.0s，明显不符合 100M bottleneck。

因此该 run **作废为方向诊断证据**，不得用于宣称 100M 受控 Observe 验证通过。没有降低任何验收阈值。

随后修正：

- `shape.sh` 新增 `BABR_DATA_DIRECTION`；
- 校准默认仍为 `sender_to_receiver`；
- HTTP/3 response 实验使用 `receiver_to_sender`；
- TBF 随 bulk-data 方向移动到 router toward-data-receiver 的 egress；
- 数据发送侧 netem 承载 delay/loss，反向 ACK/request path 保留对称 delay；
- 实验脚本强制验证 TBF 累计发送字节至少覆盖完整 bulk response；
- 实验脚本强制验证 64 MiB 用时不得快于 `configured_rate × 115%` 的理论下限；
- namespace cleanup 会终止残留 namespace process，避免隐藏 listener 泄漏。

## 4. 最终有效受控 run

代码 head：

`9323cc984aa7a22c4b6532f3042c2e475bfff231`

对应 Gate：

- P1 Final Gate `35433043143`：**PASS**
- P2 Observe Gate `35433043114`：**PASS**
- P2 Network Calibration `35433043089`：**PASS**
- P2 Real Observe Network `35433043140`：**PASS**

网络参数：

- bulk direction：`receiver_to_sender`
- TBF：100 Mbit/s
- one-way delay：20 ms
- reverse one-way delay：20 ms
- configured random loss：0%
- application payload：67,108,864 B（64 MiB）

### Off

- elapsed：**6.535168294 s**
- application goodput：**82.151046 Mbit/s**
- bottleneck timing check：PASS
- router→sender TBF bytes：**71,743,177 B**
- TBF overlimits：**77,631**
- TBF dropped：0
- response size：64 MiB，验证通过

### Observe

- elapsed：**6.521511288 s**
- application goodput：**82.323083 Mbit/s**
- bottleneck timing check：PASS
- router→sender TBF bytes：**71,738,950 B**
- TBF overlimits：**75,539**
- TBF dropped：0
- response size：64 MiB，验证通过

两次应用 payload SHA-256 完全相同：

`e1661cf5aac673b640e08b5fc32606dd946d5dab5c92ec92e1eff43c69a689fe`

这些独立真实网络运行不要求逐包相同；精确 transport-output 等价已经由确定性宿主回归负责。

## 5. Observe telemetry 实际结果

最终 Observe trace：

- records：**73**
- serialized bytes：**21,910 B**
- transport `reason` 唯一值：**MODE_NOT_LITE**
- shadow reasons：
  - `APP_LIMITED`
  - `BBR_PHASE_PROTECTED`
  - `BOUNDED_PROBE`
- last actual socket sent bytes：**69,563,913 B**
- last unique STREAM payload bytes：**67,053,715 B**
- last model delivery：**12,149,005 B/s**
- last baseline pacing：**12,149,005 B/s**
- last baseline CWND：**996,363 B**

自动验证：

- schema 全部为 `p2-observe-v1`；
- 所有 transport reason 均为 `MODE_NOT_LITE`；
- actual socket sent 与 unique payload 均出现真实值且单调不下降；
- trace 非空；
- serialized bytes 没有越过 hard cap；
- Off 不产生 Observe telemetry；
- Off/Observe 均完整收到 64 MiB；
- payload hash 一致；
- bulk response 实际穿过 100M TBF。

注意：最后一条 telemetry snapshot 的 unique acknowledged STREAM payload 可以小于客户端最终已接收 payload，因为它是 sender-side 已确认唯一载荷快照，不把尚未回到发送端的尾部 ACK 伪装为已确认交付。本 run 不替代后续 L06 的专门实网 ACK/retransmission 对账。

## 6. Artifact

有效 run `35433043140`：

- artifact ID：`10581376017`
- artifact name：`p2-real-observe-network-86e9912f99638718b40d5633ef74f41b0140451e`
- artifact size：141,674 B（ZIP）
- digest：`sha256:cea251c8ee9bb828ae6e49d9e870a3cc4f5b13e441a7254f18271dea4502e41e`

artifact 包含 Off/Observe：

- client/server logs；
- response hash；
- qdisc stats；
- transfer summary；
- Observe JSONL；
- Observe summary；
- pair summary；
- client `/usr/bin/time -v` 原始记录。

## 7. 当前结论与剩余边界

本项可以判定：

**真实受控网络 Off/Observe 长流 + Observe 无实际辅助介入：PASS。**

不能据此判定：

- CPU p95 overhead ≤2%；
- whole-connection memory ≤256 KiB；
- 60 秒真实日志预算最终开销；
- L03/L04/L05/L10/L06 网络场景；
- M2 Observe Gate；
- G2；
- Lite 可解锁。

下一步应建立重复 Off/Observe 开销基准，采用多次独立 pair 获取 server-side CPU、RSS、吞吐与日志数据，再按冻结的 p95/内存/log budget 做 Gate。
