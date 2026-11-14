#!/bin/bash
# ssh-entry.sh -- forced command for an ssh key used by an agent that runs OFF the cluster.
#
# An agent on a laptop that reaches the cluster with plain ssh acts as the user on a login
# node: no sandbox, and work on a node where none is allowed. Give the agent its own key and
# pin that key to this script in ~/.ssh/authorized_keys:
#
#   command="/path/to/agentic-sandbox/scripts/ssh-entry.sh --project /groups/lab/proj",no-port-forwarding,no-agent-forwarding,no-X11-forwarding ssh-ed25519 AAAA... agent
#
# Whatever the agent then sends (`ssh cluster '<command>'`) never runs on the login node. This
# script submits it as an interactive LSF job (`bsub -I`) whose command is sandbox-run.sh
# started in the project directory, and relays stdin, stdout, stderr and the exit status. The
# only things that run on the login node are this script and bsub.
#
#   ssh-entry.sh --project DIR [--podman] [--queue Q] [--slots N] [--walltime MIN] [-- wrapper options]
#
# The sandbox is bwrap (sandbox-run.sh) unless --podman is given, which runs the command in a
# container image through podman-run.sh instead, with the project directory bound read-write
# at the same path. Use --podman only when the work needs an image; it needs the one-time
# podman setup in SETUP.md and a /etc/subuid range for the account.
#
# Options after `--` go to the wrapper unchanged (--csub, --allow HOST, --ro DIR, --gpu, and
# for podman --image NAME, ...). For GPU work pick a GPU queue with --queue.
# With no command (a plain `ssh cluster`), the job is an interactive shell in the sandbox.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
die() { echo "ssh-entry.sh: $*" >&2; exit 1; }

PROJECT="" QUEUE="" SLOTS=1 WALLTIME=240 INNER=0 PODMAN=0
SANDBOX_OPTS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project|--queue|--slots|--walltime)
      [[ $# -ge 2 ]] || die "$1 needs an argument"
      case "$1" in
        --project) PROJECT="$2" ;;
        --queue) QUEUE="$2" ;;
        --slots) SLOTS="$2" ;;
        --walltime) WALLTIME="$2" ;;
      esac
      shift 2 ;;
    --inner) INNER=1; shift ;;
    --podman) PODMAN=1; shift ;;
    --) shift; SANDBOX_OPTS=("$@"); break ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ -n "$PROJECT" ]] || die "--project DIR is required"
[[ "$SLOTS" =~ ^[0-9]+$ && "$WALLTIME" =~ ^[0-9]+$ ]] || die "--slots and --walltime take whole numbers"
[[ -z "$QUEUE" || "$QUEUE" =~ ^[A-Za-z0-9_]+$ ]] || die "--queue $QUEUE: not a queue name"

if [[ $INNER -eq 1 ]]; then
  # On the compute node, inside the job. The agent's command arrives in the environment (LSF
  # copies the submission environment), never through bsub's command line, so it is not
  # re-parsed by any shell on the way.
  cd "$PROJECT" || die "cannot enter $PROJECT on $(hostname)"
  CMD="${AGENT_SSH_COMMAND:-}"
  # BSUB_QUIET was for the login-node bsub only: left set, it silences the "Job <n> is submitted"
  # line that csub's broker reads the job id from.
  unset AGENT_SSH_COMMAND BSUB_QUIET
  if [[ $PODMAN -eq 1 ]]; then
    # podman-run.sh binds nothing by default and starts in the image's own directory: bind
    # the project and enter it before running the command.
    if [[ -n "$CMD" ]]; then
      exec "$SCRIPT_DIR/podman-run.sh" --rw "$PROJECT" "${SANDBOX_OPTS[@]}" -- \
        bash -c 'cd "$0" && exec bash -c "$1"' "$PROJECT" "$CMD"
    else
      exec "$SCRIPT_DIR/podman-run.sh" --rw "$PROJECT" "${SANDBOX_OPTS[@]}" -- \
        bash -c 'cd "$0" && exec bash' "$PROJECT"
    fi
  fi
  if [[ -n "$CMD" ]]; then
    exec "$SCRIPT_DIR/sandbox-run.sh" "${SANDBOX_OPTS[@]}" -- bash -c "$CMD"
  else
    exec "$SCRIPT_DIR/sandbox-run.sh" "${SANDBOX_OPTS[@]}" -- bash
  fi
fi

# On the login node: submit, and nothing else.
[[ -d "$PROJECT" ]] || die "project directory $PROJECT does not exist"
PROJECT="$(cd "$PROJECT" && pwd -P)"
if ! command -v bsub >/dev/null 2>&1; then
  # A forced command gets a non-login shell; pick up LSF if the startup files did not.
  [[ -r /etc/profile.d/profile.lsf.sh ]] && . /etc/profile.d/profile.lsf.sh
  command -v bsub >/dev/null 2>&1 || die "bsub not found"
fi

export AGENT_SSH_COMMAND="${SSH_ORIGINAL_COMMAND:-}"
export BSUB_QUIET=1   # no "Job <n> is submitted" / "<<Waiting for dispatch>>" lines in the agent's output
BSUB=(bsub -n "$SLOTS" -W "$WALLTIME" -J agent-ssh)
[[ -n "$QUEUE" ]] && BSUB+=(-q "$QUEUE")
# A pty only for an interactive login with a terminal; commands get plain pipes.
if [[ -z "$AGENT_SSH_COMMAND" && -t 0 ]]; then BSUB+=(-Is); else BSUB+=(-I); fi

INNER_ARGV=("$SCRIPT_DIR/ssh-entry.sh" --inner --project "$PROJECT")
[[ $PODMAN -eq 1 ]] && INNER_ARGV+=(--podman)
INNER_ARGV+=(-- "${SANDBOX_OPTS[@]}")
# bsub joins its arguments into one string for a shell on the execution host: quote each.
exec "${BSUB[@]}" "$(printf '%q ' "${INNER_ARGV[@]}")"
