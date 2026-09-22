# P2 M4 Controlled Safety

## L03 policer safety

`run-lite-l03-policer.sh` begins on a 150 Mbps TBF so a 200 Mbps Target can enter bounded Assist without synthetic loss. It then opens that shaper and installs a real 150 Mbps UDP `tc police` action after Assist appears; the policer's `overlimits` counter is required evidence.

Frozen goals:

- Target is not treated as available capacity.
- Assist must be observed before policer injection, then remain bounded by deadline, rounds, budget and backoff after the real loss event.
- Exit reason must be observable through `p2-lite-v2` telemetry.
- This runner does not evaluate throughput improvement.

L03 evidence is a prerequisite for later L04/L05/L10 runs.
