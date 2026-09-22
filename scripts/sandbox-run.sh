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
#   --env NAME            Pass host environment variable NAME into the sandbox (repeatable).
#                         The host environment is NOT inherited by default -- see below.
#   --scratch             Shorthand for --rw /scratch/$USER
#   --claude               Run Claude Code with a per-job config directory: a throwaway
#                          copy of ~/.claude.json, ~/.claude/settings.json and
#                          ~/.claude/CLAUDE.md, with only ~/.claude/.credentials.json bound
#                          through to the real file (CLAUDE_CONFIG_DIR points at it). See
#                          "Config isolation" below.
#   --opencode             Same idea for opencode: a throwaway copy of ~/.config/opencode
#                          (XDG_CONFIG_HOME points at it) plus RW binds on its data dirs
#                          (~/.local/share/opencode, ~/.local/state/opencode, ~/.cache/opencode)
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
# Environment: the sandbox starts from an EMPTY environment (bwrap --clearenv). Only PATH,
# HOME, USER, LOGNAME, SHELL, TERM, COLORTERM, LANG, LC_*, TZ, the common CA-bundle
# variables (SSL_CERT_FILE, SSL_CERT_DIR, REQUESTS_CA_BUNDLE, CURL_CA_BUNDLE,
# NODE_EXTRA_CA_CERTS) and anything named with --env are copied in. LSF forwards the
# submitting shell's whole environment into a job, so without this an API key or token
# exported in your shell (ANTHROPIC_API_KEY, HF_TOKEN, GITHUB_TOKEN, AWS_*...) would be
# readable by the sandboxed agent even though the credential FILES are masked.
# /tmp inside the sandbox is a private tmpfs (TMPDIR points at it). When stdin is not a
# terminal (Mode A/B, plain bsub) the sandbox also gets its own session (--new-session), so
# it cannot inject keystrokes into the submitting terminal via TIOCSTI.
#
# Config isolation (--claude/--opencode): the harness's *configuration* is where a
# prompt-injected agent can persist: ~/.claude/settings.json hooks and ~/.claude.json MCP
# server entries are shell commands Claude Code runs -- unsandboxed, as you -- in your next
# session (and settings hot-reload into an already-running one); opencode.json accepts
# plugins/MCP the same way. So those files are never bound read-write. Each run gets a fresh
# directory under /scratch/$USER seeded with COPIES, which is deleted on exit; edits made
# inside die with the job. The one file that is shared is the credentials file, so an existing
# login is reused and token refreshes persist. Not carried in: ~/.claude/plugins, skills,
# projects/ history -- pass --ro/--rw explicitly if a task needs them.
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
RO_TRY_BINDS=()   # like RO_BINDS, but skipped silently if the path doesn't exist on the host
RW_TRY_BINDS=()
ALLOW_HOSTS=()
PASS_ENV=()
WANT_CLAUDE=0
WANT_OPENCODE=0
LATE_BINDS=()     # binds that must come after every --rw (nested file binds over a per-job dir)
EXTRA_SETENV=()
SANDBOX_CFG_ROOT=""

usage() { sed -n '2,59p' "${BASH_SOURCE[0]}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ro) RO_BINDS+=("$2"); shift 2 ;;
    --rw) RW_BINDS+=("$2"); shift 2 ;;
    --allow) ALLOW_HOSTS+=("$2"); shift 2 ;;
    --env) PASS_ENV+=("$2"); shift 2 ;;
    --scratch) mkdir -p "/scratch/$USER"; RW_BINDS+=("/scratch/$USER"); shift ;;
    --claude)
      WANT_CLAUDE=1
      # The CLI's own install location, not just its credential/session state -- without
      # this, `claude` itself isn't reachable inside the sandbox now that $HOME isn't bound
      # by default (confirmed live: "exec: claude: not found" otherwise). The native
      # installer's standard layout: ~/.local/bin/claude is a symlink into
      # ~/.local/share/claude/versions/<version>; bind both ends read-only since the CLI
      # binary itself shouldn't need to be writable. bind-try: a `claude` installed some other
      # way (e.g. the VS Code extension's bundled binary symlinked into ~/.local/bin) has no
      # ~/.local/share/claude at all.
      RO_TRY_BINDS+=("$HOME/.local/bin/claude" "$HOME/.local/share/claude")
      shift ;;
    --opencode)
      WANT_OPENCODE=1
      # Same reasoning as --claude above: opencode's own installer puts the actual binary
      # under ~/.opencode/bin/opencode, separate from its four XDG state dirs above.
      # Read-only, same rationale.
      RO_TRY_BINDS+=("$HOME/.opencode")
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

