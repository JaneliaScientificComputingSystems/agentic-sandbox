#!/bin/bash
# csub-policy.sh -- write the csub broker policy (~/.config/csub/broker.toml) for the wrappers.
#
# csub ships a sample policy, deploy/broker.janelia.toml, that has to be edited before use: the
# sandbox kind, where these scripts are, which directories and hosts jobs may use, and the
# limits. This script makes those edits. It starts from the sample in your csub checkout each
# time, so the queue and price tables are always csub's current ones.
#
#   csub-policy.sh --bwrap|--podman --rw DIR [--rw DIR]... [--ro DIR]... [--allow HOST]...
#                  [--gpus N] [--slots N] [--walltime MIN] [--cost USD] [--pending N]
#                  [--csub DIR] [--out FILE] [--replace]
#
#   --bwrap | --podman  how jobs submitted through csub are sandboxed: sandbox-run.sh or
#                       podman-run.sh (podman needs the one-time setup in SETUP.md section 3)
#   --rw DIR            a directory jobs may mount read-write, normally the project directory
#   --ro DIR            a directory jobs may mount, read-only at most (a venv, a dataset)
#   --allow HOST        a network host jobs may reach; none unless given
#   --gpus N            GPUs one job may ask for
#   --slots N           CPU slots one job may ask for
#   --walltime MIN      longest job, in minutes
#   --cost USD          highest estimated cost of one job
#   --pending N         pending jobs per session before submit is refused
#                       (the five limits stay as in csub's sample unless given)
#   --csub DIR          the csub checkout (default ~/csub)
#   --out FILE          where to write the policy (default ~/.config/csub/broker.toml)
#   --replace           overwrite an existing policy
#
# The options --rw, --ro and --allow mean the same as on sandbox-run.sh and podman-run.sh. A job
# submitted from inside a sandbox must pass two checks, this policy and the limits of the sandbox
# it was submitted from, so a directory or host has to be given in both places.
#
# The policy is written whole from the options. To change it later, run the script again with
# the full set of options and --replace; hand edits to the file are lost then.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
die() { echo "csub-policy.sh: $*" >&2; exit 1; }

KIND="" CSUB_DIR="$HOME/csub" OUT="$HOME/.config/csub/broker.toml" REPLACE=0
GPUS="" SLOTS="" WALLTIME="" COST="" PENDING=""
RW=() RO=() HOSTS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bwrap) KIND=bwrap; shift ;;
    --podman) KIND=podman; shift ;;
    --replace) REPLACE=1; shift ;;
    --rw|--ro|--allow|--gpus|--slots|--walltime|--cost|--pending|--csub|--out)
      [[ $# -ge 2 ]] || die "$1 needs an argument"
      case "$1" in
        --rw) RW+=("$2") ;;
        --ro) RO+=("$2") ;;
        --allow) HOSTS+=("$2") ;;
        --gpus) GPUS="$2" ;;
        --slots) SLOTS="$2" ;;
        --walltime) WALLTIME="$2" ;;
        --cost) COST="$2" ;;
        --pending) PENDING="$2" ;;
        --csub) CSUB_DIR="$2" ;;
        --out) OUT="$2" ;;
      esac
      shift 2 ;;
    -h|--help) sed -n '2,/^set -uo/{/^set -uo/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

