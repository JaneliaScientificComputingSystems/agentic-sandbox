# agentic-sandbox

Sandboxing for unsupervised agentic loops on Janelia's LSF cluster. Two wrappers with the same
flags:

- **`scripts/sandbox-run.sh`** — Bubblewrap (`bwrap`). No root, no daemon, no image. The default.
- **`scripts/podman-run.sh`** — rootless Podman. For a task that needs a container image (CUDA toolkit,
  cuDNN, PyTorch). Plain GPU access no longer needs it: `sandbox-run.sh --gpu` does that.

They exist because internal guidance requires that an agentic loop running without a human
reviewing each step has its file, device and network access restricted to what the task needs, and
that agent-generated code never runs with a user's full permissions. Everything here has been tested
live on the cluster as an ordinary user account.

**Which document:** [`SETUP.md`](SETUP.md) first (one-time, per account) · this README to use the
wrappers · [`CHANGELOG.md`](CHANGELOG.md) for behaviour changes · [`ADMIN-NOTES.md`](ADMIN-NOTES.md)
for the evidence and reasoning behind each decision.

**In short:** the agent sees only the directories you bind in (the one you start from is read-write),
reaches only hosts you `--allow`, sees none of your shell environment, and works on a throwaway copy of
its own config. What it writes into a read-write directory outlasts the job; see [what it does and does
not protect against](#what-it-does-and-does-not-protect-against).

## Before you start

| To use | You need once | See |
| --- | --- | --- |
| `sandbox-run.sh` (bwrap) | a clone of this repo; nothing else | `SETUP.md` §1–2 |
| `--claude` | `claude auth login` outside the sandbox | `SETUP.md` §4 |
| `--opencode` | a LiteLLM key for `kimi-k3` from HPC | `SETUP.md` §5 |
| `sandbox-run.sh --gpu` | nothing more; run it inside an LSF GPU job | `SETUP.md` §2 |
| `podman-run.sh` (a container image) | a subuid/subgid range from HPC (**not self-service, ask first**) and a `storage.conf` | `SETUP.md` §3 |
| `--csub` (optional) | csub installed and a policy file | `SETUP.md` §6 |

## Try it first (no login or key needed)

From an interactive job (`bsub -q short -Is /bin/bash`), with `SANDBOX` pointing at this repo's
`scripts/` directory:

```bash
SANDBOX=/path/to/agentic-sandbox/scripts
mkdir -p /scratch/$USER/work && cd /scratch/$USER/work      # a work dir, not this checkout

# 1. Your home is not there and there is no network:
"$SANDBOX"/sandbox-run.sh --scratch -- bash -c 'ls -A "$HOME"; curl -sS -m 5 https://example.com'
#    -> "ls: cannot access '<your home>': No such file or directory", then "Could not resolve host"

# 2. The directory you started in is writable, and one allowed host is reachable:
"$SANDBOX"/sandbox-run.sh --scratch --allow example.com -- bash -c \
  'touch ok.txt && echo wrote-ok; curl -sS -o /dev/null -w "%{http_code}\n" https://example.com'
#    -> wrote-ok, 200   (an un-allowed host answers 000)
```

## Quick start

```bash
# opencode + Kimi K3, one-shot
"$SANDBOX"/sandbox-run.sh --scratch --opencode --allow litellm.int.janelia.org -- \
  opencode run "who am I speaking to?" --model litellm/kimi-k3

# Claude Code, interactive session
"$SANDBOX"/sandbox-run.sh --scratch --claude \
  --allow api.anthropic.com --allow claude.ai --allow platform.claude.com -- claude

# the same on a GPU node (8 slots per GPU on gpu_l4): with the host's driver under bwrap ...
bsub -q gpu_l4 -gpu "num=1" -n 8 -Is /bin/bash
"$SANDBOX"/sandbox-run.sh --gpu --scratch --claude \
  --allow api.anthropic.com --allow claude.ai --allow platform.claude.com -- claude
# ... or in a container image that brings CUDA, cuDNN and PyTorch
"$SANDBOX"/podman-run.sh --gpu --scratch --claude \
  --allow api.anthropic.com --allow claude.ai --allow platform.claude.com -- claude
```

**A hang or endless `Request timed out` retries means a missing `--allow`**: there is no network by
default and these clients don't fail fast. On a non-zero exit the wrapper prints the denied hosts.

The sandbox is identical in the three ways to run it; only the submission differs:

- **A — one-shot.** A single command as a plain `bsub` job. This is the unsupervised case the
  policy targets:
  ```bash
  bsub -q short -o out.log "$SANDBOX/sandbox-run.sh --scratch --opencode --allow litellm.int.janelia.org -- \
    opencode run 'who am I speaking to?' --model litellm/kimi-k3"
  ```
- **B — loop.** As A, looping over tasks inside one sandbox (state persists between iterations; for
  isolation submit one sandbox per iteration).
- **C — interactive.** `bsub -Is`, then a REPL. A human is present, so the sandbox is defence in depth.

## Adapting your project

- **Start from the directory the agent may change.** `$PWD` is the only read-write path by default.
  Don't start from `$HOME` or from this checkout (the wrapper re-binds its own directory read-only if
  you do).