# Per-job config directories for --claude/--opencode (see "Config isolation" in the header).
# Created here, before the bwrap argument list, and removed by cleanup() on exit.
new_cfg_root() {
  [[ -n "$SANDBOX_CFG_ROOT" ]] && return 0
  local base="/scratch/$USER"
  [[ -d "$base" && -w "$base" ]] || base="${TMPDIR:-/tmp}"
  SANDBOX_CFG_ROOT="$(mktemp -d "$base/sandbox-cfg.XXXXXX")"
}
if [[ $WANT_CLAUDE -eq 1 ]]; then
  new_cfg_root
  CLAUDE_CFG="$SANDBOX_CFG_ROOT/claude"
  mkdir -p "$CLAUDE_CFG"
  for f in "$HOME/.claude.json" "$HOME/.claude/settings.json" "$HOME/.claude/CLAUDE.md"; do
    [[ -f "$f" ]] && cp "$f" "$CLAUDE_CFG/$(basename "$f")"
  done
  RW_BINDS+=("$CLAUDE_CFG")
  if [[ -f "$HOME/.claude/.credentials.json" ]]; then
    # Bound AFTER the directory bind (LATE_BINDS), so the real file shows through the copy dir.
    LATE_BINDS+=(--bind "$HOME/.claude/.credentials.json" "$CLAUDE_CFG/.credentials.json")
  else
    echo "sandbox-run.sh: warning: no ~/.claude/.credentials.json -- a \`claude auth login\` done inside the sandbox will NOT persist past this run. Log in once outside the sandbox first, or pass --env ANTHROPIC_API_KEY." >&2
  fi
  EXTRA_SETENV+=(CLAUDE_CONFIG_DIR "$CLAUDE_CFG")
fi
if [[ $WANT_OPENCODE -eq 1 ]]; then
  new_cfg_root
  OPENCODE_XDG_CONFIG="$SANDBOX_CFG_ROOT/opencode-xdg-config"
  mkdir -p "$OPENCODE_XDG_CONFIG"
  [[ -d "$HOME/.config/opencode" ]] && cp -R "$HOME/.config/opencode" "$OPENCODE_XDG_CONFIG/opencode"
  RW_BINDS+=("$OPENCODE_XDG_CONFIG")
  # Data dirs (auth.json, sessions, cache) stay bound to the real ones; created if missing so
  # bwrap has a source path on a fresh account.
  for d in .local/share/opencode .local/state/opencode .cache/opencode; do
    mkdir -p "$HOME/$d"
    RW_BINDS+=("$HOME/$d")
  done
  EXTRA_SETENV+=(XDG_CONFIG_HOME "$OPENCODE_XDG_CONFIG")
fi

BWRAP_ARGS=(
  --ro-bind /usr /usr --ro-bind /bin /bin --ro-bind /lib64 /lib64 --ro-bind /lib /lib
  --ro-bind /sbin /sbin --ro-bind /etc /etc
  --bind "$PWD" "$PWD"
  --tmpfs /tmp
  --proc /proc --dev /dev --unshare-net --unshare-pid --unshare-ipc --unshare-uts
  --die-with-parent
)
# Own terminal session unless a human is actually at a terminal (Mode C): with a controlling
# tty shared with the parent shell, a sandboxed process can queue keystrokes into it with the
# TIOCSTI ioctl and have them run outside the sandbox after it exits. setsid() would break
# job control for an interactive REPL, so it's only applied when stdin isn't a tty.
[[ -t 0 ]] || BWRAP_ARGS+=(--new-session)

# Start from an empty environment; copy in only what a shell/CLI needs plus --env extras.
BWRAP_ARGS+=(--clearenv --setenv TMPDIR /tmp)
PASSTHROUGH_ENV=(PATH HOME USER LOGNAME SHELL TERM COLORTERM LANG LC_ALL LC_CTYPE LC_MESSAGES TZ
                 SSL_CERT_FILE SSL_CERT_DIR REQUESTS_CA_BUNDLE CURL_CA_BUNDLE NODE_EXTRA_CA_CERTS)
for name in "${PASSTHROUGH_ENV[@]}" "${PASS_ENV[@]:-}"; do
  [[ -n "$name" && -n "${!name+x}" ]] && BWRAP_ARGS+=(--setenv "$name" "${!name}")
