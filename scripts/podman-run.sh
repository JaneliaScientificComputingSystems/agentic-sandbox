#!/bin/bash
# podman-run.sh -- convenience wrapper around podman, mirroring sandbox-run.sh's flags.
#
# Use this instead of sandbox-run.sh when the task needs GPU access -- bwrap cannot do GPU
# passthrough (see the main README's GPU section); podman + NVIDIA CDI can.
#
# Usage:
#   podman-run.sh [options] -- <command...>
#
# Options:
#   --image NAME    Image to run (default: agentic-sandbox-lite, the lightweight pre-built
#                    image on GHCR -- `podman pull` it first, or build your own locally with
#                    `podman build -t agentic-sandbox-lite:latest .` in this directory and
#                    pass `--image localhost/agentic-sandbox-lite:latest`. For a heavier
#                    image with PyTorch/cuDNN preinstalled, build ./Dockerfile.pytorch
#                    instead, or pass `--image ghcr.io/janeliascientificcomputingsystems/
#                    agentic-sandbox-gpu:latest`)
#   --ro PATH       Read-only bind (repeatable): -v PATH:PATH:ro
#   --rw PATH       Read-write bind (repeatable): -v PATH:PATH:rw
#   --allow HOST    Allowed egress domain (repeatable). Starts the allowlist proxy + relay
#                   automatically, same mechanism as sandbox-run.sh. Omit for --network=none
#                   with no exceptions.
#   --gpu           Add --device nvidia.com/gpu=all. Under LSF the job's device cgroup lets
#                    only the allocated GPUs through. In an LSF job with no GPU allocated
#                    (CUDA_VISIBLE_DEVICES empty) this is an error.
#   --scratch       Shorthand for --rw /scratch/$USER/work (created if missing). Deliberately
#                    NOT all of /scratch/$USER: this wrapper's own per-job state (podman store,
#                    runtime dir, config copies, proxy socket) lives under
#                    /scratch/$USER/.agentic-sandbox/<job>/, and podman cannot mask a path
#                    under an ancestor -v bind, so binding the whole tree would expose every
#                    concurrent job's state to this one. Never bind /scratch/$USER itself.
#   --claude        Run Claude Code with a per-job config directory (CLAUDE_CONFIG_DIR): a
#                    throwaway copy of ~/.claude.json, ~/.claude/settings.json,
#                    ~/.claude/CLAUDE.md and ~/.claude/.credentials.json, deleted on exit.
#                    Only .credentials.json is copied back afterwards (if it is still valid
#                    JSON, and the host copy was not changed by something else meanwhile), so
#                    an existing login is reused and token refreshes / a fresh
#                    `claude auth login` persist -- but edits to settings (hooks) or MCP
#                    server entries made inside the container die with it. Those are shell
#                    commands Claude Code would otherwise run unsandboxed in your next session.
#   --opencode      Same idea: a throwaway copy of ~/.config/opencode, mounted at opencode's
#                    default location inside (~/.config/opencode of the in-container user), plus
#                    RW binds on its data dirs (~/.local/share, ~/.local/state, ~/.cache)
#   --keep-id       Run as your real uid/gid instead of root (--userns=keep-id --user
#                    "$(id -u):$(id -g)"), so files land on the real filesystem with your
#                    normal ownership instead of root-mapped-through-the-user-namespace.
#                    REQUIRES a /etc/subuid/etc/subgid range wider than your account's real
#                    GID (not just "any range") -- confirmed live 2026-09-10: keep-id's
#                    default identity-mapping needs your own uid AND gid to individually fit
#                    within the granted range's width, and AD/LDAP GIDs here commonly exceed
#                    a standard 65536-wide grant.
#                    Fails with "potentially insufficient UIDs or GIDs available in user
#                    namespace" if your range isn't wide enough -- ask HPC for a wider one
#                    (width > your real gid, not just "a range") if you hit this.
#   -h, --help      Show help
#
# Unlike sandbox-run.sh, $HOME is NOT bound by default here -- use --rw/--ro if you need your
# real home directory's files. UNLIKE sandbox-run.sh, there is no credential-path masking
# here -- confirmed live 2026-09-10 that podman doesn't let a --tmpfs override a path already
# covered by an ancestor -v bind the way bwrap's sequential mounts do (see the comment near
# PODMAN_ARGS below for the full story). Never --rw/--ro a path that IS or CONTAINS $HOME --
# .ssh/.aws/.git-credentials/etc. will be fully exposed, read-write, no exceptions. Scope
# --rw/--ro to the specific subdirectory you actually need instead.
set -euo pipefail

