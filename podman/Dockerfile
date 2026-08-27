# NVIDIA's own official PyTorch container (CUDA/cuDNN/PyTorch preconfigured and tested by
# NVIDIA) as the base, with Claude Code + opencode added on top -- so a podman-sandboxed GPU
# workload gets a real, NVIDIA-maintained CUDA stack instead of us hand-rolling one.
FROM nvcr.io/nvidia/pytorch:26.07-py3

# Node.js for the CLIs (the base image doesn't ship it), plus rsync -- the one common dev
# tool the base image was missing (it already has git, gcc/g++/make, python3+pip+venv,
# curl/wget, vim/nano, unzip/jq/tar, ssh -- a real dev toolchain, not a stripped-down runtime).
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y --no-install-recommends nodejs rsync && \
    rm -rf /var/lib/apt/lists/*

# Native installer, not `npm install -g` -- Claude Code's own auto-update logic expects to
# find/manage itself at ~/.local/bin/claude (this installer's location), and nags with a
# "missing or broken, run claude install to repair" warning on every launch otherwise.
RUN curl -fsSL https://claude.ai/install.sh | bash && \
    ln -s /root/.local/bin/claude /usr/local/bin/claude
RUN curl -fsSL https://opencode.ai/install | bash && \
    ln -s /root/.opencode/bin/opencode /usr/local/bin/opencode

WORKDIR /work
