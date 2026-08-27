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
#   --image NAME    Image to run (default: the pre-built image on GHCR --
#                    `podman pull` it first, or build your own locally with
#                    `podman build -t agentic-sandbox-gpu:latest .` in this directory
#                    and pass `--image localhost/agentic-sandbox-gpu:latest`)
#   --ro PATH       Read-only bind (repeatable): -v PATH:PATH:ro
#   --rw PATH       Read-write bind (repeatable): -v PATH:PATH:rw
#   --allow HOST    Allowed egress domain (repeatable). Starts the allowlist proxy + relay
#                   automatically, same mechanism as sandbox-run.sh. Omit for --network=none
#                   with no exceptions.
#   --gpu           Add --device nvidia.com/gpu=all
#   --scratch       Shorthand for --rw /scratch/$USER
#   --claude        Shorthand for RW binds on ~/.claude and ~/.claude.json
#   --opencode      Shorthand for RW binds on opencode's XDG dirs
#   -h, --help      Show help
set -euo pipefail

# Save the real stdin before anything backgrounds `podman run` (needed below, for the
# catatonit watchdog) -- bash silently redirects a backgrounded job's stdin from /dev/null,
# confirmed live: piping input into this script and running `-- cat` produced no output at all
# once `podman run` moved to the background. fd 3 keeps the original stdin (tty, pipe, or
# redirected file, whatever it actually is) reachable via `<&3` when launching podman.
exec 3<&0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="ghcr.io/janeliascientificcomputingsystems/agentic-sandbox-gpu:latest"
VOLUMES=()
ALLOW_HOSTS=()
GPU=0

usage() { sed -n '2,25p' "${BASH_SOURCE[0]}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image) IMAGE="$2"; shift 2 ;;
    --ro) VOLUMES+=("-v" "$2:$2:ro"); shift 2 ;;
    --rw) VOLUMES+=("-v" "$2:$2:rw"); shift 2 ;;
    --allow) ALLOW_HOSTS+=("$2"); shift 2 ;;
    --gpu) GPU=1; shift ;;
    --scratch) VOLUMES+=("-v" "/scratch/$USER:/scratch/$USER:rw"); shift ;;
    --claude)
      # Mounted to /root/... (the container's actual $HOME as root, its default
      # user), NOT $HOME/... -- unlike bwrap, a container doesn't run as you by
      # default, and forcing identity via --userns=keep-id/--user hit real
      # subuid/subgid and file-permission problems here. Podman volume src/dst
      # don't have to match, so just aim at where root actually looks.
      VOLUMES+=("-v" "$HOME/.claude:/root/.claude:rw" "-v" "$HOME/.claude.json:/root/.claude.json:rw")
      shift ;;
    --opencode)
      VOLUMES+=("-v" "$HOME/.config/opencode:/root/.config/opencode:rw"
                "-v" "$HOME/.local/share/opencode:/root/.local/share/opencode:rw"
                "-v" "$HOME/.local/state/opencode:/root/.local/state/opencode:rw"
                "-v" "$HOME/.cache/opencode:/root/.cache/opencode:rw")
      shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done
CMD=("$@")
if [[ ${#CMD[@]} -eq 0 ]]; then
  echo "No command given after --" >&2; usage; exit 1
fi

# Rootless podman's shared storage state can go stale after a node reboot (Janelia's own
# Harbor-fork prior art documents this). Reconcile before every invocation instead of
# requiring the caller to remember to. Concurrency between jobs is handled separately, below
# -- this is about the shared store's own integrity, not job-vs-job collision.
unset XDG_RUNTIME_DIR
podman system migrate 2>/dev/null || true
podman info >/dev/null 2>&1 || podman system reset -f

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
# $LSB_JOBID so concurrent LSF jobs never collide; falls back to $$-$RANDOM outside LSF.
SHARED_GRAPHROOT="$(podman info --format '{{.Store.GraphRoot}}' 2>/dev/null)"
JOBTAG="${LSB_JOBID:-$$-$RANDOM}"
JOB_STORAGE_DIR="/scratch/$USER/podman-jobs/$JOBTAG"
mkdir -p "$JOB_STORAGE_DIR/root" "$JOB_STORAGE_DIR/run"
PODMAN_GLOBAL_ARGS=(--root "$JOB_STORAGE_DIR/root" --runroot "$JOB_STORAGE_DIR/run")
[[ -n "$SHARED_GRAPHROOT" ]] && PODMAN_GLOBAL_ARGS+=(--storage-opt "additionalimagestore=$SHARED_GRAPHROOT")

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
[[ $GPU -eq 1 ]] && PODMAN_ARGS+=(--device nvidia.com/gpu=all)
[[ ${#VOLUMES[@]} -gt 0 ]] && PODMAN_ARGS+=("${VOLUMES[@]}")

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
  # The watchdog below should already have reaped any lingering catatonit for this job by the
  # time we get here; this is just a last-chance sweep before removing the storage dir.
  kill_orphaned_catatonit_for_this_job
  # The overlay unmount for a just-removed container isn't always finished the instant the
  # kill above happens -- an immediate rm -rf of the storage dir can still hit a busy mount.
  # Retry for up to 30s; if it still hasn't cleared, leave it and say so rather than failing
  # silently -- it's cheap to leave (lock/metadata files only, not image data, since that
  # lives in the shared additionalimagestore).
  for _ in $(seq 1 30); do
    rm -rf "$JOB_STORAGE_DIR" 2>/dev/null && break
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
  sleep 1
  PODMAN_ARGS+=(
    -v "$SCRIPT_DIR/relay.py:/opt/relay.py:ro"
    -v "$PROXY_SOCK:/run/proxy.sock:ro"
  )
  podman "${PODMAN_GLOBAL_ARGS[@]}" run "${PODMAN_ARGS[@]}" "$IMAGE" /bin/bash -c '
    python3 /opt/relay.py 127.0.0.1 '"$RELAY_PORT"' /run/proxy.sock &
    sleep 1
    export http_proxy=http://127.0.0.1:'"$RELAY_PORT"' https_proxy=http://127.0.0.1:'"$RELAY_PORT"'
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
