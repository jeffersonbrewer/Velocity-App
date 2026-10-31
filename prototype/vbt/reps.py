"""Split a set into reps, each with an eccentric (down) and concentric (up) phase."""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from .kinematics import Kinematics


@dataclass
class Phase:
    start: int  # index of the first sample
    end: int    # index of the last sample (inclusive)

    def slice(self) -> slice:
        return slice(self.start, self.end + 1)


@dataclass
class Rep:
    number: int
    concentric: Phase
    eccentric: Phase | None


# Exercises that start with the lowering phase (squat, bench) versus the lifting phase (deadlift).
CONCENTRIC_FIRST = {"deadlift", "rdl_from_floor", "clean", "snatch", "power_clean", "row", "pendlay_row"}


def segment(kin: Kinematics, exercise: str = "squat", v_thresh: float = 0.05,
            min_rom: float = 0.10, merge_gap_s: float = 0.25) -> list[Rep]:
    """Find reps from the vertical velocity signal.

    A phase is a stretch where the bar moves the same way faster than v_thresh,
    extended out to where velocity crosses zero, covering at least min_rom meters.
    Brief slowdowns inside a phase (a sticking point) shorter than merge_gap_s do
    not split it.
    """
    up = _phases(kin, +1, v_thresh, min_rom, merge_gap_s)
    down = _phases(kin, -1, v_thresh, min_rom, merge_gap_s)

    concentric_first = exercise.lower() in CONCENTRIC_FIRST
    max_link = int(round(1.0 * kin.fps))  # phases more than 1 s apart are not one rep
    reps, used = [], set()
    for i, con in enumerate(up):
        ecc = None
        if concentric_first:
            options = [k for k, d in enumerate(down) if k not in used and 0 <= d.start - con.end <= max_link]
            if options:
                ecc = down[min(options, key=lambda k: down[k].start)]
                used.add(down.index(ecc))
        else:
            options = [k for k, d in enumerate(down) if k not in used and 0 <= con.start - d.end <= max_link]
            if options:
                ecc = down[max(options, key=lambda k: down[k].end)]
                used.add(down.index(ecc))
        reps.append(Rep(number=i + 1, concentric=con, eccentric=ecc))
    return reps


def _phases(kin: Kinematics, sign: int, v_thresh: float, min_rom: float, merge_gap_s: float) -> list[Phase]:
    v = kin.v * sign
    moving = v > v_thresh
    runs = _runs(moving)

    # Merge runs separated by a short gap in which the bar never reversed direction.
    merge_gap = int(round(merge_gap_s * kin.fps))
    merged: list[list[int]] = []
    for s, e in runs:
        if merged:
            ps, pe = merged[-1]
            gap = v[pe + 1:s]
            if s - pe - 1 <= merge_gap and (gap > -v_thresh).all():
                merged[-1][1] = e
                continue
        merged.append([s, e])

    phases = []
    n = len(v)
    for s, e in merged:
        # Extend to the zero crossings so the phase covers the whole movement.
        while s > 0 and v[s - 1] > 0:
            s -= 1
        while e < n - 1 and v[e + 1] > 0:
            e += 1
        if sign * (kin.y[e] - kin.y[s]) >= min_rom:
            phases.append(Phase(s, e))
    return phases


def _runs(mask: np.ndarray) -> list[tuple[int, int]]:
    padded = np.concatenate([[False], mask, [False]])
    diff = np.diff(padded.astype(int))
    starts = np.flatnonzero(diff == 1)
    ends = np.flatnonzero(diff == -1) - 1
    return list(zip(starts.tolist(), ends.tolist()))