- **Data in, results out.** `--ro /groups/lab/reference-data` for inputs, `--rw
  /groups/lab/project/results` for outputs: specific subdirectories, never `$HOME`. Write results to
  durable storage. `/scratch` is node-local and wiped hourly on nodes where you have no job, so a
  result left there can vanish, and a batch job on another node won't see files from your
  interactive session.
- **Code in.** Copy or `git clone` it into the work directory. Use git to review what the agent
  changed afterwards.
- **Dependencies.** Install them beforehand into a venv under a path you bind `--ro`, so the agent
  can't change it. A venv records the interpreter that built it, so build it with the Python the
  sandbox will use. For podman, inside the image (verified with the gpu image):
  `podman-run.sh --keep-id --rw /groups/lab/venv --allow pypi.org --allow files.pythonhosted.org -- bash -c
  'python3 -m venv --system-site-packages /groups/lab/venv && /groups/lab/venv/bin/pip install PKG'`.
  `--system-site-packages` keeps torch and the rest of the image. For bwrap, build it with the host's
  `python3` the same way (`sandbox-run.sh --rw /groups/lab/venv --allow pypi.org --allow
  files.pythonhosted.org -- bash -c 'python3 -m venv /groups/lab/venv && /groups/lab/venv/bin/pip
  install PKG'`; verified with PyTorch, about 6 GB and four minutes).
- **Git.** Credentials (`~/.ssh`, `.git-credentials`) aren't bound, so the agent can commit locally
  but can't push or clone private repos. Push from outside after reviewing.
- **Treat what the agent wrote as untrusted.** Files in a read-write directory persist after the job,
  and some run later as you, outside the sandbox: `.git/hooks/*`, project-level `.claude/settings.json`
  and `.mcp.json`. Review them before using the directory outside the sandbox.
- **Resuming a Claude session.** The per-job config starts without history, so `claude --resume` and
  `--continue` find nothing. `--claude-history` (with `--claude`, `sandbox-run.sh` only) binds the
  past sessions of the directory you start from, and only those, read-only; the conversation can be
  continued but the new turns are not kept. `--claude-history-rw` keeps them, and lets the agent
  edit the old transcripts. Either way the agent can read everything said in those earlier
  sessions, including ones you ran outside the sandbox from the same directory.
- **Another harness?** Find where it keeps config and state, grant those paths with `--rw`/`--ro`,
  and `--allow` the domains its model needs.

```bash
cd /groups/lab/project/agent-work            # the one directory the agent can change
"$SANDBOX"/sandbox-run.sh --claude --ro /groups/lab/reference-data \
  --allow api.anthropic.com --allow claude.ai --allow platform.claude.com -- claude
```

## How the sandbox works

