"""End to end: render a short simulated set, analyze the video, compare with the known motion."""

import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "tools"))

from make_synthetic import RepSpec, render, truth  # noqa: E402
from vbt.analyze import analyze_video  # noqa: E402


def test_video_matches_known_motion(tmp_path):
    spec = [RepSpec(0.9, 0.6, 0.55), RepSpec(1.0, 0.9, 0.54)]
    path = str(tmp_path / "set.mp4")
    render(spec, path, fps=120)
    expected = truth(spec, 100)["set"]["reps"]

    a = analyze_video(path, "squat", 100)
    got = a.set_metrics.reps
    assert len(got) == 2
    assert a.track.radius_px == pytest.approx(120, abs=1)
    for g, e in zip(got, expected):
        assert g.mean_velocity == pytest.approx(e["mean_velocity"], abs=0.02)
        assert g.peak_velocity == pytest.approx(e["peak_velocity"], abs=0.05)
        assert g.concentric_distance == pytest.approx(e["concentric_distance"], abs=0.01)
        assert g.eccentric_distance == pytest.approx(e["eccentric_distance"], abs=0.01)
