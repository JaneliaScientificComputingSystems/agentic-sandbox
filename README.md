# agentic-sandbox

Sandboxing for unsupervised agentic loops on Janelia's LSF cluster. Two wrappers with the same
flags:

- **`scripts/sandbox-run.sh`** — Bubblewrap (`bwrap`). No root, no daemon, no image. The default.
- **`scripts/podman-run.sh`** — rootless Podman. Only when a task needs a GPU, which bwrap cannot
  pass through.

They exist because internal guidance requires that an agentic loop running without a human
reviewing each step has its file, device and network access restricted to what the task needs,
and that agent-generated code never runs with a user's full permissions. Everything here has been
tested live on the cluster as an ordinary user account; the evidence and the reasoning behind each
decision are in [`ADMIN-NOTES.md`](ADMIN-NOTES.md). Behaviour changes are listed in
[`CHANGELOG.md`](CHANGELOG.md). One-time setup (podman storage, logins, csub) is in
[`SETUP.md`](SETUP.md).

## Quick start

From an interactive job (`bsub -q short -Is /bin/bash`, or a GPU queue for podman), in a work
directory, with `SANDBOX` pointing at this repo's `scripts/` directory:

```bash
SANDBOX=/path/to/agentic-sandbox/scripts
mkdir -p /scratch/$USER/work && cd /scratch/$USER/work

# opencode + Kimi K3, one-shot
"$SANDBOX"/sandbox-run.sh --scratch --opencode --allow litellm.int.janelia.org -- \
  opencode run "who am I speaking to?" --model litellm/kimi-k3

# Claude Code, interactive session
"$SANDBOX"/sandbox-run.sh --scratch --claude \
  --allow api.anthropic.com --allow claude.ai --allow platform.claude.com -- claude

# the same on a GPU node, in a container
bsub -q gpu_l4 -gpu "num=1" -n 8 -Is /bin/bash
"$SANDBOX"/podman-run.sh --gpu --scratch --claude \
  --allow api.anthropic.com --allow claude.ai --allow platform.claude.com -- claude
```

Anything that isn't a REPL can be submitted as a plain `bsub` job instead; that is the
unsupervised case the policy is about:

```bash
bsub -q short -o out.log "$SANDBOX/sandbox-run.sh --scratch --opencode --allow litellm.int.janelia.org -- \
  opencode run 'who am I speaking to?' --model litellm/kimi-k3"
```

## Which flags do I need

