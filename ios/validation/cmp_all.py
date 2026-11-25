# Compare Swift tracking+analysis with the Python prototype and with GymAware.
import json, subprocess, sys, csv, numpy as np
sys.path.insert(0, "/tmp/claude-0/va/prototype")
from vbt.compare import agreement
suffix = sys.argv[1]
ga = {}
for row in csv.DictReader(open("/mnt/project-files/velocity-app/validation-2026-11-08/gymaware_trapbar.csv")):
    ga[(int(row["video"][3:]), int(row["rep"]))] = row
rows = []
for i in range(1, 9):
    ref = json.load(open(f"set0{i}.json"))
    out = subprocess.run(["docker","run","--rm","-v","/tmp/claude-0:/w","swift:6.1-noble","/w/va/ios/VelocityCore/.build/release/vbt-cli","analyze",f"/w/ref/set0{i}{suffix}.swift.json","trap_bar_deadlift",str(ref["load_kg"]),"80"],capture_output=True,text=True)
    if out.returncode: print(f"set{i}: FAILED {out.stderr.strip()}"); continue
    sw = json.loads(out.stdout)["reps"]; py = ref["metrics"]
    print(f"set{i}: reps py {len(py)} sw {len(sw)}  MV py {[round(r['mean_velocity'],3) for r in py]}  sw {[round(r['mean_velocity'],3) for r in sw]}")
    for n, (p, s) in enumerate(zip(py, sw), 1):
        g = ga.get((i, n))
        rows.append(dict(set=i, rep=n, py=p, sw=s, ga=g))
keys = [("mean_velocity","ga_mean_velocity"),("peak_velocity","ga_peak_velocity"),("mean_power","ga_mean_power"),("peak_power","ga_peak_power"),("concentric_distance","ga_distance")]
print("\nSwift vs Python prototype (same reps):")
for k,_ in keys:
    d = np.array([r["sw"][k]-r["py"][k] for r in rows])
    print(f"  {k:22s} mean {d.mean():+.4f}  max|d| {np.abs(d).max():.4f}  within 0.01: {(np.abs(d)<=0.01).mean():.0%}" if "velocity" in k or "distance" in k else f"  {k:22s} mean {d.mean():+.1f}  max|d| {np.abs(d).max():.1f}")
print("\nvs GymAware:            bias      LoA                 ICC   | prototype bias, ICC")
for k,gk in keys:
    pr = [r for r in rows if r["ga"] and r["ga"][gk]]
    g = np.array([float(r["ga"][gk]) for r in pr])
    a_sw = agreement(np.array([r["sw"][k] for r in pr]), g); a_py = agreement(np.array([r["py"][k] for r in pr]), g)
    print(f"  {k:22s} {a_sw['bias']:+.3f}  {a_sw['loa_low']:+.3f}..{a_sw['loa_high']:+.3f}  {a_sw['icc']:.3f} | {a_py['bias']:+.3f}, {a_py['icc']:.3f}   n={len(g)}")
json.dump(rows, open(f"cmp{suffix}.json","w"))
