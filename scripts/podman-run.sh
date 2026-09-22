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
#   --gpu           Attach the GPUs LSF allocated to this job: one --device nvidia.com/gpu=<idx>
#                    per entry in $CUDA_VISIBLE_DEVICES (falls back to nvidia.com/gpu=all when
#                    that variable is unset, i.e. outside LSF). Inside the container the GPUs
#                    are renumbered from 0, so do not also pass CUDA_VISIBLE_DEVICES in.
#   --scratch       Shorthand for --rw /scratch/$USER
#   --claude        Run Claude Code with a per-job config directory (CLAUDE_CONFIG_DIR): a
#                    throwaway copy of ~/.claude.json, ~/.claude/settings.json,
#                    ~/.claude/CLAUDE.md and ~/.claude/.credentials.json, deleted on exit.
#                    Only .credentials.json is copied back afterwards (if it is still valid
#                    JSON), so an existing login is reused and token refreshes / a fresh
#                    `claude auth login` persist -- but edits to settings (hooks) or MCP
#                    server entries made inside the container die with it. Those are shell
#                    commands Claude Code would otherwise run unsandboxed in your next session.
#   --opencode      Same idea: a throwaway copy of ~/.config/opencode (XDG_CONFIG_HOME) plus
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

usage() { sed -n '2,54p' "${BASH_SOURCE[0]}"; }

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

# --claude/--opencode: the harness CONFIG is copied into a per-job directory that is mounted
# at the same path inside the container and pointed to via CLAUDE_CONFIG_DIR /
# XDG_CONFIG_HOME, so its location no longer depends on --keep-id (root's $HOME=/root vs your
# real $HOME). Only opencode's DATA dirs still need the HOME-dependent destination: default
# (no --keep-id) the container runs as root and looks under /root/...; --keep-id runs as your
# real uid with $HOME=$HOME (set via -e HOME below), same convention as bwrap. See
# ADMIN-NOTES.md's "identity/HOME saga" for why forcing identity without remapping failed.
SANDBOX_CFG_ROOT=""
CLAUDE_CFG=""
CLAUDE_CREDS_BEFORE=""
new_cfg_root() {
  [[ -n "$SANDBOX_CFG_ROOT" ]] && return 0
  local base="/scratch/$USER"
  [[ -d "$base" && -w "$base" ]] || base="${TMPDIR:-/tmp}"
  SANDBOX_CFG_ROOT="$(mktemp -d "$base/podman-sandbox-cfg.XXXXXX")"
  # The copies are read by the container's user (root-in-userns maps to you on the host, but
  # --keep-id does not remap) -- keep the tree readable by the invoking account only.
  chmod 700 "$SANDBOX_CFG_ROOT"
}
if [[ $WANT_CLAUDE -eq 1 ]]; then
  new_cfg_root
  CLAUDE_CFG="$SANDBOX_CFG_ROOT/claude"
  mkdir -p "$CLAUDE_CFG"
  for f in "$HOME/.claude.json" "$HOME/.claude/settings.json" "$HOME/.claude/CLAUDE.md" \
           "$HOME/.claude/.credentials.json"; do
    [[ -f "$f" ]] && cp "$f" "$CLAUDE_CFG/$(basename "$f")"
  done
  # Snapshot so cleanup() can tell whether the credentials changed (token refresh / login).
  [[ -f "$CLAUDE_CFG/.credentials.json" ]] && CLAUDE_CREDS_BEFORE="$(cat "$CLAUDE_CFG/.credentials.json")"
  VOLUMES+=("-v" "$CLAUDE_CFG:$CLAUDE_CFG:rw")
  ENV_ARGS+=(-e "CLAUDE_CONFIG_DIR=$CLAUDE_CFG")