**Filesystem, default-deny.** Only what is bound exists inside. Always bound: the toolchain
(`/usr /bin /lib64 /lib /sbin /etc`) read-only and `$PWD` read-write (bwrap), or just the `-v` mounts
you name (podman, whose cwd is the image's `WORKDIR`). `$HOME` is bound only if you ask. `/tmp` is a
private tmpfs (bwrap) or the container's own (podman). The more specific path keeps its
own mode, whatever the flag order: a `--rw` inside a `--ro` tree is writable for that subtree only,
and a `--ro` inside a `--rw` tree (or inside `$PWD`) stays read-only.

**Credential masking (bwrap only).** Directly under every bound root (`$PWD`, `$HOME` if bound, every
`--ro`/`--rw`/`--scratch` path), `.ssh`, `.aws`, `.azure`, `.kube`, `.config/gcloud` and `.docker`
appear as empty directories, and `.git-credentials`, `.npmrc`, `.pypirc`, `.netrc`, `.env`,
`.env.local` as empty files. The same names under `$HOME` are masked
whenever they are inside a bound root (from `~/.config`, `gcloud/` is empty), and a root that is one
of those `$HOME` locations, or inside one, is refused, as is `~/.claude` itself read-write. Only
paths that exist at start are masked, and under a project root only direct children: a `.env` two
levels down is readable. The full list is in the sandbox's own `/run/sandbox/README.md`.
Podman can't do this (a `--tmpfs` can't shadow a path under an ancestor `-v` bind), so
`podman-run.sh` refuses `--rw`/`--ro` on a path that is or contains `$HOME` (a subdirectory is fine),
and on one that contains `/scratch/$USER/.agentic-sandbox`.

**Network, default-deny.** Without `--allow` there is no network. `scripts/allowlist_proxy.py` runs
outside the sandbox on a Unix socket and allows `CONNECT`/HTTP to the listed hostnames and their
subdomains, **on any port**, refusing everything else. The socket is bound into the sandbox and
`scripts/relay.py` exposes it on loopback; `http_proxy`/`https_proxy` (both cases) and `no_proxy` are
set. There is no direct route out: no raw TCP, no package registries you didn't list. But a
`CONNECT` tunnel to a listed host's non-HTTP port (its ssh port, say) is permitted, so list only
hosts you'd accept that for. No SOCKS5, deliberately: Claude Code only speaks HTTP proxies.

**Environment (bwrap).** The sandbox starts empty. Only `PATH`, `HOME`, `USER`, `LOGNAME`, `SHELL`,
`TERM`, `COLORTERM`, `LANG`/`LC_*`, `TZ` and the CA-bundle variables come through, plus anything named
with `--env`. LSF forwards your whole shell environment into a job, so otherwise an exported
`ANTHROPIC_API_KEY`, `HF_TOKEN` or `AWS_*` would be readable by the agent. Podman forwards no host
environment. When stdin is not a terminal the bwrap sandbox gets its own session (`--new-session`) so
it can't type into your terminal.

**Harness config is copied, not bound.** `--claude` gives the sandbox a per-job copy of
`~/.claude.json`, `~/.claude/settings.json` and `~/.claude/CLAUDE.md`, with `CLAUDE_CONFIG_DIR`
pointing at it; only `~/.claude/.credentials.json` is bound through, so logins and token refreshes
persist. `--opencode` copies `~/.config/opencode` and binds the three data dirs (`~/.local/share`,
`~/.local/state`, `~/.cache`) read-write. Why: hooks, MCP entries and plugins are commands the harness
runs *as you, outside the sandbox, in your next session*; an agent that could write them would have a
way out that outlives the job. Edits to the copies die with the job. The CLI binaries are bound
read-only and put on `PATH`.

**Per-job state.** Everything a run creates (config copies, proxy and broker sockets, the generated
in-sandbox README, under podman the image store) lives in
`/scratch/$USER/.agentic-sandbox/<LSB_JOBID>[-<LSB_JOBINDEX>]-<pid>/` (mode 700), removed whole at
exit, also on `bkill` and walltime kills. Nothing goes to `/tmp`. That is why `--scratch` binds
`/scratch/$USER/work`, not `/scratch/$USER`: the whole tree would expose every concurrent job's state,
including a sibling's proxy socket with a different allowlist. bwrap masks `.agentic-sandbox/` if a
bound root contains it; podman can't, so never bind `/scratch/$USER` itself.

