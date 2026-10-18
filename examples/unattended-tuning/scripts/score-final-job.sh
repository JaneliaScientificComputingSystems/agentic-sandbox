#!/bin/bash
# Score the agent's final train.py on validation and the hidden test set, 3 seeds, in the GPU image.
# Submit on a GPU queue: bsub -q gpu_short -gpu "num=1" score-final-job.sh
: "${R:?source env.sh first}" "${HOLDOUT:?}" "${SANDBOX:?}"
H=$(cd "$(dirname "$0")" && pwd)
mkdir -p $R/final/agent; cp -p $R/project/train.py $R/final/agent/train.py; cp $H/score_final.py $R/final/
"$SANDBOX"/podman-run.sh --gpu --keep-id --rw $R/final --ro $R/eval --ro $R/data --ro $R/venv --ro $HOLDOUT \
  --image ghcr.io/janeliascientificcomputingsystems/agentic-sandbox-gpu:latest -- \
  env R=$R HOLDOUT=$HOLDOUT $R/venv/bin/python $R/final/score_final.py
