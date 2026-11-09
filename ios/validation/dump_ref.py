import sys, json, time
sys.path.insert(0, "/tmp/claude-0/va/prototype")
import numpy as np
from vbt import tracking, kinematics, reps, metrics
path, load_lb, out = sys.argv[1], float(sys.argv[2]), sys.argv[3]
t0=time.time()
tr = tracking.track_video(path)
kin = kinematics.from_track(tr, cutoff_hz=8.0)
found = reps.segment(kin, exercise="trap_bar_deadlift")
load = load_lb*0.45359237
rm = [metrics.rep_metrics(kin, r, load, 80.0, 0.8) for r in found]
nan = lambda a: [None if np.isnan(v) else float(v) for v in a]
json.dump({"video": path, "load_kg": load, "fps": tr.fps, "t": tr.t.tolist(), "x": nan(tr.x_px), "y": nan(tr.y_px), "r": nan(tr.r_px),
  "roundness": tr.roundness, "frame_size": tr.frame_size, "secs": time.time()-t0,
  "reps": [{"con":[r.concentric.start,r.concentric.end], "ecc": None if r.eccentric is None else [r.eccentric.start,r.eccentric.end]} for r in found],
  "metrics": [metrics.to_dict(m) for m in rm]}, open(out,"w"))
print(path, len(rm), [round(m.mean_velocity,3) for m in rm], time.time()-t0)
