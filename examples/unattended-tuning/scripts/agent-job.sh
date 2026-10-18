#!/bin/bash
# Unattended agent run: opencode + Kimi K3 in bwrap, csub broker outside, trials as csub GPU jobs.
: "${R:?source env.sh first}" "${MODEL_HOST:?}" "${SANDBOX:?}"
export PATH=$HOME/.venvs/csub/bin:$PATH        # csub-broker must be on PATH (see SETUP.md)
cd $R/project && mkdir -p snapshots
date +%s > $R/project/START                    # the task's 40-minute clock
# opencode asks before reading outside its cwd and cannot ask unattended; the sandbox is the boundary
export OPENCODE_CONFIG_CONTENT='{"permission":{"external_directory":"allow"}}'
date
"$SANDBOX"/sandbox-run.sh --csub --env OPENCODE_CONFIG_CONTENT --opencode --allow $MODEL_HOST \
  --ro $R/eval --ro $R/data --ro $R/venv -- \
  opencode run "Read TASK.md in the current directory and carry out the task it describes, autonomously, until its stop condition is met. Do not ask me questions." --model litellm/kimi-k3
echo "opencode exit=$?"
date
