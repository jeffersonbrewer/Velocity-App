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
| Mean / peak power (bar) | Average / highest of force x velocity over the concentric phase, using bar load |
| Mean / peak power (system) | The same, using bar load plus the moving share of body mass |
| Concentric / eccentric distance | Vertical bar travel on the way up / down |
| Velocity loss | (best rep MV - last rep MV) / best rep MV |
| Volume load | Reps x load, summed over sets and exercises |

Bar power is always reported. Pass `--body-mass` to also report system power, which counts
bar load plus body mass. `--body-mass-fraction` sets how much of body mass moves with the bar. It
defaults by exercise: 0.80 for squats and deadlifts (head, arms and trunk count fully, thighs about
half, shanks and feet not at all) and 1.0 for pull-ups, dips and anything else. Both use the bar's measured velocity, so for system power this assumes
the counted body mass moves at bar speed.

## Setup

```
cd prototype
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

## Analyze a set

```
.venv/bin/python -m vbt.analyze my_squat.mov --exercise squat --load 100 --body-mass 85 --vl-threshold 20 --out results
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

Results on a simulated 5-rep squat set at 100 kg (mean absolute error per rep, largest in brackets):

| fps | MV (m/s) | PV (m/s) | Mean power (W) | Peak power (W) | Distance (m) |
| --- | --- | --- | --- | --- | --- |
| 30 | 0.037 [0.049] | 0.015 [0.034] | 37 [48] | 26 [84] | < 0.001 |
| 60 | 0.010 [0.025] | 0.004 [0.007] | 10 [24] | 10 [26] | < 0.001 |
| 120 | 0.003 [0.010] | 0.002 [0.003] | 3 [10] | 3 [3] | < 0.001 |
| 240 | 0.002 [0.003] | 0.001 [0.001] | 2 [3] | 1 [3] | < 0.001 |

These simulated clips are cleaner than real footage, which adds lighting changes, occlusion,
camera shake, lens distortion and perspective. They check that the math is right, not that real-world
tracking is accurate. Only the GymAware comparison answers that.

## Estimated 1RM

`vbt/profile.py` fits a straight line of mean velocity against load, then reads off the load at the
1RM velocity (minimum velocity threshold). It only uses sets tagged as profile tests, never normal
working sets: those sit near one load, far above 1RM velocity, so a line through them swings widely.

```
# A warm-up ramp of 4 to 6 loads, each tagged as a profile test
.venv/bin/python -m vbt.analyze squat_60.mov --exercise squat --load 60 --profile-test --out results
# A successful heavy single also sets the lifter's personal 1RM velocity
.venv/bin/python -m vbt.analyze squat_165.mov --exercise squat --load 165 --max-single --out results
.venv/bin/python -m vbt.profile results/*.json --exercise squat
```

`profile.retest_due` suggests a new profile test every 4 weeks or when a training block ends.

Default 1RM velocities (mean concentric velocity, from linear-transducer studies):

| Exercise | m/s | Checked against a source |
| --- | --- | --- |
| Back squat | 0.30 | Yes (Conceicao et al. 2016, mean propulsive velocity); trained women averaged 0.36 (Caven et al. 2020) |
| Front squat | 0.33 | No |
| Bench press | 0.17 | Yes (Garcia-Ramos et al. 2020; powerlifters lower, about 0.10) |
| Overhead press | 0.24 | Second-hand (Fahs et al. 2019, as cited by Soriano et al. 2022) |
| Deadlift | 0.15 | No |
| Trap bar deadlift | 0.15 | GymAware's value, no study checked |
| Pull-up | 0.20 | Yes (Sanchez-Moreno et al. 2017) |
| Prone bench pull | 0.48 | Yes (Garcia-Ramos et al. 2019) |
| Hip thrust | 0.25 | No |

Individual 1RM velocities vary widely, so a lifter's own value, the slowest successful heavy single
recorded with this system (`profile.personal_mvt`), replaces the default as soon as it exists.
Olympic lifts and kettlebell or dumbbell work have no default, so no 1RM is estimated for them
unless a personal value is set.