# Save the real stdin before anything backgrounds `podman run` (needed below, for the
# catatonit watchdog) -- bash silently redirects a backgrounded job's stdin from /dev/null,
# confirmed live: piping input into this script and running `-- cat` produced no output at all
# once `podman run` moved to the background. fd 3 keeps the original stdin (tty, pipe, or
# redirected file, whatever it actually is) reachable via `<&3` when launching podman.
exec 3<&0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="ghcr.io/janeliascientificcomputingsystems/agentic-sandbox-lite:latest"
VOLUMES=()
ALLOW_HOSTS=()
GPU=0
KEEP_ID=0
WANT_CLAUDE=0
WANT_OPENCODE=0
ENV_ARGS=()

# Everything from line 2 down to the blank comment line before `set -euo pipefail`.
usage() { sed -n "2,$(( $(grep -n '^set -euo pipefail' "${BASH_SOURCE[0]}" | cut -d: -f1) - 1 ))p" "${BASH_SOURCE[0]}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image) IMAGE="$2"; shift 2 ;;
    --ro) VOLUMES+=("-v" "$2:$2:ro"); shift 2 ;;
    --rw) VOLUMES+=("-v" "$2:$2:rw"); shift 2 ;;
    --allow) ALLOW_HOSTS+=("$2"); shift 2 ;;
    --gpu) GPU=1; shift ;;
    --keep-id) KEEP_ID=1; shift ;;
    --scratch) mkdir -p "/scratch/$USER/work"; VOLUMES+=("-v" "/scratch/$USER/work:/scratch/$USER/work:rw"); shift ;;
    --claude) WANT_CLAUDE=1; shift ;;
    --opencode) WANT_OPENCODE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done
CMD=("$@")

# --claude/--opencode: the harness CONFIG is copied into a per-job directory. Claude's copy is
# mounted at the same path inside the container and pointed to via CLAUDE_CONFIG_DIR, so its
# location doesn't depend on --keep-id. opencode's copy is mounted at opencode's DEFAULT config
# location for the in-container user instead: confirmed live that even with OPENCODE_CONFIG /
# OPENCODE_CONFIG_DIR pointing elsewhere, opencode still mkdir()s ~/.config, and under --keep-id
# that fails with EACCES because podman auto-creates the unmounted $HOME inside the container
# root-owned (Bun crash banner, test 8). Mounting at the default location means the parent
# exists as a mount point, exactly as it did when the real dir was bound. So opencode's config
# AND data dirs use the HOME-dependent destination: default (no --keep-id) the container runs
# as root and looks under /root/...; --keep-id runs as your real uid with $HOME=$HOME (set via
# -e HOME below), same convention as bwrap. See ADMIN-NOTES.md's "identity/HOME saga" for why
# forcing identity without remapping failed.
# Per-job state directory: ONE place for everything this wrapper creates for a run --
# podman/ (graphroot, runroot, xdg-runtime, storage.conf), cfg/ (the config copies), proxy/
# (allowlist proxy socket + log). Mode 700, removed whole by cleanup(), nothing in /tmp.
# /scratch/$USER is node-local (where a Unix socket belongs) and swept by an hourly cleanup
# cron that is not age-based: it wipes /scratch/<user> only on nodes where the user has no
# running LSF job, so a job's state is safe for its whole lifetime and gone within an hour
# after (crash debris included). The tag
# is $LSB_JOBID plus $LSB_JOBINDEX plus this shell's PID, so no two invocations can share one:
# every element of an LSF array job shares the same $LSB_JOBID, a `brequeue`d job reuses it,
# and a job script calling this wrapper twice is one LSB_JOBID as well. "manual" outside LSF.
# /scratch/$USER is required here (podman's per-job store needs node-local storage anyway).
SANDBOX_STATE_PARENT="/scratch/$USER/.agentic-sandbox"
mkdir -p "$SANDBOX_STATE_PARENT"
chmod 700 "$SANDBOX_STATE_PARENT"
JOB_DIR="$SANDBOX_STATE_PARENT/${LSB_JOBID:-manual}${LSB_JOBINDEX:+-$LSB_JOBINDEX}-$$"
mkdir -p "$JOB_DIR"
chmod 700 "$JOB_DIR"
JOB_STORAGE_DIR="$JOB_DIR/podman"

