"""Compare camera results with GymAware readings, rep by rep.

Fill in templates/gymaware_template.csv (one row per rep), analyze each video into
a results folder, then run:
    python -m vbt.compare gymaware.csv results/
"""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path

import numpy as np

# GymAware column -> camera metric name
PAIRS = {
    "ga_mean_velocity": "mean_velocity",
    "ga_peak_velocity": "peak_velocity",
    "ga_mean_power": "mean_power",
    "ga_peak_power": "peak_power",
    "ga_distance": "concentric_distance",
}


def icc_2_1(a: np.ndarray, b: np.ndarray) -> float:
    """Two-way random, absolute agreement, single measures ICC(2,1)."""
    x = np.column_stack([a, b])
    n, k = x.shape
    grand = x.mean()
    msr = k * ((x.mean(axis=1) - grand) ** 2).sum() / (n - 1)
    msc = n * ((x.mean(axis=0) - grand) ** 2).sum() / (k - 1)
    sse = ((x - x.mean(axis=1, keepdims=True) - x.mean(axis=0, keepdims=True) + grand) ** 2).sum()
    mse = sse / ((n - 1) * (k - 1))
    return float((msr - mse) / (msr + (k - 1) * mse + k * (msc - mse) / n))


def agreement(camera: np.ndarray, reference: np.ndarray) -> dict:
    """Bland-Altman bias and 95% limits of agreement, plus MAE, Pearson r and ICC."""
    d = camera - reference
    bias, sd = float(d.mean()), float(d.std(ddof=1)) if len(d) > 1 else float("nan")
    return {
        "n": int(len(d)),
        "bias": bias,
        "loa_low": bias - 1.96 * sd,
        "loa_high": bias + 1.96 * sd,
        "mae": float(np.abs(d).mean()),
        "r": float(np.corrcoef(camera, reference)[0, 1]) if len(d) > 2 else float("nan"),
        "icc": icc_2_1(camera, reference) if len(d) > 2 else float("nan"),
    }


def load_pairs(reference_csv: str, results_dir: str) -> tuple[dict[str, tuple[list, list]], list[str]]:
    results: dict[str, dict] = {}
    for p in Path(results_dir).glob("*.json"):
        data = json.loads(p.read_text())
        results[Path(data["video"]).stem] = {r["rep"]: r for r in data["set"]["reps"]}

    pairs = {k: ([], []) for k in PAIRS}
    missing = []
    with open(reference_csv, newline="") as f:
        for row in csv.DictReader(f):
            stem = Path(row["video"]).stem
            rep = int(row["rep"])
            cam = results.get(stem, {}).get(rep)
            if cam is None:
                missing.append(f"{stem} rep {rep}")
                continue
            for ga_col, metric in PAIRS.items():
                if row.get(ga_col, "").strip():
                    pairs[ga_col][0].append(cam[metric])
                    pairs[ga_col][1].append(float(row[ga_col]))
    return pairs, missing


def main(argv=None) -> None:
    p = argparse.ArgumentParser(description="Compare camera metrics with GymAware, rep by rep.")
    p.add_argument("reference_csv")
    p.add_argument("results_dir")
    args = p.parse_args(argv)

    pairs, missing = load_pairs(args.reference_csv, args.results_dir)
    for m in missing:
        print(f"No camera result for {m}")
    print(f"\n{'Metric':<22}{'n':>4}{'Bias':>9}{'95% LoA':>20}{'MAE':>9}{'r':>7}{'ICC':>7}")
    for ga_col, (cam, ref) in pairs.items():
        if len(cam) < 2:
            continue
        s = agreement(np.array(cam), np.array(ref))
        nd = 0 if "power" in ga_col else 3
        loa = f"{s['loa_low']:.{nd}f} to {s['loa_high']:.{nd}f}"
        print(f"{PAIRS[ga_col]:<22}{s['n']:>4}{s['bias']:>9.{nd}f}{loa:>20}{s['mae']:>9.{nd}f}"
              f"{s['r']:>7.3f}{s['icc']:>7.3f}")


if __name__ == "__main__":
    main()
