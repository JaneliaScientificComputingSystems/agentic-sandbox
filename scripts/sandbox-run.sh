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
# The toolchain (/usr /bin /lib64 /lib /sbin /etc) and $PWD (read-write, wherever
# you invoke this script from) are always bound -- that's the base every sandbox
# in this repo's docs assumes; --ro/--rw are for anything ADDITIONAL. $HOME is NOT
# bound by default (changed 2026-09-10, was previously always read-only-bound) --
# use --rw/--ro if a task genuinely needs files elsewhere in your home directory.
# Known credential paths (.ssh, .aws, .git-credentials, etc.) are always masked
# wherever they'd otherwise appear -- under $PWD, and under $HOME too if you do
# pass --rw/--ro on it -- see the masking block below for the full list and why
# this can't be opted out of via a generic --rw/--ro on one of those exact paths.
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
  --bind "$PWD" "$PWD"
  --proc /proc --dev /dev --unshare-net --unshare-pid --die-with-parent
)
# SSSD's NSS socket -- lets whoami/id/getent resolve UID->username on
# AD/LDAP-joined hosts. Doesn't affect actual permission enforcement (that's
# UID-number-based at the kernel level regardless), just name resolution.
# Bound automatically when present; harmlessly skipped otherwise.
if [[ -S /var/lib/sss/pipes/nss ]]; then
  BWRAP_ARGS+=(--ro-bind /var/lib/sss/pipes/nss /var/lib/sss/pipes/nss)
fi
for p in "${RO_BINDS[@]:-}"; do [[ -n "$p" ]] && BWRAP_ARGS+=(--ro-bind "$p" "$p"); done
for p in "${RW_BINDS[@]:-}"; do [[ -n "$p" ]] && BWRAP_ARGS+=(--bind "$p" "$p"); done

# Mask well-known credential locations -- applied LAST, after every --ro/--rw
# above (including --claude/--opencode/--scratch and anything the caller
# added), so this is the unconditional final word, not something a generic
# --rw/--ro on one of these exact paths can quietly re-expose. Checked under
# both $PWD (always bound above) and $HOME (only actually visible in the
# sandbox if the caller explicitly --rw/--ro'd it or it happens to equal
# $PWD) -- deduplicated so a path checked under both isn't masked twice.
# Read access alone is enough for a prompt-injected agent to exfiltrate or
# display secret contents (Anthropic's own explicit warning in their
# secure-deployment guide). Directories get an empty tmpfs overlay (agent
# sees an empty dir, not the real one); single files get bound over with a
# freshly created empty regular file -- NOT /dev/null: confirmed live that
# binding the /dev/null device node onto a non-/dev path fails with
# "Permission denied" (bwrap applies nodev to binds outside its own --dev
# tree, which neuters the device semantics /dev/null needs). Only masks
# paths that actually exist on the host -- nothing to protect at a path the
# user doesn't have, and bwrap can't create a mountpoint for one anyway if
# its parent ended up read-only bound (confirmed live: --tmpfs on a
# nonexistent ~/.azure under a read-only $HOME failed with "Can't mkdir:
# Read-only file system").
SENSITIVE_HOME_DIRS=(.ssh .aws .azure .kube .config/gcloud .docker)
SENSITIVE_HOME_FILES=(.git-credentials .npmrc .pypirc .netrc .env .env.local)
declare -A MASK_ROOTS_SEEN=()
MASK_ROOTS=()
for root in "$PWD" "$HOME"; do
  [[ -n "${MASK_ROOTS_SEEN[$root]:-}" ]] && continue
  MASK_ROOTS_SEEN[$root]=1
  MASK_ROOTS+=("$root")
done
EMPTY_MASK_FILE=""
for root in "${MASK_ROOTS[@]}"; do
  for d in "${SENSITIVE_HOME_DIRS[@]}"; do
    [[ -d "$root/$d" ]] && BWRAP_ARGS+=(--tmpfs "$root/$d")
  done
  for f in "${SENSITIVE_HOME_FILES[@]}"; do
    if [[ -f "$root/$f" ]]; then
      [[ -z "$EMPTY_MASK_FILE" ]] && EMPTY_MASK_FILE="$(mktemp /tmp/sandbox-empty.XXXXXX)"
      BWRAP_ARGS+=(--ro-bind "$EMPTY_MASK_FILE" "$root/$f")
    fi
  done
done

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
