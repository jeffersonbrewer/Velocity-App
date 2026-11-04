"""Load-velocity profiles and estimated 1RM.

A lifter's mean velocity falls roughly in a straight line as load rises. Fitting
that line from a few sets and reading off the load at the 1RM velocity (the
minimum velocity threshold, MVT) estimates the 1RM.

The defaults below are group averages from studies using linear transducers.
Individual MVTs vary widely, and the camera may read slightly differently from a
transducer, so a lifter's own MVT, taken from heavy singles recorded with this
system, replaces the default as soon as one exists.

Example:
    python -m vbt.profile results/*.json --exercise squat
"""

from __future__ import annotations

import argparse
import json
from dataclasses import dataclass
from datetime import date, timedelta
from pathlib import Path

import numpy as np


@dataclass(frozen=True)
class Mvt:
    velocity: float   # mean concentric velocity at 1RM, m/s
    source: str
    checked: bool     # True when the value was confirmed against the paper or a direct summary of it


# Exercises without a dependable 1RM velocity (Olympic lifts, kettlebell and dumbbell
# work) are left out on purpose, so no estimated 1RM is shown for them.
DEFAULT_MVT: dict[str, Mvt] = {
    "back_squat": Mvt(0.30, "Full squat (Smith machine) mean propulsive velocity 0.30 +/- 0.04 m/s "
                            "(Conceicao et al. 2016); trained women 0.36 m/s (Caven et al. 2020, GymAware)", True),
    "front_squat": Mvt(0.33, "Less established; no study checked", False),
    "bench_press": Mvt(0.17, "0.17 m/s recommended across studies (Garcia-Ramos et al. 2020, PeerJ); "
                             "powerlifters as low as 0.10 m/s (Helms et al. 2017)", True),
    "overhead_press": Mvt(0.24, "0.24 m/s from Fahs et al. 2019, as used by Soriano et al. 2022; "
                                "original paper not checked", False),
    "deadlift": Mvt(0.15, "Not checked against a study", False),
    "sumo_deadlift": Mvt(0.15, "Not checked against a study", False),
    "trap_bar_deadlift": Mvt(0.15, "GymAware's 1RM velocity for the trap bar deadlift (supplied by Jefferson); "
                                   "no study checked", False),
    "pull_up": Mvt(0.20, "0.20 +/- 0.05 m/s (Sanchez-Moreno et al. 2017)", True),
    "prone_bench_pull": Mvt(0.48, "Mean velocity 0.479 +/- 0.032 m/s, free weight "
                                  "(Garcia-Ramos et al. 2019, PLOS ONE)", True),
    "hip_thrust": Mvt(0.25, "Less established; no study checked", False),
}
ALIASES = {"squat": "back_squat", "bench": "bench_press", "ohp": "overhead_press",
           "press": "overhead_press", "chin_up": "pull_up", "bench_pull": "prone_bench_pull",
           "row": "prone_bench_pull",
           "trap_bar": "trap_bar_deadlift", "hex_bar": "trap_bar_deadlift", "hex_bar_deadlift": "trap_bar_deadlift"}


def resolve_mvt(exercise: str, personal: dict[str, float] | None = None) -> tuple[float, str] | None:
    """Return (mvt, where it came from). A personal MVT always wins over the default."""
    key = ALIASES.get(exercise.lower(), exercise.lower())
    if personal and key in personal:
        return personal[key], "personal"
    if key in DEFAULT_MVT:
        return DEFAULT_MVT[key].velocity, "default"
    return None


def personal_mvt(single_velocities: list[float]) -> float:
    """A lifter's MVT from the mean velocities of successful 1RM (or near-1RM) singles.

    Uses the slowest successful single, since that is closest to a true maximum.
    """
    if not single_velocities:
        raise ValueError("Need at least one successful heavy single.")
    return float(min(single_velocities))


@dataclass
class LoadVelocityProfile:
    slope: float       # m/s per kg (negative)
    intercept: float   # m/s at 0 kg
    r2: float
    n_loads: int
    load_range_kg: tuple[float, float]

    def velocity_at(self, load_kg: float) -> float:
        return self.intercept + self.slope * load_kg

    def load_at(self, velocity: float) -> float:
        return (velocity - self.intercept) / self.slope