[[ -n "$KIND" ]] || die "give --bwrap or --podman"
[[ ${#RW[@]} -gt 0 ]] || die "give at least one --rw DIR (the project directory)"
for n in $GPUS $SLOTS $WALLTIME $PENDING; do
  [[ "$n" =~ ^[0-9]+$ ]] || die "not a whole number: $n"
done
[[ -z "$COST" || "$COST" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "not a number: $COST"

# A path goes into a TOML string and into a sed replacement: keep both simple.
for d in "${RW[@]}" ${RO[@]+"${RO[@]}"}; do
  [[ "$d" == /* ]] || die "not an absolute path: $d"
  [[ "$d" =~ ^[A-Za-z0-9_./+@-]+$ ]] || die "unsupported character in path: $d"
  [[ -d "$d" ]] || die "no such directory: $d"
  # csub refuses jobs that mount the home directory, and its policy rejects /scratch.
  [[ "$HOME" != "$d" && "$HOME" != "$d"/* ]] || die "$d is or contains your home directory; give a project directory"
  [[ "$d" != /scratch && "$d" != /scratch/* ]] || die "/scratch cannot be a job directory: $d"
done
for h in ${HOSTS[@]+"${HOSTS[@]}"}; do
  [[ "$h" =~ ^[a-z0-9.*-]+$ ]] || die "not a hostname (lower case, digits, dots, dashes, *): $h"
done

SAMPLE="$CSUB_DIR/deploy/broker.janelia.toml"
[[ -f "$SAMPLE" ]] || die "csub's sample policy not found: $SAMPLE (clone csub first, or give --csub DIR)"
[[ -x "$SCRIPT_DIR/sandbox-run.sh" ]] || die "sandbox-run.sh not found next to this script"
[[ ! -e "$OUT" || $REPLACE -eq 1 ]] || die "$OUT exists; add --replace to overwrite it"

# csub expands a leading ~/ itself, which keeps the file free of the account name.
SCRIPTS="$SCRIPT_DIR"
[[ "$SCRIPTS" == "$HOME"/* ]] && SCRIPTS="~/${SCRIPTS#"$HOME"/}"

toml_list() {  # "a" "b" -> ["a", "b"]
  local out="" x
  for x in "$@"; do out+="${out:+, }\"$x\""; done
  echo "[$out]"
}
ROOTS=$(toml_list "${RW[@]}" ${RO[@]+"${RO[@]}"})
READONLY=$(toml_list ${RO[@]+"${RO[@]}"})
ALLOWED=$(toml_list ${HOSTS[@]+"${HOSTS[@]}"})

mkdir -p "$(dirname "$OUT")" || die "cannot create $(dirname "$OUT")"
TMP=$(mktemp "$OUT.XXXXXX") || die "cannot write next to $OUT"
trap 'rm -f "$TMP"' EXIT
chmod 600 "$TMP"

sed -e "s|^sandbox = .*|sandbox = \"$KIND\"|" \
    -e "s|^sandbox_scripts_dir = .*|sandbox_scripts_dir = \"$SCRIPTS\"|" \
    -e "s|^allowed_roots = .*|allowed_roots = $ROOTS|" \
    -e "s|^readonly_roots = .*|readonly_roots = $READONLY|" \
    -e "/^allowed_hosts = \[/,/^\]/c allowed_hosts = $ALLOWED" \
    -e '/^project = "CHANGEME"/d' \
    "$SAMPLE" > "$TMP" || die "could not edit $SAMPLE"

# Limits: only the ones given change; the rest stay as in the sample.
limit() {  # limit KEY -> the value now in the [limits] table
  sed -n "/^\[limits\]/,/^\[queues/s/^$1 = \([0-9.]*\).*/\1/p" "$TMP" | head -1
}
set_limit() {  # set_limit KEY VALUE
  sed -i "/^\[limits\]/,/^\[queues/s|^$1 = [0-9.]*|$1 = $2|" "$TMP" || die "could not edit the policy"
  [[ "$(limit "$1")" == "$2" ]] || die "csub's sample policy has changed: could not set '$1'. Nothing written."
}
[[ -z "$GPUS" ]] || set_limit max_gpus "$GPUS"
[[ -z "$SLOTS" ]] || set_limit max_slots "$SLOTS"
[[ -z "$WALLTIME" ]] || set_limit max_walltime_min "$WALLTIME"
[[ -z "$COST" ]] || set_limit max_estimated_cost_usd "$COST"
[[ -z "$PENDING" ]] || set_limit max_pending_per_session "$PENDING"
GPUS=$(limit max_gpus) SLOTS=$(limit max_slots) WALLTIME=$(limit max_walltime_min)
COST=$(limit max_estimated_cost_usd) PENDING=$(limit max_pending_per_session)
for n in "$GPUS" "$SLOTS" "$WALLTIME" "$COST" "$PENDING"; do
  [[ -n "$n" ]] || die "csub's sample policy has changed: a limit is missing. Nothing written."
done
# Both general GPU queues count 8 slots per GPU.
(( GPUS * 8 <= SLOTS )) || echo "csub-policy.sh: warning: $GPUS GPUs need $(( GPUS * 8 )) slots on the 8-slots-per-GPU queues; the slot limit is $SLOTS" >&2

# The edits match lines of csub's sample. If csub changes its layout, stop instead of writing
# a policy that silently kept a sample value.
for want in "sandbox = \"$KIND\"" "sandbox_scripts_dir = \"$SCRIPTS\"" "allowed_roots = $ROOTS" \
            "readonly_roots = $READONLY" "allowed_hosts = $ALLOWED"; do
  grep -qF -- "$want" "$TMP" || die "csub's sample policy has changed: could not set '$want'. Nothing written."
done
grep -q CHANGEME "$TMP" && die "csub's sample policy has changed: a CHANGEME value is left. Nothing written."

# Let csub itself check the result, when it is installed.
BROKER=$(command -v csub-broker 2>/dev/null || true)
[[ -n "$BROKER" || ! -x "$HOME/.venvs/csub/bin/csub-broker" ]] || BROKER="$HOME/.venvs/csub/bin/csub-broker"
CHECKED="not checked: csub-broker is not installed yet"
if [[ -n "$BROKER" ]]; then
  REPLY_JSON=$(echo '{"protocol":1,"op":"probe"}' | "$BROKER" --policy "$TMP" 2>&1)
  [[ "$REPLY_JSON" == *'"broker_version"'* ]] || die "csub refuses the policy, nothing written:
$REPLY_JSON"
  CHECKED="csub loads it"
fi

mv -f "$TMP" "$OUT" || die "cannot write $OUT"
trap - EXIT

echo "Wrote $OUT ($CHECKED)"
echo "  sandbox for jobs:  $KIND"
echo "  read-write:        ${RW[*]}"
echo "  read-only:         ${RO[*]:-none}"
echo "  network hosts:     ${HOSTS[*]:-none}"
echo "  limits per job:    $SLOTS slots, $GPUS GPU(s), $WALLTIME minutes, \$$COST estimated cost"
echo "  pending jobs:      $PENDING per session"
