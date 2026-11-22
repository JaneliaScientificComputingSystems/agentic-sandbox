#!/bin/bash
# ssh-entry.sh -- forced command for an ssh key used by an agent that runs OFF the cluster.
#
# An agent on a laptop that reaches the cluster with plain ssh acts as the user on a login
# node: no sandbox, and work on a node where none is allowed. Give the agent its own key and
# pin that key to this script in ~/.ssh/authorized_keys:
#
#   command="/path/to/agentic-sandbox/scripts/ssh-entry.sh --project /groups/lab/proj",no-port-forwarding,no-agent-forwarding,no-X11-forwarding ssh-ed25519 AAAA... agent
#
# Whatever the agent then sends (`ssh janelia-agent '<command>'`) never runs on the login node. This
# script submits it as an interactive LSF job (`bsub -I`) whose command is sandbox-run.sh
# started in the project directory, and relays stdin, stdout, stderr and the exit status. The
# only things that run on the login node are this script and bsub.
#
#   ssh-entry.sh --project DIR [--podman] [--queue Q] [--slots N] [--gpus N] [--walltime MIN]
#                [--csub-policy FILE] [-- wrapper options]
#
# The sandbox is bwrap (sandbox-run.sh) unless --podman is given, which runs the command in a
# container image through podman-run.sh instead, with the project directory bound read-write
# at the same path. Use --podman only when the work needs an image; it needs the one-time
# podman setup in SETUP.md and a /etc/subuid range for the account.
#
# Options after `--` go to the wrapper unchanged (--csub, --allow HOST, --ro DIR, and for podman
# --image NAME, ...).
# --gpus N asks for N GPUs for every command (bsub -gpu "num=N") and gives the wrapper --gpu; it
# needs a GPU queue with --queue and enough --slots for that queue. Every command then holds
# those GPUs while it runs, so for most work leave it out and let the agent submit GPU jobs
# with csub.
# --csub-policy FILE makes the csub broker of this key line read FILE as its policy, and gives
# the wrapper --csub. Without it the broker reads ~/.config/csub/broker.toml, the same for every
# key. Use it to give two projects different limits. FILE must be outside the project, which
# the agent can write.
# With no command (a plain `ssh janelia-agent`), the job is an interactive shell in the sandbox.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
die() { echo "ssh-entry.sh: $*" >&2; exit 1; }

PROJECT="" QUEUE="" SLOTS=1 WALLTIME=240 INNER=0 PODMAN=0 GPUS=0 POLICY=""
SANDBOX_OPTS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project|--queue|--slots|--walltime|--gpus|--csub-policy)
      [[ $# -ge 2 ]] || die "$1 needs an argument"
      case "$1" in
        --project) PROJECT="$2" ;;
        --queue) QUEUE="$2" ;;
        --slots) SLOTS="$2" ;;
        --gpus) GPUS="$2" ;;
        --walltime) WALLTIME="$2" ;;
        --csub-policy) POLICY="$2" ;;
      esac
      shift 2 ;;
    --inner) INNER=1; shift ;;
    --podman) PODMAN=1; shift ;;
    --) shift; SANDBOX_OPTS=("$@"); break ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ -n "$PROJECT" ]] || die "--project DIR is required"
[[ "$SLOTS" =~ ^[0-9]+$ && "$WALLTIME" =~ ^[0-9]+$ && "$GPUS" =~ ^[0-9]+$ ]] || die "--slots, --gpus and --walltime take whole numbers"
if [[ $GPUS -gt 0 && " ${SANDBOX_OPTS[*]:-} " != *" --gpu "* ]]; then SANDBOX_OPTS+=(--gpu); fi
if [[ -n "$POLICY" && " ${SANDBOX_OPTS[*]:-} " != *" --csub "* ]]; then SANDBOX_OPTS+=(--csub); fi
[[ -z "$QUEUE" || "$QUEUE" =~ ^[A-Za-z0-9_]+$ ]] || die "--queue $QUEUE: not a queue name"

