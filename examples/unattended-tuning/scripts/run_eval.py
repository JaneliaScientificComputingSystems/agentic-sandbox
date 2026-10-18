#!/usr/bin/env python3
"""Evaluator: run project/train.py, score its predictions, print one JSON line.

    python run_eval.py --project DIR --train TRAIN.npz --predict VAL.npz [--timeout S] [-- extra train.py args]

The score is mean per-image F1 at IoU 0.5 between predicted and true nuclei
(2TP / (2TP + FP + FN)), the standard instance-segmentation measure.
"""
import argparse
import json
import os
import subprocess
import sys
import time

import numpy as np


def f1_at(pred, gt, thr):
    p, g = pred.ravel().astype(np.int64), gt.ravel().astype(np.int64)
    P, G = p.max() + 1, g.max() + 1
    inter = np.bincount(p * G + g, minlength=P * G).reshape(P, G)
    ap, ag = inter.sum(1), inter.sum(0)
    iou = (inter / np.maximum(ap[:, None] + ag[None, :] - inter, 1))[1:, 1:]
    n_pred, n_gt = int((ap[1:] > 0).sum()), int((ag[1:] > 0).sum())
    if n_pred == 0 and n_gt == 0:
        return 1.0
    tp = int((iou > thr).sum())
    return 2 * tp / max(2 * tp + (n_pred - tp) + (n_gt - tp), 1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--project", required=True)
    ap.add_argument("--train", required=True)
    ap.add_argument("--predict", required=True)
    ap.add_argument("--timeout", type=int, default=540)
    ap.add_argument("extra", nargs="*")
    a = ap.parse_args()

    out = os.path.join(a.project, "runs", time.strftime("%Y%m%d-%H%M%S") + f"-{os.getpid()}")
    os.makedirs(out, exist_ok=True)
    cmd = [sys.executable, os.path.join(a.project, "train.py"), "--train", a.train,
           "--predict", a.predict, "--out", out] + a.extra
    t0 = time.time()
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=a.timeout)
        rc, so, se = r.returncode, r.stdout, r.stderr
    except subprocess.TimeoutExpired as e:
        rc, so, se = -9, (e.stdout or b"").decode() if isinstance(e.stdout, bytes) else (e.stdout or ""), "TIMEOUT"
    secs = round(time.time() - t0, 1)
    tail = "\n".join((so + "\n" + se).strip().splitlines()[-15:])
    print("--- train.py output (tail) ---\n" + tail)
    res = {"status": "error", "seconds": secs, "return_code": rc}
    pf = os.path.join(out, "pred.npy")
    if rc == 0 and os.path.exists(pf):
        pred, gt = np.load(pf), np.load(a.predict)["labels"]
        if pred.shape != gt.shape:
            res["error"] = f"pred shape {pred.shape} != labels shape {gt.shape}"
        else:
            f50 = [f1_at(p, g, 0.5) for p, g in zip(pred, gt)]
            f75 = [f1_at(p, g, 0.75) for p, g in zip(pred, gt)]
            res = {"status": "ok", "f1_at_0.5": round(float(np.mean(f50)), 4),
                   "f1_at_0.75": round(float(np.mean(f75)), 4), "seconds": secs,
                   "mean_pred_nuclei": round(float(np.mean([len(np.unique(p)) - 1 for p in pred])), 1),
                   "mean_true_nuclei": round(float(np.mean([len(np.unique(g)) - 1 for g in gt])), 1)}
    print("RESULT " + json.dumps(res))
    sys.exit(0 if res["status"] == "ok" else 1)


if __name__ == "__main__":
    main()
