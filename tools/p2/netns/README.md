# P2 controlled-network harness

This directory is the real network prerequisite for the P2 Observe Gate.

Topology:

```text
sender namespace            router namespace             receiver namespace
10.203.0.2/24 ---- veth ---- 10.203.0.1/24
                                      |
                               IPv4 forwarding
                                      |
                         10.204.0.1/24 ---- veth ---- 10.204.0.2/24
```

The default calibration applies:

- sender egress: `netem delay 20ms loss 0%`
- router -> receiver egress: `tbf rate 100mbit`
- receiver egress: `netem delay 20ms`

Putting `netem` and `tbf` on separate egress devices avoids relying on
classless-qdisc nesting behavior while ensuring both mechanisms are actually
on the end-to-end path.

Run on Linux with root/CAP_NET_ADMIN:

```bash
sudo -E bash tools/p2/netns/calibrate.sh
```

Useful scenario variables:

```bash
BABR_RATE_MBIT=150
BABR_ONE_WAY_DELAY_MS=20
BABR_LOSS_PCT=1
sudo -E bash tools/p2/netns/calibrate.sh
```

Calibration uses four parallel TCP streams to saturate the configured TBF; this avoids treating a single flow's congestion-window/socket-buffer ramp as a shaper failure. It is a capability/effectiveness gate only. It proves namespace, routing, `netem`, `tbf`, RTT, and bottleneck-rate control are reproducible.
It does **not** count as BABR Observe or Lite network evidence by itself.

Artifacts are written to `阶段任务书/p2-network-artifacts/` and are uploaded by
the dedicated CI workflow.


## Data direction

`shape.sh` is direction-aware:

- `BABR_DATA_DIRECTION=sender_to_receiver` — default, used by network calibration.
- `BABR_DATA_DIRECTION=receiver_to_sender` — used by the HTTP/3 bulk-response Observe experiment because the tokio-quiche server is the congestion-controlled data sender.

The router TBF is always installed on the egress toward the bulk-data receiver. The data sender egress carries netem delay/loss, while the reverse ACK/request path carries the symmetric propagation delay.

`run-observe-pair.sh` additionally rejects a run unless the selected TBF carries at least the application bulk payload and the transfer duration is compatible with the configured rate plus the frozen 15% calibration tolerance.
