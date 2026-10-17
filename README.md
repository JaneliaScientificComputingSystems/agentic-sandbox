# agentic-sandbox

Sandboxing for unsupervised agentic loops on Janelia's LSF cluster. Two wrappers with the same
flags:

- **`scripts/sandbox-run.sh`** — Bubblewrap (`bwrap`). No root, no daemon, no image. The default.
- **`scripts/podman-run.sh`** — rootless Podman. Only when a task needs a GPU, which bwrap cannot
  pass through.

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
| `podman-run.sh` (GPU) | a subuid/subgid range from HPC (**not self-service, ask first**) and a `storage.conf` | `SETUP.md` §3 |
| `--csub` (optional) | csub installed and a policy file | `SETUP.md` §6 |

## Try it first (no login or key needed)

From an interactive job (`bsub -q short -Is /bin/bash`), with `SANDBOX` pointing at this repo's
`scripts/` directory:

```bash
SANDBOX=/path/to/agentic-sandbox/scripts
mkdir -p /scratch/$USER/work && cd /scratch/$USER/work      # a work dir, not this checkout

# 1. Your home is not there and there is no network:
"$SANDBOX"/sandbox-run.sh --scratch -- bash -c 'ls -A "$HOME"; curl -sS -m 5 https://example.com'
#    -> only empty .config and .ssh placeholders, then "Could not resolve host"

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

# the same on a GPU node, in a container (8 slots per GPU on gpu_l4)
bsub -q gpu_l4 -gpu "num=1" -n 8 -Is /bin/bash
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
- **Dependencies.** Install them beforehand, outside the sandbox, into a venv under a path you bind
  `--ro`. Inside you reach only the hosts you `--allow`, and compute nodes can't reach PyPI
  directly.
- **Git.** Credentials (`~/.ssh`, `.git-credentials`) aren't bound, so the agent can commit locally
  but can't push or clone private repos. Push from outside after reviewing.
- **Treat what the agent wrote as untrusted.** Files in a read-write directory persist after the job,
  and some run later as you, outside the sandbox: `.git/hooks/*`, project-level `.claude/settings.json`
  and `.mcp.json`. Review them before using the directory outside the sandbox.
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
private tmpfs (bwrap) or the container's own (podman). A more specific `--rw` inside a `--ro` tree
overrides it for that subtree only.

**Credential masking (bwrap only).** Directly under every bound root (`$PWD`, `$HOME` if bound, every
`--ro`/`--rw`/`--scratch` path), `.ssh`, `.aws`, `.azure`, `.kube`, `.config/gcloud` and `.docker`
appear as empty directories, and `.git-credentials`, `.npmrc`, `.pypirc`, `.netrc`, `.env`,
`.env.local` as empty files. Applied last, so a `--rw` on one of those paths doesn't unmask it. Only
paths that exist at start are masked, and only direct children: a `.env` two levels down is readable.
Podman can't do this (a `--tmpfs` can't shadow a path under an ancestor `-v` bind), so with
`podman-run.sh` never bind a path that is or contains `$HOME`.

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
- Inside, `csub` and `import csub` work with the sandbox's own `python3` (csub's `site-packages` is
  bound read-only, a shim is on `PATH`). `CSUB_TRANSPORT`, `CSUB_SOCKET` and `CSUB_MOUNTS` are set;
  `CSUB_MOUNTS` comes from `$PWD` and the `--rw`/`--ro` paths not under `$HOME` or `/scratch` (nested
  ones dropped), or from `$CSUB_MOUNTS` if you preset it.
- The broker applies **your** `~/.config/csub/broker.toml` (roots, images, hosts, queues, limits); the
  agent gets a job id or a `policy_violation`. Child jobs run through these wrappers (`sandbox =
  "podman"` or `"bwrap"` in the policy) and can submit again.
- **The agent controls `CSUB_MOUNTS` inside the sandbox**, and the broker accepts any directory under
  your policy's `allowed_roots`, so a child job can mount directories the sandbox itself can't see.
  Keep `allowed_roots` as narrow as the project.
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
  (add `--ro`/`--rw` for a path a task needs).
- **opencode + Kimi K3.** **Always name the model** interactively, `opencode -m litellm/kimi-k3`: bare
  `opencode` defaults to its hosted "OpenCode Zen" model, which talks to hosts outside your allowlist
  and fails with a bare `Forbidden`. One-shot `opencode run ... --model litellm/kimi-k3` is unaffected.
  Run **one opencode sandbox per account at a time**: its sqlite database on NFS is bound into every
  `--opencode` sandbox, and two concurrent ones race on it.
- **The Kimi K3 safeguard.** Requests to `kimi-k3` pass through a gateway guardrail (an LLM-as-judge
  for harmful content and jailbreaks) whatever the client. A refusal is either the gateway's
  `GuardrailRaisedException`/400 naming the check (`content_harm`) or the model declining in prose;
  both have been seen on the same prompt. Claude via Anthropic directly has no gateway guardrail.
  Treat either as a normal outcome, not a broken service.

## GPU and podman specifics
- **Why podman.** GPU access from a namespace-isolated process on data-centre NVIDIA drivers needs the
  NVIDIA Container Toolkit's CDI integration, which bwrap can't provide (nor can Anthropic's
  `sandbox-runtime`: [anthropics/claude-code#13108](https://github.com/anthropics/claude-code/issues/13108)).
  `--gpu` maps to `--device nvidia.com/gpu=all`.
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
  queue.

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
  credentials under a bound path (no masking: never bind `$HOME`).
- **Inheriting file descriptors** (bwrap): descriptors your launching shell had open beyond 0–2 are
  visible inside. Launch from a clean shell.
- **Making syscalls the kernel allows an unprivileged user** (bwrap installs no seccomp filter).
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
sandbox-run.sh [options] -- <command...>          # bwrap, no GPU
podman-run.sh  [options] -- <command...>          # podman, GPU-capable

  --ro PATH       Read-only bind (repeatable)
  --rw PATH       Read-write bind (repeatable)
  --allow HOST    Allowed egress domain (repeatable); omit for no network
  --env NAME      (sandbox-run.sh) copy host variable NAME into the sandbox (repeatable)
  --csub          Start a csub broker outside the sandbox and give the agent `csub` inside
  --scratch       Shorthand for --rw /scratch/$USER/work (created if missing)
  --claude        Per-job copy of Claude Code's config, credentials file bound through, CLI on PATH
  --opencode      Per-job copy of ~/.config/opencode, data dirs bound rw, CLI on PATH
  --gpu           (podman-run.sh) --device nvidia.com/gpu=all; an error in a job without a GPU
  --keep-id       (podman-run.sh) run as your real uid/gid instead of container-root
  --image NAME    (podman-run.sh) any OCI image; default agentic-sandbox-lite
  -h, --help      Show help
```

## Testing
`tests/test-bwrap.sh` and `tests/test-podman.sh` are live suites: run them from a compute node (podman:
a GPU job), **one at a time** (they share opencode's database). Some need a Claude login and a LiteLLM
key; the `--csub` tests need `csub-broker` on `PATH` and `CSUB_TEST_ROOT` under your policy's allowed
roots, else they're skipped. `python3 tests/test-proxy.py` tests the proxy without a cluster.

## Troubleshooting

- **`Read-only file system`**: the path isn't inside a `--rw` bind. Add the specific path.
- **A request hangs, or `claude`/`opencode` retries with `Request timed out`**: the host isn't on your
  allowlist (the wrapper prints the denied ones). Claude Code needs `api.anthropic.com`, `claude.ai`,
  `platform.claude.com`; opencode+Kimi needs `litellm.int.janelia.org`.
- **`GuardrailRaisedException`/400 from `kimi-k3`**: the safeguard, not a bug. **opencode `Forbidden`**:
  no `-m litellm/kimi-k3`. **`Failed to execute statement`/`UnknownError`**: another `--opencode`
  sandbox of yours is running.
- **`Failed to initialize NVML: GPU access blocked`**: bwrap can't do GPUs; use `podman-run.sh`.
- **`potentially insufficient UIDs or GIDs`**: `--keep-id` with a too-narrow subuid range; ask HPC.
- **`exec: claude: not found` inside**: pass `--claude`; it binds the CLI and puts it on `PATH`.
- **`--csub needs csub-broker on PATH`**: `export PATH=~/.venvs/csub/bin:$PATH` before starting.
- **`csub: broker_misconfigured: ... sandbox_scripts_dir ... missing`**: the policy points at a
  checkout that moved; fix the path in `~/.config/csub/broker.toml`.
- **`csub: policy_violation: mount ... home directory`**: `CSUB_MOUNTS` includes something under
  `$HOME`; work from a directory under an allowed root. `csub --json probe` (`--json` before the
  subcommand) shows the policy.
- **The in-sandbox README says an image or host doesn't exist for you**: it is right; change the
  policy or the `--allow` list, outside the sandbox.

## Known limitations
- bwrap can't do GPUs; podman can't mask credentials. The proxy is HTTP-style only (no SOCKS5), but
  allows any port on a listed host.
- One opencode sandbox per account at a time; `--keep-id` needs a widened subuid/subgid range.
- Per-job state needs a writable `/scratch/$USER`; `sandbox-run.sh` falls back to `$TMPDIR` only off
  the cluster and says so, `podman-run.sh` requires it.
- Not tested: a fresh `claude auth login` combined with the one-shot or loop modes.

