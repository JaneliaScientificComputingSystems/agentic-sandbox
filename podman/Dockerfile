# Default image (pushed as agentic-sandbox-lite on GHCR): bare NVIDIA CUDA runtime (no
# PyTorch/ML framework stack) plus Claude Code + opencode -- a coding-agent GPU sandbox that
# doesn't carry a full deep-learning environment. For an actual ML workload needing
# PyTorch/cuDNN preinstalled, see ./Dockerfile.pytorch (agentic-sandbox-gpu on GHCR, the
# former default, now the heavier alternate).
#
# -base, not -runtime or -devel: -base has just the CUDA runtime libraries needed for
# nvidia-smi/the CUDA runtime API to work -- enough to prove GPU passthrough works and for
# most agent coding tasks. Switch to -devel if agent-generated code needs to nvcc-compile
# CUDA kernels itself; switch to -runtime if it links against cuDNN/cuBLAS without compiling.
FROM nvcr.io/nvidia/cuda:13.3.0-base-ubuntu22.04

# Unlike Dockerfile.pytorch's base image, this one ships no dev toolchain at all -- not even
# curl or git. Install exactly what's needed: curl (for the installers below),
# ca-certificates (curl needs it for HTTPS), git (useful for a coding agent), rsync (matches
# Dockerfile.pytorch).
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl ca-certificates git rsync && \
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    rm -rf /var/lib/apt/lists/*

# Same installers as Dockerfile.pytorch -- see its comments for why native installers, not
# `npm install -g`.
RUN curl -fsSL https://claude.ai/install.sh | bash && \
    ln -s /root/.local/bin/claude /usr/local/bin/claude
RUN curl -fsSL https://opencode.ai/install | bash && \
    ln -s /root/.opencode/bin/opencode /usr/local/bin/opencode

WORKDIR /work
