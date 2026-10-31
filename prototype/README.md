# Analysis prototype

Measures each rep of a set from a side-view video of the bar, using the plate facing the camera.

## How it works

1. **Find the plate.** A circle search locates the plate in the first frame.
2. **Track it.** Each frame, template matching finds the plate roughly, then a circle is fitted to
   its outer edge for a sub-pixel center. The edge fit ignores the plate rotating.
3. **Scale to meters.** The plate's known diameter (450 mm by default) divided by its fitted
   diameter in pixels gives meters per pixel.
4. **Filter and differentiate.** A zero-lag 4th-order Butterworth low-pass (8 Hz by default)
   smooths position, then velocity and acceleration are taken by numerical differentiation.
5. **Split reps.** Eccentric and concentric phases are stretches of downward and upward movement
   faster than 0.05 m/s, extended to where velocity crosses zero, covering at least 10 cm.
6. **Compute metrics.** Force = m(a + g), power = force x velocity, over the concentric phase.

| Metric | Definition |
| --- | --- |
| Mean velocity (MV) | Average vertical velocity over the concentric phase |
| Mean propulsive velocity (MPV) | Average over the concentric until the bar decelerates faster than gravity |
| Peak velocity (PV) | Highest vertical velocity in the concentric phase |
| Mean / peak power | Average / highest of force x velocity over the concentric phase |
| Concentric / eccentric distance | Vertical bar travel on the way up / down |
| Velocity loss | (best rep MV - last rep MV) / best rep MV |
| Volume load | Reps x load, summed over sets and exercises |

Power uses bar load by default. `--body-mass` with `--body-mass-fraction` adds part of body mass.

## Setup

```
cd prototype
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

## Analyze a set

```
.venv/bin/python -m vbt.analyze my_squat.mov --exercise squat --load 100 --vl-threshold 20 --out results
```

This prints a rep-by-rep table and saves `results/my_squat.json` plus the full trajectory as CSV.
Use `--exercise deadlift` (or another lift that starts from the floor) so reps are paired up-then-down.

**iPhone slow-motion clips:** share the original file (AirDrop with "All Photos Data" on, or the
Files app). Some sharing paths re-encode slow motion at 30 fps playback, which makes everything look
8x slower. If that happens, pass the real capture rate with `--fps 240`.

## Compare with GymAware

1. Copy `templates/gymaware_template.csv` and enter one row per rep from GymAware.
   The `video` column must match the video file name.
2. Analyze every video into the same results folder.
3. Run:

```
.venv/bin/python -m vbt.compare my_gymaware.csv results
```

It reports, per metric, the bias, 95% limits of agreement (Bland-Altman), mean absolute error,
Pearson r and ICC(2,1).

## Simulated test videos

`tools/make_synthetic.py` renders a set where the true bar motion is known exactly: a plate with
sub-pixel movement, slight rotation, motion blur, noise and compression. `tools/evaluate_synthetic.py`
renders it at several frame rates and reports the error of each metric. Run the tests with
`.venv/bin/python -m pytest tests`.

These simulated clips are cleaner than real footage, which adds lighting changes, occlusion,
camera shake, lens distortion and perspective. They check that the math is right, not that real-world
tracking is accurate. Only the GymAware comparison answers that.
