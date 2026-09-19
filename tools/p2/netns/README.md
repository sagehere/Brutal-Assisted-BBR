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

Calibration is a capability/effectiveness gate only. It proves namespace,
routing, `netem`, `tbf`, RTT, and bottleneck-rate control are reproducible.
It does **not** count as BABR Observe or Lite network evidence by itself.

Artifacts are written to `阶段任务书/p2-network-artifacts/` and are uploaded by
the dedicated CI workflow.
