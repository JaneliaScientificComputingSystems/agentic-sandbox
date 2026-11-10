# Changes that affect how you use the wrappers

Newest first. Behaviour changes only; see `git log` for everything else and `ADMIN-NOTES.md` for
the evidence behind each.

## Unreleased

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
- **`sandbox-run.sh` refuses to run from `$HOME`** (or a directory above it): `$PWD` is bound
  read-write and that would expose the whole home directory. Use `--rw "$HOME"` from a project
  directory if you really mean it.
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
  written to `/tmp`; binding the whole tree would expose other jobs' state. Use
  `--rw /scratch/$USER/<subdir>` for anything else; never bind `/scratch/$USER` itself.
- **`--claude` and `--opencode` no longer bind your real config read-write** (Maris Basha, #5).
  Each run gets a throwaway copy of `~/.claude.json`, `~/.claude/settings.json`,
  `~/.claude/CLAUDE.md` and `~/.config/opencode`; only `~/.claude/.credentials.json` is bound
  through, so logins and token refreshes persist but hooks/MCP edits made inside die with the
  job. On a fresh account, log in once outside the sandbox first (or use an API key).
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
- Run `tests/test-bwrap.sh` and `tests/test-podman.sh` one at a time: both drive opencode against
  the same sqlite database on NFS.

## 2026-09-23

- `podman-run.sh` adopted the Harbor fork's packing mechanics: per-job `CONTAINERS_STORAGE_CONF`
  and runtime dir, orphan-sweep by `/proc/<pid>/environ`, signal traps, prologue retry. Several
  concurrent podman jobs from one user can share a node.

## 2026-09-10

- **`$HOME` is no longer bound by default** in `sandbox-run.sh` (it used to be, read-only). Add
  `--ro`/`--rw` for the specific path a task needs; never for `$HOME` as a whole.
- `agentic-sandbox-lite` became the default podman image; the PyTorch image is the alternate
  (`agentic-sandbox-gpu`).
- `--keep-id` works end to end on accounts with a widened subuid/subgid range.
- Credential masking under podman was removed: it never worked (a `--tmpfs` cannot shadow a path
  under an ancestor `-v` bind) and looked protected while it wasn't.
