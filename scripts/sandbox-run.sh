#!/bin/bash
# sandbox-run.sh -- convenience wrapper around bwrap + the allowlist proxy/relay.
#
# Assembles the bwrap invocation (RO/RW binds, network default-deny, optional
# domain-allowlisted egress) so you don't hand-write the raw flags every time.
#
# Usage:
#   sandbox-run.sh [options] -- <command...>
#
# Options:
#   --ro PATH            Read-only bind (repeatable). PATH is bound to itself.
#   --rw PATH            Read-write bind (repeatable). PATH is bound to itself.
#   --allow HOST         Allowed egress domain (repeatable). Starts the allowlist
#                         proxy + in-sandbox relay automatically; sets
#                         http_proxy/https_proxy inside the sandboxed command.
#                         Omit entirely for a fully network-less sandbox.
#   --scratch             Shorthand for --rw /scratch/$USER
#   --claude               Shorthand for RW binds on ~/.claude and ~/.claude.json
#                          (Claude Code's own credential/session storage)
#   --opencode             Shorthand for RW binds on opencode's XDG dirs
#                          (~/.config/opencode, ~/.local/share/opencode,
#                          ~/.local/state/opencode, ~/.cache/opencode)
#   -h, --help             Show this help
#
# The toolchain (/usr /bin /lib64 /lib /sbin /etc) and $HOME (read-only, unless
# a --rw path overrides part of it) are always bound -- that's the base every
# sandbox in this repo's docs assumes; --ro/--rw are for anything ADDITIONAL.
#
# Examples:
#   sandbox-run.sh --scratch --allow litellm.int.janelia.org -- \
#     opencode run "..." --model litellm/kimi-k3
#
#   sandbox-run.sh --scratch --claude \
#     --allow api.anthropic.com --allow claude.ai --allow platform.claude.com -- \
#     claude
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RO_BINDS=()
RW_BINDS=()
ALLOW_HOSTS=()

usage() { sed -n '2,33p' "${BASH_SOURCE[0]}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ro) RO_BINDS+=("$2"); shift 2 ;;
    --rw) RW_BINDS+=("$2"); shift 2 ;;
    --allow) ALLOW_HOSTS+=("$2"); shift 2 ;;
    --scratch) RW_BINDS+=("/scratch/$USER"); shift ;;
    --claude) RW_BINDS+=("$HOME/.claude" "$HOME/.claude.json"); shift ;;
    --opencode)
      RW_BINDS+=("$HOME/.config/opencode" "$HOME/.local/share/opencode" \
                 "$HOME/.local/state/opencode" "$HOME/.cache/opencode")
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

BWRAP_ARGS=(
  --ro-bind /usr /usr --ro-bind /bin /bin --ro-bind /lib64 /lib64 --ro-bind /lib /lib
  --ro-bind /sbin /sbin --ro-bind /etc /etc
  --ro-bind "$HOME" "$HOME"
  --proc /proc --dev /dev --unshare-net --unshare-pid --die-with-parent
)
# Mask well-known credential locations inside $HOME -- even though $HOME is
# only read-only bound above, read access alone is enough for a
# prompt-injected agent to exfiltrate or display secret contents (this is
# Anthropic's own explicit warning in their secure-deployment guide, and our
# default of binding all of $HOME was doing exactly what they warn against).
# Bind order matters in bwrap: these run AFTER the $HOME bind above, so they
# override it for just these paths. Directories get an empty tmpfs overlay
# (agent sees an empty dir, not the real one); single files get bound over
# with a freshly created empty regular file -- NOT /dev/null: confirmed live
# that binding the /dev/null device node onto a non-/dev path fails with
# "Permission denied" (bwrap applies nodev to binds outside its own --dev
# tree, which neuters the device semantics /dev/null needs). Only masks
# paths that actually exist -- $HOME is already read-only bound above, so
# bwrap can't create a new mountpoint for a path that doesn't exist yet
# (confirmed live: --tmpfs on a nonexistent ~/.azure failed with "Can't
# mkdir: Read-only file system"), and there's nothing to protect at a path
# the user doesn't have anyway.
SENSITIVE_HOME_DIRS=(.ssh .aws .azure .kube .config/gcloud .docker)
SENSITIVE_HOME_FILES=(.git-credentials .npmrc .pypirc .netrc .env .env.local)
for d in "${SENSITIVE_HOME_DIRS[@]}"; do
  [[ -d "$HOME/$d" ]] && BWRAP_ARGS+=(--tmpfs "$HOME/$d")
