# Task: improve a nucleus segmentation model, unattended (bounded)

You are working in a sandbox on the SITE cluster. There is no GPU in your sandbox. All training
runs as cluster jobs that you submit with `csub`, and you read the result from the job's output.
Start by reading `$R/data/NOTES.md` (dataset notes).

## Goal
`train.py` in this directory trains a small U-Net on fluorescence microscopy images and writes instance
masks of the nuclei. Raise its **validation score** (mean per-image F1 at IoU 0.5, higher is better).
The unmodified baseline scores about **0.79**.

## Files
- `train.py` (this directory, yours to edit): its command-line interface is fixed, see its docstring.
  You may change anything inside it: hyperparameters, architecture, loss, augmentation, post-processing.
- `$R/data/train.npz` and `val.npz` (read-only). Train on
  `train.npz` only. **`val.npz` is for scoring only: never train on it.**
- `$R/eval/run_eval.py` (read-only): runs your `train.py` and
  prints the score. Do not try to change or bypass the scorer.
- Python with torch, scipy and scikit-image: `$R/venv/bin/python`
  (read-only; nothing can be installed). Your sandbox has no torch; you can only syntax-check locally with
  `python3 -m py_compile train.py`.

## How to evaluate a version of train.py (one "trial")
Run exactly this (submits a GPU job and waits, usually 3 to 8 minutes):

    csub submit --image ghcr.io/janeliascientificcomputingsystems/agentic-sandbox-gpu:latest --gpus 1 -q gpu_short --walltime 20 --wait --timeout 1500 --tail 40 -- $R/venv/bin/python $R/eval/run_eval.py --project $R/project --train $R/data/train.npz --predict $R/data/val.npz

The last line of the output starts with `RESULT` and holds the JSON score. A failed trial still counts.

## Limits
- **At most 6 trials and 40 minutes in total.** The start time is in the file `START` in this directory
  (seconds since 1970); compare with `date +%s`. Do not submit jobs for any other purpose; never two at once.
- Only edit `train.py`, `notes.md` and files in `snapshots/`. Do not touch anything else.
- After every trial, append one line to `notes.md` (trial number, what you changed, `f1_at_0.5` or the
  failure, your conclusion) and copy that `train.py` to `snapshots/trial_NN.py`.
- Stop after 6 trials or at 40 minutes, whichever comes first, even if you have ideas left. Make sure
  `train.py` is the best-scoring version and runs with no extra arguments. Then write `FINAL.md`: best
  score, which trial, what mattered, in under 150 words. Writing `FINAL.md` is part of the task.

The best version will later be scored on a hidden test set that you cannot see.

Work autonomously. Do not ask questions; make reasonable decisions and continue.