done
for ((i = 0; i < ${#EXTRA_SETENV[@]}; i += 2)); do
  BWRAP_ARGS+=(--setenv "${EXTRA_SETENV[i]}" "${EXTRA_SETENV[i + 1]}")
done
# SSSD's NSS socket -- lets whoami/id/getent resolve UID->username on
# AD/LDAP-joined hosts. Doesn't affect actual permission enforcement (that's
# UID-number-based at the kernel level regardless), just name resolution.
# Bound automatically when present; harmlessly skipped otherwise.
if [[ -S /var/lib/sss/pipes/nss ]]; then
  BWRAP_ARGS+=(--ro-bind /var/lib/sss/pipes/nss /var/lib/sss/pipes/nss)
fi
for p in "${RO_BINDS[@]:-}"; do [[ -n "$p" ]] && BWRAP_ARGS+=(--ro-bind "$p" "$p"); done
for p in "${RO_TRY_BINDS[@]:-}"; do [[ -n "$p" ]] && BWRAP_ARGS+=(--ro-bind-try "$p" "$p"); done
for p in "${RW_BINDS[@]:-}"; do [[ -n "$p" ]] && BWRAP_ARGS+=(--bind "$p" "$p"); done
for p in "${RW_TRY_BINDS[@]:-}"; do [[ -n "$p" ]] && BWRAP_ARGS+=(--bind-try "$p" "$p"); done
[[ ${#LATE_BINDS[@]} -gt 0 ]] && BWRAP_ARGS+=("${LATE_BINDS[@]}")

# This wrapper, allowlist_proxy.py and relay.py run on the HOST (or are the trusted half of
# the sandbox). If the directory they live in falls inside a read-write bind -- which is the
# case whenever the script is run from its own checkout, e.g. `cd agentic-sandbox/scripts &&
# ./sandbox-run.sh` -- a prompt-injected agent could edit them and have the edit run
# unsandboxed on the NEXT invocation. Shadow the script directory read-only after all the
# read-write binds (later mounts win in bwrap), and say so once.
for root in "$PWD" "${RW_BINDS[@]:-}" "${RW_TRY_BINDS[@]:-}"; do
  [[ -n "$root" ]] || continue
  if [[ "$SCRIPT_DIR" == "$root" || "$SCRIPT_DIR" == "$root/"* ]]; then
    echo "sandbox-run.sh: note: $SCRIPT_DIR is inside a read-write bind ($root); re-binding it read-only. Prefer running from a separate work directory." >&2
    BWRAP_ARGS+=(--ro-bind "$SCRIPT_DIR" "$SCRIPT_DIR")
    break
  fi
done

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
wait_for_proxy_socket() {
  # $1 = socket path, $2 = proxy pid. Up to 10s; returns 1 if the proxy exits first.
  for _ in $(seq 1 100); do
    [[ -S "$1" ]] && return 0
    if ! kill -0 "$2" 2>/dev/null; then
      echo "sandbox-run.sh: allowlist proxy exited before creating $1 -- see ${1}.log" >&2
      return 1
    fi
    sleep 0.1
  done
  echo "sandbox-run.sh: allowlist proxy did not create $1 within 10s -- see ${1}.log" >&2
  return 1
}
cleanup() {
  [[ -n "$PROXY_PID" ]] && kill "$PROXY_PID" 2>/dev/null || true
  [[ -n "$PROXY_SOCK" && -e "$PROXY_SOCK" ]] && rm -f "$PROXY_SOCK"
  [[ -n "$EMPTY_MASK_FILE" && -e "$EMPTY_MASK_FILE" ]] && rm -f "$EMPTY_MASK_FILE"
  # The per-job config copies include ~/.claude.json (account details) -- never leave them.
  [[ -n "$SANDBOX_CFG_ROOT" && -d "$SANDBOX_CFG_ROOT" ]] && rm -rf "$SANDBOX_CFG_ROOT"
  true
}
trap cleanup EXIT

RELAY_PORT=$((20000 + RANDOM % 20000))

if [[ ${#ALLOW_HOSTS[@]} -gt 0 ]]; then
  PROXY_SOCK="$(mktemp -u /tmp/sandbox-proxy.XXXXXX.sock)"
  python3 "$SCRIPT_DIR/allowlist_proxy.py" "$PROXY_SOCK" "${ALLOW_HOSTS[@]}" \
    > "${PROXY_SOCK}.log" 2>&1 &
  PROXY_PID=$!
  # Wait for the socket to actually exist before bind-mounting it, and fail closed if the
  # proxy died (bad allowlist, python missing). A fixed `sleep 1` raced a slow interpreter
  # start on a busy node, and bwrap then failed with "Can't find source path".
  wait_for_proxy_socket "$PROXY_SOCK" "$PROXY_PID" || exit 1
  BWRAP_ARGS+=(
    --ro-bind "$SCRIPT_DIR/relay.py" /opt/sandbox-relay.py
    --ro-bind "$PROXY_SOCK" /run/sandbox-proxy.sock
  )
  INNER_CMD=(
    /bin/bash -c
    'python3 /opt/sandbox-relay.py 127.0.0.1 '"$RELAY_PORT"' /run/sandbox-proxy.sock & sleep 1; export http_proxy=http://127.0.0.1:'"$RELAY_PORT"' https_proxy=http://127.0.0.1:'"$RELAY_PORT"' HTTP_PROXY=http://127.0.0.1:'"$RELAY_PORT"' HTTPS_PROXY=http://127.0.0.1:'"$RELAY_PORT"' no_proxy=127.0.0.1,localhost NO_PROXY=127.0.0.1,localhost; exec "$@"'
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
  # Not exec'd either (was `exec bwrap` before): the EXIT trap must run to delete the per-job
  # config copies and the empty mask file. Exit code is propagated.
  bwrap "${BWRAP_ARGS[@]}" -- "${CMD[@]}"
  exit $?
fi