if [[ $INNER -eq 1 ]]; then
  # On the compute node, inside the job. The agent's command arrives in the environment (LSF
  # copies the submission environment), never through bsub's command line, so it is not
  # re-parsed by any shell on the way.
  cd "$PROJECT" || die "cannot enter $PROJECT on $(hostname)"
  CMD="${AGENT_SSH_COMMAND:-}"
  # BSUB_QUIET was for the login-node bsub only: left set, it silences the "Job <n> is submitted"
  # line that csub's broker reads the job id from.
  unset AGENT_SSH_COMMAND BSUB_QUIET LSF_INTERACTIVE_STDERR
  if [[ -n "$POLICY" ]]; then
    # The wrapper starts the broker from this command, and reads the state directory from the
    # file named after --policy.
    BROKER="${CSUB_BROKER_CMD:-$(command -v csub-broker || true)}"
    [[ -n "$BROKER" ]] || die "--csub-policy needs csub-broker on PATH on $(hostname)"
    export CSUB_BROKER_CMD="$BROKER --policy $POLICY"
  fi
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
PROJECT="$(cd -- "$PROJECT" && pwd -P)" || die "cannot enter the project directory"
# The project is the one directory the agent gets read-write. Under $HOME it could be ~/.ssh or
# the directory of a harness's settings; the wrappers refuse $HOME itself but not what is in it.
HOME_P="$(cd "$HOME" 2>/dev/null && pwd -P)" || HOME_P="$HOME"
if [[ "$PROJECT" == "$HOME_P" || "$PROJECT" == "${HOME_P%/}/"* || "$HOME_P" == "${PROJECT%/}/"* ]]; then
  die "project directory $PROJECT is your home directory, or inside it, or above it; use a directory outside \$HOME"
fi
if [[ -n "$POLICY" ]]; then
  [[ "$POLICY" == /* && -f "$POLICY" && -r "$POLICY" ]] || die "--csub-policy $POLICY: not a readable file with an absolute path"
  POLICY="$(cd -- "$(dirname -- "$POLICY")" && pwd -P)/$(basename -- "$POLICY")" || die "cannot resolve --csub-policy"
  [[ "$POLICY" =~ ^[A-Za-z0-9_./@+,-]+$ ]] || die "--csub-policy $POLICY: the path may hold letters, digits and _ . / @ + , - only"
  [[ ! -L "$POLICY" && "$POLICY" != "${PROJECT%/}/"* ]] || die "--csub-policy $POLICY: the policy must not be a symbolic link or inside the project, which the agent can write"
fi
if ! command -v bsub >/dev/null 2>&1; then
  # A forced command gets a non-login shell; pick up LSF if the startup files did not.
  [[ -r /etc/profile.d/profile.lsf.sh ]] && . /etc/profile.d/profile.lsf.sh
  command -v bsub >/dev/null 2>&1 || die "bsub not found"
fi

export AGENT_SSH_COMMAND="${SSH_ORIGINAL_COMMAND:-}"
export BSUB_QUIET=1   # no "Job <n> is submitted" / "<<Waiting for dispatch>>" lines in the agent's output
BSUB=(bsub -n "$SLOTS" -W "$WALLTIME" -J agent-ssh)
[[ -n "$QUEUE" ]] && BSUB+=(-q "$QUEUE")
[[ $GPUS -gt 0 ]] && BSUB+=(-gpu "num=$GPUS")
# A pty only for an interactive login with a terminal; commands get plain pipes.
if [[ -z "$AGENT_SSH_COMMAND" && -t 0 ]]; then
  BSUB+=(-Is)
else
  BSUB+=(-I)
  # Without this, LSF sends an interactive job's stderr back on stdout. Everything the wrapper or
  # the command writes to stderr (podman's "Trying to pull ...", a warning) then lands in the
  # command's output, and in a file transfer it corrupts the stream: scp and sftp under --podman
  # failed with "Received message too long". With it, stdout and stderr come back separately.
  export LSF_INTERACTIVE_STDERR=y
fi

INNER_ARGV=("$SCRIPT_DIR/ssh-entry.sh" --inner --project "$PROJECT")
[[ $PODMAN -eq 1 ]] && INNER_ARGV+=(--podman)
[[ -n "$POLICY" ]] && INNER_ARGV+=(--csub-policy "$POLICY")
INNER_ARGV+=(-- "${SANDBOX_OPTS[@]}")
# bsub joins its arguments into one string for a shell on the execution host: quote each.
exec "${BSUB[@]}" "$(printf '%q ' "${INNER_ARGV[@]}")"
