"""Rep, set, exercise and session metrics from kinematics and load."""

from __future__ import annotations

from dataclasses import asdict, dataclass, field

import numpy as np

from .kinematics import Kinematics
from .reps import Rep

G = 9.81

# Share of body mass counted as moving with the bar for system power. Squat and deadlift
# values weight each segment by its travel relative to the bar: head, arms and trunk move
# about as far as the bar, thighs about half, shanks and feet barely at all.
BODY_MASS_FRACTION = {
    "squat": 0.80, "back_squat": 0.80, "front_squat": 0.80, "box_squat": 0.80,
    "deadlift": 0.80, "sumo_deadlift": 0.80, "trap_bar_deadlift": 0.80,
    "pull_up": 1.0, "chin_up": 1.0, "dip": 1.0,
}
DEFAULT_BODY_MASS_FRACTION = 1.0


def body_mass_fraction_for(exercise: str) -> float:
    return BODY_MASS_FRACTION.get(exercise.lower(), DEFAULT_BODY_MASS_FRACTION)


@dataclass
class RepMetrics:
    rep: int
    mean_velocity: float              # m/s, concentric
    mean_propulsive_velocity: float   # m/s, concentric until the bar decelerates faster than gravity
    peak_velocity: float              # m/s
    time_to_peak_velocity: float      # s from concentric start
    mean_power: float                 # W, concentric, bar load only
    peak_power: float                 # W, bar load only
    concentric_distance: float        # m
    concentric_duration: float        # s
    eccentric_distance: float | None  # m
    eccentric_duration: float | None  # s
    eccentric_mean_velocity: float | None  # m/s, as a positive number
    eccentric_peak_velocity: float | None  # m/s, as a positive number
    horizontal_displacement: float    # m, largest left-right bar travel during the concentric
    # Bar load plus the moving share of body mass. None when no body mass is given.
    system_mean_power: float | None = None  # W
    system_peak_power: float | None = None  # W


def rep_metrics(kin: Kinematics, rep: Rep, load_kg: float, body_mass_kg: float | None = None,
                body_mass_fraction: float = 1.0) -> RepMetrics:
    """Compute one rep's metrics.

    Bar power uses load_kg alone. When body_mass_kg is given, system power also counts
    body_mass_fraction of it as moving with the bar (1.0 for pull-ups and dips; squats and
    deadlifts are often set lower, since the shanks and feet barely move).
    """
    c = rep.concentric.slice()
    v, a = kin.v[c], kin.a[c]
    dt = 1.0 / kin.fps
    power = load_kg * (a + G) * v
    system_power = None
    if body_mass_kg:
        system_power = (load_kg + body_mass_kg * body_mass_fraction) * (a + G) * v
    i_peak = int(np.argmax(v))

    # Propulsive phase ends the first time after peak velocity that the bar decelerates faster than g.
    braking = np.flatnonzero(a[i_peak:] < -G)
    prop_end = i_peak + int(braking[0]) if braking.size else len(v)
    mpv = float(np.mean(v[:max(prop_end, 1)]))

    ecc = rep.eccentric
    if ecc is not None:
        e = ecc.slice()
        ev = -kin.v[e]
        ecc_dist = float(kin.y[ecc.start] - kin.y[ecc.end])
        ecc_dur = (ecc.end - ecc.start) * dt
        ecc_mean, ecc_peak = float(np.mean(ev)), float(np.max(ev))
    else:
        ecc_dist = ecc_dur = ecc_mean = ecc_peak = None

    xs = kin.x[c]
    return RepMetrics(
        rep=rep.number,
        mean_velocity=float(np.mean(v)),
        mean_propulsive_velocity=mpv,
        peak_velocity=float(v[i_peak]),
        time_to_peak_velocity=i_peak * dt,
        mean_power=float(np.mean(power)),
        peak_power=float(np.max(power)),
        concentric_distance=float(kin.y[rep.concentric.end] - kin.y[rep.concentric.start]),
        concentric_duration=(rep.concentric.end - rep.concentric.start) * dt,
        eccentric_distance=ecc_dist,
        eccentric_duration=ecc_dur,
        eccentric_mean_velocity=ecc_mean,
        eccentric_peak_velocity=ecc_peak,
        horizontal_displacement=float(np.max(xs) - np.min(xs)),
        system_mean_power=float(np.mean(system_power)) if system_power is not None else None,
        system_peak_power=float(np.max(system_power)) if system_power is not None else None,
    )