SANDBOX_CFG_ROOT=""
CLAUDE_CFG=""
HOST_CREDS="$HOME/.claude/.credentials.json"
new_cfg_root() {
  [[ -n "$SANDBOX_CFG_ROOT" ]] && return 0
  SANDBOX_CFG_ROOT="$JOB_DIR/cfg"
  mkdir -p "$SANDBOX_CFG_ROOT"
}
if [[ $WANT_CLAUDE -eq 1 ]]; then
  new_cfg_root
  CLAUDE_CFG="$SANDBOX_CFG_ROOT/claude"
  mkdir -p "$CLAUDE_CFG"
  for f in "$HOME/.claude.json" "$HOME/.claude/settings.json" "$HOME/.claude/CLAUDE.md"; do
    [[ -f "$f" ]] && cp "$f" "$CLAUDE_CFG/$(basename "$f")"
  done
  VOLUMES+=("-v" "$CLAUDE_CFG:$CLAUDE_CFG:rw")
  # The credentials file is bind-mounted THROUGH to the real one, exactly as sandbox-run.sh
  # does -- not copied in and back. No token copy ever sits on scratch, two concurrent --claude
  # jobs see each other's refreshes immediately instead of racing a copy-back, and the file
  # mount lands on top of the directory mount (podman orders mounts by destination depth), so
  # Claude Code finds it at $CLAUDE_CONFIG_DIR/.credentials.json. Refresh-through-the-bind
  # works because the CLI falls back to an in-place rewrite when its rename-over fails with
  # EBUSY on a mountpoint (verified under bwrap with a forced refresh; same mount semantics).
  if [[ -f "$HOST_CREDS" ]]; then
    VOLUMES+=("-v" "$HOST_CREDS:$CLAUDE_CFG/.credentials.json:rw")
  else
    echo "podman-run.sh: warning: no $HOST_CREDS -- a \`claude auth login\` done inside the container will NOT persist past this run. Log in once outside first, or deliver ANTHROPIC_API_KEY into the container." >&2
  fi
  ENV_ARGS+=(-e "CLAUDE_CONFIG_DIR=$CLAUDE_CFG")
fi
if [[ $WANT_OPENCODE -eq 1 ]]; then
  new_cfg_root
  OPENCODE_CFG="$SANDBOX_CFG_ROOT/opencode-config"
  if [[ -d "$HOME/.config/opencode" ]]; then
    cp -R "$HOME/.config/opencode" "$OPENCODE_CFG"
  else
    mkdir -p "$OPENCODE_CFG"
  fi
  # Config copy at opencode's default location (see the comment above the --claude block for
  # why not OPENCODE_CONFIG); data dirs stay bound to the real ones. The data dirs are created
  # first so podman never has to auto-create a missing source (it would, silently, as a
  # root-owned directory).
  for d in .local/share/opencode .local/state/opencode .cache/opencode; do mkdir -p "$HOME/$d"; done
  if [[ $KEEP_ID -eq 1 ]]; then
    VOLUMES+=("-v" "$OPENCODE_CFG:$HOME/.config/opencode:rw")
    for d in .local/share/opencode .local/state/opencode .cache/opencode; do VOLUMES+=("-v" "$HOME/$d:$HOME/$d:rw"); done
  else
    VOLUMES+=("-v" "$OPENCODE_CFG:/root/.config/opencode:rw")
    for d in .local/share/opencode .local/state/opencode .cache/opencode; do VOLUMES+=("-v" "$HOME/$d:/root/$d:rw"); done
  fi
