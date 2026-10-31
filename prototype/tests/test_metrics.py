import sys
from pathlib import Path

import numpy as np
import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "tools"))

from make_synthetic import RepSpec, default_reps, truth  # noqa: E402
from vbt import compare, kinematics, metrics, reps  # noqa: E402


def test_exact_trajectory_gives_exact_metrics():
    t = truth(default_reps(), load_kg=100)
    got = t["set"]["reps"]
    assert len(got) == 5
    for r, mv, pv in zip(got, t["exact_mean_velocity"], t["exact_peak_velocity"]):
        assert r["mean_velocity"] == pytest.approx(mv, abs=0.005)
        assert r["peak_velocity"] == pytest.approx(pv, abs=0.005)
        assert r["eccentric_distance"] == pytest.approx(r["concentric_distance"], abs=0.002)


def test_power_is_force_times_velocity():
    # A bar lifted at constant speed: force equals the weight, so power = m * g * v.
    fps, v0 = 1000.0, 0.5
    t = np.arange(0, 2, 1 / fps)
    y = np.where(t < 0.5, 0, np.where(t < 1.5, v0 * (t - 0.5), v0))
    kin = kinematics.from_position(t, np.zeros_like(t), y, fps, cutoff_hz=None)
    found = reps.segment(kin, exercise="deadlift")
    assert len(found) == 1
    m = metrics.rep_metrics(kin, found[0], mass_kg=100)
    assert m.mean_velocity == pytest.approx(v0, abs=0.01)
    assert m.mean_power == pytest.approx(100 * metrics.G * v0, rel=0.03)


def test_velocity_loss_and_threshold():
    t = truth(default_reps(), load_kg=100)
    rep_objs = [metrics.RepMetrics(**r) for r in t["set"]["reps"]]
    s = metrics.set_summary("squat", 100, 100, rep_objs, velocity_loss_threshold_pct=20)
    expected = (rep_objs[0].mean_velocity - rep_objs[-1].mean_velocity) / rep_objs[0].mean_velocity * 100
    assert s.velocity_loss_pct == pytest.approx(expected)
    assert s.threshold_reached_at_rep == 3  # 0.917 -> 0.730 is a 20.4% loss
    assert s.volume_load_kg == 500


def test_unrack_wobble_is_not_a_rep():
    spec = [RepSpec(0.9, 0.7, 0.05), RepSpec(0.9, 0.7, 0.50)]
    assert len(truth(spec, 100)["set"]["reps"]) == 1


def test_agreement_statistics():
    ref = np.array([0.5, 0.6, 0.7, 0.8, 0.9])
    s = compare.agreement(ref + 0.02, ref)
    assert s["bias"] == pytest.approx(0.02)
    assert s["icc"] > 0.9
    assert s["r"] == pytest.approx(1.0)
