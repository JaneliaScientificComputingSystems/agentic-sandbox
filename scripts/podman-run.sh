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
#   --gpu           Add --device nvidia.com/gpu=all
#   --scratch       Shorthand for --rw /scratch/$USER
#   --claude        Shorthand for RW binds on ~/.claude and ~/.claude.json
#   --opencode      Shorthand for RW binds on opencode's XDG dirs
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

usage() { sed -n '2,46p' "${BASH_SOURCE[0]}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image) IMAGE="$2"; shift 2 ;;
    --ro) VOLUMES+=("-v" "$2:$2:ro"); shift 2 ;;
    --rw) VOLUMES+=("-v" "$2:$2:rw"); shift 2 ;;
    --allow) ALLOW_HOSTS+=("$2"); shift 2 ;;
    --gpu) GPU=1; shift ;;
    --keep-id) KEEP_ID=1; shift ;;
    --scratch) VOLUMES+=("-v" "/scratch/$USER:/scratch/$USER:rw"); shift ;;
    --claude) WANT_CLAUDE=1; shift ;;
    --opencode) WANT_OPENCODE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done
CMD=("$@")

# --claude/--opencode's mount DESTINATION depends on --keep-id, decided here (after the full
# parse) rather than at the point each flag was seen, so flag order never matters. Default
# (no --keep-id): container runs as root, $HOME=/root -- mount to /root/... where root
# actually looks; forcing identity via --user without namespace remapping hit real
# subuid/subgid and file-permission problems (see ADMIN-NOTES.md's "identity/HOME saga").
# --keep-id: container runs as your real uid, $HOME=$HOME (set via -e HOME below) -- mount to
# the real $HOME/... path instead, same convention as bwrap.
if [[ $WANT_CLAUDE -eq 1 ]]; then
  if [[ $KEEP_ID -eq 1 ]]; then
    VOLUMES+=("-v" "$HOME/.claude:$HOME/.claude:rw" "-v" "$HOME/.claude.json:$HOME/.claude.json:rw")
  else
    VOLUMES+=("-v" "$HOME/.claude:/root/.claude:rw" "-v" "$HOME/.claude.json:/root/.claude.json:rw")
  fi
fi
if [[ $WANT_OPENCODE -eq 1 ]]; then
  if [[ $KEEP_ID -eq 1 ]]; then
    VOLUMES+=("-v" "$HOME/.config/opencode:$HOME/.config/opencode:rw"
              "-v" "$HOME/.local/share/opencode:$HOME/.local/share/opencode:rw"
              "-v" "$HOME/.local/state/opencode:$HOME/.local/state/opencode:rw"
              "-v" "$HOME/.cache/opencode:$HOME/.cache/opencode:rw")
  else
    VOLUMES+=("-v" "$HOME/.config/opencode:/root/.config/opencode:rw"
              "-v" "$HOME/.local/share/opencode:/root/.local/share/opencode:rw"
              "-v" "$HOME/.local/state/opencode:/root/.local/state/opencode:rw"
              "-v" "$HOME/.cache/opencode:/root/.cache/opencode:rw")
  fi
fi
if [[ ${#CMD[@]} -eq 0 ]]; then
  echo "No command given after --" >&2; usage; exit 1
fi

# Per-job storage and runtime paths, created FIRST, before any podman command below runs.
# Keyed on $LSB_JOBID plus $LSB_JOBINDEX plus this script's own $$, so no two invocations can
# ever share one: every element of an LSF array job shares the same $LSB_JOBID, so two
# elements packed onto one node would otherwise share (and then mutually destroy) a storage
# dir; a `brequeue`d job reuses its LSB_JOBID too; and a job script that calls podman-run.sh
# twice is one LSB_JOBID as well -- $$ makes each invocation unique regardless. Falls back to
# "manual" outside LSF. Two things live here, both ported from Janelia's Harbor fork (hpc/harbor-lsf-wrapper.sh),
# where each was found by real packed-job failures:
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
JOB_STORAGE_DIR="/scratch/$USER/podman-jobs/${LSB_JOBID:-manual}${LSB_JOBINDEX:+-$LSB_JOBINDEX}-$$"
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
  python3 - "$db" "$want" "/scratch/$USER/podman-jobs/" <<'REPAIR' 2>&1 | sed 's/^/podman-run.sh: /' >&2
import sqlite3, sys
db, want, bad_prefix = sys.argv[1:4]
try:
    c = sqlite3.connect(db, timeout=15)
    row = c.execute("select TmpDir from DBConfig").fetchone()
    if row and row[0].startswith(bad_prefix) and row[0] != want:
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
[[ $GPU -eq 1 ]] && PODMAN_ARGS+=(--device nvidia.com/gpu=all)
if [[ $KEEP_ID -eq 1 ]]; then
  PODMAN_ARGS+=(--userns=keep-id --user "$(id -u):$(id -g)" -e "HOME=$HOME")
fi
[[ ${#VOLUMES[@]} -gt 0 ]] && PODMAN_ARGS+=("${VOLUMES[@]}")

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
PROXY_SOCK=""
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
  [[ -n "$PROXY_SOCK" && -e "$PROXY_SOCK" ]] && rm -f "$PROXY_SOCK" || true

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

  # Everything left (xdg-runtime, storage.conf) is owned by the invoking user directly -- no
  # subuid mapping -- so a plain rm finishes the job without needing podman at all. Retried
  # with a sweep in between: confirmed live (first invocation of tests/test-podman.sh on the
  # cluster) that a single rm here can race the replacement pause process's last writes into
  # xdg-runtime/libpod/tmp (alive, alive.lck, exits/, persist/, rootless-netns/ -- all owned by
  # the invoking user, all trivially removable a minute later), leaving that subtree behind.
  for _ in $(seq 1 5); do
    rm -rf "$JOB_STORAGE_DIR" 2>/dev/null
    [[ -e "$JOB_STORAGE_DIR" ]] || break
    sleep 1
    kill_orphaned_catatonit_for_this_job
  done
  if [[ -e "$JOB_STORAGE_DIR" ]]; then
    echo "podman-run.sh: couldn't clean up $JOB_STORAGE_DIR (still busy after 30s) -- remove later with: podman unshare rm -rf $JOB_STORAGE_DIR" >&2
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
  PROXY_SOCK="$(mktemp -u /tmp/podman-sandbox-proxy.XXXXXX.sock)"
  python3 "$SCRIPT_DIR/allowlist_proxy.py" "$PROXY_SOCK" "${ALLOW_HOSTS[@]}" \
    > "${PROXY_SOCK}.log" 2>&1 &
  PROXY_PID=$!
  sleep 1
  PODMAN_ARGS+=(
    -v "$SCRIPT_DIR/relay.py:/opt/relay.py:ro"
    -v "$PROXY_SOCK:/run/proxy.sock:ro"
  )
  podman run "${PODMAN_ARGS[@]}" "$IMAGE" /bin/bash -c '
    python3 /opt/relay.py 127.0.0.1 '"$RELAY_PORT"' /run/proxy.sock &
    sleep 1
    export http_proxy=http://127.0.0.1:'"$RELAY_PORT"' https_proxy=http://127.0.0.1:'"$RELAY_PORT"'
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