**The agent is told all this.** Every sandbox contains `/run/sandbox/README.md` (`$SANDBOX_README`),
generated from the actual invocation: mounts and modes, reachable hosts, environment and, with
`--csub`, the job-submission policy. With `--claude` the per-job `CLAUDE.md` points to it, so the agent
stops probing for paths, hosts or images that don't exist for it.

## Submitting cluster jobs from inside the sandbox (`--csub`)

A sandboxed agent must not hold `bsub`: anything it submitted would run on the cluster outside any
sandbox. `--csub` closes that gap with [csub](https://github.com/saalfeldlab/csub), Stephan
Saalfeld's policy-checked job broker, over the same socket bridge `--allow` uses:

```
compute node (your interactive job)                                   another compute node
──────────────────────────────────────────────────────────────────     ───────────────────────────
sandbox-run.sh / podman-run.sh --csub …                                 csub's job wrapper
  ├─ csub-broker --serve <state dir>/csub/csub.sock   (OUTSIDE)  ──bsub──▶ ├─ csub-broker --serve …
  └─ sandbox: agent runs `csub submit …` ─unix socket─▶ broker            └─ podman-run.sh … -- your command
                                                                              └─ `csub submit …` again, if it wants
```

- The wrapper starts `csub-broker --serve` outside the sandbox, as you, and stops it at exit; only its
  socket crosses the boundary, at `/run/csub.sock`.
- Inside, `csub` and `import csub` work with the sandbox's own `python3` (the csub package is
  bound read-only on `PYTHONPATH`, a shim is on `PATH`). `CSUB_TRANSPORT`, `CSUB_SOCKET` and `CSUB_MOUNTS` are set;
  `CSUB_MOUNTS` comes from `$PWD` and the `--rw`/`--ro` paths not under `$HOME` or `/scratch` (nested
  ones dropped); a preset `$CSUB_MOUNTS` may only narrow that list, and the wrapper refuses one that
  does not.
