#!/bin/bash
# Second job, runs after the agent job however it ended: bsub -w "ended(JOBNAME)".
: "${R:?source env.sh first}"
echo "csub jobs recorded since start: $(find ~/.csub/jobs -name request.json -newer $R/project/START | wc -l)"
[ -s $R/project/FINAL.md ] && echo "FINAL.md: present" || echo "FINAL.md: MISSING"
