# P2 M4 Controlled Safety

## L03 policer safety

`run-lite-l03-policer.sh` begins on a 150 Mbps TBF with a 200 Mbps Target. It only opens that shaper and installs a real 150 Mbps UDP `tc police` action after a real Assist admission; the policer's `overlimits` counter is required evidence. If the controller's existing safety gates never admit Assist, the runner preserves its trace as `BLOCKED` and never arms the policer or weakens the host limits.

Frozen goals:

- Target is not treated as available capacity.
- Assist must be observed before policer injection, then remain bounded by deadline, rounds, budget and backoff after the real loss event.
- Exit reason must be observable through `p2-lite-v2` telemetry.
- This runner does not evaluate throughput improvement.

Only `PASS` L03 evidence is a prerequisite for G2. A collection run may finish with
`BLOCKED` so its trace and reason are retained; that status does not permit G2.