done
EMPTY_MASK_FILE=""
for f in "${SENSITIVE_HOME_FILES[@]}"; do
  if [[ -f "$HOME/$f" ]]; then
    [[ -z "$EMPTY_MASK_FILE" ]] && EMPTY_MASK_FILE="$(mktemp /tmp/sandbox-empty.XXXXXX)"
    BWRAP_ARGS+=(--ro-bind "$EMPTY_MASK_FILE" "$HOME/$f")
  fi
done
# SSSD's NSS socket -- lets whoami/id/getent resolve UID->username on
# AD/LDAP-joined hosts. Doesn't affect actual permission enforcement (that's
# UID-number-based at the kernel level regardless), just name resolution.
# Bound automatically when present; harmlessly skipped otherwise.
if [[ -S /var/lib/sss/pipes/nss ]]; then
  BWRAP_ARGS+=(--ro-bind /var/lib/sss/pipes/nss /var/lib/sss/pipes/nss)
fi
for p in "${RO_BINDS[@]:-}"; do [[ -n "$p" ]] && BWRAP_ARGS+=(--ro-bind "$p" "$p"); done
for p in "${RW_BINDS[@]:-}"; do [[ -n "$p" ]] && BWRAP_ARGS+=(--bind "$p" "$p"); done

PROXY_PID=""
PROXY_SOCK=""
cleanup() {
  [[ -n "$PROXY_PID" ]] && kill "$PROXY_PID" 2>/dev/null || true
  [[ -n "$PROXY_SOCK" && -e "$PROXY_SOCK" ]] && rm -f "$PROXY_SOCK"
  [[ -n "$EMPTY_MASK_FILE" && -e "$EMPTY_MASK_FILE" ]] && rm -f "$EMPTY_MASK_FILE"
}
trap cleanup EXIT

RELAY_PORT=$((20000 + RANDOM % 20000))

if [[ ${#ALLOW_HOSTS[@]} -gt 0 ]]; then
  PROXY_SOCK="$(mktemp -u /tmp/sandbox-proxy.XXXXXX.sock)"
  python3 "$SCRIPT_DIR/allowlist_proxy.py" "$PROXY_SOCK" "${ALLOW_HOSTS[@]}" \
    > "${PROXY_SOCK}.log" 2>&1 &
  PROXY_PID=$!
  sleep 1
  BWRAP_ARGS+=(
    --ro-bind "$SCRIPT_DIR/relay.py" /opt/sandbox-relay.py
    --ro-bind "$PROXY_SOCK" /run/sandbox-proxy.sock
  )
  INNER_CMD=(
    /bin/bash -c
    'python3 /opt/sandbox-relay.py 127.0.0.1 '"$RELAY_PORT"' /run/sandbox-proxy.sock & sleep 1; export http_proxy=http://127.0.0.1:'"$RELAY_PORT"' https_proxy=http://127.0.0.1:'"$RELAY_PORT"'; exec "$@"'
    bash
    "${CMD[@]}"
  )
  # Deliberately NOT exec'd here: exec would replace this script's own
  # process image, which would skip the `trap cleanup EXIT` below and leak
  # the host-side allowlist_proxy.py process. Run it as a normal foreground
  # child instead, so the trap fires once it returns, and propagate its exit
  # code explicitly.
  bwrap "${BWRAP_ARGS[@]}" -- "${INNER_CMD[@]}"
  exit $?
else
  exec bwrap "${BWRAP_ARGS[@]}" -- "${CMD[@]}"
fi