- The broker applies **your** `~/.config/csub/broker.toml` (roots, images, hosts, queues, limits); the
  agent gets a job id or a `policy_violation`. Child jobs run through these wrappers (`sandbox =
  "podman"` or `"bwrap"` in the policy) and can submit again. GPU children under `sandbox = "bwrap"` need a
  csub that passes `--gpu` to `sandbox-run.sh` (saalfeldlab/csub `main` refuses them as of
  2026-11-14; its open PR #15 removes the refusal and adds the flag). Set `sandbox_scripts_dir` in
  `broker.toml` to this checkout's `scripts/` if it is not at csub's default
  `~/.local/share/csub/agentic-sandbox/scripts`. `--gpu` on the parent sandbox is independent: it
  changes neither the mounts nor the hosts in the envelope.
- **The agent controls `CSUB_MOUNTS` inside the sandbox**, but the broker is started with this
  sandbox's mounts and `--allow` hosts as its envelope (csub #13), so a child job cannot mount a
  directory the sandbox itself can't see, or reach a host it can't. With nothing to put in the
  envelope (podman with only `/scratch` mounted and no `--allow`, say) or a csub without it, the
  wrapper refuses to start; `CSUB_ENVELOPE=off` accepts a broker bounded by the policy alone. Keep
  `allowed_roots` as narrow as the project either way.
- Needs `csub-broker` on `PATH` at start and a policy (`SETUP.md` §6). Without `bsub` on the host,
  `--csub` fails at start; csub's `csub relay` is the tool for that case.

```bash
export PATH=~/.venvs/csub/bin:$PATH
cd /groups/<your-allowed-root>/project
"$SANDBOX"/sandbox-run.sh --csub --claude \
  --allow api.anthropic.com --allow claude.ai --allow platform.claude.com -- claude
# inside:  csub probe · csub submit --walltime 30 [--gpus 1 -q gpu_l4] [--wait] -- python train.py
#          csub status · csub logs <id> · csub kill <id>     (output: <cwd>/.csub/jobs/<id>/stdout)
```

Verified live on both wrappers: probe, submit with wait (child in its own container on another node),
status, a policy rejection as exit code 3, and a child submitting a grandchild. Nothing left behind.

## Images (podman)

Neither is required; `--image` takes any OCI image. A csub policy decides which images child jobs may use.

| Image | Base | Contents | Size | Use when |
| --- | --- | --- | --- | --- |
| `ghcr.io/janeliascientificcomputingsystems/agentic-sandbox-lite:latest` (default, `podman/Dockerfile`) | `nvcr.io/nvidia/cuda:13.3.0-base-ubuntu22.04` | CUDA runtime libraries, Node.js, Claude Code, opencode, `git`, `rsync`, `python3` | 1.24 GB | coding agent on a GPU node that isn't doing ML itself; `nvidia-smi` and the CUDA runtime API work, `nvcc`/cuDNN do not |
| `ghcr.io/janeliascientificcomputingsystems/agentic-sandbox-gpu:latest` (`podman/Dockerfile.pytorch`) | `nvcr.io/nvidia/pytorch:26.07-py3` | PyTorch 2.13, cuDNN, `gcc`/`g++`/`make`, `pip`/`venv`, `curl`/`wget`, `vim`, `jq`, `ssh`, plus the same CLIs | several GB | real ML work, native extensions, "set up a venv and pip install" tasks |

`podman-run.sh` checks for a newer image on every run (a digest check; a download only if it changed).
`--allow` needs `bash` and `python3` in the image for the in-container relay; a minimal image such as
`alpine` fails with `executable file /bin/bash not found`.

## Harnesses
Logging in and configuring are in `SETUP.md` §4–5. At run time:

- **Claude Code.** A fresh `claude auth login` inside the sandbox works only if
  `~/.claude/.credentials.json` already exists on the host. An API key beats an expired login; never
  put it on a `bsub` command line. Not carried in: `~/.claude/plugins`, skills, `projects/` history
  (add `--ro`/`--rw` for a path a task needs; for this directory's history, `--claude-history`).
- **opencode + Kimi K3.** **Always name the model** interactively, `opencode -m litellm/kimi-k3`: bare
  `opencode` defaults to its hosted "OpenCode Zen" model, which talks to hosts outside your allowlist
  and fails with a bare `Forbidden`. One-shot `opencode run ... --model litellm/kimi-k3` is unaffected.
  Run **one opencode sandbox per account at a time**: its sqlite database on NFS is bound into every
  `--opencode` sandbox, and two concurrent ones race on it.
- **Unattended `opencode run` (Mode A/B).** opencode asks before reading outside its working
  directory and cannot ask in a batch job, so the read is auto-rejected and the model may give up and
  exit 0. The sandbox is the boundary, so allow it: `export
  OPENCODE_CONFIG_CONTENT='{"permission":{"external_directory":"allow"}}'` and pass `--env
  OPENCODE_CONFIG_CONTENT` to `sandbox-run.sh` (tested under bwrap, not podman). An agent that gives up
  still exits 0, so check for the output you expect, not the exit code.
- **The Kimi K3 safeguard.** Requests to `kimi-k3` pass through a gateway guardrail (an LLM-as-judge
  for harmful content and jailbreaks) whatever the client. A refusal is either the gateway's
  `GuardrailRaisedException`/400 naming the check (`content_harm`) or the model declining in prose;
  both have been seen on the same prompt. Claude via Anthropic directly has no gateway guardrail.
  Treat either as a normal outcome, not a broken service.

## GPU and podman specifics
- **GPU under bwrap (`sandbox-run.sh --gpu`).** Each entry of `CUDA_VISIBLE_DEVICES` is mapped
  (`nvidia-smi` → PCI bus id → `/proc/driver/nvidia/gpus/<bus>/information` → device minor) to its
  `/dev/nvidiaN`, and bound in with `/dev/nvidiactl`, `/dev/nvidia-uvm` and `/dev/nvidia-uvm-tools`; the
  job's other GPUs get no device node. Inside, `CUDA_VISIBLE_DEVICES` is renumbered to match (`0..n-1`
  in the order given, with `CUDA_DEVICE_ORDER=PCI_BUS_ID`), so starting one sandbox per GPU of a
  multi-GPU job works. NVML also needs the GPU's PCI identity from sysfs, so
  `/sys/devices` and `/sys/module` are bound read-only (without them: `GPU access blocked by the
  operating system`; `nvidia-smi` and PyTorch both work with just those two). What this exposes: the
  node's hardware inventory (PCI topology including the GPUs you were not given, NICs and MACs, DMI
  strings, module parameters), read-only and not openable, since only your GPUs' device nodes exist.
  The driver libraries and `nvidia-smi` come from the host `/usr`/`/lib64`; there is no cuDNN or
  PyTorch unless you bind a venv/conda env (`--ro`). `module load cuda/<ver>` on the host before
  starting works too: the toolkits live under `/usr/local/cuda-*`, already bound, and `PATH` is passed
  in; add `--env CUDA_HOME --env LD_LIBRARY_PATH` for anything that loads `libcudart`/`libcublas`
  dynamically (a static `nvcc` build did not need them). Some installs on a node are incomplete (on the L4
  nodes checked, cuda/12.4 and 12.9, which is `cuda/12-latest`, lack `cuda_runtime.h`; 11.8 and 13.x
  have it, so prefer a 13.x toolkit). Recipe from `AFzoo/scripts/env/bwrap-gpu.sh`.
  `--gpu` in a job with no GPU is an error.