fi
if [[ ${#CMD[@]} -eq 0 ]]; then
  echo "No command given after --" >&2; usage; exit 1
fi

# Per-job podman storage and runtime paths ($JOB_DIR/podman, see the state-dir comment above),
# created FIRST, before any podman command below runs. Two things live here, both ported from
# Janelia's Harbor fork (hpc/harbor-lsf-wrapper.sh), where each was found by real packed-job
# failures:
#   root/ + run/   -- this job's own podman graphroot/runroot (see CONTAINERS_STORAGE_CONF
#                     below). Sharing the static one from storage.conf is what let two
#                     concurrent podman jobs from the same user corrupt each other's state on
#                     one node (the original reason this repo asked for a full node per job).
#   xdg-runtime/   -- this job's own XDG_RUNTIME_DIR. CONTAINERS_STORAGE_CONF only isolates
#                     *persistent* storage; crun's *live* per-container state lives under
#                     $XDG_RUNTIME_DIR/crun, and with the variable merely unset that defaults
#                     to the shared, UID-keyed /run/user/$(id -u), identical for every
#                     concurrent job from this user on the node. Harbor confirmed live that
#                     packed claude-code jobs then intermittently lost track of their own
#                     still-running container ("crun: container ... does not exist ...
#                     /run/user/<uid>/crun/<id>/status: No such file or directory").
# It also has to exist before the prologue calls because the orphan sweep further down
# matches candidates by this path appearing in /proc/<pid>/environ -- a pause process spawned
# by the prologue health checks before the export would carry no job-scoped path and be
# unreapable by both the watchdog and the cleanup trap.
mkdir -p "$JOB_STORAGE_DIR/root" "$JOB_STORAGE_DIR/run" "$JOB_STORAGE_DIR/xdg-runtime"
chmod 700 "$JOB_STORAGE_DIR/xdg-runtime"

# The prologue calls below (migrate / info / pull) run against the SHARED store with
# XDG_RUNTIME_DIR UNSET, so podman derives its libpod tmp dir from its stable default
# (${TMPDIR:-/tmp}/podman-run-<uid>/libpod/tmp), NOT from this job's xdg-runtime dir. This
# matters far more than it looks: podman records the tmp dir in the store's own database
# (DBConfig.TmpDir) the first time it initializes that store, and every later invocation
# that doesn't pass --tmpdir explicitly silently ADOPTS the recorded value. Confirmed live on
# three cluster nodes: with the per-job XDG_RUNTIME_DIR exported before these calls, the
# first job to touch a fresh shared store (post-reboot, post-/scratch-purge) permanently
# stamped ITS per-job path into the shared DB; that job then deleted the dir in cleanup, and
# every subsequent job's prologue on that node recreated
# /scratch/$USER/podman-jobs/<long-gone-job>/xdg-runtime/libpod/tmp -- the shared store
# believed it had rebooted on every single invocation. The per-job XDG_RUNTIME_DIR is
# exported only AFTER the prologue, right alongside CONTAINERS_STORAGE_CONF.
unset XDG_RUNTIME_DIR

# Where rootless podman keeps the SHARED store's pause process pid with XDG_RUNTIME_DIR unset:
# <runtime dir>/libpod/tmp/pause.pid, where c/storage derives the runtime dir as /run/user/<uid>
# if that exists and is ours, else ${TMPDIR:-/tmp}/storage-run-<uid> (confirmed live: podman
# 5.8.2 on the cluster reports its socket under /tmp/storage-run-<uid>/podman/). The orphan
# sweep below kills that pause process at job end, and podman 5.8.2 does NOT recover from the
# stale pid file it leaves behind -- every later `podman info`/`pull` on the node fails with
# "cannot re-exec process to join the existing user namespace" (rc 125) until the file is
# removed, which this script would otherwise misread as a permanently unhealthy shared store
# (confirmed live on h08u08). So the pid file is removed whenever the pid it names is dead:
# here, before the prologue, to heal a node an earlier job left in that state, and in the
# sweep itself right after the kill. A live pid (a sibling's pause) is never touched.
shared_runtime_dir() {
  local d="/run/user/$(id -u)"
  if [[ -d "$d" && -O "$d" ]]; then echo "$d"; else echo "${TMPDIR:-/tmp}/storage-run-$(id -u)"; fi
}
SHARED_RUNTIME_DIR="$(shared_runtime_dir)"
SHARED_PAUSE_PIDFILE="$SHARED_RUNTIME_DIR/libpod/tmp/pause.pid"
remove_stale_shared_pause_pidfile() {
  local p
  [[ -f "$SHARED_PAUSE_PIDFILE" ]] || return 0
  p="$(cat "$SHARED_PAUSE_PIDFILE" 2>/dev/null)"
  if [[ -n "$p" ]] && ! kill -0 "$p" 2>/dev/null; then
    rm -f "$SHARED_PAUSE_PIDFILE"
    echo "podman-run.sh: removed stale shared pause pid file ($SHARED_PAUSE_PIDFILE -> dead pid $p)" >&2
  fi
  true
}
remove_stale_shared_pause_pidfile

# Reconcile podman's cached boot-ID state in case this node rebooted since the last job that
# used the shared graphroot (Janelia's Harbor fork documents this). Cheap and harmless when
# there's nothing to migrate. CONTAINERS_STORAGE_CONF is deliberately NOT exported yet --
# these prologue calls must see the SHARED store from ~/.config/containers/storage.conf, both
# to health-check it and to read its graphroot for the cache reference below.
podman system migrate 2>/dev/null || true
# Do NOT `podman system reset -f` the shared store on a failed `podman info` here: this
# script deliberately runs multiple podman jobs concurrently on one node, so that store may
# be in active use by a sibling job's additionalimagestores right now. Resetting it out from
# under a running job is exactly the kind of cross-job collision the per-job store exists to
# avoid. Just note it and skip the image cache for this invocation instead. This isn't only
# defensive: the shared graphroot lives under /scratch, which is swept on a periodic cleanup
# cron that can delete blobs out from under a live store's metadata DB, so `podman info`
# genuinely can go unhealthy mid-run through no fault of any job here.
SHARED_STORE_HEALTHY=1
SHARED_GRAPHROOT=""
if podman info >/dev/null 2>&1; then
  SHARED_GRAPHROOT="$(podman info --format '{{.Store.GraphRoot}}' 2>/dev/null)"
else
  echo "podman-run.sh: shared podman store looks unhealthy on $(hostname) -- skipping its image cache for this invocation rather than resetting a store a sibling job may be using" >&2
  SHARED_STORE_HEALTHY=0
fi

# Repair a shared-store DB already stamped with some job's per-job tmp dir by an earlier
# version of this script (or of the Harbor fork's wrapper, which shares this design and had
# the same bug) -- see the XDG_RUNTIME_DIR comment above. Podman offers no command to change
# DBConfig short of `podman system reset` (which would wipe the image cache out from under
# sibling jobs), so this is a one-column, idempotent sqlite update, applied ONLY when the
# recorded tmp dir is under this user's podman-jobs/ tree, and set to exactly the path podman
# would have derived on its own with XDG_RUNTIME_DIR unset (<shared runtime dir>/libpod/tmp).
# Concurrent jobs repairing at once write the same value; sqlite serializes them. Never
# deletes the stale dir itself: it might still belong to a live sibling.
#
# Expect this to log almost never: the Harbor fork observed live that `podman system migrate`
# above, running with XDG_RUNTIME_DIR unset, already re-stamps podman's own derived default
# whenever the recorded dir is MISSING on disk -- which it normally is, since the poisoning
# job deleted it at cleanup. This only matters when the poisoned path still exists (a live
# sibling running an unfixed wrapper version).
repair_shared_store_tmpdir() {
  local db="$1/db.sql" want="$SHARED_RUNTIME_DIR/libpod/tmp"
  [[ -f "$db" ]] || return 0
  python3 - "$db" "$want" "/scratch/$USER/podman-jobs/" "$SANDBOX_STATE_PARENT/" <<'REPAIR' 2>&1 | sed 's/^/podman-run.sh: /' >&2
import sqlite3, sys
db, want = sys.argv[1:3]
bad_prefixes = tuple(sys.argv[3:])
try:
    c = sqlite3.connect(db, timeout=15)
    row = c.execute("select TmpDir from DBConfig").fetchone()
    if row and row[0].startswith(bad_prefixes) and row[0] != want:
        c.execute("update DBConfig set TmpDir = ?", (want,))
        c.commit()
        print(f"repaired shared store tmp dir: {row[0]} -> {want}")
except Exception as e:
    print(f"could not check/repair shared store tmp dir in {db}: {e}")
REPAIR
  true
}
[[ -n "$SHARED_GRAPHROOT" ]] && repair_shared_store_tmpdir "$SHARED_GRAPHROOT"

# Check for a newer version of the image on every run rather than relying on the caller to
# remember `podman pull`. Cheap in the common case -- this is a manifest-digest check, not a
# re-download, unless the image actually changed. Runs against the SHARED store on purpose
# (before CONTAINERS_STORAGE_CONF is exported) so the pull warms the node-local cache that
# every sibling job reads through additionalimagestores. Skipped for a purely local image
# (localhost/...), which has no registry to check against.
if [[ "$IMAGE" != localhost/* ]]; then
  podman pull "$IMAGE" || true
fi

# Give this invocation its own storage root/runroot via a per-job storage.conf, handed to
# podman through CONTAINERS_STORAGE_CONF rather than --root/--runroot flags: the environment
# variable is honored by EVERY podman call from here on -- `podman run`, the `podman rm` and
# `podman unshare` in cleanup, and anything the container's own tooling shells out to -- so
# nothing can accidentally address the shared store with a job-scoped flag missing.
# additionalimagestores points back at the shared graphroot as a READ-ONLY layer source (when
# healthy), so this doesn't cost a re-pull for another job landing on the SAME node --
# confirmed live: two concurrent invocations both saw the already-pulled image instantly and
# ran to completion with no collision. (If storage.conf's graphroot is under /scratch, per the
# README's one-time setup, that cache is node-local scratch, not cluster-wide -- a job that
# lands on a different node still pays a fresh pull regardless of this mechanism.)
cat > "$JOB_STORAGE_DIR/storage.conf" <<STORAGECONF
[storage]
driver = "overlay"
runroot = "$JOB_STORAGE_DIR/run"
graphroot = "$JOB_STORAGE_DIR/root"

[storage.options]
mount_program = "/usr/bin/fuse-overlayfs"
STORAGECONF
if [[ -n "$SHARED_GRAPHROOT" ]]; then
  echo "additionalimagestores = [\"$SHARED_GRAPHROOT\"]" >> "$JOB_STORAGE_DIR/storage.conf"
fi
export CONTAINERS_STORAGE_CONF="$JOB_STORAGE_DIR/storage.conf"
# From here on every podman call is job-scoped: its own store AND its own runtime dir (crun's
# live per-container state, the pause process, rootless-netns) -- see the header comment on
# xdg-runtime/ above for why the runtime dir has to be per-job too.
export XDG_RUNTIME_DIR="$JOB_STORAGE_DIR/xdg-runtime"

# Absorb transient shared-store lock contention: when several jobs start on one node in the
# same second, their prologue migrate/info calls can hold the shared store's DB lock long
# enough that a sibling's first call against its job store (which reads the shared store
# through additionalimagestores) fails. Retry until the job store answers before launching.
for _ in $(seq 1 10); do
  podman info >/dev/null 2>&1 && break
  sleep 3
done

# Kill any catatonit for OUR job that's actually orphaned (lingering, PPID reparented to 1) --
# NOT just any catatonit that happens to reference our storage path, which is also true of our
# own container's catatonit while it's still healthy and actively running. Confirmed live:
# without the PPID check, the watchdog below can catch a perfectly healthy catatonit mid-exit
# and SIGKILL it, which is what was actually causing a wrong/nonzero podman-run.sh exit code
# even on fast, successful runs -- not a cluster-specific storage quirk, a bug in this check.
#
# Match by /proc/$pid/environ, NOT /proc/$pid/mountinfo (ported from the Harbor fork, which
# confirmed live this is the difference between a check that never fires and one that works):
# mountinfo only references this job's storage path while a container's overlay is still
# actively mounted, so by the time the container has been torn down (exactly the state being
# checked for) it no longer matches anything. The pause process still carries
# CONTAINERS_STORAGE_CONF / XDG_RUNTIME_DIR (both pointing inside this job's dir) in its
# environment, inherited from whichever podman invocation spawned it, and that survives in
# /proc/$pid/environ regardless of what's still mounted. The trailing slash on the match is
# load-bearing: without it, job 12345's sweep also matches sibling job 123456's environ.
#
# Caveat on the PPID==1 gate: it assumes a healthy job's pause process is reparented to
# something OTHER than init (LSF's res acting as a subreaper), which holds under LSF on this
# cluster but is not guaranteed by podman itself -- rootless podman double-forks the pause
# process, so on a host with no subreaper in the chain a HEALTHY pause process also lands on
# PPID 1 and this sweep would kill it mid-run. Since this script also supports running outside
# LSF, the sweep is a no-op unless $LSB_JOBID is set.
#
# Two kinds of pause process can be ours: the per-job one (environ carries this job's storage
# path via CONTAINERS_STORAGE_CONF/XDG_RUNTIME_DIR), and the SHARED-store one spawned by our
# prologue calls, which ran with XDG_RUNTIME_DIR unset and so carry no job path -- but do carry
# our LSB_JOBID (matched as a whole NUL-delimited environ entry). Killing that shared pause is
# safe now that no container ever runs under it: a sibling's in-flight prologue call has
# already joined its namespaces (which outlive the pause process), and its next call simply
# spawns a fresh one. Left alive, it's what held finished LSF jobs in RUN for minutes.
kill_orphaned_catatonit_for_this_job() {
  [[ -n "${LSB_JOBID:-}" ]] || return 0
  for pid in $(pgrep -u "$USER" -x catatonit 2>/dev/null); do
    [[ "$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')" == "1" ]] || continue
    if grep -aq "$JOB_STORAGE_DIR/" "/proc/$pid/environ" 2>/dev/null \
       || grep -azq "^LSB_JOBID=$LSB_JOBID\$" "/proc/$pid/environ" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null
    fi
  done
  # The shared pause we may just have killed leaves a pid file podman 5.8 can't get past --
  # see remove_stale_shared_pause_pidfile above. Give the kill a moment to land first.
  sleep 0.2
  remove_stale_shared_pause_pidfile 2>/dev/null
  true
}

PODMAN_ARGS=(--rm --network=none)
# Without -i, podman leaves stdin closed -- an interactive shell/TUI inside hits EOF and
# exits immediately (looks like the container "won't stay open", but it ran fine and exited
# on its own). Only add -t when a real terminal is attached; podman errors on -t under a
# tty-less bsub/one-shot job.
if [[ -t 0 ]]; then
  PODMAN_ARGS+=(-it)
else
  PODMAN_ARGS+=(-i)
fi
if [[ $GPU -eq 1 ]]; then
  # All CDI devices, not one per entry in CUDA_VISIBLE_DEVICES: LSF renumbers the allocated GPUs
  # from 0 inside the job (a 1-GPU job always sees CUDA_VISIBLE_DEVICES=0), while CDI names
  # count the whole node, and a node's CDI spec can map names to the wrong /dev/nvidiaN when it
  # was generated before device minors changed. Either way a per-GPU --device can hand the
  # container a node the job may not open. The job's device cgroup lets only the allocated GPUs
  # through, so `all` inside it is exactly the job's GPUs.
  if [[ -n "${LSB_JOBID:-}" && -z "${CUDA_VISIBLE_DEVICES:-}" ]]; then
    echo "podman-run.sh: --gpu inside LSF job $LSB_JOBID, but CUDA_VISIBLE_DEVICES is empty --" \
         "the job has no GPU allocated (submit with -gpu \"num=1\" on a GPU queue)" >&2
    exit 1
  fi
  PODMAN_ARGS+=(--device nvidia.com/gpu=all)
fi
if [[ $KEEP_ID -eq 1 ]]; then
  PODMAN_ARGS+=(--userns=keep-id --user "$(id -u):$(id -g)" -e "HOME=$HOME")
fi
[[ ${#VOLUMES[@]} -gt 0 ]] && PODMAN_ARGS+=("${VOLUMES[@]}")
[[ ${#ENV_ARGS[@]} -gt 0 ]] && PODMAN_ARGS+=("${ENV_ARGS[@]}")

# NOTE: an earlier version of this script attempted to mask credential paths under $HOME
# here, the same way sandbox-run.sh does (an empty --tmpfs over .ssh/.aws/etc., appended
# after $VOLUMES so it'd override an earlier --rw/--ro on $HOME). REMOVED 2026-09-10:
# confirmed live it does NOT work -- `df -h` inside the container shows the tmpfs correctly
# mounted at e.g. $HOME/.ssh, but the real files (id_rsa, known_hosts, credentials.db, etc.)
# remained fully readable through it regardless, byte-identical to the real ones on disk. An
# isolated --tmpfs with no overlapping -v (no ancestor bind covering it) worked correctly in
# the same test, so the failure is specific to nesting a --tmpfs inside a path already
# covered by an active -v bind of an ancestor directory -- podman/crun most likely treats a
# -v bind of a whole directory tree as a single mount rather than applying mounts as
# sequential, overridable syscalls the way bwrap does, so "later argument wins" (which is
# what makes sandbox-run.sh's fix work) does not hold here. Leaving this masked-but-broken
# would be worse than no masking at all -- it looks protected in `df -h` while the real data
# stays fully exposed. See "Filesystem access" in README.md for the actual mitigation
# (never --rw/--ro a path containing $HOME -- scope to the specific subdirectory you need).

PROXY_PID=""
PROXY_DIR=""
PROXY_SOCK=""
wait_for_proxy_socket() {
  # $1 = socket path, $2 = proxy pid. Up to 10s; returns 1 if the proxy exits first. The socket
  # lives in a fresh 0700 directory of our own, so a socket at this path can only be ours.
  for _ in $(seq 1 100); do
    [[ -S "$1" ]] && return 0
    if ! kill -0 "$2" 2>/dev/null; then
      echo "podman-run.sh: allowlist proxy exited before creating $1 -- see $PROXY_DIR/proxy.log" >&2
      return 1
    fi
    sleep 0.1
  done
  echo "podman-run.sh: allowlist proxy did not create $1 within 10s -- see $PROXY_DIR/proxy.log" >&2
  return 1
}
cleanup() {
  # IMPORTANT: this function's own LAST command's exit status becomes the script's real exit
  # code, silently overriding whatever `exit N` triggered it -- bash only honors the original
  # N if the EXIT trap itself doesn't leave a nonzero status behind. Confirmed live: an
  # earlier version ended on a bare `[[ -e ... ]] && echo ...`, which evaluates to *false*
  # (exit 1) in the common case where cleanup actually succeeded -- silently turning every
  # successful run's exit code into 1 regardless of the real command's exit status. Every
  # line below must not be the accidental last word; the explicit `true` at the end is load
  # -bearing, not decorative.
  [[ -n "$PROXY_PID" ]] && kill "$PROXY_PID" 2>/dev/null || true

  # Remove this job's own containers before tearing down the storage config they're addressed
  # through -- a container that outlives this cleanup becomes unreachable once storage.conf is
  # gone. Scoped to CONTAINERS_STORAGE_CONF, so this can never touch a sibling job's containers.
  podman rm -f --all --time 10 >/dev/null 2>&1 || true

  # The watchdog below should already have reaped any lingering catatonit for this job by the
  # time we get here; this is just a last-chance sweep before removing the storage dir.
  kill_orphaned_catatonit_for_this_job

  # The overlay unmount for a just-removed container isn't always finished the instant the
  # kill above happens -- an immediate rm -rf of the storage dir can still hit a busy mount.
  # Retry for up to 30s; if it still hasn't cleared, leave it and say so rather than failing
  # silently. `podman unshare` first: a private graphroot's overlay diff dirs are owned by
  # subuid-mapped UIDs, so a plain rm -rf as the invoking user gets "Permission denied" on
  # most of the tree and leaves debris behind.
  #
  # Only root/ and run/ here, NOT the whole $JOB_STORAGE_DIR: podman unshare itself needs
  # $XDG_RUNTIME_DIR and $CONTAINERS_STORAGE_CONF (both inside this dir) alive to run --
  # deleting the whole tree on iteration 1 while a busy mount makes the overall rm fail would
  # leave iterations 2-30 invoking podman against its own deleted runtime dir, degrading every
  # retry to the debris-leaving plain-rm path this loop exists to avoid.
  for _ in $(seq 1 30); do
    { podman unshare rm -rf "$JOB_STORAGE_DIR/root" "$JOB_STORAGE_DIR/run" 2>/dev/null \
        || rm -rf "$JOB_STORAGE_DIR/root" "$JOB_STORAGE_DIR/run" 2>/dev/null; } && break
    sleep 1
  done

  # `podman unshare` above is itself a podman command, run AFTER the sweep may have already
  # killed this job's pause process -- that sequence can spawn a brand new replacement pause
  # process to service it, which nothing then checks for again. One more sweep here catches
  # that replacement instead of leaving it as a second, unnoticed orphan. (The environ match
  # stays valid even once the directory itself no longer exists on disk.)
  kill_orphaned_catatonit_for_this_job

  # Everything left (xdg-runtime, storage.conf, cfg/, proxy/) is owned by the invoking user
  # directly -- no subuid mapping -- so a plain rm of the whole per-job state dir finishes the
  # job without needing podman at all (the credentials bind only ever existed in the
  # container's namespace; on the host cfg/ holds an empty placeholder at most). Retried
  # with a sweep in between: confirmed live (first invocation of tests/test-podman.sh on the
  # cluster) that a single rm here can race the replacement pause process's last writes into
  # xdg-runtime/libpod/tmp (alive, alive.lck, exits/, persist/, rootless-netns/ -- all owned by
  # the invoking user, all trivially removable a minute later), leaving that subtree behind.
  for _ in $(seq 1 5); do
    rm -rf "$JOB_DIR" 2>/dev/null
    [[ -e "$JOB_DIR" ]] || break
    sleep 1
    kill_orphaned_catatonit_for_this_job
  done
  if [[ -e "$JOB_DIR" ]]; then
    echo "podman-run.sh: couldn't clean up $JOB_DIR (still busy after 30s) -- remove later with: podman unshare rm -rf $JOB_DIR" >&2
  fi
  true
}
trap cleanup EXIT
# bash does NOT run EXIT traps when killed by an untrapped fatal signal, and that is exactly
# how LSF ends over-walltime jobs (SIGUSR2/SIGTERM before SIGKILL) and how `bkill` works --
# without these, a walltime kill leaks the container, the pause process, and the per-job
# /scratch store until the cleanup cron. Trapping the signal to `exit` routes it through the
# EXIT trap above.
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 141' USR2

RELAY_PORT=$((20000 + RANDOM % 20000))

if [[ ${#ALLOW_HOSTS[@]} -gt 0 ]]; then
  # A fresh 0700 directory holds the socket and its log: nobody else on the node can reach the
  # socket (it is created 0755), and no one else's socket can stand in for ours. It must stay on
  # node-local storage -- a Unix socket cannot be bound on NFS.
  PROXY_DIR="$JOB_DIR/proxy"
  mkdir -p "$PROXY_DIR"
  PROXY_SOCK="$PROXY_DIR/proxy.sock"
  python3 "$SCRIPT_DIR/allowlist_proxy.py" "$PROXY_SOCK" "${ALLOW_HOSTS[@]}" \
    > "$PROXY_DIR/proxy.log" 2>&1 &
  PROXY_PID=$!
  # Bounded, fail-closed wait, as in sandbox-run.sh (a fixed sleep raced the interpreter start).
  wait_for_proxy_socket "$PROXY_SOCK" "$PROXY_PID" || exit 1
  PODMAN_ARGS+=(
    -v "$SCRIPT_DIR/relay.py:/opt/relay.py:ro"
    -v "$PROXY_SOCK:/run/proxy.sock:ro"
  )
  podman run "${PODMAN_ARGS[@]}" "$IMAGE" /bin/bash -c '
    python3 /opt/relay.py 127.0.0.1 '"$RELAY_PORT"' /run/proxy.sock &
    sleep 1
    export http_proxy=http://127.0.0.1:'"$RELAY_PORT"' https_proxy=http://127.0.0.1:'"$RELAY_PORT"'
    export HTTP_PROXY=http://127.0.0.1:'"$RELAY_PORT"' HTTPS_PROXY=http://127.0.0.1:'"$RELAY_PORT"'
    export no_proxy=127.0.0.1,localhost NO_PROXY=127.0.0.1,localhost
    exec "$@"
  ' bash "${CMD[@]}" <&3 &
else
  podman run "${PODMAN_ARGS[@]}" "$IMAGE" "${CMD[@]}" <&3 &
fi
PODMAN_PID=$!

# `catatonit` (podman's container-init) lingering after the container's own command has
# finished is a known issue on this cluster, independent of this script -- Janelia's own
# Harbor/LSF fork documents hitting the same thing (hpc/README.md there works around it with a
# blanket `pkill catatonit` in .bashrc). A blanket kill isn't safe for us: this script
# deliberately runs multiple podman jobs concurrently on one node now, so killing every
# catatonit for this user could kill a sibling job's still-running container. This has to run
# CONCURRENTLY with `podman run`, not after it returns: confirmed live that catatonit can get
# reparented to PID 1 before podman's monitor reaps it, which then blocks `podman run` itself
# from ever returning -- a post-hoc cleanup trap never gets a chance to run in that case.
(
  while kill -0 "$PODMAN_PID" 2>/dev/null; do
    kill_orphaned_catatonit_for_this_job
    sleep 2
  done
) &
WATCHDOG_PID=$!

EXIT_CODE=0
wait "$PODMAN_PID" || EXIT_CODE=$?
kill "$WATCHDOG_PID" 2>/dev/null
wait "$WATCHDOG_PID" 2>/dev/null || true
exit "$EXIT_CODE"
