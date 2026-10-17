# One-time setup

Everything here is per account and done once. None of it runs on a login node: start an
interactive job first (`bsub -q short -Is /bin/bash`) and do the setup there. The README assumes
all of this is in place.

## 1. Get the wrappers

```bash
git clone https://github.com/JaneliaScientificComputingSystems/agentic-sandbox.git
SANDBOX="$PWD/agentic-sandbox/scripts"        # the README's examples use this variable
# a new job shell starts without it: put the line above in your shell startup file
```

Run the wrappers from a work directory, not from inside the checkout: the directory you invoke
them from is bound read-write, and the wrapper and its helper scripts run on the host. (If you do
run from the checkout, the wrapper re-binds its own directory read-only and says so.)

## 2. bwrap: nothing to set up

`sandbox-run.sh` needs only `bwrap` and `python3`, both present on the cluster nodes, and
unprivileged user namespaces (`/proc/sys/user/max_user_namespaces` > 0), which are enabled here.

## 3. Podman (GPU jobs)

**Rootless podman needs a `/etc/subuid`/`/etc/subgid` range for your account.** HPC provisions
these per user; they are not self-service and not granted by default. Ask before your first
podman job. For `--keep-id` the range must be *wider than your real GID*, which for AD/LDAP
accounts means more than the standard 65536 (a 131072-wide range works); ask for that explicitly
if you want `--keep-id`.

Point podman's image and container storage at node-local scratch instead of your home
directory, and turn off its own logging. Both are per-user config files in `$HOME`, so this is
once per account even though `/scratch` is per node:

```bash
mkdir -p ~/.config/containers
cat > ~/.config/containers/storage.conf << 'EOF'
[storage]
driver = "overlay"
runroot = "/scratch/$USER/podman-run"
graphroot = "/scratch/$USER/podman-storage"
[storage.options]
mount_program = "/usr/bin/fuse-overlayfs"
EOF

cat > ~/.config/containers/containers.conf << 'EOF'
[engine]
events_logger = "none"

[containers]
log_driver = "none"
EOF
```

If you already have a `containers.conf`, add or update the two settings rather than overwriting
it. You do not need to create the storage directories; podman does that on first use on each
node.

What this buys and costs: podman's per-user storage would otherwise land in
`~/.local/share/containers` and fill your home with multi-GB images. On scratch it is node-local
and wiped by the hourly cleanup whenever you have no job on that node, so a job on a new node, or
one starting more than an hour after your previous job there, pulls the image again (the lite
image is 1.24 GB; the PyTorch one several GB). If you'd rather trade that for a durable cache,
point `graphroot`/`runroot` at a path under `$HOME`.

No `podman login` or `podman pull` is needed: the images are public and `podman-run.sh` checks
for a newer one on every run.

## 4. Claude Code

Log in once outside the sandbox, from an interactive job:

```bash
claude auth login      # browser flow; paste the code back
```

That writes `~/.claude/.credentials.json`, which the wrappers bind through into every `--claude`
sandbox, so logins and token refreshes persist. A fresh `claude auth login` *inside* a sandbox
also works, but only if that file already exists on the host; otherwise the login is lost with
the job. The wrappers warn when that applies. The OAuth redirect goes to `platform.claude.com` and
lands on a paste-the-code prompt, so open the URL in your own browser, outside the sandbox.

Alternative, an API key: `export ANTHROPIC_API_KEY=...` and pass it with
`sandbox-run.sh --env ANTHROPIC_API_KEY`. For podman, which forwards no environment, put the key
in a `chmod 600` file under `/scratch/$USER/work` and read it inside the container. Never put
the key on a `bsub` command line: LSF keeps that verbatim in `bjobs -l`/`bhist -l`.

## 5. opencode with Kimi K3

Kimi K3 is served behind Janelia's LiteLLM gateway (`litellm.int.janelia.org`). Ask the HPC team
for a LiteLLM virtual key scoped to `kimi-k3`, then:

```bash
mkdir -p ~/.config/opencode && chmod 700 ~/.config/opencode
cat > ~/.config/opencode/opencode.json << 'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "litellm": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "LiteLLM",
      "options": {
        "baseURL": "https://litellm.int.janelia.org/v1",
        "apiKey": "<your kimi-k3-scoped LiteLLM virtual key>"
      },
      "models": { "kimi-k3": { "name": "Kimi K3" } }
    }
  }
}
EOF
chmod 600 ~/.config/opencode/opencode.json
```

The wrappers give each sandbox a throwaway copy of this directory, so edits made inside never
reach it.

## 6. csub (optional: letting a sandboxed agent submit cluster jobs)

Skip this unless an agent must submit jobs. [csub](https://github.com/saalfeldlab/csub) is Stephan
Saalfeld's policy-checked job broker; the wrappers' `--csub` flag starts it for you. Clone it (for
its sample policy) and install it in a venv:

```bash
git clone https://github.com/saalfeldlab/csub ~/csub
python3 -m venv ~/.venvs/csub
~/.venvs/csub/bin/pip install ~/csub
```

Compute nodes reach GitHub but not PyPI. On Python 3.9 csub needs `tomli`, so download that
wheel on a machine with internet, copy it into your home, and
`~/.venvs/csub/bin/pip install --no-index ~/tomli-*.whl`.

```bash
mkdir -p ~/.config/csub
cp ~/csub/deploy/broker.janelia.toml ~/.config/csub/broker.toml
chmod 600 ~/.config/csub/broker.toml
```

Edit the policy:

- `allowed_roots`: directories jobs may mount. Use the narrowest directory under `/groups` or `/nrs`
  that holds the project, ideally one you created for agent work. A sandboxed agent can ask a child
  job to mount any directory beneath a root, not only the ones you gave the sandbox, so everything
  under it is in reach. Never `$HOME` (csub refuses it) and never `/scratch` (the policy rejects it).
- `sandbox_scripts_dir`: this repo's `scripts/` directory; child jobs run through it.
- `allowed_images`: list the concrete images rather than the default glob, so `csub probe` and
  the in-sandbox README can tell an agent exactly what exists:
  `ghcr.io/janeliascientificcomputingsystems/agentic-sandbox-lite:latest` and
  `ghcr.io/janeliascientificcomputingsystems/agentic-sandbox-gpu:latest`.
- `allowed_hosts`, `limits`, `queues`: to taste. The Janelia file's slot and memory numbers mirror
  the cluster's esub.

Check it, then make the broker findable whenever you start a `--csub` sandbox:

```bash
echo '{"protocol":1,"op":"probe"}' | ~/.venvs/csub/bin/csub-broker     # expect "ok":true
export PATH=~/.venvs/csub/bin:$PATH
```

## 7. The images (podman)

Both are pre-built on GHCR and pulled automatically. Build your own only if you need something
they lack:

```bash
cd agentic-sandbox/podman
podman build -t agentic-sandbox-lite:latest .                                   # CUDA runtime + CLIs
podman build -t agentic-sandbox-pytorch:latest -f Dockerfile.pytorch .          # NVIDIA PyTorch + CLIs
# then: podman-run.sh --image localhost/agentic-sandbox-lite:latest ...
```

Note that csub policies cannot use `localhost/` images (they are not visible on other nodes).
