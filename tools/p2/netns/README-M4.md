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

`run-lite-l05-ack-suppression.sh` runs three independent attempts with the
accepted sender-side 150 Mbps FQ pacing setup and a 200 Mbps Target. Each attempt
waits for a real Assist budget pre-debit, then installs a router egress drop
filter for client-to-server UDP packets—the ACK direction during server data
transfer. QUIC encrypts packet contents, so the filter cannot distinguish ACK
frames from other client-to-server control packets. The per-run trace checker
requires the router's actual dropped-packet counter, `ASSIST_TIMEOUT` at or after
the admitted deadline, a legal `PTO_FIRED`, and successful socket-send progress
after expiry. One complete PASS makes the aggregate PASS; if all runs are
BLOCKED, the aggregate stays BLOCKED. A failed or malformed run makes the
aggregate FAIL. No missing evidence closes L05 or G2.

This tests that the Assist deadline does not wait for an ACK and that ordinary
host recovery continues after the auxiliary lease expires. It does not change
the frozen deadline, pacing, congestion window, or recovery rules.

Only the L05 runner opts into a 5 ms Lite telemetry file drain; normal Lite
and Observe use the existing 250 ms cadence. The collector requires a fresh,
currently active Assist authorization with a real budget pre-debit before it
installs the filter. An empty `clsact` hook is installed before the transfer;
only the drop action is installed after admission. The collector polls at 5 ms
and records admission detection and filter installation monotonic timestamps and
retains all independent attempts, including BLOCKED traces. This affects
experiment observability only; frozen controller and pacing rules are unchanged.

If `tc` activation from the parent still takes longer than a live Assist
window, the runner starts an ACK-path helper in the router namespace before
the connection begins. That helper waits on a pipe and creates no drop rule
until a real admission wakes it. The installed rule's actual dropped count
and the time spent signalling and waiting remain part of the evidence.
