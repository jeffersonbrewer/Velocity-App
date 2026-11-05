"""Turn a pixel track into filtered position, velocity and acceleration in SI units."""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np
from scipy.signal import butter, filtfilt

from .tracking import Track

# Standard bumper and competition plates (10 to 25 kg) are 450 mm across.
STANDARD_PLATE_DIAMETER_M = 0.45


@dataclass
class Kinematics:
    t: np.ndarray   # s
    x: np.ndarray   # m, horizontal (positive = right in the image)
    y: np.ndarray   # m, vertical (positive = up)
    v: np.ndarray   # m/s, vertical velocity
    a: np.ndarray   # m/s^2, vertical acceleration
    fps: float
    m_per_px: float


def fill_gaps(sig: np.ndarray, max_gap: int) -> np.ndarray:
    """Linearly interpolate NaN runs no longer than max_gap samples.

    Longer gaps are left as NaN and must be handled by the caller.
    """
    out = sig.copy()
    isnan = np.isnan(out)
    if not isnan.any():
        return out
    idx = np.arange(len(out))
    good = ~isnan
    if good.sum() < 2:
        return out
    interp = np.interp(idx, idx[good], out[good])
    # Only fill runs that are short enough.
    run_start = None
    for i, bad in enumerate(np.append(isnan, False)):
        if bad and run_start is None:
            run_start = i
        elif not bad and run_start is not None:
            if i - run_start <= max_gap and run_start > 0 and i < len(out):
                out[run_start:i] = interp[run_start:i]
            run_start = None
    return out


def lowpass(sig: np.ndarray, fps: float, cutoff_hz: float, order: int = 4) -> np.ndarray:
    """Zero-lag Butterworth low-pass filter."""
    nyq = fps / 2
    if cutoff_hz >= nyq * 0.95:
        return sig.copy()
    b, a = butter(order, cutoff_hz / nyq)
    return filtfilt(b, a, sig, padlen=min(3 * max(len(a), len(b)), len(sig) - 1))


def from_track(track: Track, plate_diameter_m: float = STANDARD_PLATE_DIAMETER_M,
               cutoff_hz: float = 8.0, max_gap_s: float = 0.1) -> Kinematics:
    """Scale the track to meters using the plate's known diameter, then filter and differentiate."""
    m_per_px = plate_diameter_m / (2 * track.radius_px)
    max_gap = max(1, int(round(max_gap_s * track.fps)))
    xp = fill_gaps(track.x_px, max_gap)
    yp = fill_gaps(track.y_px, max_gap)

    good = ~np.isnan(yp)
    if not good.any():
        raise ValueError("The plate was not tracked in any frame.")
    # Trim leading and trailing frames without a plate; interior long gaps stop analysis.
    first, last = np.argmax(good), len(good) - np.argmax(good[::-1])
    if np.isnan(yp[first:last]).any():
        raise ValueError("Tracking was lost for longer than max_gap_s in the middle of the clip.")
    t = track.t[first:last]
    y = -(yp[first:last] - yp[first]) * m_per_px  # image y points down; flip so up is positive
    x = (xp[first:last] - xp[first]) * m_per_px
    return from_position(t, x, y, track.fps, cutoff_hz, m_per_px)


def from_position(t: np.ndarray, x: np.ndarray, y: np.ndarray, fps: float,
                  cutoff_hz: float | None = 8.0, m_per_px: float = float("nan")) -> Kinematics:
    """Filter a position signal (meters) and differentiate it. cutoff_hz=None skips filtering."""
    if cutoff_hz:
        y = lowpass(y, fps, cutoff_hz)
        x = lowpass(x, fps, cutoff_hz)
    dt = 1.0 / fps
    v = np.gradient(y, dt)
    a = np.gradient(v, dt)
    return Kinematics(t=t, x=x, y=y, v=v, a=a, fps=fps, m_per_px=m_per_px)
