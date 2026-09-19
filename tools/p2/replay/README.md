# P2 deterministic replay

This directory contains the executable reference model used before BABR is
allowed to affect the quiche host.

Run:

```bash
bash tools/p2/verify_observe.sh
```

The replay model is intentionally transport-free. In `observe`, candidate
outputs are telemetry only: final pacing and CWND must equal the BBR baseline.

Do not use replay PASS as a substitute for the real-network evidence required
by stage 02. In particular L03/L04/L05/L10 still require controlled-link
artifacts before G2.
