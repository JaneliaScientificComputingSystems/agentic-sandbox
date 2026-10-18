#!/bin/bash
# Build the read-only venv INSIDE the GPU image, so its interpreter symlink resolves in the child container.
: "${R:?source env.sh first}" "${SANDBOX:?}"
mkdir -p $R/venv $R/logs; cd $R/logs
"$SANDBOX"/podman-run.sh --keep-id --rw $R/venv --allow pypi.org --allow files.pythonhosted.org \
  --image ghcr.io/janeliascientificcomputingsystems/agentic-sandbox-gpu:latest -- bash -c "
set -e
python3 -m venv --system-site-packages $R/venv
$R/venv/bin/pip install --no-cache-dir scikit-image 2>&1 | tail -3
$R/venv/bin/python -c 'import torch, scipy, skimage, numpy; print(\"venv ok\", torch.__version__, skimage.__version__)'
"
