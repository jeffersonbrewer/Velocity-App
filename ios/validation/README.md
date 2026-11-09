# Swift engine check against the Python prototype and GymAware (2026-11-09)

The 8 trap bar originals (IMG_0563-0570, 95-255 lb, 38 reps with GymAware readings) were run
through both the Python prototype and the Swift engine (`ios/VelocityCore`) at the default
settings (8 Hz filter, tilt-corrected scale). Per-rep numbers: `swift_vs_python_vs_gymaware.csv`.

## Results

**Signal processing (filter, scaling, rep detection, metrics).** Given the same plate track, Swift
and Python agree to within 1e-8 on every metric of every rep, and find identical rep boundaries
(`cmp_kin.py`).

**Whole pipeline including plate tracking**, against GymAware:

| Metric | Swift bias | Swift 95% LoA | Swift ICC | Prototype bias | Prototype ICC |
| --- | --- | --- | --- | --- | --- |
| Mean velocity (m/s) | -0.021 | -0.087 to +0.044 | 0.978 | -0.022 | 0.979 |
| Peak velocity (m/s) | +0.118 | -0.111 to +0.347 | 0.869 | +0.120 | 0.863 |
| Mean power (W) | -32 | -91 to +27 | 0.852 | -32 | 0.864 |
| Peak power (W) | +400 | -174 to +974 | 0.231 | +408 | 0.198 |
| Distance (m) | +0.023 | -0.020 to +0.065 | 0.714 | +0.023 | 0.702 |

Swift vs prototype per rep: mean velocity within 0.01 m/s on 31 of 38 reps (82%); mean difference
+0.001 m/s. The 7 larger differences come from two places where the prototype itself is unstable:

1. **Rep start.** After the bar is set down, a small settling bump can reach the 0.05 m/s threshold
   in one system and not the other (0.049 vs 0.051 m/s on set 6 rep 2), which moves the rep start
   by 20 frames and changes mean velocity by 0.05 m/s. Set 2 rep 1 is the same effect the other way:
   Swift reads 0.80 m/s, the prototype 0.68, GymAware 0.77.
2. **Motion blur.** During fast frames the outline fit depends on where it starts searching. Given
   the same frame and the same starting point, Swift and Python return identical circles, but the
   prototype's own result can move by 20 px with a few pixels' change in starting point.

Both are worth fixing in the shared algorithm (and re-checking against GymAware) rather than
copying the prototype's noise.

## Differences from the prototype on purpose

- Plate search runs at half size with its own Hough vote, then picks the largest concentric circle
  whose outline fits on the full image (the prototype's "rim beats hub" rule).
- Template matching runs at 1/8 then 1/2 size, first in a small box around the predicted position.
  About 3x faster than a full search with the same result.
- A long tracking loss mid-clip no longer fails the set: the gap is bridged and reps overlapping it
  are dropped with a warning (set 5 lost the plate for 17 frames during setup).
- Plate roundness uses a direct least-squares ellipse fit (same idea as cv2.fitEllipse).

## Re-running

`dump_ref.py` writes the prototype's track and metrics; `track_swift.sh` decodes a clip with ffmpeg
(frame times from ffprobe) and tracks it with `vbt-cli`; `cmp_all.py` compares.
