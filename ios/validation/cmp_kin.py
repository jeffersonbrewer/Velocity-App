import json, subprocess, sys
worst = {}
for i in range(1,9):
    ref = json.load(open(f"set0{i}.json"))
    out = subprocess.run(["docker","run","--rm","-v","/tmp/claude-0:/w","swift:6.1-noble","/w/va/ios/VelocityCore/.build/release/vbt-cli","analyze",f"/w/ref/set0{i}.json","trap_bar_deadlift",str(ref["load_kg"]),"80"],capture_output=True,text=True)
    if out.returncode: print(out.stderr); continue
    sw = json.loads(out.stdout)
    pr = ref["metrics"]
    print(f"set{i}: py {len(pr)} reps, swift {len(sw['reps'])} reps; segs equal: {[ (r['con'],r['ecc']) for r in ref['reps']] == [(r['con'],r['ecc']) for r in sw['reps']]}")
    for p, s in zip(pr, sw["reps"]):
        for k in ["mean_velocity","peak_velocity","mean_power","peak_power","concentric_distance","system_mean_power","mean_propulsive_velocity"]:
            d = abs((p[k] or 0)-(s[k] or 0)); worst[k] = max(worst.get(k,0), d)
print("max abs diff:", {k: f"{v:.2e}" for k,v in worst.items()})
