# Changes that affect how you use the wrappers

Newest first. Behaviour changes only; see `git log` for everything else, including the test results
behind each change.

## 2026-11-21

### Fixes from a review of the scripts

- **`sandbox-run.sh`: the job's environment was readable inside the sandbox.** `bwrap` stays
  inside as process 1, and it was started with the wrapper's whole environment, so
  `/proc/1/environ` showed every variable of the job, including any API key or token exported
  there. The command's own environment was clean, as documented. `bwrap` now starts with the job id
  and array index only. `podman-run.sh` was not affected.
- **`sandbox-run.sh`: a value passed with `--env` was on a command line.** Each `--env` variable
  went to `bwrap` as an argument, and command lines are readable by every user on a node
  (`ps -ef`). The values now reach `bwrap` on a file descriptor and are on no command line.
- **Both wrappers: a Python file in the working directory could run outside the sandbox.** With
  `--csub`, and in `podman-run.sh` on every start, the wrapper ran Python on the host from the
  working directory, and Python looks there for modules first. With an empty or relative entry in
  your `PYTHONPATH`, the proxy started by `--allow` did the same. A file the agent left
  in its project ran as you, unsandboxed, the next time a sandbox started there; through
  `ssh-entry.sh` that is the agent's next command. Host-side Python now runs isolated from the
  working directory, and empty or relative `PYTHONPATH` entries are dropped. A broker set with
  `CSUB_BROKER_CMD` is started from `/` unless it is the `csub-broker` command itself, so a
  relative `--policy` path works only with that form.
- **`ssh-entry.sh` refuses a project directory inside `$HOME`** (and `$HOME` itself, or a directory
  above it), on the login node, before it submits anything. The script used to check only that the
  directory existed, so a key line could hand the agent `~/.ssh` read-write.
- **Proxy: an allowed name is checked for where it points.** `--allow NAME` used to connect to
  whatever the name resolved to. The proxy now resolves it once, refuses loopback, link-local
  (169.254), multicast, unspecified and reserved addresses, and connects to the address it checked.
  A name with a dot is looked up as written, so the node's search domains are not appended to it.
  Private addresses still work, because the cluster's own services live there. A host you allowed
  can therefore appear in the denied list at exit: its name resolves to an address of that kind.
- **`csub-policy.sh` checks the physical path.** `--rw "$HOME/"`, `--rw /`, a path through `..` and
  a symlink into the home directory used to pass the home-directory check, which compared text.
  The policy now holds the physical path.
- **`--csub` in both wrappers:** a mount path that contains a comma or a colon is refused, and so is
  a preset `CSUB_MOUNTS` entry with `..` in it. Either could put a directory the sandbox does not
  have into the list handed to csub.

- **Files that run later are read-only, in both wrappers.** `.git/hooks`, `.git/config`,
  `.mcp.json`, `.claude/` settings and commands, `.vscode`, `.pre-commit-config.yaml` and similar
  files are now bound read-only where they exist at the top of a read-write directory, and `.git`
  cannot be moved aside. An agent could otherwise plant a git hook or an MCP server that ran as
  you the next time you used the project outside the sandbox. **This changes behaviour:**
  `git config` inside a repository fails (commits and branches work, and your git identity is
  passed in), and `--no-protect` turns the protection off. If the command creates
  such a file where there was none, the wrapper names it at exit. A path named with `--ro` or `--rw`
  keeps the mode given to it, and a name that is a symlink is left alone and named in a note.

- **A checkout inside a read-write directory cannot be swapped.** The wrappers already re-bound
  their own `scripts/` directory read-only when it lay inside a read-write mount. The directories
  above it could still be renamed, and a new checkout put in their place. They are now pinned,
  under both wrappers, and `podman-run.sh` applies the same to `--scratch`.
