"""Analyze one recorded set.

Example:
    python -m vbt.analyze squat_100kg.mov --exercise squat --load 100 --out results/
"""

from __future__ import annotations

import argparse
import csv
import json
from dataclasses import dataclass
from pathlib import Path

from . import kinematics, metrics, reps, tracking


@dataclass
class Analysis:
    video: str
    track: tracking.Track
    kin: kinematics.Kinematics
    set_metrics: metrics.SetMetrics
    warnings: list[str]


def analyze_video(path: str, exercise: str, load_kg: float, *,
                  plate_diameter_m: float = kinematics.STANDARD_PLATE_DIAMETER_M,
                  body_mass_kg: float | None = None, body_mass_fraction: float | None = None,
                  cutoff_hz: float = 8.0, fps: float | None = None,
                  velocity_loss_threshold_pct: float | None = None,
                  target_mean_velocity: tuple[float, float] | None = None) -> Analysis:
    track = tracking.track_video(path, fps=fps)
    kin = kinematics.from_track(track, plate_diameter_m=plate_diameter_m, cutoff_hz=cutoff_hz)
    found = reps.segment(kin, exercise=exercise)
    # Bar power always; system power (load plus moving body mass) too when body mass is given.
    if body_mass_fraction is None:
        body_mass_fraction = metrics.body_mass_fraction_for(exercise)
    system_mass = load_kg + (body_mass_kg or 0.0) * body_mass_fraction
    rep_list = [metrics.rep_metrics(kin, r, load_kg, body_mass_kg, body_mass_fraction) for r in found]
    summary = metrics.set_summary(exercise, load_kg, system_mass, rep_list,
                                  velocity_loss_threshold_pct, target_mean_velocity)
    return Analysis(path, track, kin, summary, _warnings(track))


def _warnings(track: tracking.Track) -> list[str]:
    out = []
    if track.fps < 100:
        out.append(f"Frame rate is {track.fps:.0f} fps. Use 120 or 240 fps slow motion for accurate peak values.")
    if track.roundness < 0.97:
        out.append(f"Plate looks oval (roundness {track.roundness:.2f}). The camera may not be square to the bar, "
                   "which distorts distances and velocities.")
    if track.lost_fraction > 0.05:
        out.append(f"Plate was not found in {track.lost_fraction:.0%} of frames.")
    return out


def _fmt(x, nd=2):
    return "" if x is None else f"{x:.{nd}f}"


def print_report(a: Analysis) -> None:
    s = a.set_metrics
    print(f"\n{Path(a.video).name}: {s.exercise}, {s.load_kg:g} kg, {s.rep_count} reps")
    print(f"Scale {a.kin.m_per_px * 1000:.3f} mm/px, plate radius {a.track.radius_px:.1f} px, "
          f"{a.track.fps:.0f} fps")
    for w in a.warnings:
        print(f"WARNING: {w}")
    has_system = s.system_mean_power is not None
    header = ["Rep", "MV", "MPV", "PV", "MP (W)", "PP (W)"]
    if has_system:
        header += ["Sys MP", "Sys PP"]
    header += ["Con (m)", "Ecc (m)"]
    print("  ".join(f"{h:>7}" for h in header))
    for r in s.reps:
        row = [r.rep, _fmt(r.mean_velocity), _fmt(r.mean_propulsive_velocity), _fmt(r.peak_velocity),
               _fmt(r.mean_power, 0), _fmt(r.peak_power, 0)]
        if has_system:
            row += [_fmt(r.system_mean_power, 0), _fmt(r.system_peak_power, 0)]
        row += [_fmt(r.concentric_distance), _fmt(r.eccentric_distance)]
        print("  ".join(f"{str(c):>7}" for c in row))
    print(f"Set: MV {s.mean_velocity:.2f} (best {s.best_mean_velocity:.2f}), PV {s.peak_velocity:.2f}, "
          f"MP {s.mean_power:.0f} W, PP {s.peak_power:.0f} W, velocity loss {s.velocity_loss_pct:.1f}%, "
          f"volume {s.volume_load_kg:g} kg")
    if has_system:
        print(f"System ({s.system_mass_kg:g} kg moving): MP {s.system_mean_power:.0f} W, "
              f"PP {s.system_peak_power:.0f} W")
    if s.threshold_reached_at_rep:
        print(f"Velocity-loss threshold of {s.velocity_loss_threshold_pct:g}% reached at rep {s.threshold_reached_at_rep}.")


def save(a: Analysis, out_dir: Path) -> Path:
    out_dir.mkdir(parents=True, exist_ok=True)
    stem = Path(a.video).stem
    result = {
        "video": Path(a.video).name,
        "fps": a.track.fps,
        "m_per_px": a.kin.m_per_px,
        "plate_radius_px": a.track.radius_px,
        "plate_roundness": a.track.roundness,
        "warnings": a.warnings,
        "set": metrics.to_dict(a.set_metrics),
    }
    json_path = out_dir / f"{stem}.json"
    json_path.write_text(json.dumps(result, indent=2))
    with open(out_dir / f"{stem}_trajectory.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["t_s", "x_m", "y_m", "v_mps", "a_mps2"])
        for row in zip(a.kin.t, a.kin.x, a.kin.y, a.kin.v, a.kin.a):
            w.writerow([f"{val:.5f}" for val in row])
    return json_path


def main(argv=None) -> None:
    p = argparse.ArgumentParser(description="Measure barbell velocity from a side-view video.")
    p.add_argument("video")
    p.add_argument("--exercise", default="squat")
    p.add_argument("--load", type=float, required=True, help="Bar load in kg")
    p.add_argument("--plate-diameter", type=float, default=kinematics.STANDARD_PLATE_DIAMETER_M,
                   help="Diameter in meters of the plate facing the camera (default 0.45)")
    p.add_argument("--body-mass", type=float,
                   help="Lifter body mass in kg. Adds system power (load + body mass) to the report")
    p.add_argument("--body-mass-fraction", type=float,
                   help="Share of body mass that moves with the bar, for system power "
                        "(default by exercise: 0.80 squats and deadlifts, 1.0 otherwise)")
    p.add_argument("--cutoff", type=float, default=8.0, help="Low-pass filter cutoff in Hz")
    p.add_argument("--fps", type=float, help="Override the frame rate stored in the video")
    p.add_argument("--vl-threshold", type=float, help="Velocity-loss threshold in percent")
    p.add_argument("--target", type=float, nargs=2, metavar=("LOW", "HIGH"),
                   help="Target mean velocity zone in m/s")
    p.add_argument("--out", default="results", help="Folder for JSON and trajectory CSV")
    args = p.parse_args(argv)

    a = analyze_video(args.video, args.exercise, args.load,
                      plate_diameter_m=args.plate_diameter, body_mass_kg=args.body_mass,
                      body_mass_fraction=args.body_mass_fraction, cutoff_hz=args.cutoff, fps=args.fps,
                      velocity_loss_threshold_pct=args.vl_threshold,
                      target_mean_velocity=tuple(args.target) if args.target else None)
    print_report(a)
    path = save(a, Path(args.out))
    print(f"\nSaved {path}")


if __name__ == "__main__":
    main()