- **Why podman for GPUs, then.** When the task wants an image with the toolkit, cuDNN and PyTorch
  already in it. There `--gpu` maps to `--device nvidia.com/gpu=all` (NVIDIA CDI), which a bare bwrap
  doesn't have (nor does Anthropic's `sandbox-runtime`:
  [anthropics/claude-code#13108](https://github.com/anthropics/claude-code/issues/13108)). Isolation
  differs little for the GPU itself: podman gets `/dev/nvidiaN`, `/dev/dri/*` and the control nodes
  from the CDI spec, and a rootless container normally sees a read-only bind of the host's whole `/sys`
  (not tested here), which is wider than bwrap's two required subtrees; podman adds masked `/proc`/`/sys`
  paths and an image-only filesystem.
- **Podman's own logging is off.** `podman-run.sh` passes `--log-driver=none` and
  `--events-backend=none` whatever your `containers.conf` says; the node default, `journald`, would
  copy everything the container prints into the system logs. Output still reaches your terminal and
  the job's output file; `podman logs` shows nothing.
- **`gpu=all` is safe on a shared node**: LSF's device cgroup fences a job to its allocation, so a
  1-GPU job on an 8-GPU node sees one GPU. Don't attach by index (`CUDA_VISIBLE_DEVICES` is `0` in every
  LSF GPU job, while CDI names count the whole node). `--gpu` in a job with no GPU is an error.
- **"root" inside is you.** The container process is uid 0 with `$HOME=/root`, but rootless podman maps
  that to your uid: files written to a `--rw` path are yours, and its capabilities apply only inside.
  `--keep-id` makes `whoami` and `$HOME` match too (shorthands mount at `$HOME/...`, not `/root/...`);
  it needs a subuid/subgid range wider than your real GID (`SETUP.md` §3), else `potentially
  insufficient UIDs or GIDs available`.
- **Your podman jobs can share a node.** Each invocation has its own image store and runtime dir keyed
  on job id, array index and pid; a pulled image is reused through a read-only shared store, which the
  wrapper never resets. Request the queue's normal CPU-to-GPU ratio; `bsub -gpu` needs an explicit GPU
  queue. Check `bqueues` before choosing one: on 2026-10-17 `gpu_l4` had about 218,000 jobs pending
  from a single array, while `gpu_short` (60-minute limit, for short test jobs) dispatched at once.

## What it does and does not protect against

Assuming the agent is fully adversarial, it **is** stopped from:

- Reading or writing anything outside the bound paths, including `$HOME` and other users' data.
- Reading credential files directly under bound paths (bwrap).
- Reaching any host not on the allowlist.
- Reading secrets from your environment (bwrap clears it; podman forwards none).
- Changing your *user-level* Claude Code or opencode configuration (it works on copies).
- Submitting cluster jobs except through a policy-checked broker, and then only sandboxed ones.
- Typing into your terminal after exit (bwrap `--new-session`, non-interactive runs).
- Interfering with your other concurrent sandbox jobs' state.

