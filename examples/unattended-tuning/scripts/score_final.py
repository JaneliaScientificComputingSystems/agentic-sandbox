#!/usr/bin/env python3
"""Final comparison on the hidden test set, with seed noise measured.

For the baseline and for the agent's final train.py: train with seeds 0..4 and score each run on both
the validation set (what the agent saw) and the hidden test set (what it never saw).
Writes FINAL/score_final.json. Run inside the gpu image with the venv's python (see score-final-job.sh).
"""
import json
import os
import statistics as st
import subprocess
import sys

R = os.environ["R"]
HOLD = os.environ["HOLDOUT"] + "/test.npz"
SPLITS = {"val": f"{R}/data/val.npz", "test": HOLD}
VARIANTS = {"agent": f"{R}/final/agent"}
SEEDS = range(3)


def score(proj, predict, seed):
    cmd = [sys.executable, f"{R}/eval/run_eval.py", "--project", proj, "--train", f"{R}/data/train.npz",
           "--predict", predict, "--timeout", "540", "--", "--seed", str(seed)]
    r = subprocess.run(cmd, capture_output=True, text=True)
    line = [l for l in r.stdout.splitlines() if l.startswith("RESULT ")]
    return json.loads(line[-1][7:]) if line else {"status": "error", "stderr": r.stderr[-300:]}


out = {}
for v, proj in VARIANTS.items():
    out[v] = {s: [] for s in SPLITS}
    for seed in SEEDS:
        for split, path in SPLITS.items():
            res = score(proj, path, seed)
            out[v][split].append({"seed": seed, **res})
            print(v, split, seed, json.dumps(res), flush=True)
summary = {}
for v in out:
    for split in SPLITS:
        xs = [r["f1_at_0.5"] for r in out[v][split] if r.get("status") == "ok"]
        summary[f"{v}_{split}"] = {"n": len(xs), "mean": round(st.mean(xs), 4) if xs else None,
                                   "sd": round(st.stdev(xs), 4) if len(xs) > 1 else None,
                                   "min": min(xs) if xs else None, "max": max(xs) if xs else None}
out["summary"] = summary
json.dump(out, open(f"{R}/final/score_final.json", "w"), indent=1)
print("SUMMARY", json.dumps(summary, indent=1))