def fit_profile(loads_kg: list[float], mean_velocities: list[float]) -> LoadVelocityProfile:
    """Least-squares straight line of mean velocity against load."""
    x, y = np.asarray(loads_kg, float), np.asarray(mean_velocities, float)
    if len(np.unique(x)) < 2:
        raise ValueError("Need sets at two or more different loads.")
    slope, intercept = np.polyfit(x, y, 1)
    if slope >= 0:
        raise ValueError("Velocity does not fall as load rises; check the sets.")
    pred = intercept + slope * x
    ss_res = float(((y - pred) ** 2).sum())
    ss_tot = float(((y - y.mean()) ** 2).sum())
    r2 = 1 - ss_res / ss_tot if ss_tot > 0 else 1.0
    return LoadVelocityProfile(float(slope), float(intercept), r2, int(len(np.unique(x))),
                               (float(x.min()), float(x.max())))


@dataclass
class OneRmEstimate:
    one_rm_kg: float
    mvt: float
    mvt_source: str    # "personal" or "default"
    profile: LoadVelocityProfile
    warnings: list[str]


def estimate_1rm(exercise: str, loads_kg: list[float], mean_velocities: list[float],
                 personal: dict[str, float] | None = None, mvt: float | None = None) -> OneRmEstimate:
    if mvt is not None:
        source = "given"
    else:
        found = resolve_mvt(exercise, personal)
        if found is None:
            raise ValueError(f"No 1RM velocity for '{exercise}'. Record heavy singles to set a personal one.")
        mvt, source = found
    prof = fit_profile(loads_kg, mean_velocities)
    one_rm = prof.load_at(mvt)

    warnings = []
    if prof.n_loads < 4:
        warnings.append(f"Only {prof.n_loads} loads; 4 or more spread across light to heavy give a steadier line.")
    if prof.r2 < 0.9:
        warnings.append(f"The points fit a line loosely (R^2 {prof.r2:.2f}); the estimate is less reliable.")
    if prof.load_range_kg[1] < 0.8 * one_rm:
        warnings.append("The heaviest set is under about 80% of the estimate, so the line is extended a long way.")
    if source == "default":
        warnings.append("Uses the group-average 1RM velocity. Record heavy singles to personalize it.")
    return OneRmEstimate(float(one_rm), float(mvt), source, prof, warnings)


RETEST_INTERVAL_DAYS = 28


def retest_due(last_test: date | None, today: date, block_end: date | None = None,
               interval_days: int = RETEST_INTERVAL_DAYS) -> str | None:
    """Return why a new profile test is suggested, or None. The app only suggests; it never tests on its own."""
    if last_test is None:
        return "No profile test yet for this exercise."
    if block_end is not None and last_test < block_end <= today:
        return "The training block has ended."
    if today - last_test >= timedelta(days=interval_days):
        return f"Last profile test was {(today - last_test).days} days ago."
    return None


def main(argv=None) -> None:
    p = argparse.ArgumentParser(description="Estimate 1RM from analyzed sets of one exercise.")
    p.add_argument("results", nargs="+", help="JSON files from vbt.analyze")
    p.add_argument("--exercise", required=True)
    p.add_argument("--mvt", type=float, help="1RM velocity to use instead of the default")
    p.add_argument("--use", choices=["best", "first"], default="best",
                   help="Which rep of each set represents the load (default: fastest rep)")
    p.add_argument("--include-untagged", action="store_true",
                   help="Also use sets not tagged as profile tests (not recommended)")
    args = p.parse_args(argv)

    loads, vels, singles, skipped = [], [], [], 0
    for path in args.results:
        data = json.loads(Path(path).read_text())
        if not (data.get("profile_test") or args.include_untagged):
            skipped += 1
            continue
        s = data["set"]
        mvs = [r["mean_velocity"] for r in s["reps"]]
        if data.get("max_single"):
            singles.append(min(mvs))
        loads.append(s["load_kg"])
        vels.append(max(mvs) if args.use == "best" else mvs[0])
    if skipped:
        print(f"Skipped {skipped} working set(s) not tagged as profile tests.")
    personal = None
    if singles and args.mvt is None:
        personal = {ALIASES.get(args.exercise.lower(), args.exercise.lower()): personal_mvt(singles)}
    est = estimate_1rm(args.exercise, loads, vels, personal=personal, mvt=args.mvt)
    prof = est.profile
    print(f"Profile: MV = {prof.intercept:.3f} {prof.slope:+.5f} x load (R^2 {prof.r2:.3f}, {prof.n_loads} loads)")
    print(f"1RM velocity {est.mvt:.2f} m/s ({est.mvt_source}) -> estimated 1RM {est.one_rm_kg:.1f} kg")
    for w in est.warnings:
        print(f"Note: {w}")


if __name__ == "__main__":
    main()
