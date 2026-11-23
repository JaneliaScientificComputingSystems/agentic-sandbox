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
FROM nvcr.io/nvidia/cuda:13.5.0-base-ubuntu22.04

# Unlike Dockerfile.pytorch's base image, this one ships no dev toolchain at all -- not even
# curl or git. Install exactly what's needed: curl (for the installers below),
# ca-certificates (curl needs it for HTTPS), git (useful for a coding agent), rsync (matches
# Dockerfile.pytorch).
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl ca-certificates git rsync && \
    curl -fsSL https://deb.nodesource.com/setup_24.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    rm -rf /var/lib/apt/lists/*

# Same installers as Dockerfile.pytorch -- see its comments for why native installers, not
# `npm install -g`.
RUN curl -fsSL https://claude.ai/install.sh | bash && \
    ln -s /root/.local/bin/claude /usr/local/bin/claude
RUN curl -fsSL https://opencode.ai/install | bash && \
    ln -s /root/.opencode/bin/opencode /usr/local/bin/opencode

# /root is mode 700 by default -- blocks traversal into it entirely for a non-root process,
# which is exactly what `podman-run.sh --keep-id` runs as. Confirmed live: with --keep-id,
# /usr/local/bin/claude (a symlink into /root/.local/bin/claude) and opencode's equivalent
# both fail with "Permission denied", not because the target files themselves are
# unreadable, but because /root itself can't be traversed by a different uid at all.
# Deliberately targeted, not a blanket `chmod -R o+rX /root`: only opens traversal on /root
# itself plus read+execute on the two install trees these symlinks actually point into.
RUN chmod o+rx /root && chmod -R o+rX /root/.local /root/.opencode

# OpenAI's Codex CLI, from npm (a global install lands in /usr/lib/node_modules and /usr/bin,
# readable by every user, so --keep-id needs nothing extra).
RUN npm install -g @openai/codex && codex --version

# What an agent that reaches this container through ssh-entry.sh --podman needs, so that it can do
# here what it can do in the Bubblewrap sandbox:
#  - pip and venv, to install Python packages into a venv in the project directory (the base
#    image has python3 but neither);
#  - the server half of sftp, which is what `scp` and `sftp` from the laptop talk to. It runs
#    inside the sandbox like every other command. Ubuntu's package brings the ssh client with
#    it as a dependency; no daemon comes with it. The cluster's sshd asks for the server at
#    the RHEL path, so that path is linked to Ubuntu's.
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3-pip python3-venv openssh-sftp-server && \
    rm -rf /var/lib/apt/lists/* && \
    mkdir -p /usr/libexec/openssh && \
    ln -s /usr/lib/openssh/sftp-server /usr/libexec/openssh/sftp-server

# The installers above are piped into a shell, so a failed download still "succeeds" and leaves a
# dangling link. Fail the build here instead.
RUN claude --version && opencode --version && codex --version

WORKDIR /work
