# P2 M4 Controlled Safety

## L03 policer safety

`run-lite-l03-policer.sh` creates a controlled bottleneck below Target and checks that Lite produces bounded control evidence.

Frozen goals:

- Target is not treated as available capacity.
- Assist must remain bounded by deadline, rounds and budget.
- Exit reason must be observable through `p2-lite-v1` telemetry.
- This runner does not evaluate throughput improvement.

L03 evidence is a prerequisite for later L04/L05/L10 runs.
