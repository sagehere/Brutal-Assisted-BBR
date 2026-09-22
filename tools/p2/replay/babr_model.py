#!/usr/bin/env python3
"""Deterministic BABR P2 reference model.

This module is deliberately transport-free: it cannot send packets and is not
linked into quiche. It makes the frozen p1-baseline-v4 rules executable before
host integration. Observe mode may evolve a shadow assist state for telemetry,
but final pacing/cwnd/send permission remain the baseline.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
import json
from pathlib import Path
from typing import Any, Optional


class Mode(str, Enum):
    OFF = "off"
    OBSERVE = "observe"
    LITE = "lite"


class State(str, Enum):
    BASELINE = "BASELINE"
    ASSIST = "ASSIST"
    ASSIST_BACKOFF = "ASSIST_BACKOFF"


ALLOWED_PHASES = {
    "ProbeBW.Refill",
    "ProbeBW.Up",
    "ProbeBW.Cruise",
}

PROTECTED_PHASES = {
    "Startup",
    "Drain",
    "ProbeRTT",
    "ProbeBW.Down",
}


@dataclass(frozen=True)
class FrozenRules:
    target_min: int
    target_max: int
    target_enter_ratio: float
    target_exit_ratio: float
    max_relative_rate_gain: float
    weight_step: float
    max_duration_ms: int
    max_rounds: int
    no_benefit_round: int
    minimum_model_gain_ratio: float
    soft_queue_delay_min_ms: int
    soft_queue_delay_min_rtt_ratio: float
    hard_queue_delay_min_ms: int
    hard_queue_delay_min_rtt_ratio: float
    max_unrevocable_queue_bytes: int

    @classmethod
    def from_contract(cls, contract: dict[str, Any]) -> "FrozenRules":
        target = contract["target"]
        assist = contract["assist"]
        guards = contract["guards"]
        return cls(
            target_min=int(target["minimum_nonzero_byte_per_s"]),
            target_max=int(target["maximum_byte_per_s"]),
            target_enter_ratio=float(target["enter_ratio"]),
            target_exit_ratio=float(target["exit_ratio"]),
            max_relative_rate_gain=float(assist["max_relative_rate_gain"]),
            weight_step=float(assist["weight_step_per_bbr_round"]),
            max_duration_ms=int(assist["max_duration_ms"]),
            max_rounds=int(assist["max_rounds"]),
            no_benefit_round=int(assist["no_benefit_round"]),
            minimum_model_gain_ratio=float(assist["minimum_model_gain_ratio"]),
            soft_queue_delay_min_ms=int(guards["soft_queue_delay_min_ms"]),
            soft_queue_delay_min_rtt_ratio=float(
                guards["soft_queue_delay_min_rtt_ratio"]
            ),
            hard_queue_delay_min_ms=int(guards["hard_queue_delay_min_ms"]),
            hard_queue_delay_min_rtt_ratio=float(
                guards["hard_queue_delay_min_rtt_ratio"]
            ),
            max_unrevocable_queue_bytes=int(
                assist["max_unrevocable_queue_bytes"]
            ),
        )


@dataclass(frozen=True)
class Snapshot:
    now_ms: int
    baseline_pacing: int
    baseline_cwnd: int
    model_delivery_rate: int
    srtt_ms: float
    min_rtt_ms: float
    bbr_phase: str
    sample_valid: bool = True
    app_limited: bool = False
    receiver_limited: bool = False
    policy_limited: bool = False
    loss_detected: bool = False
    pto_fired: bool = False
    path_changed: bool = False


@dataclass(frozen=True)
class Decision:
    state: State
    reason: str
    shadow_reason: str
    w: float
    candidate_pacing: int
    final_pacing: int
    final_cwnd: int
    control_applied: bool
    soft_guard: bool
    hard_guard: bool


class BabrReferenceController:
    """Executable reference for P2 replay.

    In OBSERVE, state/W are a shadow trajectory only. They are discarded when
    leaving OBSERVE and never change final transport output.
    """

    def __init__(
        self,
        rules: FrozenRules,
        mode: Mode = Mode.OFF,
        target: int = 0,
        max_rate: Optional[int] = None,
    ) -> None:
        self.rules = rules
        self.mode = mode
        self.target = target
        self.max_rate = max_rate
        self.state = State.BASELINE
        self.w = 0.0
        self.rounds = 0
        self.b_ref: Optional[int] = None
        self.assist_start_ms: Optional[int] = None
        self.assist_deadline_ms: Optional[int] = None

    def set_mode(self, mode: Mode) -> None:
        if mode != self.mode:
            self.mode = mode
            self._clear_assist()

    def set_target(self, target: int) -> None:
        self.target = target

    def set_max_rate(self, max_rate: Optional[int]) -> None:
        self.max_rate = max_rate

    def on_ack(self) -> None:
        """ACK frequency is intentionally not a control clock."""
        return None

    def _clear_assist(self) -> None:
        self.state = State.BASELINE
        self.w = 0.0
        self.rounds = 0
        self.b_ref = None
        self.assist_start_ms = None
        self.assist_deadline_ms = None

    def _target_reason(self) -> Optional[str]:
        if self.target == 0:
            return "TARGET_DISABLED"
        if self.target < self.rules.target_min or self.target > self.rules.target_max:
            return "INVALID_TARGET"
        if self.max_rate is not None and self.max_rate < self.target:
            return "POLICY_LIMITED"
        return None

    def _guards(self, s: Snapshot) -> tuple[Optional[str], bool, bool]:
        if s.path_changed:
            return "PATH_CHANGED", False, False
        if s.app_limited:
            return "APP_LIMITED", False, False
        if s.receiver_limited:
            return "RECEIVER_LIMITED", False, False
        if s.policy_limited:
            return "POLICY_LIMITED", False, False
        if s.loss_detected:
            return "LOSS_DETECTED", False, False
        if s.pto_fired:
            return "PTO_FIRED", False, False
        if s.bbr_phase not in ALLOWED_PHASES:
            return "BBR_PHASE_PROTECTED", False, False
        if not s.sample_valid or s.model_delivery_rate <= 0:
            return "SAMPLE_INVALID", False, False

        qdelay = max(0.0, s.srtt_ms - s.min_rtt_ms)
        soft_threshold = max(
            float(self.rules.soft_queue_delay_min_ms),
            self.rules.soft_queue_delay_min_rtt_ratio * s.min_rtt_ms,
        )
        hard_threshold = max(
            float(self.rules.hard_queue_delay_min_ms),
            self.rules.hard_queue_delay_min_rtt_ratio * s.min_rtt_ms,
        )
        hard = qdelay >= hard_threshold
        soft = qdelay >= soft_threshold
        if hard:
            return "HARD_QUEUE_DELAY", soft, hard
        return None, soft, hard

    def _baseline(
        self,
        s: Snapshot,
        reason: str,
        shadow_reason: Optional[str] = None,
    ) -> Decision:
        return Decision(
            state=self.state,
            reason=reason,
            shadow_reason=shadow_reason or reason,
            w=self.w,
            candidate_pacing=s.baseline_pacing,
            final_pacing=s.baseline_pacing,
            final_cwnd=s.baseline_cwnd,
            control_applied=False,
            soft_guard=False,
            hard_guard=False,
        )

    def on_round(self, s: Snapshot) -> Decision:
        target_reason = self._target_reason()
        if target_reason is not None:
            self._clear_assist()
            return self._baseline(s, target_reason)

        if self.mode == Mode.OFF:
            self._clear_assist()
            return self._baseline(s, "MODE_NOT_LITE")

        guard_reason, soft, hard = self._guards(s)
        if guard_reason is not None:
            self._clear_assist()
            d = self._baseline(
                s,
                "MODE_NOT_LITE" if self.mode == Mode.OBSERVE else guard_reason,
                guard_reason,
            )
            return Decision(
                **{**d.__dict__, "soft_guard": soft, "hard_guard": hard}
            )

        if (
            self.state != State.ASSIST
            and s.model_delivery_rate >= self.rules.target_enter_ratio * self.target
        ):
            self._clear_assist()
            return self._baseline(
                s,
                "MODE_NOT_LITE" if self.mode == Mode.OBSERVE else "TARGET_NEAR",
                "TARGET_NEAR",
            )

        if (
            self.state == State.ASSIST
            and s.model_delivery_rate >= self.rules.target_exit_ratio * self.target
        ):
            self._clear_assist()
            return self._baseline(
                s,
                "MODE_NOT_LITE" if self.mode == Mode.OBSERVE else "TARGET_NEAR",
                "TARGET_NEAR",
            )

        if self.state != State.ASSIST or self.b_ref is None:
            self.state = State.ASSIST
            self.b_ref = s.model_delivery_rate
            self.assist_start_ms = s.now_ms
            self.assist_deadline_ms = s.now_ms + self.rules.max_duration_ms
            self.rounds = 0
            self.w = 0.0

        assert self.b_ref is not None
        assert self.assist_deadline_ms is not None

        if s.now_ms >= self.assist_deadline_ms:
            self._clear_assist()
            return self._baseline(
                s,
                "MODE_NOT_LITE" if self.mode == Mode.OBSERVE else "ASSIST_TIMEOUT",
                "ASSIST_TIMEOUT",
            )

        self.rounds += 1

        if self.rounds >= self.rules.no_benefit_round and (
            s.model_delivery_rate <
            self.rules.minimum_model_gain_ratio * self.b_ref
        ):
            self._clear_assist()
            return self._baseline(
                s,
                "MODE_NOT_LITE" if self.mode == Mode.OBSERVE else "NO_BENEFIT",
                "NO_BENEFIT",
            )

        if self.rounds >= self.rules.max_rounds:
            self._clear_assist()
            return self._baseline(
                s,
                "MODE_NOT_LITE" if self.mode == Mode.OBSERVE else "MAX_ROUNDS",
                "MAX_ROUNDS",
            )

        if not soft:
            self.w = min(1.0, self.w + self.rules.weight_step)
            shadow_reason = "BOUNDED_PROBE"
        else:
            shadow_reason = "SOFT_FREEZE"

        p_cap = min(
            self.target,
            int(self.rules.max_relative_rate_gain * self.b_ref),
        )
        candidate = int(
            self.b_ref + self.w * max(0, p_cap - self.b_ref)
        )
        if self.max_rate is not None:
            candidate = min(candidate, self.max_rate)

        if self.mode == Mode.OBSERVE:
            return Decision(
                state=self.state,
                reason="MODE_NOT_LITE",
                shadow_reason=shadow_reason,
                w=self.w,
                candidate_pacing=candidate,
                final_pacing=s.baseline_pacing,
                final_cwnd=s.baseline_cwnd,
                control_applied=False,
                soft_guard=soft,
                hard_guard=hard,
            )

        return Decision(
            state=self.state,
            reason=shadow_reason,
            shadow_reason=shadow_reason,
            w=self.w,
            candidate_pacing=candidate,
            final_pacing=candidate,
            final_cwnd=s.baseline_cwnd,
            control_applied=True,
            soft_guard=soft,
            hard_guard=hard,
        )



@dataclass(frozen=True)
class PayloadSpan:
    stream_id: int
    offset: int
    length: int


@dataclass(frozen=True)
class AccountingSnapshot:
    actual_socket_sent_bytes: int
    unique_payload_delivered_bytes: int
    sent_packets: int
    loss_events: int
    ack_events: int
    spurious_ack_events: int


@dataclass
class _ReplayPacket:
    actual_socket_bytes: int
    payload: tuple[PayloadSpan, ...]
    state: str = "sent"


class DeliveryAccountingReplay:
    """Deterministic transport-accounting replay for P2.

    This models the accounting contract only. Every successful socket send is
    charged in full, while STREAM payload delivery is deduplicated by
    (stream_id, offset range). An ACK for a packet previously declared lost is
    deliberately accepted as a late/spurious ACK so L06 can prove that payload
    delivery is still counted only once.
    """

    def __init__(self) -> None:
        self._packets: dict[int, _ReplayPacket] = {}
        self._delivered: dict[int, list[tuple[int, int]]] = {}
        self.actual_socket_sent_bytes = 0
        self.unique_payload_delivered_bytes = 0
        self.loss_events = 0
        self.ack_events = 0
        self.spurious_ack_events = 0

    def _insert_unique_range(
        self, stream_id: int, start: int, end: int
    ) -> int:
        if end <= start:
            return 0

        ranges = self._delivered.setdefault(stream_id, [])
        old_total = sum(e - s for s, e in ranges)

        merged: list[tuple[int, int]] = []
        cur_start, cur_end = start, end
        placed = False

        for s, e in ranges:
            if e < cur_start:
                merged.append((s, e))
                continue

            if cur_end < s:
                if not placed:
                    merged.append((cur_start, cur_end))
                    placed = True
                merged.append((s, e))
                continue

            cur_start = min(cur_start, s)
            cur_end = max(cur_end, e)

        if not placed:
            merged.append((cur_start, cur_end))

        merged.sort()
        self._delivered[stream_id] = merged
        new_total = sum(e - s for s, e in merged)
        return max(0, new_total - old_total)

    def send(
        self,
        packet_id: int,
        actual_socket_bytes: int,
        payload: list[PayloadSpan] | tuple[PayloadSpan, ...],
    ) -> AccountingSnapshot:
        if packet_id in self._packets:
            raise ValueError(f"packet_id already sent: {packet_id}")
        if actual_socket_bytes < 0:
            raise ValueError("actual_socket_bytes must be non-negative")

        spans = tuple(payload)
        for span in spans:
            if span.offset < 0 or span.length < 0:
                raise ValueError("payload offset/length must be non-negative")

        self._packets[packet_id] = _ReplayPacket(
            actual_socket_bytes=actual_socket_bytes,
            payload=spans,
        )
        self.actual_socket_sent_bytes += actual_socket_bytes
        return self.snapshot()

    def loss(self, packet_id: int) -> AccountingSnapshot:
        packet = self._packets[packet_id]
        if packet.state == "acked":
            raise ValueError("acked packet cannot become lost")
        if packet.state != "lost":
            packet.state = "lost"
            self.loss_events += 1
        return self.snapshot()

    def ack(self, packet_id: int) -> AccountingSnapshot:
        packet = self._packets[packet_id]
        if packet.state == "acked":
            return self.snapshot()

        if packet.state == "lost":
            self.spurious_ack_events += 1

        packet.state = "acked"
        self.ack_events += 1

        for span in packet.payload:
            delta = self._insert_unique_range(
                span.stream_id,
                span.offset,
                span.offset + span.length,
            )
            self.unique_payload_delivered_bytes += delta

        return self.snapshot()

    def snapshot(self) -> AccountingSnapshot:
        return AccountingSnapshot(
            actual_socket_sent_bytes=self.actual_socket_sent_bytes,
            unique_payload_delivered_bytes=self.unique_payload_delivered_bytes,
            sent_packets=len(self._packets),
            loss_events=self.loss_events,
            ack_events=self.ack_events,
            spurious_ack_events=self.spurious_ack_events,
        )


def run_accounting_trace(trace: dict[str, Any]) -> list[AccountingSnapshot]:
    replay = DeliveryAccountingReplay()
    snapshots: list[AccountingSnapshot] = []

    for event in trace["events"]:
        kind = event["type"]
        packet_id = int(event["packet_id"])

        if kind == "send":
            payload = [
                PayloadSpan(
                    stream_id=int(span["stream_id"]),
                    offset=int(span["offset"]),
                    length=int(span["length"]),
                )
                for span in event.get("payload", [])
            ]
            snapshot = replay.send(
                packet_id=packet_id,
                actual_socket_bytes=int(event["actual_socket_bytes"]),
                payload=payload,
            )
        elif kind == "loss":
            snapshot = replay.loss(packet_id)
        elif kind == "ack":
            snapshot = replay.ack(packet_id)
        else:
            raise ValueError(f"unknown accounting event type: {kind}")

        snapshots.append(snapshot)

    return snapshots

def load_rules(path: str | Path) -> FrozenRules:
    contract = json.loads(Path(path).read_text(encoding="utf-8"))
    if contract.get("schema_version") != "p1-baseline-v4":
        raise ValueError("P2 requires schema_version=p1-baseline-v4")
    return FrozenRules.from_contract(contract)