- **`podman-run.sh` refuses credential directories.** `--ro` or `--rw` on `~/.ssh`, `~/.aws`,
  `~/.claude`, the Hugging Face cache and the other credential locations, on a directory inside
  one, or on one that contains one (`~/.config`, `~/.cache`), is refused, as `sandbox-run.sh` refuses or masks them. So is the
  shared image store.
- **Paths are checked again right before they are mounted,** in both wrappers, so a directory
  replaced by a link while the sandbox is being set up is not mounted.

### Other changes

- **`ssh-entry.sh`: stderr comes back on stderr.** LSF returned an interactive job's stderr on
  stdout, so anything the wrapper or the command wrote to stderr (with `--podman`, "Trying to pull
  ..." and an image id on every command) appeared in the command's output. Commands without a
  terminal now get the two streams separately.
- **`scp` and `sftp` work through `ssh-entry.sh --podman`.** This needs both the new images and
  this version of `ssh-entry.sh`; with an old checkout the copy still fails with "Received message
  too long". Both images now carry `sftp-server`. The default image also gained `pip` and `venv`.
  The GPU image sends NVIDIA's start-up banner to stderr, so a command's stdout holds only its own
  output. `podman/Dockerfile` and `Dockerfile.pytorch` now match the published images (they lacked
  Codex, Ray and the CUDA 13.5 base, added to the images on 2026-11-19). Nodes pull the new layers
  on the next run. Tested through the forced command, not yet through a real sshd.
- **Cleanup holds under races, in both wrappers.** A process that vanished between being found and
  being killed, a directory that was still busy or that the agent left without permissions, or a
  second signal from `bkill` could end the cleanup early: the state directory stayed behind (with
  the copy of `~/.claude.json`) and the job returned 1. `podman-run.sh` now removes the
  configuration copies first. In an array job each element's watchdog also matched its siblings'
  pause processes; it now matches the array index too.
- **`podman-run.sh`:** the host's `http_proxy`, `https_proxy` and `no_proxy` are no longer copied
  into the container (podman does that by default); `--opencode` copies the target of a symlinked
  `~/.config/opencode` (in `sandbox-run.sh` too); an `--image` value that starts with `-` is
  refused.
- **Proxy: the log is bounded.** Log lines are cut and the log stops at 20000 lines of each kind,
  so a sandboxed process cannot fill the node's scratch disk through it. A request with a bad or
  missing `Host` header is logged as `BAD`, no longer as a denied host.
- **Laptop instruction files** (`config/CLAUDE.md`, `config/AGENTS.md`, `config/AGENTS-podman.md`).
  The agent submits without `--wait` and checks with `csub status` no more often than once a
  minute, the rule of the HPC hints page; the rule holds even though the sandbox's own description
  lists `--wait`. The submit rule shows how to ask for a GPU. `pip install` needs `pypi.org` and
  `files.pythonhosted.org` among the allowed hosts, and the file says to ask for them. The host
  rule now reads "for ssh and scp, use only janelia-agent". `AGENTS-podman.md` says which
  description of the working directory to believe.
- **`SETUP.md` §8:** step 1 carries `--replace`, so it no longer stops when §6 already wrote a
  policy; `EXPIRES` in the key line is the first day the key no longer works, not the last day it
  works (sshd reads a date without a time as midnight at the start of that day).
- **`podman-run.sh`** runs `podman system migrate` only when the shared store does not answer. It
  ran at every start, and it stops the containers of that store.
- **`examples/unattended-tuning`:** the evaluator passes the agent's `train.py` the images to
  predict without the labels.
- **`--dry-run`**, in both wrappers: every check runs, no sandbox, proxy or broker is started, and the
  `bwrap` or `podman` command, the proxy, the broker and (for bwrap) the command's environment are
  printed. Values passed with
  `--env` are not shown.
- **A record of each run** in which the proxy saw a request or csub recorded a job is written to
  `~/.agentic-sandbox/records/<date>/`, outside the sandbox: the command, its exit status, every
  host the proxy allowed or refused with the time, and the csub jobs recorded meanwhile. The proxy's
  log lines now carry the time. `SANDBOX_RECORD=off` turns the record off.
- **`sandbox-run.sh`** refuses to run from `/tmp` and refuses `--ro`/`--rw` of `/`, `/tmp`, `/proc`
  or `/dev`: the sandbox has its own, and the bind put the node's in their place. A directory
  beneath them works as before.
- **`csub-policy.sh`** refuses a directory inside the home directory, as `ssh-entry.sh` does.
- **`--env NAME`** passes the value from the environment the wrapper was started with. A name the
  wrapper also uses for itself (`CMD`, `p`) gave the wrapper's value.
- **A proxy or broker that stops while starting:** the wrapper prints the last lines of its log.
- **`bkill`'s USR2** ends a wrapper with status 140, not 141.
- **Cleanup always runs to its end**, also when the wrapper's messages go to a pipe whose reader has
  gone (`... 2>&1 | head`) or to a closed terminal. It could stop there and leave the csub broker
  and the per-job directory.
- **`podman-run.sh`** asks for a terminal only when both input and output are one. With the output
  sent to a file or a pipe from an interactive shell, it held carriage returns and error messages.
- **`--claude`** starts when `~/.claude/CLAUDE.md` is read-only.
- **`ssh-entry.sh --gpus N`** gives every command of a key line N GPUs. `--gpu` after the `--`
  alone could not work: the job was submitted without a GPU request, which the GPU queues reject.
- **Laptop instruction files:** the `scp` rule says the agent need not ask the user first, and that
  the laptop may still ask for approval of the command.
- **Records older than 30 days are removed** when a new one is written. `SANDBOX_RECORD_DAYS` sets
  another number of days, and `0` keeps them all.
- **CI** runs `shellcheck` at warning level on every shell script.

## 2026-11-20

- **`podman-run.sh` fix:** the wrapper could return 1 although the command inside had succeeded
  (about one run in twenty in an array of 20). It now returns the command's own exit status.
- **`podman-run.sh` fix:** with several podman jobs of one user on a node, a job could return 1
  without running its command, or return 1 after its command had succeeded (2 of 60 starts, ten
  at a time). A sibling job removed a pid file between this script's test for it and its read.
- **`tests/test-array.sh`** (new): many elements of one LSF array job on one node, each in its
  own sandbox, for either wrapper. Arrays needed no other change.

## 2026-11-16

- **`scripts/csub-policy.sh`** writes `~/.config/csub/broker.toml`, replacing the hand edits of
  csub's sample policy: `csub-policy.sh --bwrap --rw PROJECT [--ro DIR] [--allow HOST]`.
  It starts from the sample in your csub checkout, checks that csub loads the result, and refuses
  to overwrite an existing policy without `--replace`. Jobs get no network hosts unless `--allow`
  names them; the limits stay as in the sample unless given. An existing policy keeps working.
- **`config/CLAUDE.md`, `config/AGENTS.md`, `config/AGENTS-podman.md`**: the instruction file for an
  agent on a laptop that works through `ssh-entry.sh` (`SETUP.md` §8, new).
- **`tests/test-csub-policy.sh`** tests `csub-policy.sh` without a cluster and runs on every push.
- **`config/storage.conf` and `config/containers.conf`**: the two one-time podman files of
  `SETUP.md` §3 are now files to copy. `containers.conf` gained `cgroup_manager = "cgroupfs"`,
  without which podman prints four warnings on every run.

## 2026-11-14

- **`scripts/ssh-entry.sh`**: a forced command for an ssh key used by an agent that runs off the
  cluster, such as Claude Code or Codex on a laptop. Tied to the key in `~/.ssh/authorized_keys`, it
  turns every `ssh janelia-agent '<command>'` into an interactive LSF job that runs the command through
  `sandbox-run.sh` (or `podman-run.sh` with `--podman`) in one project directory. Only the script and
  `bsub` run on the login node. Documented on 2026-11-16: README, "An agent on your laptop".
- **`sandbox-run.sh --gpu`**: GPU jobs no longer need podman (csub GPU children under bwrap need PR #15 of the csub repo, merged 2026-11-15; see README). The LSF-allocated GPUs (from
  `CUDA_VISIBLE_DEVICES`) get their `/dev/nvidiaN` nodes plus the control/UVM nodes, `/sys/devices` and
  `/sys/module` are bound read-only (NVML needs them), and `CUDA_VISIBLE_DEVICES` is set to their
  numbering inside (`0..n-1`, in the order given; a subset such as the job's second GPU alone is `0`
  there). An error in a job with no GPU allocated. No CUDA toolkit comes with it; a bound venv or
  conda env, or a podman image, supplies one. (#10, hokinus)
- **`sandbox-run.sh --claude-history` and `--claude-history-rw`** (with `--claude`): the past Claude
  sessions of the directory you start from become visible, so `claude --resume` and `--continue`
  work. Read-only by default (new turns are not kept); `-rw` keeps them. Only that directory's
  history is bound. The sandboxed agent can read those earlier sessions, including unsandboxed
  ones. The flag without `--claude` is an error. (#9, hokinus)
- **`--claude`/`--opencode` no longer fail with "Can't mount on symlink destination"** when the
  directory holding the CLI's symlink (`~/.local/bin/claude`) is itself bound, for example with
  `--ro ~/.local`: the link is recreated inside and its target bound. (#11, hokinus) A tool symlink
  whose target is a credential location under `$HOME` is refused.

## 2026-11-10

- **`podman-run.sh` turns podman's own logging off** (`--log-driver=none`, `--events-backend=none`),
  whatever `containers.conf` says. The compute nodes default to `journald`, so without the
  one-time `containers.conf` setup everything a container printed -- every screen redraw of an
  interactive agent, and the conversation itself -- was copied into the node's journal and the
  central syslog. Output still reaches your terminal and the job's output file as before;
  `podman logs` shows nothing for these containers (the wrapper never used it). There is no flag
  to turn it back on.
- **`podman-run.sh --shm-size SIZE`**, and `/dev/shm` is **8g by default with `--gpu`** (it was
  podman's 64 MB, which PyTorch DataLoader workers fill at once: "unable to allocate shared
  memory(shm)"). Without `--gpu` and without the flag nothing changes. csub child jobs that run
  with `--gpu` get the default too. (#8, reported by mahdibaghbanzadeh)

## 2026-11-09

- **Credential masks under `$HOME` apply wherever they are visible** (`sandbox-run.sh`). Since the
  previous entry's "masks only when `$HOME` is visible" change, a bound directory *inside* `$HOME`
  lost them: from `~/.config`, `gcloud/` and `gh/` were readable. The `$HOME` locations are now
  masked whenever they sit inside any bound root. A root that **is** one of those locations or lies
  inside one (`--ro ~/.ssh`, running from `~/.aws/sso`) is refused, as is `~/.claude` itself bound
  read-write (cwd or `--rw`).
- **Binds are applied shallowest path first** (`sandbox-run.sh`), so the deeper path keeps its own
  mode whatever the flag order: `--rw proj --ro proj/sub` now leaves `proj/sub` read-only (it was
  writable), and `--ro proj` from inside `proj/sub` no longer makes the working directory read-only.
- `--csub`: a read-write mount with a read-only directory inside it is passed to child jobs
  **read-only**, with a note (csub cannot express the nesting, and read-write would give children
  access the sandbox lacks). Child jobs then need a read-write working directory elsewhere.
- **`podman-run.sh` refuses mounts it cannot protect**: `--rw`/`--ro` on `$HOME` or a directory
  above it (there is no credential masking under podman; a subdirectory of `$HOME` is fine), and on
  `/scratch/$USER` or anything containing `.agentic-sandbox`. Previously documented as "never do
  this". Its own script directory is mounted read-only when it sits inside an `--rw` mount, as
  `sandbox-run.sh` already did, and `--rw` on that directory itself is refused.
- **`sandbox-run.sh` refuses to run from `/`** as well as from `$HOME` and directories above it.
- The allowlist proxy rejects a host that is not a plain hostname or IP literal (400), so a
  sandboxed process can no longer put terminal escape sequences into the denied-host summary.
- `podman-run.sh`: the image ID printed by the automatic `podman pull` goes to stderr; stdout is the
  sandboxed command's alone.
- `--csub` under bwrap: only the csub package (plus `tomli`) is on `PYTHONPATH`, at `/run/csub-lib`,
  no longer the csub venv's whole `site-packages`. A path given as both `--rw` and `--ro` is listed
  once in `CSUB_MOUNTS` (bwrap, read-write) or refused (podman).
- An option missing its value, and `--env NAME=value`, are usage errors with a message. The
  in-sandbox README lists the current masked paths; its opencode model hint follows
  `SANDBOX_OPENCODE_MODEL` (default `litellm/kimi-k3`).

## 2026-11-02

- **`sandbox-run.sh` refuses to run from `$HOME`** (or a directory above it): `$PWD` is bound
  read-write and that would expose the whole home directory. `--rw "$HOME"` from a project
  directory is still accepted.
- **More credential paths masked** under a visible `$HOME`/`$PWD`/bound root: `.gnupg`, `.config/gh`,
  `.config/git/credentials`, `.pgpass`, `.vault-token`, `.cache/huggingface/token`, shell history
  files, and the other harness's credentials (`~/.claude/.credentials.json` without `--claude`,
  opencode's `auth.json` and `~/.config/opencode` without `--opencode`). Masks under `$HOME` are
  applied only when `$HOME` is actually visible inside, so an unbound home no longer shows empty
  `~/.ssh`-style placeholders.
- **Inherited file descriptors are closed** before bwrap starts (only 0-2 pass through); the README
  no longer lists this as a limitation.
- **Paths are canonical.** `--ro`/`--rw` arguments are resolved with `realpath` and must exist; the
  working directory is its physical path; the wrappers can be run through a symlink.
- `--csub`: the host's `PYTHONPATH` is no longer passed into a bwrap sandbox; under podman only the
  csub package (plus `tomli`) is mounted, at `/opt/csub-lib`, instead of the whole host venv.
- The in-sandbox relay is waited for instead of slept on, and no longer prints a banner on the
  command's stderr. The proxy bounds header reads (64 KiB, 200 lines, 30 s) and honours half-closes.

## 2026-10-31

- **`--csub` bounds client-claimed mounts to the sandbox.** Both wrappers start the broker with
  this sandbox's own mounts and `--allow` hosts as an envelope (`--envelope-mount`/`--envelope-host`,
  csub #13), so `CSUB_MOUNTS`/`--cwd` can no longer name a directory under `allowed_roots` that the
  sandbox cannot see. **`--csub` now refuses to start** when the envelope would be empty (no mount
  outside `$HOME`/`/scratch` and no `--allow`; csub treats that as no envelope) or when csub lacks
  the flags; `CSUB_ENVELOPE=off` accepts a policy-only broker explicitly. A preset `CSUB_MOUNTS` may
  only narrow the derived list, never widen it. A child job that names an `agent` needs that agent's
  hosts in `--allow`, or the envelope refuses it.
- **Early exits leave no per-job state.** The per-job dir (with its `~/.claude.json` copy) is now
  removed on every exit path, including a usage error or `--gpu` with no GPU allocated.

## 2026-10-16

- Every sandbox now contains `/run/sandbox/README.md` (also `$SANDBOX_README`): a generated
  description of this session's mounts, reachable hosts, environment, and, with `--csub`, the
  job-submission policy. With `--claude`, the per-job copy of `CLAUDE.md` gets a pointer to it, so
  Claude Code reads it at start. Your real `~/.claude/CLAUDE.md` is not touched.

## 2026-10-12

- **`--csub`** on both wrappers: a sandboxed agent can submit LSF jobs through a csub broker that
  runs outside the sandbox and enforces your `~/.config/csub/broker.toml`. Child jobs run
  sandboxed too and can submit again. Needs `csub-broker` on `PATH` (see `SETUP.md`).
- `--claude`/`--opencode` put the bound CLI directories on `PATH` inside the bwrap sandbox, so
  they work from a scrubbed environment such as a csub-launched job (Konrad Rokicki, #7).
- `sandbox-run.sh` traps TERM/INT/USR2 like `podman-run.sh` already did: `bkill` and walltime
  kills now clean up the proxy, broker and state dir.
- When the sandboxed command exits non-zero, the wrapper prints a one-line summary of the hosts
  the allowlist proxy denied. Successful runs stay quiet.
- `podman-run.sh --allow` is documented to require `bash` and `python3` in the image.

## 2026-10-08

- **`--scratch` now binds `/scratch/$USER/work`, not all of `/scratch/$USER`.** Everything a
  wrapper creates for a run lives in `/scratch/$USER/.agentic-sandbox/<job>/` and nothing is
  written to `/tmp`; binding the whole tree would expose other jobs' state.
  `--rw /scratch/$USER/<subdir>` covers anything else.
- **`--claude` and `--opencode` no longer bind your real config read-write** (Maris Basha, #5).
  Each run gets a throwaway copy of `~/.claude.json`, `~/.claude/settings.json`,
  `~/.claude/CLAUDE.md` and `~/.config/opencode`; only `~/.claude/.credentials.json` is bound
  through, so logins and token refreshes persist but hooks/MCP edits made inside die with the
  job. A first login done inside the sandbox on a fresh account is therefore not kept.
- **`sandbox-run.sh` starts from an empty environment.** Only `PATH`, `HOME`, `USER`, `LOGNAME`,
  `SHELL`, `TERM`, `COLORTERM`, `LANG`/`LC_*`, `TZ` and the CA-bundle variables come through;
  anything else needs `--env NAME` (e.g. `--env ANTHROPIC_API_KEY`). `/tmp` inside is a private
  tmpfs; non-interactive runs get their own session (`--new-session`).
- Credential paths (`.ssh`, `.aws`, `.env`, `.git-credentials`, …) are masked directly under
  **every** bound root, not just `$PWD` and `$HOME`.
- The allowlist proxy honours the port in the `Host:` header, matches hostnames
  case-insensitively, and both wrappers wait for its socket instead of sleeping.
- `podman-run.sh`: per-job storage key includes the LSF array index and the wrapper's PID (array
  jobs and repeated calls in one job no longer collide); per-job `XDG_RUNTIME_DIR`; the shared
  store is never reset, only skipped when unhealthy; `--keep-id` works on the pytorch image too
  (`agentic-sandbox-gpu:latest` rebuilt 2026-10-08).
- `tests/test-bwrap.sh` and `tests/test-podman.sh` cannot run at the same time: both drive opencode
  against the same sqlite database on NFS.

## 2026-09-23

- `podman-run.sh` adopted the Harbor fork's packing mechanics: per-job `CONTAINERS_STORAGE_CONF`
  and runtime dir, orphan-sweep by `/proc/<pid>/environ`, signal traps, prologue retry. Several
  concurrent podman jobs from one user can share a node.

## 2026-09-10

- **`$HOME` is no longer bound by default** in `sandbox-run.sh` (it used to be, read-only).
  `--ro`/`--rw` bind the specific paths a task needs.
- `agentic-sandbox-lite` became the default podman image; the PyTorch image is the alternate
  (`agentic-sandbox-gpu`).
- `--keep-id` works end to end on accounts with a widened subuid/subgid range.
- Credential masking under podman was removed: it never worked (a `--tmpfs` cannot shadow a path
  under an ancestor `-v` bind) and looked protected while it wasn't.
