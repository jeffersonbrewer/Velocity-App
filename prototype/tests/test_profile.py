import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from vbt import profile  # noqa: E402


def test_fit_and_estimate_on_a_known_line():
    # MV = 1.62 - 0.008 x load, so a 0.30 m/s 1RM velocity gives 165 kg.
    loads = [60, 80, 100, 120, 140]
    mvs = [1.62 - 0.008 * x for x in loads]
    est = profile.estimate_1rm("squat", loads, mvs)
    assert est.one_rm_kg == pytest.approx(165, abs=0.01)
    assert est.mvt_source == "default"
    assert est.profile.r2 == pytest.approx(1.0)


def test_personal_mvt_overrides_default():
    loads = [60, 80, 100, 120, 140]
    mvs = [1.62 - 0.008 * x for x in loads]
    est = profile.estimate_1rm("back_squat", loads, mvs, personal={"back_squat": 0.26})
    assert est.mvt_source == "personal"
    assert est.one_rm_kg == pytest.approx(170, abs=0.01)
    assert profile.personal_mvt([0.27, 0.24, 0.29]) == 0.24


def test_no_estimate_without_a_1rm_velocity():
    with pytest.raises(ValueError):
        profile.estimate_1rm("kettlebell_swing", [16, 24, 32], [1.2, 1.0, 0.8])
    # A personal value makes it possible.
    est = profile.estimate_1rm("kettlebell_swing", [16, 24, 32], [1.2, 1.0, 0.8],
                               personal={"kettlebell_swing": 0.5})
    assert est.one_rm_kg == pytest.approx(44, abs=0.01)


def test_warnings_for_thin_or_light_data():
    est = profile.estimate_1rm("bench_press", [40, 50], [0.9, 0.8])
    text = " ".join(est.warnings)
    assert "Only 2 loads" in text
    assert "extended a long way" in text


def test_rejects_rising_velocity():
    with pytest.raises(ValueError):
        profile.fit_profile([60, 80], [0.8, 0.9])