fi
if [[ $WANT_OPENCODE -eq 1 ]]; then
  new_cfg_root
  OPENCODE_XDG_CONFIG="$SANDBOX_CFG_ROOT/opencode-xdg-config"
  mkdir -p "$OPENCODE_XDG_CONFIG"
  [[ -d "$HOME/.config/opencode" ]] && cp -R "$HOME/.config/opencode" "$OPENCODE_XDG_CONFIG/opencode"
  VOLUMES+=("-v" "$OPENCODE_XDG_CONFIG:$OPENCODE_XDG_CONFIG:rw")
  ENV_ARGS+=(-e "XDG_CONFIG_HOME=$OPENCODE_XDG_CONFIG")
  # Data dirs stay bound to the real ones; created first so podman never has to auto-create a
  # missing source (it would, silently, as a root-owned directory).
  for d in .local/share/opencode .local/state/opencode .cache/opencode; do
    mkdir -p "$HOME/$d"
    if [[ $KEEP_ID -eq 1 ]]; then
      VOLUMES+=("-v" "$HOME/$d:$HOME/$d:rw")
    else
      VOLUMES+=("-v" "$HOME/$d:/root/$d:rw")
    fi
  done
fi
if [[ ${#CMD[@]} -eq 0 ]]; then
  echo "No command given after --" >&2; usage; exit 1
fi

# Rootless podman's shared storage state can go stale after a node reboot (Janelia's own
# Harbor-fork prior art documents this). Reconcile before every invocation instead of
# requiring the caller to remember to. Concurrency between jobs is handled separately, below
# -- this is about the shared store's own integrity, not job-vs-job collision.
unset XDG_RUNTIME_DIR
podman system migrate 2>/dev/null || true
# Do NOT `podman system reset -f` the shared store on a failed `podman info` here: this
# script deliberately runs multiple podman jobs concurrently on one node (see the
# --root/--runroot section below), so that store may be in active use by a sibling job's
# --storage-opt additionalimagestore right now. Resetting it out from under a running job
# is exactly the kind of cross-job collision the per-job --root/--runroot below exists to
# avoid. Just note it and skip the additionalimagestore cache for this invocation instead.
SHARED_STORE_HEALTHY=1
if ! podman info >/dev/null 2>&1; then
  echo "podman-run.sh: shared podman store looks unhealthy on $(hostname) -- skipping its image cache for this invocation rather than resetting a store a sibling job may be using" >&2
  SHARED_STORE_HEALTHY=0
fi

# Check for a newer version of the image on every run rather than relying on the caller to
# remember `podman pull`. Cheap in the common case -- this is a manifest-digest check, not a
# re-download, unless the image actually changed. Skipped for a purely local image
# (localhost/...), which has no registry to check against.
if [[ "$IMAGE" != localhost/* ]]; then
  podman pull "$IMAGE" || true
fi

# Give this invocation its own storage root/runroot instead of sharing the one from
# storage.conf -- that's what let two concurrent podman jobs from the same user corrupt each
# other's state on the same node (the original reason this whole repo asked for a full node
# per podman job; see ADMIN-NOTES.md). --storage-opt additionalimagestore points back at the
# shared graphroot as a READ-ONLY layer source, so this doesn't cost a re-pull for another job
# landing on the SAME node -- confirmed live: two concurrent invocations with distinct
# --root/--runroot both saw the already-pulled image instantly via `podman images` and ran to
# completion with no collision. (If storage.conf's graphroot is under /scratch, per the
# README's one-time setup, that cache is node-local scratch, not cluster-wide -- a job that
# lands on a different node still pays a fresh pull regardless of this mechanism.) Keyed on
# $LSB_JOBID plus the array index plus this shell's PID: every element of an LSF array job
# shares one LSB_JOBID (only LSB_JOBINDEX differs), and two invocations inside one job -- a
# loop, or a parallel job's per-host blaunch -- share both. Either case would otherwise share
# --root/--runroot, which is exactly the corruption this isolation exists to avoid, and the
# first invocation to finish would `rm -rf` the sibling's live storage in cleanup() while the
# catatonit watchdog matched the sibling's processes. Outside LSF: nolsf-<pid>.
JOBTAG="${LSB_JOBID:-nolsf}${LSB_JOBINDEX:+.$LSB_JOBINDEX}-$$"
JOB_STORAGE_DIR="/scratch/$USER/podman-jobs/$JOBTAG"
mkdir -p "$JOB_STORAGE_DIR/root" "$JOB_STORAGE_DIR/run"
PODMAN_GLOBAL_ARGS=(--root "$JOB_STORAGE_DIR/root" --runroot "$JOB_STORAGE_DIR/run")
if [[ "$SHARED_STORE_HEALTHY" -eq 1 ]]; then
  SHARED_GRAPHROOT="$(podman info --format '{{.Store.GraphRoot}}' 2>/dev/null)"
  [[ -n "$SHARED_GRAPHROOT" ]] && PODMAN_GLOBAL_ARGS+=(--storage-opt "additionalimagestore=$SHARED_GRAPHROOT")
fi

# Kill any catatonit for OUR job that's actually orphaned (lingering, PPID reparented to 1) --
# NOT just any catatonit that happens to reference our storage path, which is also true of our
# own container's catatonit while it's still healthy and actively running. Confirmed live:
# without the PPID check, the watchdog below can catch a perfectly healthy catatonit mid-exit
# and SIGKILL it, which is what was actually causing a wrong/nonzero podman-run.sh exit code
# even on fast, successful runs -- not a cluster-specific storage quirk, a bug in this check.
kill_orphaned_catatonit_for_this_job() {
  for pid in $(pgrep -u "$USER" -x catatonit 2>/dev/null); do
    [[ "$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')" == "1" ]] || continue
    grep -q "$JOB_STORAGE_DIR" "/proc/$pid/mountinfo" 2>/dev/null && kill -9 "$pid" 2>/dev/null
  done
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
  # podman passes no host environment, so LSF's CUDA_VISIBLE_DEVICES (the GPUs it fenced for
  # THIS job) is invisible inside; `nvidia.com/gpu=all` would attach every GPU on a shared
  # node and CUDA would pick device 0 -- someone else's -- unless the device cgroup happened to
  # refuse it. Attach exactly the allocated devices instead. CDI accepts either an index or a
  # GPU-<uuid>, which is what LSF puts in the variable.
  if [[ -n "${CUDA_VISIBLE_DEVICES:-}" ]]; then
    IFS=, read -r -a _gpu_ids <<< "$CUDA_VISIBLE_DEVICES"
    for _g in "${_gpu_ids[@]}"; do
      [[ -n "$_g" ]] && PODMAN_ARGS+=(--device "nvidia.com/gpu=$_g")
    done
  else
    PODMAN_ARGS+=(--device nvidia.com/gpu=all)
  fi
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
PROXY_SOCK=""
wait_for_proxy_socket() {
  # $1 = socket path, $2 = proxy pid. Up to 10s; returns 1 if the proxy exits first.
  for _ in $(seq 1 100); do
    [[ -S "$1" ]] && return 0
    if ! kill -0 "$2" 2>/dev/null; then
      echo "podman-run.sh: allowlist proxy exited before creating $1 -- see ${1}.log" >&2
      return 1
    fi
    sleep 0.1
  done
  echo "podman-run.sh: allowlist proxy did not create $1 within 10s -- see ${1}.log" >&2
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
  [[ -n "$PROXY_SOCK" && -e "$PROXY_SOCK" ]] && rm -f "$PROXY_SOCK" || true
  # --claude: persist ONLY the credentials file, and only if the container left valid JSON
  # behind that differs from what went in (token refresh, or a fresh `claude auth login`).
  # Settings/MCP edits made inside stay in the copy and are deleted with it below.
  if [[ -n "$CLAUDE_CFG" && -f "$CLAUDE_CFG/.credentials.json" ]]; then
    if [[ "$(cat "$CLAUDE_CFG/.credentials.json")" != "$CLAUDE_CREDS_BEFORE" ]] \
       && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if isinstance(d, dict) else 1)' \
            "$CLAUDE_CFG/.credentials.json" 2>/dev/null; then
      mkdir -p "$HOME/.claude"
      (umask 077; cp "$CLAUDE_CFG/.credentials.json" "$HOME/.claude/.credentials.json.tmp.$$") \
        && mv -f "$HOME/.claude/.credentials.json.tmp.$$" "$HOME/.claude/.credentials.json" || true
    fi
  fi
  [[ -n "$SANDBOX_CFG_ROOT" && -d "$SANDBOX_CFG_ROOT" ]] && { podman unshare rm -rf "$SANDBOX_CFG_ROOT" 2>/dev/null || rm -rf "$SANDBOX_CFG_ROOT" 2>/dev/null; } || true
  # The watchdog below should already have reaped any lingering catatonit for this job by the
  # time we get here; this is just a last-chance sweep before removing the storage dir.
  kill_orphaned_catatonit_for_this_job
  # The overlay unmount for a just-removed container isn't always finished the instant the
  # kill above happens -- an immediate rm -rf of the storage dir can still hit a busy mount.
  # Retry for up to 30s; if it still hasn't cleared, leave it and say so rather than failing
  # silently -- it's cheap to leave (lock/metadata files only, not image data, since that
  # lives in the shared additionalimagestore). `podman unshare` first: a private
  # graphroot's overlay diff dirs are owned by subuid-mapped UIDs, so a plain rm -rf as the
  # invoking user gets "Permission denied" on most of the tree and leaves debris behind.
  for _ in $(seq 1 30); do
    { podman unshare rm -rf "$JOB_STORAGE_DIR" 2>/dev/null \
        || rm -rf "$JOB_STORAGE_DIR" 2>/dev/null; } && break
    sleep 1
  done
  if [[ -e "$JOB_STORAGE_DIR" ]]; then
    echo "podman-run.sh: couldn't clean up $JOB_STORAGE_DIR (still busy after 30s) -- safe to remove later" >&2
  fi
  true
}
trap cleanup EXIT

RELAY_PORT=$((20000 + RANDOM % 20000))

if [[ ${#ALLOW_HOSTS[@]} -gt 0 ]]; then
  PROXY_SOCK="$(mktemp -u /tmp/podman-sandbox-proxy.XXXXXX.sock)"
  python3 "$SCRIPT_DIR/allowlist_proxy.py" "$PROXY_SOCK" "${ALLOW_HOSTS[@]}" \
    > "${PROXY_SOCK}.log" 2>&1 &
  PROXY_PID=$!
  # Same bounded, fail-closed wait as sandbox-run.sh (a fixed sleep raced the interpreter start).
  wait_for_proxy_socket "$PROXY_SOCK" "$PROXY_PID" || exit 1
  PODMAN_ARGS+=(
    -v "$SCRIPT_DIR/relay.py:/opt/relay.py:ro"
    -v "$PROXY_SOCK:/run/proxy.sock:ro"
  )
  podman "${PODMAN_GLOBAL_ARGS[@]}" run "${PODMAN_ARGS[@]}" "$IMAGE" /bin/bash -c '
    python3 /opt/relay.py 127.0.0.1 '"$RELAY_PORT"' /run/proxy.sock &
    sleep 1
    export http_proxy=http://127.0.0.1:'"$RELAY_PORT"' https_proxy=http://127.0.0.1:'"$RELAY_PORT"'
    export HTTP_PROXY=http://127.0.0.1:'"$RELAY_PORT"' HTTPS_PROXY=http://127.0.0.1:'"$RELAY_PORT"'
    export no_proxy=127.0.0.1,localhost NO_PROXY=127.0.0.1,localhost
    exec "$@"
  ' bash "${CMD[@]}" <&3 &
else
  podman "${PODMAN_GLOBAL_ARGS[@]}" run "${PODMAN_ARGS[@]}" "$IMAGE" "${CMD[@]}" <&3 &
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
