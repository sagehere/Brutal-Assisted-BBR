# P2 M4 Controlled Safety

## L03 policer safety

`run-lite-l03-policer.sh` begins on a 150 Mbps TBF with a 200 Mbps Target. Four concurrent 256 MiB HTTP/3 streams keep one real connection supplied for a 1 GiB total flow beyond the frozen 30-second startup backoff, then the runner only opens that shaper and installs a real 150 Mbps UDP `tc police` action after a real Assist admission; the policer's `overlimits` counter is required evidence. If the controller's existing safety gates never admit Assist, the runner preserves its trace as `BLOCKED` and never arms the policer or weakens the host limits.

Frozen goals:

- Target is not treated as available capacity.
- Assist must be observed before policer injection, then remain bounded by deadline, rounds, budget and backoff after the real loss event.
- Exit reason must be observable through `p2-lite-v2` telemetry.
- This runner does not evaluate throughput improvement.

Only `PASS` L03 evidence is a prerequisite for G2. A collection run may finish with
`BLOCKED` so its trace and reason are retained; that status does not permit G2.

## L05 ACK suppression safety

`run-lite-l05-ack-suppression.sh` uses the accepted sender-side 150 Mbps FQ pacing
setup with a 200 Mbps Target. It waits for a real Assist budget pre-debit, then
installs a router egress drop filter for client-to-server UDP packets—the ACK
direction during server data transfer—immediately after a real Assist budget
debit. QUIC encrypts packet contents, so the filter cannot distinguish ACK
frames from other client-to-server control packets. The trace checker requires the
router's actual dropped-packet counter, `ASSIST_TIMEOUT`, a legal `PTO_FIRED`,
and successful socket-send progress after deadline expiry. Missing admission,
deadline-window timing, filter drops, timer/PTO evidence, or post-deadline socket
progress is retained as `BLOCKED`; it cannot close L05 or G2.

This tests that the Assist deadline does not wait for an ACK and that ordinary
host recovery continues after the auxiliary lease expires. It does not change
the frozen deadline, pacing, congestion window, or recovery rules.
