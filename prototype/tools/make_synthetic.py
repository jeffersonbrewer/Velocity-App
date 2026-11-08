"""Render a simulated side-view video of a set where the true bar motion is known exactly.

Used to check the analysis end to end before real footage exists. The plate is drawn
with sub-pixel placement, slight rotation, motion blur, sensor noise and video
compression, so the tracker sees something close to a real clip.

Example:
    python tools/make_synthetic.py --fps 240 --out synthetic/squat_240.mp4
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import asdict, dataclass
from pathlib import Path

import cv2
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from vbt import kinematics, metrics, reps  # noqa: E402

PLATE_DIAMETER_M = 0.45
TRUTH_RATE = 4000.0  # Hz used to sample the exact trajectory


@dataclass
class RepSpec:
    eccentric_s: float
    concentric_s: float
    rom_m: float


def default_reps() -> list[RepSpec]:
    """Five squat reps that slow down rep to rep, like a set taken near failure."""
    return [RepSpec(0.9, 0.60, 0.55), RepSpec(0.9, 0.66, 0.55), RepSpec(0.95, 0.74, 0.54),
            RepSpec(1.0, 0.84, 0.54), RepSpec(1.0, 0.98, 0.53)]


def min_jerk(tau: np.ndarray) -> np.ndarray:
    tau = np.clip(tau, 0, 1)
    return 10 * tau ** 3 - 15 * tau ** 4 + 6 * tau ** 5


def build_trajectory(spec: list[RepSpec], lead_s=0.6, bottom_pause_s=0.08, top_pause_s=0.4, tail_s=0.6):
    """Return segment list [(t0, t1, y0, y1)] and total duration. y is meters above the start."""
    segs, t = [], 0.0
    segs.append((t, t + lead_s, 0.0, 0.0)); t += lead_s
    for r in spec:
        segs.append((t, t + r.eccentric_s, 0.0, -r.rom_m)); t += r.eccentric_s
        segs.append((t, t + bottom_pause_s, -r.rom_m, -r.rom_m)); t += bottom_pause_s
        segs.append((t, t + r.concentric_s, -r.rom_m, 0.0)); t += r.concentric_s
        segs.append((t, t + top_pause_s, 0.0, 0.0)); t += top_pause_s
    segs.append((t, t + tail_s, 0.0, 0.0)); t += tail_s
    return segs, t


def position(segs, t: np.ndarray) -> np.ndarray:
    y = np.zeros_like(t)
    for t0, t1, y0, y1 in segs:
        m = (t >= t0) & (t <= t1)
        y[m] = y0 + (y1 - y0) * min_jerk((t[m] - t0) / (t1 - t0))
    return y


def sway(t: np.ndarray) -> np.ndarray:
    """Small forward-back bar drift, as in a real squat."""
    return 0.012 * np.sin(2 * np.pi * 0.35 * t)


def truth(spec: list[RepSpec], load_kg: float, exercise: str = "squat") -> dict:
    segs, total = build_trajectory(spec)
    t = np.arange(0, total, 1 / TRUTH_RATE)
    kin = kinematics.from_position(t, sway(t), position(segs, t), TRUTH_RATE, cutoff_hz=None)
    found = reps.segment(kin, exercise=exercise)
    rep_list = [metrics.rep_metrics(kin, r, load_kg) for r in found]
    s = metrics.set_summary(exercise, load_kg, load_kg, rep_list)
    return {
        "spec": [asdict(r) for r in spec],
        "exact_mean_velocity": [r.rom_m / r.concentric_s for r in spec],
        # Peak of a minimum-jerk profile is 1.875 x its mean.
        "exact_peak_velocity": [1.875 * r.rom_m / r.concentric_s for r in spec],
        "set": metrics.to_dict(s),
    }


def _plate_patch(radius_px: float, ss: int = 4):
    """Draw a bumper plate face (supersampled, then reduced) with an alpha mask."""
    size = int(np.ceil(radius_px * 2.2))
    big = size * ss
    c = big / 2
    R = radius_px * ss
    img = np.zeros((big, big), np.uint8)
    alpha = np.zeros((big, big), np.float32)
    ci = (int(c), int(c))
    cv2.circle(alpha, ci, int(R), 1.0, -1, cv2.LINE_AA)
    cv2.circle(img, ci, int(R), 38, -1, cv2.LINE_AA)                     # rubber face
    cv2.circle(img, ci, int(R * 0.96), 55, int(R * 0.03), cv2.LINE_AA)   # outer lip
    cv2.circle(img, ci, int(R * 0.30), 120, -1, cv2.LINE_AA)             # steel insert
    cv2.circle(img, ci, int(R * 0.22), 70, -1, cv2.LINE_AA)
    cv2.circle(img, ci, int(R * 0.13), 200, -1, cv2.LINE_AA)             # sleeve end
    cv2.putText(img, "20 KG", (int(c - R * 0.42), int(c - R * 0.48)), cv2.FONT_HERSHEY_DUPLEX,
                R / 110, 210, int(R / 40), cv2.LINE_AA)
    cv2.putText(img, "IWF", (int(c - R * 0.2), int(c + R * 0.68)), cv2.FONT_HERSHEY_DUPLEX,
                R / 160, 180, int(R / 60), cv2.LINE_AA)
    img = cv2.resize(img.astype(np.float32), (size, size), interpolation=cv2.INTER_AREA)
    alpha = cv2.resize(alpha, (size, size), interpolation=cv2.INTER_AREA)
    return img, alpha


def _background(w: int, h: int, rng: np.random.Generator) -> np.ndarray:
    gx = np.linspace(0, 1, w)[None, :]
    gy = np.linspace(0, 1, h)[:, None]
    bg = 150 + 40 * gx - 30 * gy
    bg = np.broadcast_to(bg, (h, w)).astype(np.float32).copy()
    for x in (int(w * 0.62), int(w * 0.82)):  # rack uprights behind the bar
        cv2.rectangle(bg, (x, 0), (x + 40, h), 95, -1)
        for y in range(40, h, 60):
            cv2.circle(bg, (x + 20, y), 6, 60, -1)
    cv2.rectangle(bg, (0, int(h * 0.93)), (w, h), 80, -1)  # floor
    bg += rng.normal(0, 4, bg.shape).astype(np.float32)
    return bg


def render(spec: list[RepSpec], path: str, fps: float = 240, width: int = 1280, height: int = 720,
           radius_px: float = 120, top_y_px: float = 200, noise: float = 3.0,
           shutter_fraction: float = 0.5, seed: int = 0) -> None:
    rng = np.random.default_rng(seed)
    px_per_m = radius_px / (PLATE_DIAMETER_M / 2)
    segs, total = build_trajectory(spec)
    patch, alpha = _plate_patch(radius_px)
    pc = patch.shape[0] / 2
    bg = _background(width, height, rng)
    writer = cv2.VideoWriter(path, cv2.VideoWriter_fourcc(*"mp4v"), fps, (width, height), isColor=False)
    n_frames = int(total * fps)
    sub = 3  # sub-frame samples across the exposure for motion blur
    for i in range(n_frames):
        t_mid = i / fps
        ts = t_mid + (np.arange(sub) - (sub - 1) / 2) / sub * shutter_fraction / fps
        acc = np.zeros((height, width), np.float32)
        for tk in ts:
            tk_arr = np.array([tk])
            cx = width * 0.38 + sway(tk_arr)[0] * px_per_m
            cy = top_y_px - position(segs, tk_arr)[0] * px_per_m
            angle = 4.0 * np.sin(2 * np.pi * 0.2 * tk)  # plate slowly rotating a few degrees
            M = cv2.getRotationMatrix2D((pc, pc), angle, 1.0)
            M[0, 2] += cx - pc
            M[1, 2] += cy - pc
            p = cv2.warpAffine(patch, M, (width, height), flags=cv2.INTER_LINEAR)
            a = cv2.warpAffine(alpha, M, (width, height), flags=cv2.INTER_LINEAR)
            acc += bg * (1 - a) + p * a
        frame = acc / sub + rng.normal(0, noise, (height, width))
        writer.write(np.clip(frame, 0, 255).astype(np.uint8))
    writer.release()


def main(argv=None) -> None:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--fps", type=float, default=240)
    p.add_argument("--load", type=float, default=100.0)
    p.add_argument("--out", default="synthetic/squat_240.mp4")
    args = p.parse_args(argv)
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    spec = default_reps()
    render(spec, str(out), fps=args.fps)
    out.with_suffix(".truth.json").write_text(json.dumps(truth(spec, args.load), indent=2))
    print(f"Wrote {out} and {out.with_suffix('.truth.json')}")


if __name__ == "__main__":
    main()
