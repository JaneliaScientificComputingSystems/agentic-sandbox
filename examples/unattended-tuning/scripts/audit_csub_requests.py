import json, os, sys
import os
R = os.environ["R"]
want = {(f"{R}/project", "rw"), (f"{R}/eval", "ro"), (f"{R}/data", "ro"), (f"{R}/venv", "ro")}
ids = sorted(os.listdir(f"{R}/project/.csub/jobs"))
out = []
for i in ids:
    d = os.path.expanduser(f"~/.csub/jobs/{i}")
    req = json.load(open(f"{d}/request.json")); meta = json.load(open(f"{d}/meta.json"))
    mounts = {(m["path"], m["mode"]) for m in req["spec"]["mounts"]}
    res = req.get("resolved", {})
    out.append({"job": i, "queue": meta["queue"], "image": meta["image"].split("/")[-1], "gpus": req["spec"]["gpus"],
                "walltime": req["spec"]["walltime_min"], "allow_hosts": req["spec"]["allow_hosts"],
                "mounts_match_sandbox": mounts == want, "extra_mounts": sorted(mounts - want),
                "exit_code": open(f"{d}/exit_code").read().strip(), "session": meta["session"],
                "command0": " ".join(req["spec"]["command"])[:90]})
print(json.dumps(out, indent=1))
print("ALL MOUNTS WITHIN SANDBOX SET:", all(o["mounts_match_sandbox"] for o in out), "jobs:", len(out))