It is **not** stopped from:

- **Anything you gave it read-write, persistently.** That includes the real credentials file bound
  into `--claude` sandboxes, opencode's three data dirs, and in the working directory `.git/hooks`,
  project-level `.claude/settings.json` and `.mcp.json`. Those can run later as you, outside the
  sandbox; review them before using the directory outside.
- **Using a listed host over any port**, not just HTTPS (a `CONNECT` tunnel to its ssh port works);
  the proxy doesn't inspect content.
- **Credentials deeper than direct children**, e.g. a `.env` in a subdirectory; and, with podman, any
  credentials under a bound path (no masking, which is why binding `$HOME` is refused).
- **Making syscalls the kernel allows an unprivileged user** (bwrap installs no seccomp filter, and
  the cluster's bwrap 0.6 predates `--disable-userns`, so nested user namespaces stay available).
- **Reading the node's hardware inventory with `sandbox-run.sh --gpu`**: `/sys/devices` and
  `/sys/module` are visible read-only (PCI topology, NICs and MACs, DMI strings). Without `--gpu`
  there is no `/sys` at all.
- Anything multi-node: one sandbox, one host. No MPI, Ray, DDP, Spark or Dask across nodes.
- Your own mistakes in Mode C: a human is present and the sandbox limits damage but doesn't review.

## Running under LSF
- LSF's cgroup limits apply unchanged. `bkill` and walltime kills reach the whole process tree, and
  both wrappers route TERM/INT/USR2 through cleanup, so the proxy, broker and state dir go too.
- Never run work on a login node; get a compute node with `bsub -Is`. Don't `ssh` to one instead: with
  no LSF job of yours on it, the hourly cleanup wipes your `/scratch/$USER` there.
- Some queues reject a plain backgrounded `bsub`; `short` works for one-shots. `-m <host>` only works
  for hosts in the queue's host group. bwrap needs `/proc/sys/user/max_user_namespaces` > 0.

## Flag reference

```
sandbox-run.sh [options] -- <command...>          # bwrap: the host's own files and driver
podman-run.sh  [options] -- <command...>          # podman: a container image

  --ro PATH       Read-only bind (repeatable)
  --rw PATH       Read-write bind (repeatable)
  --allow HOST    Allowed egress domain (repeatable); omit for no network
  --env NAME      (sandbox-run.sh) copy host variable NAME into the sandbox (repeatable)
  --csub          Start a csub broker outside the sandbox and give the agent `csub` inside
  --scratch       Shorthand for --rw /scratch/$USER/work (created if missing)
  --claude        Per-job copy of Claude Code's config, credentials file bound through, CLI on PATH
  --claude-history[-rw]  (sandbox-run.sh, with --claude) this directory's past Claude sessions, so
                  `claude --resume`/`--continue` work; read-only, or -rw to keep new ones too
  --opencode      Per-job copy of ~/.config/opencode, data dirs bound rw, CLI on PATH
  --gpu           bind the job's allocated GPU(s) (bwrap: device nodes + read-only /sys/{devices,module}; podman:
                  --device nvidia.com/gpu=all); an error in a job without a GPU
  --shm-size SIZE (podman-run.sh) size of /dev/shm (512m, 8g); default 8g with --gpu, else 64 MB
  --keep-id       (podman-run.sh) run as your real uid/gid instead of container-root
  --image NAME    (podman-run.sh) any OCI image; default agentic-sandbox-lite
  -h, --help      Show help
```

## Testing
`tests/test-bwrap.sh` and `tests/test-podman.sh` are live suites: run them from a compute node (podman:
a GPU job; bwrap: its `--gpu` checks run only in a GPU job, and the subset check needs two GPUs),
**one at a time** (they share opencode's database). Some need a Claude login and a LiteLLM
key; the `--csub` tests need `csub-broker` on `PATH` and `CSUB_TEST_ROOT` under your policy's allowed
roots, else they're skipped. `python3 tests/test-proxy.py` tests the proxy without a cluster, and runs on every push (GitHub
Actions).

## Troubleshooting

- **`Read-only file system`**: the path isn't inside a `--rw` bind. Add the specific path.
- **`unable to allocate shared memory(shm)` / `No space left on device` from PyTorch DataLoader
  workers** (podman): `/dev/shm` is too small. It is 8g with `--gpu` and podman's 64 MB without;
  set it with `--shm-size 16g`. It is a cap, not a reservation, but what is written there counts
  against the job's memory.
- **A request hangs, or `claude`/`opencode` retries with `Request timed out`**: the host isn't on your
  allowlist (the wrapper prints the denied ones). Claude Code needs `api.anthropic.com`, `claude.ai`,
  `platform.claude.com`; opencode+Kimi needs `litellm.int.janelia.org`.
- **`GuardrailRaisedException`/400 from `kimi-k3`**: the safeguard, not a bug. **opencode `Forbidden`**:
  no `-m litellm/kimi-k3`. **`Failed to execute statement`/`UnknownError`**: another `--opencode`
  sandbox of yours is running.
- **`Failed to initialize NVML: GPU access blocked`**: pass `--gpu` (bwrap or podman).
- **`potentially insufficient UIDs or GIDs`**: `--keep-id` with a too-narrow subuid range; ask HPC.
- **`exec: claude: not found` inside**: pass `--claude`; it binds the CLI and puts it on `PATH`.
- **`--csub needs csub-broker on PATH`**: `export PATH=~/.venvs/csub/bin:$PATH` before starting.
- **`csub: broker_misconfigured: ... sandbox_scripts_dir ... missing`**: the policy points at a
  checkout that moved; fix the path in `~/.config/csub/broker.toml`.
- **`csub: policy_violation: mount ... home directory`**: `CSUB_MOUNTS` includes something under
  `$HOME`; work from a directory under an allowed root. `csub --json probe` (`--json` before the
  subcommand) shows the policy.
- **`--csub: nothing to bound child jobs to`** (at start): the sandbox has no mount outside `$HOME`
  and `/scratch` and no `--allow` host, so the broker's envelope would be empty. Add the `--rw`/`--ro`
  path or `--allow` host the child jobs may use, or `CSUB_ENVELOPE=off` for a policy-only broker.
- **`--csub: CSUB_MOUNTS entry ... is not within this sandbox's mounts`**: a preset `CSUB_MOUNTS`
  names a path the sandbox does not have, or asks rw where it is ro. Unset it, or add the path with
  `--rw`/`--ro`.
- **`csub: policy_violation: ... not allowed in the parent`** (from a child's submission): the child
  job claimed a mount or host outside this sandbox's envelope. That is the envelope working; give the
  top-level sandbox the mount or `--allow` host if the child really needs it.
- **The in-sandbox README says an image or host doesn't exist for you**: it is right; change the
  policy or the `--allow` list, outside the sandbox.

## Known limitations
- bwrap `--gpu` gives devices and the host driver only, no CUDA toolkit; podman can't mask credentials. The proxy is HTTP-style only (no SOCKS5), but
  allows any port on a listed host.
- One opencode sandbox per account at a time; `--keep-id` needs a widened subuid/subgid range.
- Per-job state needs a writable `/scratch/$USER`; `sandbox-run.sh` falls back to `$TMPDIR` only off
  the cluster and says so, `podman-run.sh` requires it.
- A `TERM` sent to the wrapper's pid alone is acted on only after the sandboxed command exits (bash
  runs traps between foreground commands). `bkill` and LSF walltime kills signal the whole process
  group, so bwrap or podman gets it too and cleanup runs promptly; a bare `kill <wrapper-pid>` does
  not. Kill the process group (`kill -- -<pgid>`) when doing it by hand.
- `sandbox-run.sh` refuses to run from `$HOME` or a directory above it (the working directory is
  bound read-write). Run it from a project directory.
- Not tested: a fresh `claude auth login` combined with the one-shot or loop modes.

