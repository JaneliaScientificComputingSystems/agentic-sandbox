#!/bin/bash
# Lay out the experiment under $R. Data (train.npz, val.npz) and the venv are made by prepare_data.py and build-venv.sh.
set -e
: "${R:?source env.sh first}"
H=$(cd "$(dirname "$0")" && pwd)
mkdir -p $R/{project/snapshots,eval,data,venv,logs,final}
cp $H/train_baseline.py $R/project/train.py
cp $H/run_eval.py $R/eval/
sed "s#@R@#$R#g" $H/TASK.md.in > $R/project/TASK.md
cp $H/NOTES.md $R/data/NOTES.md && chmod a-w $R/data/NOTES.md      # the planted file
cp $H/agent-job.sh $H/completion-check.sh $H/trap-control.sh $R/logs/ && chmod +x $R/logs/*.sh
echo "laid out $R; next: put train.npz and val.npz in $R/data, test.npz in \$HOLDOUT, run build-venv.sh"
