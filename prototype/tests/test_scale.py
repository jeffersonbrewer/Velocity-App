import numpy as np

from vbt.kinematics import from_track, radius_vs_height
from vbt.tracking import Track


def _track(y_px, r_px, fps=120.0):
    n = len(y_px)
    return Track(fps=fps, t=np.arange(n) / fps, x_px=np.full(n, 500.0), y_px=y_px, r_px=r_px,
                 roundness=1.0, frame_size=(1080, 1920))


def test_tilted_camera_scale_is_corrected():
    # Plate rises 500 mm. With a tilted camera it looks 7% smaller at the top than at the floor.
    d = 0.45
    # Lifter sets up for a while first, so most frames have the plate on the floor.
    true_y = np.r_[np.zeros(400), 0.25 * (1 - np.cos(np.linspace(0, np.pi, 300)))]  # m, 0 -> 0.5
    # r(y_px) = a + b*y_px. Choose floor at y_px=1400 with r=256 and r=238 at the top.
    # Build the pixel path by integrating dy_px = dy_m * 2 r / D.
    y_px = np.empty_like(true_y); y_px[0] = 1400.0
    r = lambda y: 256.0 + (y - 1400.0) * 0.033
    for i in range(1, len(true_y)):
        y_px[i] = y_px[i - 1] - (true_y[i] - true_y[i - 1]) * 2 * r(y_px[i - 1]) / d
    r_px = r(y_px)
    fit = radius_vs_height(y_px, r_px)
    assert fit is not None
    kin = from_track(_track(y_px, r_px), plate_diameter_m=d, cutoff_hz=None)
    assert abs(kin.y[-1] - 0.5) < 0.003
    fixed = from_track(_track(y_px, r_px), plate_diameter_m=d, cutoff_hz=None, position_scale=False)
    assert abs(fixed.y[-1] - 0.5) > 0.01  # one scale for the whole clip is visibly off


def test_level_camera_uses_single_scale():
    y_px = np.linspace(1400, 900, 400)
    assert radius_vs_height(y_px, np.full(400, 250.0)) is None
