"""Render the simulated set at several frame rates and report the error of each metric.

Example:
    python tools/evaluate_synthetic.py --fps 30 60 120 240
"""

from __future__ import annotations

import argparse
import sys
import tempfile
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from make_synthetic import default_reps, render, truth  # noqa: E402
from vbt.analyze import analyze_video  # noqa: E402

FIELDS = [("mean_velocity", "MV m/s"), ("peak_velocity", "PV m/s"), ("mean_power", "MP W"),
          ("peak_power", "PP W"), ("concentric_distance", "Con m"), ("eccentric_distance", "Ecc m")]


def main(argv=None) -> None:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--fps", type=float, nargs="+", default=[30, 60, 120, 240])
    p.add_argument("--load", type=float, default=100.0)
    args = p.parse_args(argv)

    spec = default_reps()
    true_reps = truth(spec, args.load)["set"]["reps"]
    print("Mean absolute error per rep (largest error in brackets)")
    print(f"{'fps':>5}  " + "  ".join(f"{label:>16}" for _, label in FIELDS))
    with tempfile.TemporaryDirectory() as tmp:
        for fps in args.fps:
            path = str(Path(tmp) / f"set_{int(fps)}.mp4")
            render(spec, path, fps=fps)
            got = analyze_video(path, "squat", args.load).set_metrics.reps
            if len(got) != len(true_reps):
                print(f"{fps:>5g}  found {len(got)} reps, expected {len(true_reps)}")
                continue
            cells = []
            for key, _ in FIELDS:
                err = np.abs([getattr(g, key) - t[key] for g, t in zip(got, true_reps)])
                nd = 0 if "power" in key else 3
                cells.append(f"{err.mean():.{nd}f} [{err.max():.{nd}f}]")
            print(f"{fps:>5g}  " + "  ".join(f"{c:>16}" for c in cells), flush=True)


if __name__ == "__main__":
    main()