@dataclass
class SetMetrics:
    exercise: str
    load_kg: float
    system_mass_kg: float         # load plus the counted share of body mass
    reps: list[RepMetrics]
    rep_count: int
    mean_velocity: float          # average of rep mean velocities
    best_mean_velocity: float
    first_rep_mean_velocity: float
    last_rep_mean_velocity: float
    velocity_loss_pct: float      # (best - last) / best
    mean_peak_velocity: float
    peak_velocity: float          # highest rep peak velocity
    mean_power: float             # average of rep mean powers
    best_mean_power: float
    mean_peak_power: float
    peak_power: float             # highest rep peak power
    total_concentric_distance: float
    total_eccentric_distance: float
    mean_concentric_distance: float
    mean_eccentric_distance: float | None
    volume_load_kg: float         # reps x load
    system_mean_power: float | None = None       # average of rep system mean powers
    system_peak_power: float | None = None       # highest rep system peak power
    velocity_loss_threshold_pct: float | None = None
    threshold_reached_at_rep: int | None = None  # first rep whose loss passed the threshold
    below_target_reps: list[int] = field(default_factory=list)


def set_summary(exercise: str, load_kg: float, system_mass_kg: float, reps: list[RepMetrics],
                velocity_loss_threshold_pct: float | None = None,
                target_mean_velocity: tuple[float, float] | None = None) -> SetMetrics:
    if not reps:
        raise ValueError("No reps were detected in this set.")
    mv = np.array([r.mean_velocity for r in reps])
    pv = np.array([r.peak_velocity for r in reps])
    mp = np.array([r.mean_power for r in reps])
    pp = np.array([r.peak_power for r in reps])
    cd = np.array([r.concentric_distance for r in reps])
    ed = np.array([r.eccentric_distance for r in reps if r.eccentric_distance is not None])

    best = float(mv.max())
    loss_by_rep = (np.maximum.accumulate(mv) - mv) / np.maximum.accumulate(mv) * 100
    reached = None
    if velocity_loss_threshold_pct is not None:
        over = np.flatnonzero(loss_by_rep >= velocity_loss_threshold_pct)
        reached = int(reps[over[0]].rep) if over.size else None
    below = []
    if target_mean_velocity is not None:
        lo, hi = target_mean_velocity
        below = [r.rep for r in reps if not lo <= r.mean_velocity <= hi]
    has_system = reps[0].system_mean_power is not None

    return SetMetrics(
        exercise=exercise, load_kg=load_kg, system_mass_kg=system_mass_kg, reps=reps,
        rep_count=len(reps),
        mean_velocity=float(mv.mean()), best_mean_velocity=best,
        first_rep_mean_velocity=float(mv[0]), last_rep_mean_velocity=float(mv[-1]),
        velocity_loss_pct=float((best - mv[-1]) / best * 100),
        mean_peak_velocity=float(pv.mean()), peak_velocity=float(pv.max()),
        mean_power=float(mp.mean()), best_mean_power=float(mp.max()),
        mean_peak_power=float(pp.mean()), peak_power=float(pp.max()),
        total_concentric_distance=float(cd.sum()),
        total_eccentric_distance=float(ed.sum()) if ed.size else 0.0,
        mean_concentric_distance=float(cd.mean()),
        mean_eccentric_distance=float(ed.mean()) if ed.size else None,
        volume_load_kg=float(load_kg * len(reps)),
        system_mean_power=float(np.mean([r.system_mean_power for r in reps])) if has_system else None,
        system_peak_power=float(max(r.system_peak_power for r in reps)) if has_system else None,
        velocity_loss_threshold_pct=velocity_loss_threshold_pct,
        threshold_reached_at_rep=reached,
        below_target_reps=below,
    )


@dataclass
class ExerciseSummary:
    exercise: str
    set_count: int
    rep_count: int
    mean_velocity: float       # average over every rep of the exercise
    peak_velocity: float
    mean_power: float
    peak_power: float
    total_concentric_distance: float
    total_eccentric_distance: float
    volume_load_kg: float
    system_mean_power: float | None = None
    system_peak_power: float | None = None


def exercise_summary(sets: list[SetMetrics]) -> ExerciseSummary:
    reps = [r for s in sets for r in s.reps]
    return ExerciseSummary(
        exercise=sets[0].exercise,
        set_count=len(sets),
        rep_count=len(reps),
        mean_velocity=float(np.mean([r.mean_velocity for r in reps])),
        peak_velocity=float(max(r.peak_velocity for r in reps)),
        mean_power=float(np.mean([r.mean_power for r in reps])),
        peak_power=float(max(r.peak_power for r in reps)),
        total_concentric_distance=float(sum(s.total_concentric_distance for s in sets)),
        total_eccentric_distance=float(sum(s.total_eccentric_distance for s in sets)),
        volume_load_kg=float(sum(s.volume_load_kg for s in sets)),
        system_mean_power=(float(np.mean([r.system_mean_power for r in reps]))
                           if all(r.system_mean_power is not None for r in reps) else None),
        system_peak_power=(float(max(r.system_peak_power for r in reps))
                           if all(r.system_peak_power is not None for r in reps) else None),
    )


def session_volume(exercises: list[ExerciseSummary]) -> float:
    return float(sum(e.volume_load_kg for e in exercises))


def to_dict(obj) -> dict:
    return asdict(obj)