| Task | Wrapper | Flags |
| --- | --- | --- |
| Agent with a model, CPU only | `sandbox-run.sh` | `--opencode --allow litellm.int.janelia.org` or `--claude --allow api.anthropic.com --allow claude.ai --allow platform.claude.com` |
| Same, needs a GPU | `podman-run.sh` | the above plus `--gpu`, in a GPU-queue job |
| Agent must read reference data / write results elsewhere | either | `--ro /groups/lab/ref --rw /groups/lab/project/out` (specific subdirectories, never `$HOME`) |
| Node-local scratch space | either | `--scratch` (binds `/scratch/$USER/work`) |
| Agent must submit cluster jobs | either | `--csub` (see [Submitting cluster jobs](#submitting-cluster-jobs-from-inside-the-sandbox---csub)) |
| API key instead of a login | `sandbox-run.sh` | `--env ANTHROPIC_API_KEY` after exporting it; podman: a `chmod 600` file under a mount |
| Run as your real uid inside the container | `podman-run.sh` | `--keep-id` (needs a widened subuid range, see `SETUP.md`) |
| No network at all | either | omit `--allow` |

## How the sandbox works

**Filesystem, default-deny.** Only what is bound exists inside. Always bound: the toolchain
(`/usr /bin /lib64 /lib /sbin /etc`) read-only and `$PWD` read-write (bwrap), or the `-v` mounts you
name (podman, which binds nothing by default and whose cwd is the image's `WORKDIR`). `$HOME` is
never bound unless you ask; ask for the specific subdirectory a task needs, never `$HOME` itself.
`/tmp` is a private tmpfs (bwrap) or the container's own (podman). A more specific `--rw` inside a
`--ro` tree overrides it for that subtree only.

**Credential masking (bwrap only).** Directly under every bound root — `$PWD`, `$HOME` if bound,
every `--ro`/`--rw`/`--scratch` path — `.ssh`, `.aws`, `.azure`, `.kube`, `.config/gcloud` and
`.docker` appear as empty directories, and `.git-credentials`, `.npmrc`, `.pypirc`, `.netrc`,
`.env`, `.env.local` as empty files. Applied last, so a `--rw` on one of those paths does not
unmask it. Only paths that exist when the sandbox starts are masked; a `.env` the agent creates
itself is just a file. Only direct children are checked; a `.env` two levels down is not. Podman cannot do
this (a `--tmpfs` cannot shadow a path under an ancestor `-v` bind), so with `podman-run.sh`
never bind a path that is or contains `$HOME`.

**Network, default-deny.** Without `--allow` there is no network. Each `--allow HOST` is enforced
by `scripts/allowlist_proxy.py`, which runs outside the sandbox on a Unix socket, allows
`CONNECT`/HTTP to the listed hostnames and their subdomains on any port, and refuses the rest.
The socket is bound into the sandbox and `scripts/relay.py` inside exposes it on loopback;
`http_proxy`/`https_proxy` (both cases) and `no_proxy` are set. Nothing else gets out: no raw
TCP, no ssh, no package registries you did not list. If the sandboxed command exits non-zero the
wrapper prints the hosts the proxy denied, which is the list to compare with your `--allow`
flags. No SOCKS5, deliberately: Claude Code only speaks HTTP proxies.

**Environment (bwrap).** The sandbox starts empty. Only `PATH`, `HOME`, `USER`, `LOGNAME`,
`SHELL`, `TERM`, `COLORTERM`, `LANG`/`LC_*`, `TZ` and the CA-bundle variables come through, plus
anything named with `--env`. LSF forwards your whole shell environment into a job, so without this
an exported `ANTHROPIC_API_KEY`, `HF_TOKEN` or `AWS_*` would be readable by the agent. Podman
forwards no host environment at all. When stdin is not a terminal the bwrap sandbox gets its own
session (`--new-session`) so it cannot type into your terminal.

**Harness config is copied, not bound.** `--claude` gives the sandbox a per-job copy of
`~/.claude.json`, `~/.claude/settings.json` and `~/.claude/CLAUDE.md` with `CLAUDE_CONFIG_DIR`
pointing at it; only `~/.claude/.credentials.json` is bound through to the real file, so logins
and token refreshes persist. `--opencode` copies `~/.config/opencode` and binds the three data
dirs (`~/.local/share`, `~/.local/state`, `~/.cache`). Reason: hooks, MCP server entries and
opencode plugins are commands the harness runs *as you, outside the sandbox, in your next
session*; a prompt-injected agent that could write them would have a way out that outlives the
job. Edits made inside die with the job. The CLI binaries themselves are bound read-only and put
on `PATH`.

**Per-job state.** Everything a run creates lives in
`/scratch/$USER/.agentic-sandbox/<LSB_JOBID>[-<LSB_JOBINDEX>]-<pid>/` (mode 700): the config
copies, the proxy socket and log, the csub broker socket, the generated in-sandbox README, and
under podman the per-job image store and runtime dir. Removed whole at exit, also on `bkill` and
walltime kills. Nothing is written to `/tmp`. This is why `--scratch` binds `/scratch/$USER/work`
and not `/scratch/$USER`: the whole tree would expose every other concurrent job's state (same
uid, so permissions don't help), including a sibling's proxy socket with a different allowlist.
bwrap masks `.agentic-sandbox/` if a bound root contains it; podman cannot, so never bind
`/scratch/$USER` itself. The hourly scratch cleanup wipes `/scratch/<user>` only on nodes where
you have no running job, so a job's state is safe for its whole lifetime and crash debris is gone
within an hour.

**The agent is told all this.** Every sandbox contains `/run/sandbox/README.md` (also
`$SANDBOX_README`), generated from the actual invocation: the mounts and their modes, the
reachable hosts, what the environment contains, and with `--csub` the job-submission policy. With
`--claude` the per-job `CLAUDE.md` copy gets a pointer to it, so Claude Code reads it at start.
This stops an agent from probing for paths, hosts or images that do not exist for it.

## Submitting cluster jobs from inside the sandbox (`--csub`)

A sandboxed agent must not hold `bsub`: anything it submitted would run on the cluster outside
any sandbox. `--csub` closes that gap with [csub](https://github.com/saalfeldlab/csub), Stephan
Saalfeld's policy-checked job broker, using the same socket bridge `--allow` uses:

```
compute node (your interactive job)                                   another compute node
──────────────────────────────────────────────────────────────────     ───────────────────────────
sandbox-run.sh / podman-run.sh --csub …                                 csub's job wrapper
  ├─ csub-broker --serve <state dir>/csub/csub.sock   (OUTSIDE)  ──bsub──▶ ├─ csub-broker --serve …
  └─ sandbox: agent runs `csub submit …` ─unix socket─▶ broker            └─ podman-run.sh … -- your command
                                                                              └─ `csub submit …` again, if it wants
```

- The wrapper starts `csub-broker --serve` outside the sandbox, as you, on the node you are on,
  and stops it when the sandbox exits. Only its socket crosses the boundary, at `/run/csub.sock`.
- Inside, `csub` and `import csub` work with the sandbox's own `python3`: csub's `site-packages`
  is bound read-only and a shim is on `PATH`. `CSUB_TRANSPORT`, `CSUB_SOCKET` and `CSUB_MOUNTS`
  are set; `CSUB_MOUNTS` is derived from `$PWD` and the `--rw`/`--ro` paths not under `$HOME` or
  `/scratch` (nested paths dropped, since csub rejects overlapping mounts), or taken from
  `$CSUB_MOUNTS` if you preset it.
- The broker applies **your** `~/.config/csub/broker.toml`: allowed roots, images, hosts, queues,
  limits. The agent gets a job id or a `policy_violation` error, nothing else. Child jobs run
  through these wrappers on their node (`sandbox = "podman"` or `"bwrap"` in the policy) and can
  submit again through csub's own per-job broker.
- Requires `csub-broker` on `PATH` when you start the sandbox (`export PATH=~/.venvs/csub/bin:$PATH`)
  and a policy; see `SETUP.md`. On a host without `bsub`, `--csub` fails at start; csub's `csub
  relay` is the tool for that case.

```bash
export PATH=~/.venvs/csub/bin:$PATH
cd /groups/<your-allowed-root>/project
"$SANDBOX"/sandbox-run.sh --csub --claude \
  --allow api.anthropic.com --allow claude.ai --allow platform.claude.com -- claude
# inside:  csub probe · csub submit --walltime 30 [--gpus 1 -q gpu_l4] [--wait] -- python train.py
#          csub status · csub logs <id> · csub kill <id>     (output: <cwd>/.csub/jobs/<id>/stdout)
```

Verified live, both wrappers: probe, submit with wait (child in its own container on another
node), status, a policy rejection reaching the agent as exit code 3, and a child submitting a
grandchild from inside its own sandbox. Nothing left behind afterwards.

## Images (podman)

Neither image is required; `--image` takes any OCI image and the sandboxing is the same. A csub
policy decides which images child jobs may use.

| Image | Base | Contents | Size | Use when |
| --- | --- | --- | --- | --- |
| `ghcr.io/janeliascientificcomputingsystems/agentic-sandbox-lite:latest` (default, `podman/Dockerfile`) | `nvcr.io/nvidia/cuda:13.3.0-base-ubuntu22.04` | CUDA runtime libraries, Node.js, Claude Code, opencode, `git`, `rsync`, `python3` | 1.24 GB | coding-agent GPU sandbox that isn't doing ML itself; `nvidia-smi` and the CUDA runtime API work, `nvcc`/cuDNN do not |
| `ghcr.io/janeliascientificcomputingsystems/agentic-sandbox-gpu:latest` (`podman/Dockerfile.pytorch`) | `nvcr.io/nvidia/pytorch:26.07-py3` | PyTorch 2.13, cuDNN, `gcc`/`g++`/`make`, `pip`/`venv`, `curl`/`wget`, `vim`, `jq`, `ssh`, plus the same CLIs | several GB | real ML work, compiling native extensions, "set up a venv and pip install" tasks |

Both open `/root` for traversal so `--keep-id` can run the CLIs installed there. `podman-run.sh`
checks for a newer image on every run (a digest check; a real download only when it changed).
`--allow` under podman needs `bash` and `python3` in the image for the in-container relay; a
minimal image such as `alpine` fails with `executable file /bin/bash not found`.

## The three operating modes

The sandbox is identical in all three; only what runs inside and how the job is submitted differ.

- **Mode A — one-shot, non-interactive.** A single command as a plain `bsub` job. This is the
  unsupervised case the policy targets.
- **Mode B — non-interactive loop.** As A, but the wrapped command loops over tasks inside one
  sandbox; state persists between iterations. For isolation between iterations submit one
  sandbox per iteration instead.
- **Mode C — interactive.** `bsub -Is`, then a REPL (`claude`, `opencode`) inside the sandbox. A
  human is present, so the sandbox is defence in depth. The REPL behaves as it does unsandboxed,
  with context persisting across turns.

## Harnesses

**Claude Code.** Three ways to authenticate. (1) Reuse an existing login: `claude auth login`
once outside, then `--claude` just works, because the credentials file is the real one. (2) A
fresh login inside the sandbox: works, but only if `~/.claude/.credentials.json` already exists
on the host (a file can only be bound through if it exists); the OAuth redirect goes to
`platform.claude.com` and lands on a paste-the-code prompt, so open the URL in your own browser
outside the sandbox. (3) An API key: `--env ANTHROPIC_API_KEY` (bwrap) or a `chmod 600` file
under a mount (podman); verified in all three modes, the key takes precedence over an expired
login. Never on a `bsub` command line. Not carried into the sandbox: `~/.claude/plugins`, skills,
`projects/` history; add `--ro`/`--rw` for a specific path if a task needs one.

**opencode + Kimi K3.** The key lives in `~/.config/opencode/opencode.json` (see `SETUP.md`), of
which the sandbox gets a copy. **Always name the model** for an interactive session,
`opencode -m litellm/kimi-k3`: bare `opencode` defaults to its hosted "OpenCode Zen" model, which
talks to hosts outside your allowlist and fails with a bare `Forbidden`. One-shot `opencode run
... --model litellm/kimi-k3` is unaffected. One opencode sandbox per account at a time: its sqlite
database on NFS is bound into every `--opencode` sandbox, and two concurrent ones race on it.

**The Kimi K3 safeguard.** Requests to `kimi-k3` through the LiteLLM gateway pass through a
custom guardrail (an LLM-as-judge for harmful content and jailbreaks), independent of the client.
A refusal takes one of two shapes: the gateway's `GuardrailRaisedException`/400 naming the check
(`content_harm`), or the model declining in prose before the guardrail has anything to do; both
have been observed on the same prompt. Claude via Anthropic directly has no such gateway
guardrail and declines on its own. Treat either as a normal outcome, not a broken service.

## GPU and podman specifics

- **Why podman for GPUs.** GPU access from a namespace-isolated process on data-centre NVIDIA
  drivers needs the NVIDIA Container Toolkit's runtime integration (CDI). bwrap's raw namespaces
  cannot provide it, and neither can Anthropic's own `sandbox-runtime`
  ([anthropics/claude-code#13108](https://github.com/anthropics/claude-code/issues/13108)).
  `--gpu` maps to `--device nvidia.com/gpu=all`.
- **`gpu=all` is safe on a shared node** because LSF's device cgroup already fences a job to its
  allocation: a 1-GPU job on an 8-GPU node sees exactly one GPU inside the container. Do not try
  to attach GPUs by index: `CUDA_VISIBLE_DEVICES` is `0` in every LSF GPU job whichever physical
  GPU it holds, while CDI names count the whole node. `--gpu` in a job with no GPU allocated is an
  error.
- **"root" inside is you.** By default the container process is uid 0 and `$HOME` is `/root`, but
  rootless podman maps that to your own uid: files it writes to a `--rw` path land owned by you,
  and its capabilities apply only inside the container. `--keep-id` makes the identity match too
  (`whoami` is you, `$HOME` is your home, the shorthands mount at `$HOME/...` instead of
  `/root/...`); it needs a subuid/subgid range wider than your real GID (see `SETUP.md`) and
  fails with `potentially insufficient UIDs or GIDs available` otherwise.
- **Several of your podman jobs can share a node.** Each invocation gets its own image store and
  runtime dir keyed on job id, array index and pid; a pulled image is a cache hit for the next job
  on the same node through a read-only shared store, which the wrapper never resets (only skips
  when unhealthy). Request the queue's normal CPU-to-GPU ratio (8 slots per GPU on `gpu_l4`) and
  let LSF pack. `bsub -gpu` needs an explicit GPU queue.

## Security model

What the sandbox protects against, assuming the agent is fully adversarial:

- Reading or writing anything outside the bound paths, including `$HOME` and other users' data.
- Reading credential files under bound paths (bwrap).
- Reaching any host not on the allowlist, or anything but HTTP(S) on allowed hosts.
- Reading secrets from your environment (bwrap clears it; podman forwards none).
- Persisting commands into Claude Code or opencode configuration that would run outside the
  sandbox later.
- Submitting cluster jobs except through a policy-checked broker, and then only sandboxed ones.
- Typing into your terminal after exit (bwrap `--new-session`, non-interactive runs).
- Interfering with your other concurrent sandbox jobs' state.

What it does not protect against, by design or limitation:

- Podman has no credential masking: never bind `$HOME` or a path containing it.
- Masking is of direct children only; a `.env` deeper in a project is readable.
- An agent can write to anything you gave it read-write, including the real credentials file
  bound into `--claude` sandboxes.
- A host on the allowlist is fully reachable over HTTP(S); the proxy does not inspect content.
- Nothing multi-node: one sandbox, one host. No MPI, Ray, DDP, Spark or Dask across nodes.
- In Mode C a human is present; the sandbox limits damage but does not review actions.

## Running under LSF

- LSF's cgroup limits apply unchanged; the sandbox does not detach from the job's cgroup.
- `bkill` and walltime kills reach the whole process tree, and both wrappers route TERM/INT/USR2
  through their cleanup, so the proxy, broker and state dir are removed on those paths too.
- Never run work on a login node. Get a compute node with `bsub -Is`. Don't `ssh` to one instead:
  with no LSF job of yours on it, the hourly cleanup wipes your `/scratch/$USER` there.
- Some queues reject a plain backgrounded `bsub`; `short` works for one-shots and is what the test
  suites use. `-m <host>` only works if the host is in the queue's host group.
- bwrap needs unprivileged user namespaces (`/proc/sys/user/max_user_namespaces` > 0).

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

`tests/test-bwrap.sh` and `tests/test-podman.sh` are live regression suites; run them from a
compute node, the podman one from a GPU job, and **one at a time** (they share opencode's
database). Some tests need a Claude login and a LiteLLM key. The `--csub` tests run only when
`csub-broker` is on `PATH` and `CSUB_TEST_ROOT` names a directory under your csub policy's allowed
roots; otherwise they are skipped. `python3 tests/test-proxy.py` tests the allowlist proxy without
a cluster.

## Troubleshooting

- **`Read-only file system`**: the path isn't inside a `--rw` bind. Add the specific path.
- **A request hangs, or `claude`/`opencode` retries forever with `Request timed out`**: the host
  isn't on your allowlist. When the command exits non-zero the wrapper prints the denied hosts.
  Claude Code needs `api.anthropic.com`, `claude.ai`, `platform.claude.com`; opencode+Kimi needs
  `litellm.int.janelia.org`.
- **`GuardrailRaisedException`/400 from `kimi-k3`**: the safeguard, not a bug.
- **opencode says `Forbidden`**: you launched it without `-m litellm/kimi-k3`.
- **opencode: `Failed to execute statement` or a LiteLLM `UnknownError`**: another `--opencode`
  sandbox of yours is running at the same time.
- **`Failed to initialize NVML: GPU access blocked`**: bwrap cannot do GPUs; use `podman-run.sh`.
- **`potentially insufficient UIDs or GIDs`**: `--keep-id` with a too-narrow subuid range; ask HPC.
- **`exec: claude: not found` inside**: pass `--claude`; it binds the CLI and puts it on `PATH`.
- **`--csub needs csub-broker on PATH`**: `export PATH=~/.venvs/csub/bin:$PATH` before starting.
- **`csub: broker_misconfigured: ... sandbox_scripts_dir ... missing`**: the policy points at a
  checkout that moved; fix the path in `~/.config/csub/broker.toml`.
- **`csub: policy_violation: mount ... home directory`**: `CSUB_MOUNTS` includes something under
  `$HOME`; work from a directory under an allowed root. `csub --json probe` (`--json` before the
  subcommand) shows the policy.
- **The in-sandbox README says an image or host doesn't exist for you**: it is right; the policy
  or the `--allow` list is the thing to change, outside the sandbox.

## Known limitations

- bwrap cannot do GPU passthrough; podman cannot mask credentials under `$HOME`.
- No SOCKS5; the proxy is HTTP(S) only.
- One opencode sandbox per account at a time.
- `--keep-id` needs a widened subuid/subgid range.
- Per-job state requires a writable `/scratch/$USER`; `sandbox-run.sh` falls back to `$TMPDIR`
  only on a non-cluster machine and says so, `podman-run.sh` requires it.
- Not tested: a fresh `claude auth login` combined with the one-shot or loop modes.
