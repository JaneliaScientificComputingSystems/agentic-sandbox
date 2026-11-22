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
#   --csub                Let the sandboxed agent submit LSF jobs through csub
#                         (https://github.com/saalfeldlab/csub): starts `csub-broker --serve`
#                         OUTSIDE the sandbox, binds its Unix socket in at /run/csub.sock, binds
#                         the csub client in read-only, and sets CSUB_TRANSPORT/CSUB_SOCKET/
#                         CSUB_MOUNTS inside. The agent never holds bsub; the broker applies
#                         the user's ~/.config/csub/broker.toml policy and the child jobs run
#                         sandboxed again via these wrappers. Needs csub-broker on PATH (or
#                         $CSUB_BROKER_CMD). See "csub" below.
#   --gpu                 Expose the LSF-allocated GPU(s) inside the sandbox: each entry of
#                         $CUDA_VISIBLE_DEVICES is mapped (nvidia-smi -> PCI bus id -> driver
#                         minor) to its /dev/nvidiaN node, which is bound in together with
#                         /dev/nvidiactl, /dev/nvidia-uvm and /dev/nvidia-uvm-tools. Only the
#                         job's own GPUs get a device node. CUDA_VISIBLE_DEVICES is set to their
#                         numbering inside (0..n-1, same order), CUDA_DEVICE_ORDER to PCI_BUS_ID.
#                         An error if no GPU is allocated. Driver libraries come from the
#                         read-only /usr and /lib64 binds, and the PCI identity NVML needs from
#                         read-only /sys/{devices,module}; needs nvidia-smi on the host.
#   --scratch             Shorthand for --rw /scratch/$USER/work (created if missing).
#                         Deliberately NOT all of /scratch/$USER -- see "Per-job state" below.
#   --job-nodes           For one worker of a multi-node LSF job (started once per node, e.g. by
#                         blaunch): a private network that reaches the OTHER NODES OF THIS JOB
#                         and nothing else -- no other host, no internet, no DNS. The node list
#                         comes from LSF ($LSB_MCPU_HOSTS). Needs pasta (the passt package) on
#                         the node. Not with --allow, --csub, --claude or --opencode. See
#                         "Multi-node jobs" below.
#   --peers HOST[,HOST]   Like --job-nodes, with the nodes named explicitly (outside LSF, tests).
#                         Inside an LSF job every name must be a node of that job.
#   --listen PORT         With --job-nodes: also accept connections from the job's nodes on PORT
#                         (repeatable). For a port the launcher picked on the node, such as
#                         torchrun's master port. Ports the sandboxed program opens itself need
#                         no flag -- see "Multi-node jobs".
#   --host-net            For one worker of a multi-node LSF job on a queue WITHOUT InfiniBand:
#                         the node's own network, unrestricted. Files, credentials, environment
#                         and processes are sandboxed as always; the network is not. Use it only
#                         where --job-nodes is too slow, which is when the data itself travels
#                         over TCP (NCCL on Ethernet). Not with --job-nodes, --allow, --csub,
#                         --claude or --opencode. See "Multi-node jobs" below.
#   --ib                  Expose the node's InfiniBand (RDMA verbs) devices: /dev/infiniband and,
#                         read-only, the sysfs entries NCCL and libibverbs read. Verbs traffic
#                         does not pass through the sandbox's network, so this opens the
#                         InfiniBand fabric to the sandboxed process whatever else is closed.
#   --claude               Run Claude Code with a per-job config directory: a throwaway
#                          copy of ~/.claude.json, ~/.claude/settings.json and
#                          ~/.claude/CLAUDE.md, with only ~/.claude/.credentials.json bound
#                          through to the real file (CLAUDE_CONFIG_DIR points at it). See
#                          "Config isolation" below.
#   --claude-history[-rw]  With --claude: make this project's past Claude sessions visible
#                          (~/.claude/projects/<cwd>) so `claude --resume` works. Read-only;
#                          -rw also lets new transcripts persist, at the cost of letting the
#                          agent edit old ones. Only the current directory's history is bound.
#   --opencode             Same idea for opencode: a throwaway copy of ~/.config/opencode
#                          (OPENCODE_CONFIG/OPENCODE_CONFIG_DIR point at it; XDG_CONFIG_HOME is
#                          left alone, so git/gh config still resolve) plus RW binds on its data dirs
#                          (~/.local/share/opencode, ~/.local/state/opencode, ~/.cache/opencode)
#   --dry-run             Do every check, start no sandbox, proxy or broker, and print the bwrap
#                          command, the host-side helpers and the environment a real run
#                          would use.
#   --no-protect          Leave the files that tools run later writable (.git/hooks,
#                          .git/config, .mcp.json, .claude/, .vscode and the like). By default
#                          they are read-only where they exist in a read-write directory, and
#                          ones the command creates are reported at exit. See "Files that run
#                          later" in the README.
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
# terminal (Mode A/B, plain bsub) the sandbox also gets its own session (--new-session).
#
# Multi-node jobs (--job-nodes, --ib): one sandbox per node, started by the job's launcher, which
# stays outside. torchrun, NCCL and Ray need TCP between the job's nodes, which the default empty
# network forbids. With --job-nodes the wrapper starts itself again under pasta, a user-space
# network relay: pasta gives a new network namespace the node's own address, and connects it to
# the node's network through ordinary sockets. Inside that namespace, before the sandbox starts,
# every route is removed and one host route is added per other node of the job, so a connection
# to anything else is refused at once ("connection refused"). The sandbox then runs in a nested
# user namespace, which holds no capability over the network namespace: the sandboxed process
# cannot add a route. /etc/hosts inside lists the job's nodes (there is no DNS).
#   Ports: connections FROM the job's other nodes are accepted on a block of 2000 ports and on
#   each --listen PORT. The block is 13000-14999 on a node whose own range for outgoing
#   connections starts at 15000; each further sandbox of this kind on the node takes the next
#   block down, to 5000, so five fit. $SANDBOX_README inside names the block. A listener that lets
#   the system pick its port (bind to port 0: torchrun workers, NCCL, most of Ray) gets one
#   from the top 1500 of the block, so it is reachable without any flag. A program that wants
#   fixed ports must take them from the lower 500 (Ray: its node manager, object manager, agent
#   and worker ports). A port in use on the node is skipped.
#   Speed: only connections set up through TCP cross the relay. With --ib, NCCL's data goes
#   over RDMA verbs directly (measured: no difference to an unsandboxed job on H200 nodes).
#   Without InfiniBand the data itself crosses the relay, which is slower.
#   Nothing is filtered on the node itself (no nftables); the limit is the routing table of a
#   namespace the sandboxed process cannot change.
#   --host-net is the fallback for queues without InfiniBand. There NCCL sends its data over
#   TCP, through the relay, and a bandwidth test on two L4 nodes ran about 40 times slower
#   (0.15 GB/s against 6 GB/s). --host-net leaves the network namespace alone instead: full
#   speed, on the node's own network, unrestricted. Files, credentials, environment and
#   processes are sandboxed as always.
#
# Config isolation (--claude/--opencode): the harness's *configuration* is where a
# prompt-injected agent can persist: ~/.claude/settings.json hooks and ~/.claude.json MCP
# server entries are shell commands Claude Code runs -- unsandboxed, as you -- in your next
# session (and settings hot-reload into an already-running one); opencode.json accepts
# plugins/MCP the same way. So those files are never bound read-write. Each run gets a fresh
# cfg/ directory inside its per-job state dir (below) seeded with COPIES, deleted on exit;
# edits made inside die with the job. The one file that is shared is the credentials file, so
# an existing login is reused and token refreshes persist. Not carried in: ~/.claude/plugins,
# skills, projects/ history -- pass --ro/--rw explicitly if a task needs them.
#
# Per-job state: everything this wrapper creates for one run lives in ONE directory,
# /scratch/$USER/.agentic-sandbox/<LSB_JOBID>[-<LSB_JOBINDEX>]-<pid>/ (mode 700): cfg/ (the
# copies above), proxy/ (the allowlist proxy's Unix socket + log), and the empty file used to
# mask credential files. Nothing is ever written to /tmp. /scratch/$USER is node-local, which
# is where a Unix socket belongs, and is swept by an hourly cleanup cron, which turns a crashed
# job's leftovers into a non-problem. Two consequences:
#   - --scratch binds /scratch/$USER/work, not /scratch/$USER: binding the whole tree would
#     expose every concurrent job's state dir (same uid, so permissions don't help) -- a
#     sibling's proxy socket, which has a DIFFERENT allowlist, and its config copies. As
#     belt and braces, if any --rw/--ro root does contain .agentic-sandbox/, an empty tmpfs
#     is mounted over it after all other binds, and only this job's own cfg/ is bound back.
#     Never bind /scratch/$USER itself; use --rw /scratch/$USER/<subdir> for anything else.
#   - the hourly scratch cleanup (/misc/local/admin/lsf_clean_scratch.py) is not age-based:
#     it wipes /scratch/<user> only on nodes where that user has NO running LSF job, so a
#     job's state is safe for the job's whole lifetime and gone within an hour after.
#
# csub (--csub): the same bridge as --allow, for job submission instead of HTTP egress. The
# broker is csub's own (`csub-broker --serve <socket>`), started by this wrapper outside the
# sandbox and killed with it; only its socket crosses the boundary. Inside: CSUB_TRANSPORT=unix,
# CSUB_SOCKET=/run/csub.sock, PYTHONPATH pointing at a read-only bind of the csub package alone
# (/run/csub-lib, so the system python3 can `import csub`), a `csub` shim on PATH, and
# CSUB_MOUNTS listing this sandbox's mounts as csub expects them ("path:rw,path:ro"), derived
# from $PWD and the --rw/--ro paths that are not under $HOME or /scratch (csub refuses home, and
# its policy forbids scratch as a root); a preset $CSUB_MOUNTS may only narrow that list. Which
# of those csub then accepts is the broker policy's business, reported per request. The same
# mounts and the --allow hosts bound every request as the broker's envelope (csub #13): a child
# job cannot claim what this sandbox cannot see. Without anything to put in the envelope, or
# with a csub that lacks it, the wrapper refuses to start; CSUB_ENVELOPE=off overrides that.
#
# Examples:
#   sandbox-run.sh --scratch --opencode --allow litellm.int.janelia.org -- \
#     opencode run "..." --model litellm/kimi-k3
#
#   sandbox-run.sh --scratch --claude \
#     --allow api.anthropic.com --allow claude.ai --allow platform.claude.com -- \
#     claude
set -euo pipefail
# The environment as it was handed to this script, for --env: looked up later, a name such as CMD
# or p would give this script's own variable of that name.
declare -A ENV_AT_START=()
while IFS= read -r _n; do [[ "$_n" == ENV_AT_START ]] || ENV_AT_START[$_n]="${!_n-}"; done < <(compgen -e)
unset _n

# Python that this script starts on the host (the csub broker, its lookup) must never import from
# a directory the sandboxed process can write. An empty or relative PYTHONPATH entry means "the
# working directory", so those are dropped here, once, for everything started below.
if [[ -n "${PYTHONPATH+x}" ]]; then
  _pp=""
  IFS=: read -ra _ppe <<< "$PYTHONPATH"
  for _e in ${_ppe[@]+"${_ppe[@]}"}; do [[ "$_e" == /* ]] && _pp="${_pp:+$_pp:}$_e"; done
  if [[ -n "$_pp" ]]; then export PYTHONPATH="$_pp"; else unset PYTHONPATH; fi
  unset _pp _ppe _e
fi

# Physical paths throughout: the script's own directory (so running it through a symlink still
# finds allowlist_proxy.py and relay.py next to it, and the read-only re-bind below shadows the
# real directory), and the working directory (bwrap binds and csub's envelope compare paths
# literally, and csub realpaths its side).
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd -P)"
cd -P . || exit 1
RO_BINDS=()
RW_BINDS=()
RO_TRY_BINDS=()   # like RO_BINDS, but skipped silently if the path doesn't exist on the host
RW_TRY_BINDS=()
ALLOW_HOSTS=()
PASS_ENV=()
WANT_CSUB=0
PROTECT=1
DRY_RUN=0
WANT_GPU=0
WANT_IB=0
WANT_JOBNET=0     # --job-nodes / --peers
WANT_HOSTNET=0    # --host-net
PEER_LIST=""      # --peers HOST,HOST (empty: take the nodes from LSF)
LISTEN_PORTS=()   # --listen PORT
ORIG_ARGS=("$@")  # --job-nodes starts this script again, with the same arguments, under pasta
WANT_CLAUDE=0
WANT_OPENCODE=0
CLAUDE_HISTORY=""   # "", ro or rw: --claude-history[-rw]
CFG_BINDS=()      # the per-job cfg/ dirs: bound after the sibling-state tmpfs (see "Per-job state")
LATE_BINDS=()     # binds that must come after CFG_BINDS (nested file binds over a per-job dir)
EXTRA_SETENV=()
PATH_PREPEND=""    # --claude/--opencode bind a CLI under $HOME; put its dir on PATH (see below)
SANDBOX_CFG_ROOT=""

# Everything from line 2 down to the line before `set -euo pipefail`.
usage() { sed -n "2,$(( $(grep -n '^set -euo pipefail' "${BASH_SOURCE[0]}" | cut -d: -f1) - 1 ))p" "${BASH_SOURCE[0]}"; }

# An option that takes a value must have one: without this a trailing `--rw` died with bash's
# own "unbound variable" instead of a usage error.
need_arg() { [[ $# -ge 2 ]] || { echo "sandbox-run.sh: $1 needs an argument" >&2; exit 1; }; }
# /, /tmp, /proc and /dev are the sandbox's own (a private /tmp, its own /proc and /dev). A bind of
# one of them, or the working directory being one, would put the node's in their place.
refuse_base_path() {  # $1 = how it was named, $2 = canonical path
  case "$2" in
    /|/tmp|/proc|/dev)
      echo "sandbox-run.sh: $1: $2 cannot be bound: the sandbox has its own. Use a directory beneath it." >&2
      exit 1 ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ro|--rw)
      need_arg "$@"
      # Canonical, existing path: a relative or symlinked argument would otherwise be bound under
      # one name and compared (masking, script-dir shadowing, csub envelope) under another.
      p="$(realpath -e -- "$2" 2>/dev/null)" || { echo "sandbox-run.sh: $1 $2: no such path" >&2; exit 1; }
      refuse_base_path "$1 $2" "$p"
      if [[ "$1" == --ro ]]; then RO_BINDS+=("$p"); else RW_BINDS+=("$p"); fi
      shift 2 ;;
    --allow) need_arg "$@"; ALLOW_HOSTS+=("$2"); shift 2 ;;
    --no-protect) PROTECT=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --env)
      need_arg "$@"
      # A NAME, looked up in this shell's environment -- not NAME=value.
      [[ "$2" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo "sandbox-run.sh: --env takes a variable NAME (got '$2'); export the value first" >&2; exit 1; }
      PASS_ENV+=("$2"); shift 2 ;;
    --csub) WANT_CSUB=1; shift ;;
    --gpu) WANT_GPU=1; shift ;;
    --ib) WANT_IB=1; shift ;;
    --job-nodes) WANT_JOBNET=1; shift ;;
    --host-net) WANT_HOSTNET=1; shift ;;
    --peers)
      need_arg "$@"
      [[ "$2" =~ ^[A-Za-z0-9._,-]+$ ]] || { echo "sandbox-run.sh: --peers takes host names separated by commas (got '$2')" >&2; exit 1; }
      WANT_JOBNET=1; PEER_LIST="$2"; shift 2 ;;
    --listen)
      need_arg "$@"
      [[ "$2" =~ ^[0-9]+$ && "$2" -ge 1024 && "$2" -le 65535 ]] || { echo "sandbox-run.sh: --listen takes a port from 1024 to 65535 (got '$2')" >&2; exit 1; }
      LISTEN_PORTS+=("$2"); shift 2 ;;
    --scratch) mkdir -p "/scratch/$USER/work"; RW_BINDS+=("$(realpath "/scratch/$USER/work")"); shift ;;
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
      PATH_PREPEND+="$HOME/.local/bin:"
      shift ;;
    --claude-history) CLAUDE_HISTORY=ro; shift ;;
    --claude-history-rw) CLAUDE_HISTORY=rw; shift ;;
    --opencode)
      WANT_OPENCODE=1
      # Same reasoning as --claude above: opencode's own installer puts the actual binary
      # under ~/.opencode/bin/opencode, separate from its XDG dirs (config, data, state, cache).
      # Read-only, same rationale.
      RO_TRY_BINDS+=("$HOME/.opencode")
      PATH_PREPEND+="$HOME/.opencode/bin:"
      shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done
CMD=("$@")
# $PWD is always bound read-write. From $HOME, or from a directory above it, that is the whole
# home directory, and the masks below cover only its well-known direct children. Refuse; a
# deliberate home-wide sandbox is `--rw "$HOME"` from a project directory, where the header's
# warning applies knowingly.
HOME_P="$(cd -P "$HOME" 2>/dev/null && pwd -P || echo "$HOME")"
# "${PWD%/}/" so that / itself counts as "above $HOME" ("$PWD/" would be "//" there and match
# nothing): from / the bind is the entire filesystem.
if [[ "$PWD" == "$HOME_P" || "$HOME_P" == "${PWD%/}/"* ]]; then
  echo "sandbox-run.sh: refusing to run from $PWD: the working directory is bound read-write and would expose your whole home directory. cd into a project directory first." >&2
  exit 1
fi
refuse_base_path "the working directory" "$(pwd -P)"
if [[ ${#CMD[@]} -eq 0 ]]; then
  echo "No command given after --" >&2; usage; exit 1
fi
if [[ -n "$CLAUDE_HISTORY" && $WANT_CLAUDE -eq 0 ]]; then
  echo "sandbox-run.sh: --claude-history needs --claude (the history is bound into the per-job Claude config)" >&2; exit 1
fi

# --job-nodes (see "Multi-node jobs" in the header). Two stages of this same script:
#   outer  works out the job's other nodes and starts pasta, which runs the script again
#   inner  runs as root of pasta's user+network namespace: narrows the routes, then carries on
#          to the normal sandbox, which gets a nested user namespace instead of --unshare-net
# Both run before anything is created, so a refusal here leaves nothing behind.
jobnet_die() { echo "sandbox-run.sh: --job-nodes: $*" >&2; exit 1; }
JOBNET_INNER=0
JOBNET_DRY=0      # --dry-run with --job-nodes: the outer stage's values, and pasta is not started
JOBNET_PASTA=()   # the pasta command of the outer stage (for --dry-run)
if [[ $WANT_HOSTNET -eq 1 ]]; then
  # One flag must not be enough to run an agent itself, or its job broker, with an open network.
  _why=""
  [[ $WANT_JOBNET -eq 1 ]] && _why="--job-nodes or --peers (choose one of the two networks)"
  [[ $WANT_IB -eq 1 ]] && _why="--ib: a job on InfiniBand takes --job-nodes --ib, which is as fast and keeps the network limited"
  [[ ${#ALLOW_HOSTS[@]} -gt 0 ]] && _why="--allow (the network is already open)"
  [[ $WANT_CSUB -eq 1 ]] && _why="--csub"
  [[ $WANT_CLAUDE -eq 1 || $WANT_OPENCODE -eq 1 ]] && _why="--claude or --opencode: run the agent in the ordinary sandbox and let it start multi-node work as a job"
  [[ -z "$_why" ]] || { echo "sandbox-run.sh: --host-net: not with $_why" >&2; exit 1; }
  echo "sandbox-run.sh: --host-net: this sandbox shares the node's network; nothing limits where it connects" >&2
fi
if [[ $WANT_IB -eq 1 ]]; then
  # --ib opens the InfiniBand fabric, which nothing here limits. For a job's workers only.
  _why=""
  [[ $WANT_CSUB -eq 1 ]] && _why="--csub"
  [[ $WANT_CLAUDE -eq 1 || $WANT_OPENCODE -eq 1 ]] && _why="--claude or --opencode: run the agent in the ordinary sandbox and let it start multi-node work as a job"
  [[ -z "$_why" ]] || { echo "sandbox-run.sh: --ib: not with $_why" >&2; exit 1; }
  [[ -d /dev/infiniband ]] || { echo "sandbox-run.sh: --ib: this node has no /dev/infiniband" >&2; exit 1; }
fi
if [[ $WANT_JOBNET -eq 0 && ${#LISTEN_PORTS[@]} -gt 0 ]]; then
  echo "sandbox-run.sh: --listen needs --job-nodes (or --peers)" >&2; exit 1
fi
if [[ $WANT_JOBNET -eq 1 ]]; then
  # The agent itself stays in the ordinary single-node sandbox; this mode is for its workers.
  [[ $WANT_CLAUDE -eq 0 && $WANT_OPENCODE -eq 0 ]] || jobnet_die "not with --claude or --opencode: run the agent in the ordinary sandbox and let it start multi-node work as a job"
  # The allowlist proxy and the csub broker would start inside the narrowed network.
  [[ ${#ALLOW_HOSTS[@]} -eq 0 ]] || jobnet_die "not with --allow: a worker reaches the job's nodes only"
  [[ $WANT_CSUB -eq 0 ]] || jobnet_die "not with --csub"
  IP_BIN="$(command -v ip || echo /usr/sbin/ip)"
  if [[ "${SANDBOX_NET_STAGE:-}" != inner ]]; then
    # ---- outer stage
    command -v pasta >/dev/null || jobnet_die "needs pasta (the passt package) on $(hostname)"
    # `|| true`: an unknown name must reach the message below, not end the script under `set -e`.
    _myip="$(getent ahostsv4 "$(hostname)" | awk 'NR==1{print $1}')" || true
    [[ "$_myip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || jobnet_die "cannot resolve this node's own address ($(hostname))"
    _hif="$("$IP_BIN" -o -4 addr show | awk -v ip="$_myip" '{split($4, a, "/"); if (a[1] == ip) {print $2; exit}}')"
    [[ -n "$_hif" ]] || jobnet_die "no network interface holds $_myip"
    _names=() _jobaddrs=""
    if [[ -n "$PEER_LIST" ]]; then
      IFS=, read -ra _names <<< "$PEER_LIST"
      # Inside an LSF job --peers may only narrow the job's own nodes, so that a launcher or a
      # typing mistake cannot open a path to another host by naming it. The list comes from
      # LSB_MCPU_HOSTS in the environment: it guards whoever starts the wrapper against a mistake,
      # not against themselves. The sandboxed process never starts the wrapper outside the sandbox.
      if [[ -n "${LSB_MCPU_HOSTS:-}" ]]; then
        read -ra _mc <<< "$LSB_MCPU_HOSTS"
        for ((i = 0; i < ${#_mc[@]}; i += 2)); do
          _jobaddrs+=" $(getent ahostsv4 "${_mc[i]}" | awk 'NR==1{print $1}' || true)"
        done
      fi
    elif [[ -n "${LSB_MCPU_HOSTS:-}" ]]; then
      # "host1 slots1 host2 slots2 ..." -- LSF sets it in every task of the job
      read -ra _mc <<< "$LSB_MCPU_HOSTS"
      for ((i = 0; i < ${#_mc[@]}; i += 2)); do _names+=("${_mc[i]}"); done
    else
      jobnet_die "not inside an LSF job (LSB_MCPU_HOSTS is not set); name the nodes with --peers HOST,HOST"
    fi
    _peers="" _hosts="$_myip $(getent hosts "$_myip" 2>/dev/null | awk '{for (i = 2; i <= NF; i++) printf "%s ", $i}' || true)"$'\n'
    for n in "${_names[@]}"; do
      [[ "$n" =~ ^[A-Za-z0-9._-]+$ ]] || jobnet_die "not a host name: $n"
      a="$(getent ahostsv4 "$n" | awk 'NR==1{print $1}')" || true
      [[ "$a" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || jobnet_die "cannot resolve $n"
      [[ -z "$_jobaddrs" || " $_jobaddrs " == *" $a "* ]] || jobnet_die "--peers $n: not a node of this LSF job ($LSB_MCPU_HOSTS)"
      [[ "$a" == "$_myip" || " $_peers " == *" $a "* ]] && continue
      _peers+="${_peers:+ }$a"
      _hosts+="$a $(getent hosts "$a" 2>/dev/null | awk '{for (i = 2; i <= NF; i++) printf "%s ", $i}' || true)"$'\n'
    done
    _markdir="/scratch/$USER/.agentic-sandbox"
    mkdir -p "$_markdir" 2>/dev/null || { _markdir="${TMPDIR:-/tmp}/agentic-sandbox-$(id -u)"; mkdir -p "$_markdir"; }
    chmod 700 "$_markdir"
    for _try in 1 2 3; do
      # One sandbox at a time on this node chooses its block and lets pasta bind it: two that
      # look at the same instant would each get part of the same block. Held until the inner
      # stage has started (or pasta has given up), never across the sandboxed command.
      # (Not in a dry run, which binds no port.)
      if [[ $DRY_RUN -eq 0 ]]; then
        exec {_lockfd}> "$_markdir/net.lock"
        flock "$_lockfd"
      fi
      # Ports other nodes may connect to: a block of 2000 below the node's own range for outgoing
      # connections, so that nothing on the node hands one out by chance. Ports already listening
      # on the node are left out (pasta would report each one it cannot bind). A block that is
      # mostly taken belongs to another sandbox on this node, so the next block down is tried.
      read -r _elo _ < /proc/sys/net/ipv4/ip_local_port_range
      _top=14999; [[ "$_elo" -le "$_top" ]] && _top=$((_elo - 1))
      _listening="$(ss -Htln 2>/dev/null | awk '{n = split($4, a, ":"); print a[n]}' | sort -un || true)"
      _lo="" _hi="" _busy=""
      for ((_h = _top; _h - 1999 >= 5000; _h -= 2000)); do
        _b="$(awk -v lo=$((_h - 1999)) -v hi="$_h" '$1 >= lo && $1 <= hi' <<< "$_listening")"
        if [[ "$(grep -c . <<< "$_b" || true)" -lt 1000 ]]; then _lo=$((_h - 1999)); _hi=$_h; _busy="$_b"; break; fi
      done
      [[ -n "$_lo" ]] || jobnet_die "no free block of 2000 ports between 5000 and $_top on $(hostname): sandboxes with --job-nodes or --peers hold them all, possibly other users' (five fit on a node). Submit again, or to nodes the job has to itself."
      # Excludes only: pasta then forwards the rest best effort.
      _spec="~1-$((_lo - 1)),~$((_hi + 1))-65535"
      for port in $_busy; do _spec+=",~$port"; done
      _fwd=(-t "$_myip/$_spec")
      for port in "${LISTEN_PORTS[@]:-}"; do
        [[ -n "$port" ]] || continue
        [[ "$port" -ge "$_lo" && "$port" -le "$_hi" ]] || _fwd+=(-t "$_myip/$port")
      done
      # A killed parent takes its child with it, at both levels: this shell -> pasta -> inner stage.
      _pre=(); command -v setpriv >/dev/null && _pre=(setpriv --pdeathsig KILL)
      JOBNET_PASTA=(${_pre[@]+"${_pre[@]}"} pasta --config-net -4 -q -i "$_hif" -I "$_hif" "${_fwd[@]}"
                    -u none -T none -U none --no-map-gw --
                    ${_pre[@]+"${_pre[@]}"} "$SCRIPT_DIR/$(basename "$(readlink -f "${BASH_SOURCE[0]}")")" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"})
      if [[ $DRY_RUN -eq 1 ]]; then
        # A dry run starts nothing: no pasta, no second run of this script. What the inner stage
        # would be given is set here (not exported), the routes are left alone, and the script
        # carries on to build and print the bwrap command of the inner stage. dry_run_print names
        # the pasta command.
        SANDBOX_NET_PEERS="$_peers" SANDBOX_NET_MYIP="$_myip" SANDBOX_NET_IF="$_hif" SANDBOX_NET_HOSTS="$_hosts"
        SANDBOX_NET_UID="$(id -u)" SANDBOX_NET_GID="$(id -g)" SANDBOX_NET_PORTS="$_lo $_hi" SANDBOX_NET_PID="$$"
        JOBNET_DRY=1
        break
      fi
      SANDBOX_NET_STAGE=inner SANDBOX_NET_PEERS="$_peers" SANDBOX_NET_MYIP="$_myip"
      SANDBOX_NET_IF="$_hif" SANDBOX_NET_HOSTS="$_hosts" SANDBOX_NET_HOSTNAME="$(hostname)"
      SANDBOX_NET_UID="$(id -u)" SANDBOX_NET_GID="$(id -g)" SANDBOX_NET_PORTS="$_lo $_hi" SANDBOX_NET_PID="$$" SANDBOX_NET_MARK="$_markdir/net-$$.starting"
      export SANDBOX_NET_STAGE SANDBOX_NET_PEERS SANDBOX_NET_MYIP SANDBOX_NET_IF SANDBOX_NET_HOSTS SANDBOX_NET_HOSTNAME \
             SANDBOX_NET_UID SANDBOX_NET_GID SANDBOX_NET_PORTS SANDBOX_NET_PID SANDBOX_NET_MARK
      : > "$SANDBOX_NET_MARK"
      # pasta is stopped on every way out of this stage. (It normally ends with the inner stage,
      # and _pp is emptied once it has been waited for.)
      _pp="" _sig=""
      trap '[[ -n "$_pp" ]] && kill "$_pp" 2>/dev/null || true' EXIT
      # A signal sent to this pid alone (a launcher stopping one worker) is passed to everything
      # below pasta: the inner stage, bwrap and the sandboxed command. The inner stage alone would
      # not do: bash runs a trap only when its foreground command returns, so it would sit on the
      # signal until the sandboxed command ended by itself. (bkill and walltime kills signal every
      # process of the job anyway.) Set before pasta starts: a signal that arrives while the inner
      # stage is still coming up is remembered and passed on once it is there.
      _tree() { local c; for c in $(pgrep -P "$1" 2>/dev/null || true); do echo "$c"; _tree "$c"; done; }
      _fwd_sig() { local k=""; _sig="$1"; [[ -n "$_pp" ]] && k="$(_tree "$_pp")"; [[ -n "$k" ]] && kill -"$1" $k 2>/dev/null; true; }
      trap '_fwd_sig TERM' TERM; trap '_fwd_sig INT' INT; trap '_fwd_sig USR2' USR2
      # In the background, so that the traps below run at once; `<&0` keeps the caller's stdin.
      "${JOBNET_PASTA[@]}" <&0 {_lockfd}>&- &
      _pp=$!
      for ((_w = 0; _w < 300; _w++)); do
        [[ -e "$SANDBOX_NET_MARK" ]] && kill -0 "$_pp" 2>/dev/null || break
        sleep 0.1
      done
      exec {_lockfd}>&-
      # A signal from the start-up window: pass it on now that the inner stage exists, or stop
      # pasta if it has nothing below it.
      if [[ -n "$_sig" ]]; then
        if [[ -n "$(_tree "$_pp")" ]]; then _fwd_sig "$_sig"; else kill "$_pp" 2>/dev/null || true; fi
      fi
      _rc=0
      while :; do
        wait "$_pp" && _rc=0 || _rc=$?
        kill -0 "$_pp" 2>/dev/null || break   # still there: `wait` was interrupted by a trap
      done
      # The inner stage removes the marker when it starts. Still there: pasta gave up before that,
      # which is what happens when another sandbox on this node took the same block of ports in
      # the same instant. Look again and retry; any other failure repeats and is reported as is.
      _pp=""   # waited for: nothing left for the EXIT trap to stop
      # Stopped by a signal, at whatever point: that is the end, not a reason to try again.
      if [[ -n "$_sig" ]]; then
        rm -f "$SANDBOX_NET_MARK"
        case "$_sig" in TERM) exit 143 ;; INT) exit 130 ;; *) exit 140 ;; esac
      fi
      [[ -e "$SANDBOX_NET_MARK" ]] || exit "$_rc"
      rm -f "$SANDBOX_NET_MARK"
      [[ $_try -lt 3 ]] || exit "$_rc"
      sleep "$((_try)).$((RANDOM % 10))"
    done
  fi
  # ---- inner stage. SANDBOX_NET_STAGE is only an environment variable, so prove where we are
  # before touching a routing table: root of a user namespace that maps to the calling user.
  # (As plain root on the node, the flush below would hit the node's own routes.)
  if [[ $JOBNET_DRY -eq 0 ]]; then
    read -r _in _out _cnt < /proc/self/uid_map
    [[ "$(id -u)" == 0 && "$_in" == 0 && "$_cnt" == 1 && "$_out" != 0 && "$_out" == "${SANDBOX_NET_UID:-}" ]] \
      || jobnet_die "internal: the inner stage is not running in pasta's namespace"
    [[ "${SANDBOX_NET_GID:-}" =~ ^[0-9]+$ && "${SANDBOX_NET_PID:-}" =~ ^[0-9]+$ && "${SANDBOX_NET_IF:-}" =~ ^[A-Za-z0-9._-]{1,15}$ \
       && "${SANDBOX_NET_PORTS:-}" =~ ^[0-9]+\ [0-9]+$ && "${SANDBOX_NET_PEERS-x}" =~ ^[0-9.\ ]*$ ]] \
      || jobnet_die "internal: bad settings from the outer stage"
    "$IP_BIN" -4 route flush dev "$SANDBOX_NET_IF" || jobnet_die "could not clear the routes"
    _n=0
    for a in $SANDBOX_NET_PEERS; do
      "$IP_BIN" -4 route add "$a/32" dev "$SANDBOX_NET_IF" || jobnet_die "could not add the route to $a"
      _n=$((_n + 1))
    done
    # Every other address is made local to this namespace. Without it a socket bound to the
    # interface (SO_BINDTODEVICE needs no privilege) skips the failed route lookup, the kernel
    # treats the destination as on-link, and pasta forwards the packet: shown on the cluster on
    # 21 November 2026, a datagram reached a node that was not a peer. With this route the lookup
    # succeeds and the packet stays inside.
    # `src`: without it a UDP socket connected to an outside address reports that address as its own,
    # and software that finds "my address" that way (Ray, Dask) would advertise it.
    "$IP_BIN" -4 route add local default dev "$SANDBOX_NET_IF" src "$SANDBOX_NET_MYIP" || jobnet_die "could not add the catch-all local route"
    # Exactly one route per other node in the main table, and that one in the local table: fail
    # closed on anything unexpected.
    _rt="$("$IP_BIN" -4 route show)"
    [[ "$(grep -c . <<< "$_rt" || true)" == "$_n" && -z "$(grep -E 'default|/' <<< "$_rt" || true)" \
       && "$("$IP_BIN" -4 route show table local | grep -c "^local default dev $SANDBOX_NET_IF " || true)" == 1 ]] \
      || jobnet_die "the routing table is not what was set: $(tr '\n' ';' <<< "$_rt")"
    # Listeners that let the system pick a port get one from the top 1500 of the forwarded range.
    echo "$(( ${SANDBOX_NET_PORTS#* } - 1499 )) ${SANDBOX_NET_PORTS#* }" > /proc/sys/net/ipv4/ip_local_port_range \
      || jobnet_die "could not set the port range"
    # pasta names its namespace pasta-<host>; software that looks itself up needs the real name.
    hostname "$SANDBOX_NET_HOSTNAME" 2>/dev/null || true
  fi
  JOBNET_INNER=1
  JOBNET_PID="$SANDBOX_NET_PID"
  [[ "${SANDBOX_NET_MARK:-}" == */net-"$SANDBOX_NET_PID".starting ]] && rm -f "$SANDBOX_NET_MARK"
fi

# --gpu: resolve the job's GPUs to device nodes now, before anything is created, so the common
# mistake (no GPU allocated) exits with nothing to clean up. Each CUDA_VISIBLE_DEVICES entry
# (index or GPU-UUID) -> PCI bus id -> driver device minor (the N in /dev/nvidiaN). Not
# `--device nvidia.com/gpu=all` as podman does: bwrap has no CDI, so nodes are bound one by one.
GPU_BINDS=()
GPU_CVD=""
_buses=()
if [[ $WANT_GPU -eq 1 ]]; then
  if [[ -z "${CUDA_VISIBLE_DEVICES:-}" ]]; then
    echo "sandbox-run.sh: --gpu, but CUDA_VISIBLE_DEVICES is empty -- no GPU is allocated (submit with -gpu \"num=1\" on a GPU queue)" >&2
    exit 1
  fi
  command -v nvidia-smi >/dev/null || { echo "sandbox-run.sh: --gpu needs nvidia-smi on the host" >&2; exit 1; }
  IFS=',' read -ra _gpus <<< "$CUDA_VISIBLE_DEVICES"
  for g in "${_gpus[@]}"; do
    bus="$(nvidia-smi -i "$g" --query-gpu=pci.bus_id --format=csv,noheader 2>/dev/null)" \
      || { echo "sandbox-run.sh: --gpu: nvidia-smi cannot find GPU '$g' (from CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES)" >&2; exit 1; }
    bus="$(echo "${bus#00000000:}" | tr 'A-F' 'a-f')"
    info="/proc/driver/nvidia/gpus/0000:$bus/information"
    minor="$(awk '/Device Minor/ {print $3}' "$info" 2>/dev/null)"
    [[ -n "$minor" && -e "/dev/nvidia$minor" ]] \
      || { echo "sandbox-run.sh: --gpu: could not resolve GPU '$g' to a /dev/nvidiaN node (read $info)" >&2; exit 1; }
    echo "sandbox-run.sh: --gpu: $g -> /dev/nvidia$minor" >&2
    GPU_BINDS+=(--dev-bind "/dev/nvidia$minor" "/dev/nvidia$minor")
    _buses+=("$bus")
  done
  # The numbering inside. Only the bound GPUs can be opened there, so CUDA counts them from 0 (in
  # PCI bus order, pinned with CUDA_DEVICE_ORDER below). Passing the job's own value through
  # worked only when it was 0..n-1: `CUDA_VISIBLE_DEVICES=1` in a 2-GPU job bound one GPU and then
  # pointed CUDA at a second one that did not exist ("No CUDA GPUs are available"). Each entry
  # becomes its GPU's rank among the bound ones, in the order given.
  _sorted="$(printf '%s\n' "${_buses[@]}" | sort -u)"
  for b in "${_buses[@]}"; do
    i=$(( $(printf '%s\n' "$_sorted" | grep -n -x -F -- "$b" | cut -d: -f1) - 1 ))
    GPU_CVD+="${GPU_CVD:+,}$i"
  done
  [[ "$GPU_CVD" == "$CUDA_VISIBLE_DEVICES" ]] || echo "sandbox-run.sh: --gpu: CUDA_VISIBLE_DEVICES is $GPU_CVD inside the sandbox" >&2
  # NVML/CUDA read the GPU's PCI identity from sysfs; without it nvidia-smi fails with "GPU access
  # blocked by the operating system" even with every device node present (verified live). Only the
  # two subtrees it needs, read-only (bisected; PyTorch too): not /sys/bus, /sys/dev, /sys/fs
  # (cgroups), /sys/kernel, /sys/firmware.
  for d in devices module; do GPU_BINDS+=(--ro-bind "/sys/$d" "/sys/$d"); done
  for n in nvidiactl nvidia-uvm nvidia-uvm-tools; do
    if [[ -e /dev/$n ]]; then GPU_BINDS+=(--dev-bind "/dev/$n" "/dev/$n")
    elif [[ $n != nvidia-uvm-tools ]]; then echo "sandbox-run.sh: --gpu: /dev/$n is missing on this host" >&2; exit 1; fi
  done
fi

# Per-job state directory (see "Per-job state" in the header). Created here, before the bwrap
# argument list, and removed whole by cleanup() on exit. The tag matches podman-run.sh's.
# /scratch itself is owned by root and not world-writable on the nodes, so no other user can
# create /scratch/$USER before you do; this layout relies on that.
SANDBOX_STATE_PARENT="/scratch/$USER/.agentic-sandbox"
if ! mkdir -p "$SANDBOX_STATE_PARENT" 2>/dev/null; then
  # Not a cluster node (no writable /scratch/$USER). Only then fall back to $TMPDIR.
  SANDBOX_STATE_PARENT="${TMPDIR:-/tmp}/agentic-sandbox-$(id -u)"
  echo "sandbox-run.sh: note: /scratch/$USER is not writable here; per-job state goes to $SANDBOX_STATE_PARENT instead" >&2
  mkdir -p "$SANDBOX_STATE_PARENT"
fi
chmod 700 "$SANDBOX_STATE_PARENT"
# --job-nodes: the inner stage is pid 1 of pasta's pid namespace, every time, so it takes the outer
# stage's pid (which is pasta's) -- two workers on one node would otherwise claim the same directory.
JOB_DIR="$SANDBOX_STATE_PARENT/${LSB_JOBID:-manual}${LSB_JOBINDEX:+-$LSB_JOBINDEX}-${JOBNET_PID:-$$}"
# Plain mkdir: the tag is unique by construction, so an existing dir is debris from a reused pid
# or a bug, and reusing it would mix two jobs' state. Fail loudly instead.
mkdir "$JOB_DIR" || { echo "sandbox-run.sh: per-job state dir $JOB_DIR already exists; remove it if no job is using it" >&2; exit 1; }
chmod 700 "$JOB_DIR"
RECORD_START="$(date +%Y-%m-%dT%H:%M:%S%z)"; : > "$JOB_DIR/.start"   # for the per-job record
# Removed on every exit from here on: the cfg/ copies below include ~/.claude.json (account
# details), so no exit between here and the full cleanup() further down may leave them behind.
# cleanup() replaces this trap once there is a proxy or broker to stop as well.
early_cleanup() { rm -rf "$JOB_DIR"; true; }
trap early_cleanup EXIT
# bash does NOT run EXIT traps when killed by an untrapped fatal signal -- exactly how `bkill`
# and LSF walltime kills arrive (SIGUSR2/SIGTERM before SIGKILL). Route them through the EXIT
# trap so the proxy, the csub broker and the per-job state dir are cleaned up on those paths
# too; bwrap itself dies with the wrapper (--die-with-parent).
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 140' USR2
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
    # --no-preserve=mode: a read-only original must still give a copy the wrapper can append to.
    [[ -f "$f" ]] && cp --no-preserve=mode "$f" "$CLAUDE_CFG/$(basename "$f")"
  done
  CFG_BINDS+=(--bind "$CLAUDE_CFG" "$CLAUDE_CFG")
  if [[ -f "$HOME/.claude/.credentials.json" ]]; then
    # Bound AFTER the directory bind (LATE_BINDS), so the real file shows through the copy dir.
    LATE_BINDS+=(--bind "$HOME/.claude/.credentials.json" "$CLAUDE_CFG/.credentials.json")
  else
    echo "sandbox-run.sh: warning: no ~/.claude/.credentials.json -- a \`claude auth login\` done inside the sandbox will NOT persist past this run. Log in once outside the sandbox first, or pass --env ANTHROPIC_API_KEY." >&2
  fi
  EXTRA_SETENV+=(CLAUDE_CONFIG_DIR "$CLAUDE_CFG")
  if [[ -n "$CLAUDE_HISTORY" ]]; then
    # Only THIS project's transcripts (Claude keys them by cwd, non-alphanumerics -> '-'), not
    # all of ~/.claude/projects.
    HIST_DIR="$HOME/.claude/projects/$(printf '%s' "$PWD" | sed 's/[^A-Za-z0-9]/-/g')"
    [[ $CLAUDE_HISTORY == rw ]] && mkdir -p "$HIST_DIR"
    if [[ -d "$HIST_DIR" ]]; then
      if [[ $CLAUDE_HISTORY == rw ]]; then HB=--bind; else HB=--ro-bind; fi
      LATE_BINDS+=("$HB" "$HIST_DIR" "$CLAUDE_CFG/projects/${HIST_DIR##*/}")
    else
      echo "sandbox-run.sh: warning: --claude-history: no past sessions at $HIST_DIR" >&2
    fi
  fi
fi
if [[ $WANT_OPENCODE -eq 1 ]]; then
  new_cfg_root
  OPENCODE_XDG_CONFIG="$SANDBOX_CFG_ROOT/opencode-xdg-config"
  mkdir -p "$OPENCODE_XDG_CONFIG"
  [[ -d "$HOME/.config/opencode" ]] && cp -RH "$HOME/.config/opencode" "$OPENCODE_XDG_CONFIG/opencode"
  mkdir -p "$OPENCODE_XDG_CONFIG/opencode"
  OPENCODE_CONFIG_FILE="$OPENCODE_XDG_CONFIG/opencode/opencode.json"
  [[ -f "$OPENCODE_XDG_CONFIG/opencode/opencode.jsonc" && ! -f "$OPENCODE_CONFIG_FILE" ]] \
    && OPENCODE_CONFIG_FILE="$OPENCODE_XDG_CONFIG/opencode/opencode.jsonc"
  CFG_BINDS+=(--bind "$OPENCODE_XDG_CONFIG" "$OPENCODE_XDG_CONFIG")
  # Data dirs (auth.json, sessions, cache) stay bound to the real ones; created if missing so
  # bwrap has a source path on a fresh account.
  for d in .local/share/opencode .local/state/opencode .cache/opencode; do
    mkdir -p "$HOME/$d"
    # The physical path: the binds are compared and re-checked by name, and $HOME may be reached
    # through a symlink.
    RW_BINDS+=("$(realpath -e -- "$HOME/$d")")
  done
  # opencode's own variables, not XDG_CONFIG_HOME: that would also hide git's, gh's and every
  # other tool's ~/.config from the sandboxed process. OPENCODE_CONFIG is the config file,
  # OPENCODE_CONFIG_DIR the agents/commands/modes/plugins directory (opencode.ai/docs/config).
  EXTRA_SETENV+=(OPENCODE_CONFIG "$OPENCODE_CONFIG_FILE"
                 OPENCODE_CONFIG_DIR "$OPENCODE_XDG_CONFIG/opencode")
fi

BWRAP_ARGS=(
  --ro-bind /usr /usr --ro-bind /bin /bin --ro-bind /lib64 /lib64 --ro-bind /lib /lib
  --ro-bind /sbin /sbin --ro-bind /etc /etc
  # /tmp BEFORE $PWD (which is bound with the other binds further down): bwrap applies mounts
  # in order, so a tmpfs mounted after the $PWD bind would cover a $PWD that lives under /tmp,
  # and the agent would start in an empty directory.
  --tmpfs /tmp
  # --unshare-pid is also what cleans up: when bwrap's process 1 exits, the kernel kills
  # everything left in the namespace. Without it the in-sandbox relay (relay.py) outlived the
  # command and stayed on the node after the job.
  # The network: --unshare-net is added just below, except for a multi-node worker.
  --proc /proc --dev /dev --unshare-pid --unshare-ipc --unshare-uts
  --die-with-parent
)
if [[ $JOBNET_INNER -eq 1 ]]; then
  # The network namespace is the one pasta serves, already narrowed above. The nested user
  # namespace is what makes that final: inside it, uid 0 of the outer namespace is the user
  # again, with no capability over the network namespace. (/etc/hosts for the job's nodes is
  # bound with the other multi-node binds, in the sorted list below.)
  BWRAP_ARGS+=(--unshare-user --uid "$SANDBOX_NET_UID" --gid "$SANDBOX_NET_GID")
elif [[ $WANT_HOSTNET -eq 0 ]]; then
  BWRAP_ARGS+=(--unshare-net)
fi
# After --dev /dev (mounts apply in order): the GPU device nodes, and the job's device numbering.
if [[ ${#GPU_BINDS[@]} -gt 0 ]]; then
  BWRAP_ARGS+=("${GPU_BINDS[@]}")
  EXTRA_SETENV+=(CUDA_VISIBLE_DEVICES "$GPU_CVD" CUDA_DEVICE_ORDER PCI_BUS_ID)
fi
# Own terminal session unless a human is actually at a terminal (Mode C): with a controlling
# tty shared with the parent shell, a sandboxed process can queue keystrokes into it with the
# TIOCSTI ioctl and have them run outside the sandbox after it exits. setsid() would break
# job control for an interactive REPL, so it's only applied when stdin isn't a tty.
[[ -t 0 ]] || BWRAP_ARGS+=(--new-session)

# Start from an empty environment; copy in only what a shell/CLI needs plus --env extras.
BWRAP_ARGS+=(--clearenv --setenv TMPDIR /tmp)
PASSTHROUGH_ENV=(PATH HOME USER LOGNAME SHELL TERM COLORTERM LANG TZ
                 SSL_CERT_FILE SSL_CERT_DIR REQUESTS_CA_BUNDLE CURL_CA_BUNDLE NODE_EXTRA_CA_CERTS)
# Every LC_* the invoking shell has, as documented above -- not a fixed subset.
while IFS= read -r name; do PASSTHROUGH_ENV+=("$name"); done < <(compgen -e LC_)
# These values do NOT go on bwrap's command line: a command line is readable by every user on
# the node (/proc/<pid>/cmdline, `ps -ef`), and --env exists to pass secrets such as an API key.
# They are collected here and handed to bwrap on a file descriptor (--args 9, see run_bwrap). The
# position of --args keeps the order: bwrap takes the last --setenv for a name.
# With .git/config read-only, `git config user.name ...` fails inside, and $HOME is not there to
# supply an identity. Pass yours in the variables git reads, so that commits still work. Read
# from / so that no repository's configuration is consulted on the host.
if [[ $PROTECT -eq 1 ]] && command -v git >/dev/null 2>&1; then
  _gn="$(cd / && git config --global --get user.name 2>/dev/null || true)"
  _ge="$(cd / && git config --global --get user.email 2>/dev/null || true)"
  # A name or address already in your environment wins over the global configuration.
  _gn="${GIT_AUTHOR_NAME:-$_gn}"; _ge="${GIT_AUTHOR_EMAIL:-$_ge}"
  [[ -n "$_gn" ]] && EXTRA_SETENV+=(GIT_AUTHOR_NAME "$_gn" GIT_COMMITTER_NAME "${GIT_COMMITTER_NAME:-$_gn}")
  [[ -n "$_ge" ]] && EXTRA_SETENV+=(GIT_AUTHOR_EMAIL "$_ge" GIT_COMMITTER_EMAIL "${GIT_COMMITTER_EMAIL:-$_ge}")
  unset _gn _ge
fi
ENV_ARGS=()
for name in "${PASSTHROUGH_ENV[@]}"; do
  [[ -n "${!name+x}" ]] && ENV_ARGS+=(--setenv "$name" "${!name}")
done
for name in "${PASS_ENV[@]:-}"; do
  [[ -n "$name" && -n "${ENV_AT_START[$name]+x}" ]] && ENV_ARGS+=(--setenv "$name" "${ENV_AT_START[$name]}")
done
for ((i = 0; i < ${#EXTRA_SETENV[@]}; i += 2)); do
  ENV_ARGS+=(--setenv "${EXTRA_SETENV[i]}" "${EXTRA_SETENV[i + 1]}")
done
BWRAP_ARGS+=(--args 9)
# The CLI dirs bound by --claude/--opencode are only reachable by name if PATH names them. An
# interactive shell's PATH usually does already; one from `bsub -env none` or another scrubbed
# environment does not, and `exec: claude: not found` was the result.
[[ -n "$PATH_PREPEND" ]] && BWRAP_ARGS+=(--setenv PATH "$PATH_PREPEND$PATH")
# SSSD's NSS socket -- lets whoami/id/getent resolve UID->username on
# AD/LDAP-joined hosts. Doesn't affect actual permission enforcement (that's
# UID-number-based at the kernel level regardless), just name resolution.
# Bound automatically when present; harmlessly skipped otherwise.
if [[ -S /var/lib/sss/pipes/nss ]]; then
  BWRAP_ARGS+=(--ro-bind /var/lib/sss/pipes/nss /var/lib/sss/pipes/nss)
fi
# $PWD and every --ro/--rw bind, SHALLOWEST PATH FIRST. bwrap applies mounts in order and a later
# mount covers an earlier one beneath it, so emitting them by flag (all --ro, then all --rw) made
# `--rw proj --ro proj/sub` leave proj/sub writable, and `--ro proj` from inside proj/sub made the
# working directory read-only. Sorted by depth, the deeper path always keeps its own mode, whatever
# order the flags came in. Same path twice: $PWD, then --ro, then --rw, so the last of those wins.
_bind_lines=""
_seq=0
add_bind() {  # $1 = bwrap flag, $2 = path, $3 = source if it is not the path itself
  local d="${2//[^\/]/}"
  _seq=$((_seq + 1))
  _bind_lines+="${#d}"$'\t'"$_seq"$'\t'"$1"$'\t'"$2"$'\t'"${3:-$2}"$'\n'
}
add_bind --bind "$PWD"
for p in "${RO_BINDS[@]:-}"; do [[ -n "$p" ]] && add_bind --ro-bind "$p"; done
for p in "${RO_TRY_BINDS[@]:-}"; do [[ -n "$p" ]] && add_bind --ro-bind-try "$p"; done
for p in "${RW_BINDS[@]:-}"; do [[ -n "$p" ]] && add_bind --bind "$p"; done
for p in "${RW_TRY_BINDS[@]:-}"; do [[ -n "$p" ]] && add_bind --bind-try "$p"; done
# ---- What is added to the binds above before they are sorted ---------------------------------
# Everything below goes through add_bind, into the same depth-sorted list as $PWD and the --ro
# and --rw paths. That matters: a bind covers whatever was mounted beneath it before, so a bind
# emitted AFTER the sorted list could uncover a deeper --ro of yours. In the sorted list the
# deeper path always comes later and keeps its own mode.

# The mode a path has from your own binds: that of the deepest of $PWD, --ro and --rw that
# contains it (same path: $PWD, then --ro, then --rw, as in the sort). Prints rw, ro or nothing.
eff_mode() {
  local p="$1" best=-1 mode="" r d
  if [[ "$p" == "$PWD" || "$p" == "${PWD%/}/"* ]]; then d="${PWD//[^\/]/}"; best=${#d}; mode=rw; fi
  for r in "${RO_BINDS[@]:-}"; do
    [[ -n "$r" && ( "$p" == "$r" || "$p" == "${r%/}/"* ) ]] || continue
    d="${r//[^\/]/}"; if [[ ${#d} -ge $best ]]; then best=${#d}; mode=ro; fi
  done
  for r in "${RW_BINDS[@]:-}"; do
    [[ -n "$r" && ( "$p" == "$r" || "$p" == "${r%/}/"* ) ]] || continue
    d="${r//[^\/]/}"; if [[ ${#d} -ge $best ]]; then best=${#d}; mode=rw; fi
  done
  echo "$mode"
}
user_named() {  # $1 = path; true if you named exactly this path with --ro or --rw
  local r
  for r in "${RO_BINDS[@]:-}" "${RW_BINDS[@]:-}"; do [[ -n "$r" && "$1" == "$r" ]] && return 0; done
  return 1
}
# True if no component of the path is a symlink. A path that goes through a link is never bound
# by name: the name could lead out of the directory it appears to be in.
plain_path() { [[ "$(realpath -e -- "$1" 2>/dev/null)" == "$1" ]]; }

# PYTHONPATH once more, now that the binds are known: an absolute entry inside a directory that is
# writable in the sandbox is as good as the working directory to host-side Python (the csub
# broker), so those entries are dropped too.
if [[ -n "${PYTHONPATH:-}" ]]; then
  _pp=""
  IFS=: read -ra _ppe <<< "$PYTHONPATH"
  for _e in ${_ppe[@]+"${_ppe[@]}"}; do
    [[ "$(eff_mode "$(realpath -m -- "$_e" 2>/dev/null || echo "$_e")")" == rw ]] || _pp="${_pp:+$_pp:}$_e"
  done
  if [[ -n "$_pp" ]]; then export PYTHONPATH="$_pp"; else unset PYTHONPATH; fi
  unset _pp _ppe _e
fi

# Multi-node workers: the sysfs entries NCCL and libibverbs read, all read-only. Through add_bind
# like everything else here, so that a --ro or --rw of yours above one of them (/sys, /etc) cannot
# cover it, and a deeper one of yours keeps its own mode.
#   /sys/class/net: NCCL sizes its socket transport from the interface's speed. Without it a
#   bandwidth test over Ethernet ran about 27% slower inside the sandbox than outside.
#   /sys/bus/pci, /sys/class/pci_bus: NCCL decides that a NIC is a PCI device by following
#   <device>/subsystem into /sys/bus/pci. Without them InfiniBand comes up, NCCL logs "network
#   path ... is not a PCI device", and the job dies with "Could not find NET with id 0" (verified
#   live, NCCL 2.27.3 on H200 nodes).
if [[ $WANT_IB -eq 1 || $WANT_HOSTNET -eq 1 || $JOBNET_INNER -eq 1 ]]; then
  [[ $WANT_GPU -eq 1 ]] || add_bind --ro-bind /sys/devices     # --gpu has bound it already
  for d in /sys/class/net /sys/bus/pci /sys/class/pci_bus; do
    [[ -e "$d" ]] && add_bind --ro-bind "$d"
  done
fi
# --ib: the verbs devices and their class entries.
if [[ $WANT_IB -eq 1 ]]; then
  add_bind --dev-bind /dev/infiniband
  for d in /sys/class/infiniband /sys/class/infiniband_verbs; do
    [[ -e "$d" ]] && add_bind --ro-bind "$d"
  done
fi
# --job-nodes: /etc/hosts names the job's nodes (there is no DNS inside).
if [[ $JOBNET_INNER -eq 1 ]]; then
  JOBNET_HOSTS="$JOB_DIR/hosts"
  { echo "127.0.0.1 localhost"; printf '%s' "$SANDBOX_NET_HOSTS"; } > "$JOBNET_HOSTS"
  add_bind --ro-bind /etc/hosts "$JOBNET_HOSTS"
fi

# This wrapper, allowlist_proxy.py and relay.py run on the HOST (or are the trusted half of
# the sandbox). If the directory they live in is writable inside -- which is the case whenever
# the script is run from its own checkout, e.g. `cd agentic-sandbox/scripts &&
# ./sandbox-run.sh` -- a prompt-injected agent could edit them and have the edit run
# unsandboxed on the NEXT invocation. So the script directory is bound read-only, and every
# writable directory above it is bound onto itself: a read-only bind makes the script
# directory a mount point, which cannot be renamed, but the directories ABOVE it still could
# be, and a new checkout put in their place. Mount points cannot.
if [[ "$(eff_mode "$SCRIPT_DIR")" == rw ]]; then
  echo "sandbox-run.sh: note: $SCRIPT_DIR is inside a read-write bind; re-binding it read-only. Prefer running from a separate work directory." >&2
  _a="$(dirname "$SCRIPT_DIR")"
  while [[ -n "$_a" && "$_a" != / ]]; do
    if [[ "$(eff_mode "$_a")" == rw && "$_a" != "$PWD" ]] && ! user_named "$_a"; then add_bind --bind "$_a"; fi
    _a="$(dirname "$_a")"
  done
  add_bind --ro-bind "$SCRIPT_DIR"
fi

# ---- Files that run later ------------------------------------------------------------------
# Some files in a project are not the work product but instructions to tools: git runs
# .git/hooks and what .git/config names (core.hooksPath, core.fsmonitor, aliases, an ssh command),
# Claude Code loads .mcp.json and .claude/, an editor runs .vscode tasks, pre-commit runs what
# .pre-commit-config.yaml lists. A sandboxed process that can write them gets code run LATER, as
# you, outside the sandbox, the next time you use git or open the project. So where they exist
# in a directory that is writable inside, they are bound read-only, unless --no-protect is given.
#   - Their parents (.git, .claude) are bound onto themselves first. That makes them mount points,
#     which the kernel refuses to rename or remove: without it the process could move .git aside
#     and build a new one with its own hooks.
#   - Only what exists at start can be bound. Names that are absent are remembered, and the ones
#     that appear during the run are reported at exit (see report_new_config). That includes
#     .git/commondir and .git/config.worktree, which redirect git to another configuration.
#   - A name that is a symlink, or lies behind one, is not bound (see plain_path) and is named
#     in a note at start.
#   - A path you named yourself with --ro or --rw keeps the mode you gave it.
#   - Only directly under each read-write directory, like the credential masks.
PROTECT_PINS=(.git .claude)
PROTECT_DIRS=(.git/hooks .claude/commands .claude/agents .claude/hooks .claude/skills
              .vscode .devcontainer .husky .codex .opencode)
PROTECT_FILES=(.git/config .git/commondir .git/config.worktree .mcp.json .claude/settings.json
               .claude/settings.local.json .pre-commit-config.yaml opencode.json)
PROTECTED=()   # what was bound read-only, for the in-sandbox README
WATCHED=()     # absent at start; reported if present at exit
LINKED=()      # not bound because a symlink is involved
declare -A PROTECT_SEEN=()
protect_one() {  # $1 = dir|file, $2 = path
  local p="$2"
  [[ -z "${PROTECT_SEEN[$p]:-}" ]] || return 0
  PROTECT_SEEN[$p]=1
  user_named "$p" && return 0
  [[ "$(eff_mode "$p")" == rw ]] || return 0
  if [[ -L "$p" ]] || { [[ -e "$p" ]] && ! plain_path "$p"; }; then LINKED+=("$p"); return 0; fi
  if [[ ! -e "$p" ]]; then WATCHED+=("$p"); return 0; fi
  if { [[ "$1" == dir && -d "$p" ]] || [[ "$1" == file && -f "$p" ]]; }; then
    add_bind --ro-bind "$p"; PROTECTED+=("$p")
  fi
  return 0
}
protect_root() {  # $1 = a directory that is writable inside
  local root="${1%/}" x p hp part skip=" "
  [[ -d "$root" ]] || return 0
  for x in "${PROTECT_PINS[@]}"; do
    p="$root/$x"
    if [[ -L "$p" ]] || { [[ -e "$p" ]] && ! plain_path "$p"; }; then
      LINKED+=("$p"); skip+="$x "
    elif [[ -d "$p" ]]; then
      if [[ "$(eff_mode "$p")" == rw ]] && ! user_named "$p"; then add_bind --bind "$p"; fi
    elif [[ -f "$p" ]]; then
      protect_one file "$p"; skip+="$x "       # .git as a file: a worktree or submodule pointer
    else
      # Not there yet (.git before a clone or `git init`): watched as one name, so that a new
      # repository is reported once and not once per file inside it.
      [[ "$(eff_mode "$p")" == rw ]] && WATCHED+=("$p")
      skip+="$x "
    fi
  done
  for x in "${PROTECT_DIRS[@]}"; do [[ "$skip" == *" ${x%%/*} "* ]] || protect_one dir "$root/$x"; done
  for x in "${PROTECT_FILES[@]}"; do [[ "$skip" == *" ${x%%/*} "* ]] || protect_one file "$root/$x"; done
  # A hooks directory named in .git/config. git itself reads the file (from /, so that no
  # repository on the host is consulted); the value is the sandboxed process's to write, so it is
  # used only as a plain relative path inside this directory, and each directory on the way to
  # it is pinned like .git.
  if [[ "$skip" != *" .git "* && -f "$root/.git/config" ]] && command -v git >/dev/null 2>&1; then
    hp="$(cd / && git config --file "$root/.git/config" --includes --get core.hooksPath 2>/dev/null || true)"
    hp="${hp%/}"
    if [[ -n "$hp" && "$hp" != /* && "$hp" != "~"* && "$hp" != . && "/$hp/" != */../* && "/$hp/" != */./* && "$hp" != *$'\n'* ]]; then
      p="$root"
      while [[ "$hp" == */* ]]; do
        part="${hp%%/*}"; hp="${hp#*/}"; p="$p/$part"
        if [[ -d "$p" && ! -L "$p" ]] && plain_path "$p" && [[ "$(eff_mode "$p")" == rw ]] && ! user_named "$p"; then add_bind --bind "$p"; fi
      done
      protect_one dir "$p/$hp"
    fi
  fi
  return 0
}
report_new_config() {  # at exit: which of the watched names did the command create?
  local x new=()
  for x in ${WATCHED[@]+"${WATCHED[@]}"}; do [[ -e "$x" || -L "$x" ]] && new+=("$x"); done
  [[ ${#new[@]} -gt 0 ]] || return 0
  echo "sandbox-run.sh: the command created files that tools run or load outside the sandbox. Review them before you use git, an editor or an agent in that directory:" >&2
  printf '  %s\n' "${new[@]}" >&2
  return 0
}
if [[ $PROTECT -eq 1 ]]; then
  for root in "$PWD" "${RW_BINDS[@]:-}"; do [[ -n "$root" ]] && protect_root "$root"; done
  if [[ ${#LINKED[@]} -gt 0 ]]; then
    echo "sandbox-run.sh: note: not protected, because a symlink is involved: ${LINKED[*]}" >&2
  fi
fi

while IFS=$'\t' read -r _ _ _flag _path _src; do
  [[ -n "$_path" ]] || continue
  if [[ "$_flag" == --ro-bind-try && -L "$_path" ]]; then
    # bwrap: "Can't mount on symlink destination" -- recreate the link inside instead, and bind
    # its canonical target (skipped if already covered, e.g. ~/.local/share/claude).
    _t="$(realpath -e -- "$_path" 2>/dev/null)" || continue
    BWRAP_ARGS+=(--ro-bind-try "$_t" "$_t" --symlink "$_t" "$_path")
  else
    BWRAP_ARGS+=("$_flag" "${_src:-$_path}" "$_path")
  fi
done < <(printf '%s' "$_bind_lines" | sort -t$'\t' -k1,1n -k2,2n)



# Mask well-known credential locations -- applied LAST, after every --ro/--rw
# above (including --claude/--opencode/--scratch and anything the caller
# added), so this is the unconditional final word, not something a generic
# --rw/--ro on one of these exact paths can quietly re-expose. Checked under
# every root that ends up visible: $PWD (always bound above), $HOME (only
# actually visible if the caller --rw/--ro'd it or it equals $PWD), and every
# --ro/--rw/--scratch/shorthand path -- a project dir passed with --rw can
# carry a .env or .git-credentials just as easily as $PWD can (and it used to
# be the one place these were NOT masked). Deduplicated so a path reached via
# two roots isn't masked twice. Only DIRECT children of a root are checked;
# a .env two levels down inside a project is not, by design.
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
SENSITIVE_HOME_DIRS=(.ssh .aws .azure .kube .config/gcloud .docker .gnupg .config/gh)
SENSITIVE_HOME_FILES=(.git-credentials .config/git/credentials .npmrc .pypirc .netrc .pgpass
                      .vault-token .cache/huggingface/token .env .env.local
                      .bash_history .zsh_history .python_history)
# The agent harnesses' own credentials and config, masked only when that harness is NOT the one
# running: --claude binds the real credentials file through into its per-job config dir and
# --opencode binds its data dir read-write, so each needs its own; the other one's token is just
# another secret in $HOME. (.config/git/credentials, not .config/git: the latter also holds the
# user's identity, which commits need.)
[[ $WANT_CLAUDE -eq 1 ]] || SENSITIVE_HOME_FILES+=(.claude/.credentials.json)
if [[ $WANT_OPENCODE -eq 0 ]]; then
  SENSITIVE_HOME_FILES+=(.local/share/opencode/auth.json)
  SENSITIVE_HOME_DIRS+=(.config/opencode)
fi
# Where the masks apply:
#   - directly under every bound root (a project dir carries a .env or .git-credentials as easily
#     as $HOME does), and
#   - at the same names under $HOME, whenever that location is inside a bound root. That covers a
#     visible $HOME and a bound directory BETWEEN $HOME and the secret: from ~/.config, the
#     direct-children rule looks for ~/.config/.config/gcloud and finds nothing, while
#     ~/.config/gcloud is right there. An unbound $HOME gets no masks at all: masking it made
#     bwrap create empty ~/.ssh, ~/.aws, ... mountpoints, which told the agent which of those
#     the user has.
# A root that IS one of the $HOME credential locations, or lies inside one (`--ro ~/.ssh`, running
# from ~/.aws/sso), is refused: a mask there would hide the very directory that was asked for, and
# no mask would hand over the credentials. So is a read-write root that is ~/.claude itself
# (settings.json hooks run unsandboxed in the next session; its subdirectories remain a
# deliberate --ro/--rw choice, see the header).
HOME_ROOTS=("$HOME_P")
[[ "$HOME" != "$HOME_P" ]] && HOME_ROOTS+=("$HOME")
ALL_ROOTS=()
for root in "$PWD" "${RO_BINDS[@]:-}" "${RW_BINDS[@]:-}" "${RO_TRY_BINDS[@]:-}" "${RW_TRY_BINDS[@]:-}"; do
  [[ -n "$root" ]] && ALL_ROOTS+=("$root")
done
for h in "${HOME_ROOTS[@]}"; do
  for root in "$PWD" "${RO_BINDS[@]:-}" "${RW_BINDS[@]:-}"; do
    [[ -n "$root" ]] || continue
    for s in "${SENSITIVE_HOME_DIRS[@]}" "${SENSITIVE_HOME_FILES[@]}"; do
      if [[ "$root" == "$h/$s" || "$root" == "$h/$s/"* ]]; then
        echo "sandbox-run.sh: refusing to bind $root: it is (or is inside) the credential location $h/$s, which is always masked. Work from, and bind, a project directory instead." >&2
        exit 1
      fi
    done
  done
  # A tool path that is a symlink is bound by its real target (see the bind loop above), so the
  # target gets the same test: a ~/.local/bin/claude pointing into ~/.ssh would otherwise bind
  # that file at its real path, where no mask covers it.
  for root in "${RO_TRY_BINDS[@]:-}"; do
    [[ -n "$root" && -L "$root" ]] || continue
    _t="$(realpath -e -- "$root" 2>/dev/null)" || continue
    for s in "${SENSITIVE_HOME_DIRS[@]}" "${SENSITIVE_HOME_FILES[@]}"; do
      if [[ "$_t" == "$h/$s" || "$_t" == "$h/$s/"* ]]; then
        echo "sandbox-run.sh: refusing to start: $root is a symlink into the credential location $h/$s" >&2
        exit 1
      fi
    done
  done
  for root in "$PWD" "${RW_BINDS[@]:-}"; do
    if [[ -n "$root" && "$root" == "$h/.claude" ]]; then
      echo "sandbox-run.sh: refusing to bind $root read-write: it holds Claude Code's settings (hooks) and credentials. Use --claude for a per-job config, or bind the one subdirectory you need." >&2
      exit 1
    fi
  done
done
declare -A MASKED=()
EMPTY_MASK_FILE=""
mask_dir() {
  [[ -d "$1" && -z "${MASKED[$1]:-}" ]] || return 0
  MASKED[$1]=1
  BWRAP_ARGS+=(--tmpfs "$1")
}
mask_file() {
  [[ -f "$1" && -z "${MASKED[$1]:-}" ]] || return 0
  MASKED[$1]=1
  if [[ -z "$EMPTY_MASK_FILE" ]]; then EMPTY_MASK_FILE="$JOB_DIR/empty"; : > "$EMPTY_MASK_FILE"; fi
  BWRAP_ARGS+=(--ro-bind "$EMPTY_MASK_FILE" "$1")
}
for root in "${ALL_ROOTS[@]}"; do
  [[ -d "$root" ]] || continue
  for d in "${SENSITIVE_HOME_DIRS[@]}"; do mask_dir "$root/$d"; done
  for f in "${SENSITIVE_HOME_FILES[@]}"; do mask_file "$root/$f"; done
done
for h in "${HOME_ROOTS[@]}"; do
  for s in "${SENSITIVE_HOME_DIRS[@]}" "${SENSITIVE_HOME_FILES[@]}"; do
    for root in "${ALL_ROOTS[@]}"; do
      if [[ "$h/$s" == "${root%/}/"* ]]; then mask_dir "$h/$s"; mask_file "$h/$s"; break; fi
    done
  done
done

# Hide every OTHER job's state dir if a bound root happens to contain the state parent (someone
# passed --rw /scratch/$USER despite the header), then bind this job's own cfg/ dirs back on top
# -- later mounts win, so the order here is the whole point. See "Per-job state" in the header.
for root in "$PWD" "${RO_BINDS[@]:-}" "${RW_BINDS[@]:-}" "${RO_TRY_BINDS[@]:-}" "${RW_TRY_BINDS[@]:-}"; do
  [[ -n "$root" ]] || continue
  if [[ "$SANDBOX_STATE_PARENT" == "$root" || "$SANDBOX_STATE_PARENT" == "$root/"* ]]; then
    BWRAP_ARGS+=(--tmpfs "$SANDBOX_STATE_PARENT")
    break
  fi
done
[[ ${#CFG_BINDS[@]} -gt 0 ]] && BWRAP_ARGS+=("${CFG_BINDS[@]}")

[[ ${#LATE_BINDS[@]} -gt 0 ]] && BWRAP_ARGS+=("${LATE_BINDS[@]}")

PROXY_PID=""
PROXY_DIR=""
PROXY_SOCK=""
wait_for_socket() {
  # $1 = what, $2 = socket path, $3 = pid, $4 = log. Up to 10s; returns 1 if the process exits
  # first. The socket lives in a fresh 0700 directory of our own, so a socket there can only be
  # ours.
  for _ in $(seq 1 100); do
    [[ -S "$2" ]] && return 0
    if ! kill -0 "$3" 2>/dev/null; then
      echo "sandbox-run.sh: $1 exited before creating $2. Its last lines:" >&2
      tail -n 8 "$4" 2>/dev/null | sed 's/^/  /' >&2
      return 1
    fi
    sleep 0.1
  done
  echo "sandbox-run.sh: $1 did not create $2 within 10s. Its last lines:" >&2
  tail -n 8 "$4" 2>/dev/null | sed 's/^/  /' >&2
  return 1
}
wait_for_proxy_socket() { wait_for_socket "allowlist proxy" "$1" "$2" "$PROXY_DIR/proxy.log"; }
# The proxy log goes away with the per-job state dir, so the one thing a user needs from it --
# which hosts were refused, i.e. what is missing from --allow -- is printed to stderr at exit.
summarize_proxy_denials() {
  local log="$PROXY_DIR/proxy.log" n
  [[ -n "$PROXY_DIR" && -s "$log" ]] || return 0
  n=$(grep -cE '^\[allowlist_proxy\] ([0-9T:-]+ )?DENY ' "$log" 2>/dev/null || true)
  [[ "${n:-0}" -gt 0 ]] || return 0
  echo "sandbox-run.sh: allowlist proxy denied $n request(s): $(grep -oE '^\[allowlist_proxy\] ([0-9T:-]+ )?DENY (CONNECT|HTTP) [^ ]+' "$log" | awk '{print $NF}' | sed 's/:.*//' | sort | uniq -c | sort -rn | head -8 | awk '{printf "%s%s (%s)", (NR>1?", ":""), $2, $1}')" >&2
  true
}
CSUB_PID=""

# ---- The per-job record -----------------------------------------------------------------------
# What the sandboxed command reached, kept where it cannot touch it: every host the proxy allowed
# or refused, with the time, and the csub jobs recorded while the sandbox ran. One small file per
# run under ~/.agentic-sandbox/records/<date>/, written at exit, and only when there is something
# to record (a run without --allow and --csub has nothing). $HOME is not bound into the sandbox,
# so a later run cannot rewrite an earlier record. SANDBOX_RECORD=off turns it off.
# Records older than 30 days are removed when a new one is written (SANDBOX_RECORD_DAYS; 0 keeps all).
record_csub_jobs() {  # ids of the csub jobs recorded since this sandbox started (best effort)
  local policy="$HOME/.config/csub/broker.toml" state w prev=""
  for w in ${CSUB_BROKER:-}; do [[ "$prev" == --policy ]] && policy="$w"; prev="$w"; done
  state="$(sed -n 's/^[[:space:]]*state_dir[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' "$policy" 2>/dev/null | head -1)"
  state="${state:-$HOME/.csub}"; state="${state/#\~/$HOME}"
  [[ -d "$state/jobs" && -e "$JOB_DIR/.start" ]] || return 0
  { find "$state/jobs" -mindepth 1 -maxdepth 1 -newer "$JOB_DIR/.start" -printf '%f\n' 2>/dev/null | grep -E '^[0-9]' | sort -n | head -200; } || true   # no match is not a failure
}
prune_records() {  # day directories older than SANDBOX_RECORD_DAYS (default 30) go when a record is written
  local keep="${SANDBOX_RECORD_DAYS:-30}" root="$HOME/.agentic-sandbox/records" cutoff d n
  [[ "$keep" =~ ^[0-9]+$ && "$keep" -gt 0 ]] || return 0   # 0: keep everything
  cutoff="$(date -d "$keep days ago" +%Y-%m-%d 2>/dev/null)" || return 0
  [[ "$cutoff" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 0
  for d in "$root"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]; do
    n="${d##*/}"
    # Only what this wrapper made: a real directory named for a day, and older than the cutoff.
    if [[ -d "$d" && ! -L "$d" && "$n" < "$cutoff" ]]; then rm -rf -- "$d" 2>/dev/null; fi
  done
  return 0
}
write_record() {  # $1 = exit status of the command
  [[ "${SANDBOX_RECORD:-on}" != off && ${DRY_RUN:-0} -eq 0 && -n "${JOB_DIR:-}" ]] || return 0
  local plog="" jobs="" dir file
  [[ -n "${PROXY_DIR:-}" && -s "$PROXY_DIR/proxy.log" ]] && grep -qE '^\[allowlist_proxy\] [0-9T:-]+ (ALLOW|DENY|BAD) ' "$PROXY_DIR/proxy.log" 2>/dev/null && plog="$PROXY_DIR/proxy.log"
  if [[ ${WANT_CSUB:-0} -eq 1 ]]; then jobs="$(record_csub_jobs)" || jobs=""; fi
  [[ -n "$plog" || -n "$jobs" ]] || return 0
  dir="$HOME/.agentic-sandbox/records/$(date +%Y-%m-%d)"
  mkdir -p "$dir" 2>/dev/null || return 0
  chmod 700 "$HOME/.agentic-sandbox" "$HOME/.agentic-sandbox/records" 2>/dev/null || true
  prune_records
  file="$dir/${JOB_DIR##*/}.log"
  {
    echo "agentic-sandbox record (sandbox-run.sh)"
    echo "started:   ${RECORD_START:-unknown}"
    echo "ended:     $(date +%Y-%m-%dT%H:%M:%S%z)"
    echo "job:       ${LSB_JOBID:-none}${LSB_JOBINDEX:+ index $LSB_JOBINDEX} on $(hostname -s) as $USER"
    echo "directory: $PWD"
    echo "command:   $(printf '%q ' "${CMD[@]}" | cut -c1-600)"
    echo "exit:      $1"
    echo "allowed hosts: ${ALLOW_HOSTS[*]:-none}"
    echo
    echo "## Network (every request the proxy saw)"
    if [[ -n "$plog" ]]; then
      grep -E '^\[allowlist_proxy\] [0-9T:-]+ (ALLOW|DENY|BAD) ' "$plog" | sed 's/^\[allowlist_proxy\] //; s/ (peer=[^)]*)$//' | head -5000
      [[ "$(grep -cE '^\[allowlist_proxy\] [0-9T:-]+ (ALLOW|DENY|BAD) ' "$plog")" -le 5000 ]] || echo "(more than 5000 lines; the rest is not kept)"
    else
      echo "none"
    fi
    if [[ ${WANT_CSUB:-0} -eq 1 ]]; then
      echo
      echo "## csub jobs recorded while this sandbox ran"
      echo "(taken from csub's own state directory; refused requests are not recorded there, and"
      echo " other sandboxes of yours running at the same time appear here too)"
      if [[ -n "$jobs" ]]; then echo "$jobs"; else echo "none"; fi
    fi
  } > "$file" 2>/dev/null || true
  return 0
}
# The proxy and the broker run outside the sandbox and must be stopped here. A job that ends
# normally does not have its stragglers swept by LSF the way a `bkill`ed one does, so anything
# left running would stay on the node.
cleanup() {
  # $? on entry is the script's exit status (the `exit $?` after bwrap, or 130/140/143 from the
  # signal traps). The denied-host summary is a troubleshooting hint, so it is printed only
  # when the sandboxed command did not succeed: a clean run must not grow an extra stderr line
  # (tests and user pipelines take `2>&1 | tail -1`), and opencode denials in a successful run
  # (its registry.npmjs.org / models.opencode.ai pings) are the allowlist working, not news.
  local rc=$?
  # Nothing in here may end the cleanup early. `set -e` would, on any command that fails, and so
  # would a message written to a stderr whose reader has gone (`... 2>&1 | head`, a closed
  # terminal): bash dies of SIGPIPE in the middle. Either way the broker and the per-job state
  # directory would be left. The status is restored by the `exit` at the end.
  set +e
  trap '' PIPE
  # bkill sends INT, then TERM, then KILL. The first one brings us here; without this the
  # second would run its own `exit` trap in the middle of cleanup and skip the rest of it.
  trap '' TERM INT USR2
  [[ -n "$PROXY_PID" ]] && kill "$PROXY_PID" 2>/dev/null || true
  [[ $rc -ne 0 ]] && summarize_proxy_denials
  declare -F report_new_config >/dev/null && report_new_config
  write_record "$rc" || true   # the record is best effort; nothing in it may stop the cleanup below
  # Wait for the broker to actually exit (csub's serve loop polls its stop flag every 0.5s), so
  # the wrapper never returns with a broker still alive -- an LSF job would otherwise linger,
  # and anything checking for leftovers right after us would see one.
  [[ -n "$CSUB_PID" ]] && { kill "$CSUB_PID" 2>/dev/null; wait "$CSUB_PID" 2>/dev/null; } || true
  # The per-job config copies include ~/.claude.json (account details) -- never leave them.
  # The whole per-job state dir: cfg/ copies (incl. ~/.claude.json account details), proxy
  # socket + log, the empty mask file. The bind-mounted credentials file is NOT inside it on
  # the host side -- bwrap's mount only ever existed in the sandbox's namespace.
  # chmod first: the sandboxed command can write in cfg/, and a directory it left without
  # permissions (chmod 000 around the ~/.claude.json copy) would otherwise survive the rm.
  if [[ -n "${JOB_DIR:-}" && -d "$JOB_DIR" ]]; then
    chmod -R u+rwX "$JOB_DIR" 2>/dev/null || true
    rm -rf "$JOB_DIR" 2>/dev/null || echo "sandbox-run.sh: could not remove $JOB_DIR; remove it by hand (it holds copies of your agent configuration)" >&2
  fi
  exit "$rc"
}
# Replaces early_cleanup (installed right after the per-job dir was made); the signal traps set
# up there keep routing through whichever EXIT trap is current.
trap cleanup EXIT

RELAY_PORT=$((20000 + RANDOM % 20000))

if [[ $WANT_CSUB -eq 1 ]]; then
  CSUB_BROKER="${CSUB_BROKER_CMD:-$(command -v csub-broker || true)}"
  if [[ -z "$CSUB_BROKER" ]]; then
    echo "sandbox-run.sh: --csub needs csub-broker on PATH (or CSUB_BROKER_CMD set); install csub into a venv and activate it" >&2
    exit 1
  fi
  # The client for inside the sandbox: the csub package (and tomli, which it needs on a python
  # without tomllib) bound read-only under /run/csub-lib, plus a shim so plain `csub` works with
  # the sandbox's own python3 (csub is pure Python). Only those two, not the install's whole
  # site-packages: that put every other package of the csub venv on PYTHONPATH for every python
  # in the sandbox, ahead of the python's own.
  CSUB_PY="$(dirname "$(command -v "${CSUB_BROKER%% *}")")/python3"
  [[ -x "$CSUB_PY" ]] || CSUB_PY=python3
  # Host-side Python must never import from the working directory: that is the directory the
  # agent can write, and a csub.py or json.py planted there would run OUTSIDE the sandbox, as
  # you, on the next start. `python -c` and `python -` put the current directory first on the
  # module path, so the csub lookup runs from / (not -I: a csub installed with `pip --user` or
  # found through PYTHONPATH must still be found), and a broker given in the `python -m ...` form
  # is started from / as well. The usual csub-broker console script is not affected (its module
  # path starts at its own bin directory) and keeps the working directory.
  CSUB_SITE="$(cd / && "$CSUB_PY" -c 'import csub, os; print(os.path.dirname(os.path.dirname(csub.__file__)))' 2>/dev/null || true)"
  # Only the csub-broker console script keeps the working directory (its module path starts at
  # its own bin directory, and a relative --policy in the command must still resolve). Every
  # other form (python -m, env python3 -m, uv run, a wrapper script) is started from /.
  CSUB_BROKER_CWD=/
  [[ "$(basename -- "${CSUB_BROKER%% *}")" == csub-broker ]] && CSUB_BROKER_CWD=.
  if [[ -z "$CSUB_SITE" || ! -d "$CSUB_SITE/csub" ]]; then
    echo "sandbox-run.sh: --csub: cannot locate the csub package next to $CSUB_BROKER" >&2
    exit 1
  fi
  CSUB_DIR="$JOB_DIR/csub"
  mkdir -p "$CSUB_DIR/bin"
  printf '%s\n' '#!/bin/sh' 'exec python3 -m csub.cli "$@"' > "$CSUB_DIR/bin/csub"
  chmod 700 "$CSUB_DIR/bin/csub"
  CSUB_SOCK="$CSUB_DIR/csub.sock"
  # CSUB_MOUNTS: what this sandbox can see, in csub's "path:mode,..." form, always derived from
  # $PWD and the --rw/--ro binds that are not under $HOME or /scratch (csub refuses home, and its
  # policy forbids scratch as a root). csub rejects overlapping mounts, so a path nested under
  # another listed path is dropped (the outer one carries it): $PWD inside a --rw project root
  # is the common case.
  # Effective mode per path, as the binds above resolve it: $PWD read-write, then --ro, then --rw
  # (the last one named wins for one path).
  declare -A _mmode=()
  _paths=()
  _add_mount() {
    # The list is handed on as path:mode,path:mode. A comma or colon inside a path would be read
    # as a separator and put a directory this sandbox does not have into the envelope.
    if [[ "$1" == *,* || "$1" == *:* ]]; then
      echo "sandbox-run.sh: --csub: '$1' contains a comma or a colon, which the mount list passed to csub cannot carry; use a path without them" >&2
      exit 1
    fi
    [[ -n "${_mmode[$1]+x}" ]] || _paths+=("$1"); _mmode[$1]="$2"
  }
  _add_mount "$PWD" rw
  for p in "${RO_BINDS[@]:-}"; do [[ -n "$p" && "$p" != "$HOME_P" && "$p" != "$HOME_P/"* && "$p" != /scratch/* ]] && _add_mount "$p" ro; done
  for p in "${RW_BINDS[@]:-}"; do [[ -n "$p" && "$p" != "$HOME_P" && "$p" != "$HOME_P/"* && "$p" != /scratch/* ]] && _add_mount "$p" rw; done
  # csub cannot express a read-only directory inside a read-write one (nested entries are
  # dropped, the outer one carries them). Passing the outer one as rw would give child jobs
  # write access this sandbox does not have, so it goes to them READ-ONLY instead, with a note:
  # a child job needs a read-write cwd, so submissions from there will be refused by csub.
  DERIVED_MOUNTS=""
  for cp in "${_paths[@]}"; do
    nested=0
    for op in "${_paths[@]}"; do
      [[ "$op" != "$cp" && "$cp" == "${op%/}/"* ]] && { nested=1; break; }
    done
    [[ $nested -eq 1 ]] && continue
    m="${_mmode[$cp]}"
    if [[ "$m" == rw ]]; then
      for r in "${RO_BINDS[@]:-}"; do
        [[ -n "$r" && "$r" == "${cp%/}/"* ]] || continue
        [[ " ${RW_BINDS[*]:-} " == *" $r "* ]] && continue
        echo "sandbox-run.sh: --csub: $cp is passed to child jobs read-only, because $r inside it is read-only here and csub cannot express that. Child jobs need a read-write working directory outside $cp." >&2
        m=ro
        break
      done
    fi
    DERIVED_MOUNTS="${DERIVED_MOUNTS:+$DERIVED_MOUNTS,}$cp:$m"
  done
  # A preset $CSUB_MOUNTS may only NARROW that list: every entry must be one of the derived
  # mounts or a path under one, and not rw where the sandbox has it ro. It is checked here, not
  # left to the broker, because the same list becomes the envelope below -- an envelope wider
  # than the sandbox would let child jobs reach what the sandbox itself cannot, which is the one
  # thing the envelope exists to prevent. (Bare "path" means rw, as in csub.)
  if [[ -n "${CSUB_MOUNTS:-}" ]]; then
    IFS=, read -ra _pre <<< "$CSUB_MOUNTS"
    IFS=, read -ra _der <<< "$DERIVED_MOUNTS"
    for e in "${_pre[@]}"; do
      [[ -n "$e" ]] || continue
      ep="${e%:*}"; em="${e##*:}"; [[ "$em" == "$ep" ]] && em=rw
      # Compared as text below, so "/proj/../other" must not pass for something under /proj.
      if [[ "$ep" != /* || "/$ep/" == */../* || "/$ep/" == */./* ]]; then
        echo "sandbox-run.sh: --csub: CSUB_MOUNTS entry '$e' is not a plain absolute path" >&2
        exit 1
      fi
      ok=0
      for d in "${_der[@]}"; do
        dp="${d%:*}"; dm="${d##*:}"
        [[ "$ep" == "$dp" || "$ep" == "$dp/"* ]] || continue
        [[ "$em" == ro || "$dm" == rw ]] && { ok=1; break; }
      done
      if [[ $ok -eq 0 ]]; then
        echo "sandbox-run.sh: --csub: CSUB_MOUNTS entry '$e' is not within this sandbox's mounts ($DERIVED_MOUNTS). A preset CSUB_MOUNTS may only narrow them; add the path with --rw/--ro instead." >&2
        exit 1
      fi
    done
  else
    CSUB_MOUNTS="$DERIVED_MOUNTS"
  fi
  # Envelope (--envelope-mount/--envelope-host, csub #13): every broker request is bounded by
  # this sandbox's own mounts and --allow hosts, so a client cannot claim a directory it cannot
  # see (CSUB_MOUNTS and --cwd are otherwise limited only by the policy's allowed_roots). Two
  # cases would leave the broker bounded by the policy alone, and both are refused rather than
  # warned about -- nobody reads a warning in an unattended run: a csub without the flags, and an
  # envelope with nothing in it (csub reads "no --envelope-* flags" as "no envelope", not as "an
  # envelope that allows nothing"). CSUB_ENVELOPE=off accepts a policy-only broker explicitly.
  CSUB_ENV_ARGS=()
  if [[ "${CSUB_ENVELOPE:-on}" != off ]]; then
    if ! (cd "$CSUB_BROKER_CWD" && exec $CSUB_BROKER --help) 2>&1 | grep -q -- --envelope-mount; then
      echo "sandbox-run.sh: --csub: this csub-broker has no --envelope-mount (needs csub with #13), so requests would be bounded by the policy only. Upgrade csub, or set CSUB_ENVELOPE=off to accept that." >&2
      exit 1
    fi
    IFS=, read -ra _em <<< "$CSUB_MOUNTS"
    for m in "${_em[@]:-}"; do [[ -n "$m" ]] && CSUB_ENV_ARGS+=(--envelope-mount "$m"); done
    for h in "${ALLOW_HOSTS[@]:-}"; do [[ -n "$h" ]] && CSUB_ENV_ARGS+=(--envelope-host "$h"); done
    if [[ ${#CSUB_ENV_ARGS[@]} -eq 0 ]]; then
      echo "sandbox-run.sh: --csub: nothing to bound child jobs to (no mounts outside \$HOME and /scratch, no --allow hosts), and csub treats an empty envelope as no envelope. Add the --rw/--ro path or --allow host the child jobs may use, or set CSUB_ENVELOPE=off to run the broker bounded by the policy only." >&2
      exit 1
    fi
  else
    echo "sandbox-run.sh: --csub: CSUB_ENVELOPE=off -- requests are bounded by the policy only" >&2
  fi
  CSUB_PROBE_JSON="$CSUB_DIR/probe.json"
  if [[ $DRY_RUN -eq 0 ]]; then
    (cd "$CSUB_BROKER_CWD" && exec $CSUB_BROKER ${CSUB_ENV_ARGS[@]+"${CSUB_ENV_ARGS[@]}"} --serve "$CSUB_SOCK") > "$CSUB_DIR/broker.log" 2>&1 &
    CSUB_PID=$!
    wait_for_socket "csub-broker" "$CSUB_SOCK" "$CSUB_PID" "$CSUB_DIR/broker.log" || exit 1
    # One probe for the in-sandbox README's policy summary (same request the agent's `csub probe` makes).
    echo '{"protocol":1,"op":"probe"}' | (cd "$CSUB_BROKER_CWD" && exec $CSUB_BROKER ${CSUB_ENV_ARGS[@]+"${CSUB_ENV_ARGS[@]}"}) > "$CSUB_PROBE_JSON" 2>/dev/null || true
  fi
  # PATH: bwrap takes the LAST --setenv, so this one must carry the --claude/--opencode CLI
  # dirs ($PATH_PREPEND, set above) as well as the csub shim, or --csub would drop them.
  BWRAP_ARGS+=(
    --ro-bind "$CSUB_SOCK" /run/csub.sock
    --ro-bind "$CSUB_SITE/csub" /run/csub-lib/csub
    --ro-bind "$CSUB_DIR/bin" /run/csub-bin
    --setenv CSUB_TRANSPORT unix --setenv CSUB_SOCKET /run/csub.sock
    --setenv CSUB_MOUNTS "$CSUB_MOUNTS"
    --setenv PYTHONPATH /run/csub-lib
    --setenv PATH "/run/csub-bin:${PATH_PREPEND}${PATH}"
  )
  [[ -d "$CSUB_SITE/tomli" ]] && BWRAP_ARGS+=(--ro-bind "$CSUB_SITE/tomli" /run/csub-lib/tomli)
fi


# Environment description FOR THE AGENT, generated from this invocation's actual configuration
# and bound read-only at /run/sandbox/README.md (also $SANDBOX_README). A sandboxed agent
# cannot read this repo's README, and left to itself it probes around (confirmed live: an agent
# spent three jobs guessing image names GHCR couldn't be asked for). With --claude a pointer is
# appended to the per-job COPY of CLAUDE.md, so Claude Code reads it at session start; the copy
# dies with the job, the real ~/.claude/CLAUDE.md is never touched.
write_sandbox_readme() {
  SANDBOX_README_FILE="$JOB_DIR/README.md"
  {
    echo "# This sandbox"
    echo
    echo "You are running inside a sandbox started by sandbox-run.sh (agentic-sandbox) on $(hostname),"
    echo "LSF job ${LSB_JOBID:-none}, as user $USER. Everything below describes THIS session."
    echo
    echo "## Filesystem"
    echo
    echo "- $PWD (read-write; your working directory)"
    for p in "${RW_BINDS[@]:-}"; do [[ -n "$p" && "$p" != "$PWD" ]] && echo "- $p (read-write)"; done
    for p in "${RO_BINDS[@]:-}"; do [[ -n "$p" ]] && echo "- $p (read-only)"; done
    for p in "${RO_TRY_BINDS[@]:-}"; do [[ -n "$p" && -e "$p" ]] && echo "- $p (read-only; a tool install)"; done
    [[ -n "${CLAUDE_CFG:-}" ]] && echo "- $CLAUDE_CFG (read-write; Claude Code config copy, CLAUDE_CONFIG_DIR)"
    [[ -n "${OPENCODE_XDG_CONFIG:-}" ]] && echo "- $OPENCODE_XDG_CONFIG (read-write; opencode config copy)"
    echo "- /tmp (private tmpfs, TMPDIR), /usr /bin /lib /lib64 /sbin /etc (read-only system)"
    echo "- Not available: the home directory (unless listed above), other users' data, anything not listed."
    echo "- Credential files directly under any listed directory (${SENSITIVE_HOME_DIRS[*]}"
    echo "  ${SENSITIVE_HOME_FILES[*]}) appear EMPTY on purpose. Nothing is wrong; do not try to work around it."
    echo
    echo "## Network"
    echo
    if [[ ${#ALLOW_HOSTS[@]} -gt 0 ]]; then
      echo "- Only these hosts are reachable, over HTTP(S) through a proxy already configured in http_proxy/https_proxy:"
      for h in "${ALLOW_HOSTS[@]}"; do echo "  - $h (and its subdomains)"; done
      echo "- Everything else (other hosts, raw TCP, ssh, package registries not listed) fails. Do not retry or look for a route; ask the user."
    elif [[ $JOBNET_INNER -eq 1 ]]; then
      echo "- This is one worker of a multi-node job. Only the other nodes of this job are reachable:"
      for a in $SANDBOX_NET_PEERS; do echo "  - $a"; done
      [[ -n "$SANDBOX_NET_PEERS" ]] || echo "  - (none: this job has one node)"
      echo "- This node's address is $SANDBOX_NET_MYIP, on interface $SANDBOX_NET_IF. Use addresses, or the names in /etc/hosts; there is no DNS."
      echo "- Everything else (other hosts, the internet, package registries) is refused at once ('connection refused'). Do not retry or look for a route."
      echo "- Other nodes can connect to this one on ports ${SANDBOX_NET_PORTS% *}-${SANDBOX_NET_PORTS#* }${LISTEN_PORTS[*]:+ and on ${LISTEN_PORTS[*]}}. A listener that lets the system pick its port (port 0) gets a reachable one. A fixed port must be in the lowest 500 of that range; the system hands out the rest."
    elif [[ $WANT_HOSTNET -eq 1 ]]; then
      echo "- This is one worker of a multi-node job, on the node's own network. Connections are not limited by this sandbox."
      echo "- Use the network for the job's own nodes only. Do not download or upload anything from here."
    else
      echo "- No network at all. Every connection attempt fails by design."
    fi
    if [[ $WANT_IB -eq 1 ]]; then
      echo "- InfiniBand (RDMA verbs) devices are available in /dev/infiniband."
    fi
    echo
    echo "## Environment"
    echo
    echo "- Started from an EMPTY environment. Only these variables came from the host: ${PASSTHROUGH_ENV[*]}${PASS_ENV[*]:+ ${PASS_ENV[*]}}."
    echo "- Any API key or token you need must have been passed in explicitly by the user (--env NAME); if it is not set, ask, do not search for it."
    echo
    echo "## Cluster jobs"
    echo
    if [[ $WANT_CSUB -eq 1 ]]; then
      echo "- You cannot run bsub/bjobs/bkill. Use \`csub\` instead; it submits LSF jobs through a broker that enforces the user's policy."
      echo "  Each child job runs inside its own sandbox (same mechanism as this one) and can itself call csub."
      echo "- \`csub probe\` prints the policy. \`csub --json probe\` for machine-readable output (--json goes BEFORE the subcommand)."
      echo "- \`csub submit --walltime <min> [--cpus N] [--mem 32G] [--gpus 1 -q <gpu queue>] [--image <image>] [--wait] -- <command>\`,"
      echo "  then \`csub status\`, \`csub logs <id>\`, \`csub kill <id>\`. A child's output lands in <cwd>/.csub/jobs/<id>/stdout and stderr."
      echo "- Jobs are refused with a policy_violation error when they ask for something the policy does not allow. Read the message and adjust; do not probe or guess."
      if [[ -n "${CSUB_PROBE_JSON:-}" && -s "$CSUB_PROBE_JSON" ]]; then
        python3 -I - "$CSUB_PROBE_JSON" <<'PY' 2>/dev/null || true
import json, sys
try:
    p = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
if not p.get("ok"):
    sys.exit(0)
lim = p.get("limits", {})
print("- Policy summary (authoritative source: csub probe):")
print(f"  - default image: {p.get('default_image')}")
imgs = p.get("allowed_images") or []
if imgs:
    if any("*" in i or "?" in i for i in imgs):
        print("  - --image must match one of these PATTERNS; there is no registry to query, so if you need an image other than the default, ask the user for its exact name rather than guessing:")
    else:
        print("  - images you may name with --image (these are the ONLY ones; there is no registry to query):")
    for i in imgs: print(f"    - {i}")
roots = p.get("allowed_roots") or []
if roots: print(f"  - jobs may mount paths under: {', '.join(roots)}; your cwd must be inside a read-write mount under one of these")
hosts = p.get("allowed_hosts") or []
print(f"  - hosts a job may --allow: {', '.join(hosts) if hosts else 'none'}")
qs = p.get("queues") or {}
if qs:
    print("  - queues:")
    for n, q in qs.items():
        g = f", GPU queue, {q.get('slots_per_gpu')} slots per GPU" if q.get("gpu") else ""
        print(f"    - {n}: {q.get('mem_per_slot_mb')} MB per slot, max walltime {q.get('max_walltime_min')} min{g}")
print(f"  - limits: max {lim.get('max_slots')} slots, {lim.get('max_gpus')} GPUs, {lim.get('max_walltime_min')} min walltime, {lim.get('max_pending_per_session') or 'unlimited'} pending jobs per session, est. cost cap ${lim.get('max_estimated_cost_usd')} per job")
print("  - memory is requested as slots: slots = max(cpus, ceil(mem / mem_per_slot)); the cluster ignores any other memory request")
PY
      fi
    else
      echo "- You cannot submit cluster jobs from here (no bsub, no csub). Run work in this sandbox or ask the user."
    fi
    echo
    echo "## Tools"
    echo
    [[ $WANT_CLAUDE -eq 1 ]] && echo "- Claude Code is available as \`claude\` (per-job config at \$CLAUDE_CONFIG_DIR; settings/MCP edits do not persist past this session)."
    [[ $WANT_OPENCODE -eq 1 ]] && echo "- opencode is available as \`opencode\`; name the model explicitly: \`--model ${SANDBOX_OPENCODE_MODEL:-litellm/kimi-k3}\` (or \`-m\`)."
    if [[ ${#PROTECTED[@]} -gt 0 ]]; then
      echo "- These are read-only here, because tools run or load them later outside the sandbox: ${PROTECTED[*]}. Do not try to change, move or replace them. \`git config\` in such a repository fails; commits work, your git identity is already set in GIT_AUTHOR_* and GIT_COMMITTER_*. If the task needs one of them changed, say so in your answer and the user will do it."
    fi
    [[ $PROTECT -eq 1 ]] && echo "- If you create .mcp.json, .vscode, .claude/ settings, git hooks or similar files, the user is told at exit."
    echo "- /tmp is private to this sandbox and discarded at exit. Keep results in the read-write directories above."
    echo "- When the sandbox exits, the user is shown which hosts were denied, if the command failed."
  } > "$SANDBOX_README_FILE"
  BWRAP_ARGS+=(--ro-bind "$SANDBOX_README_FILE" /run/sandbox/README.md --setenv SANDBOX_README /run/sandbox/README.md)
  if [[ $WANT_CLAUDE -eq 1 && -n "${CLAUDE_CFG:-}" ]]; then
    printf '\n# Sandbox\n\nThis session runs inside a sandbox. Read %s FIRST: it lists exactly which directories you can write to, which hosts you can reach, and whether and how you can submit cluster jobs. Do not probe for other paths, hosts, or images; what is not listed there does not exist for you.\n' /run/sandbox/README.md >> "$CLAUDE_CFG/CLAUDE.md"
  fi
}

write_sandbox_readme

# bwrap passes every open descriptor through to the sandboxed process, and a launching shell or
# LSF job script usually has a few open beyond 0-2 (a redirected log, a lock file, bash's own
# fd for a sourced script). Close them in a subshell right before exec'ing bwrap: 0-2 stay, and
# the wrapper's own descriptors (the script on 255, say) are untouched in the parent.
dry_run_print() {  # "$@" = everything after `bwrap`
  local i n
  echo "sandbox-run.sh: dry run. No sandbox, proxy or broker was started. A real run would do this:"
  if [[ ${#ALLOW_HOSTS[@]} -gt 0 ]]; then
    echo; echo "On the host, the allowlist proxy:"
    printf '  python3 -I %q %q' "$SCRIPT_DIR/allowlist_proxy.py" "$PROXY_SOCK"; printf ' %q' "${ALLOW_HOSTS[@]}"; echo
  fi
  if [[ $WANT_CSUB -eq 1 ]]; then
    echo; echo "On the host, the csub broker:"
    echo "  $CSUB_BROKER ${CSUB_ENV_ARGS[*]:-} --serve $CSUB_SOCK"
  fi
  if [[ $JOBNET_DRY -eq 1 ]]; then
    echo; echo "On the host, the network relay (pasta), which runs this script again in a network namespace of its own:"
    printf ' '; printf ' %q' "${JOBNET_PASTA[@]}"; echo
    echo "In that namespace, before the sandbox starts: every route is removed and one host route is added per other node of the job (${SANDBOX_NET_PEERS:-none})."
    echo "Ports open to the job's other nodes: ${SANDBOX_NET_PORTS% *}-${SANDBOX_NET_PORTS#* }${LISTEN_PORTS[*]:+ and ${LISTEN_PORTS[*]}}."
  fi
  [[ $WANT_HOSTNET -eq 1 ]] && { echo; echo "The network: the node's own (--host-net); no helper is started."; }
  echo; echo "The sandbox:"
  printf '  bwrap'; printf ' %q' "$@"; echo
  echo; echo "Environment of the command (handed to bwrap as --args 9; values passed with --env are not shown):"
  for ((i = 0; i + 2 < ${#ENV_ARGS[@]}; i += 3)); do
    n="${ENV_ARGS[i + 1]}"
    if [[ " ${PASS_ENV[*]:-} " == *" $n "* ]]; then echo "  $n=<set, not shown>"; else echo "  $n=${ENV_ARGS[i + 2]}"; fi
  done
  echo; echo "Per-job state would be in $JOB_DIR (removed at exit)."
}
run_bwrap() {
  local fd p
  # Each path was made physical and checked when the arguments were read. Seconds have passed
  # since (the proxy and the broker were started); look once more, so that a directory swapped
  # for a symlink in between is not mounted under the name that was checked.
  for p in "$PWD" "${RO_BINDS[@]:-}" "${RW_BINDS[@]:-}"; do
    [[ -n "$p" ]] || continue
    if [[ "$(realpath -e -- "$p" 2>/dev/null)" != "$p" ]]; then
      echo "sandbox-run.sh: $p changed while the sandbox was being set up (it is no longer the directory that was checked); not starting" >&2
      exit 1
    fi
  done
  # The environment for the command, NUL-separated, on descriptor 9 (see ENV_ARGS above). printf
  # is a builtin, so the values are in no process's command line. bwrap reads the descriptor and
  # closes it; it is not passed on to the command.
  exec 9< <(printf '%s\0' ${ENV_ARGS[@]+"${ENV_ARGS[@]}"})
  for fd in /proc/self/fd/*; do
    fd="${fd##*/}"
    if [[ "$fd" -gt 2 && "$fd" -ne 9 ]]; then eval "exec $fd>&-" 2>/dev/null || true; fi
  done
  # --clearenv empties the environment of the COMMAND only. bwrap itself stays inside the sandbox
  # as PID 1, and the environment it was started with is readable there at /proc/1/environ: every
  # variable of the job, API keys and tokens included. So bwrap is started with an environment of
  # its own that holds only the job's id and array index (not secrets; they let someone on the
  # node trace a bwrap process back to its job). What the command gets is unchanged: that comes
  # from the --setenv arguments, which were read from this script's environment above.
  local bwrap_bin keep=()
  bwrap_bin="$(command -v bwrap)" || { echo "sandbox-run.sh: bwrap not found on PATH" >&2; exit 127; }
  [[ -n "${LSB_JOBID:-}" ]] && keep+=("LSB_JOBID=$LSB_JOBID")
  [[ -n "${LSB_JOBINDEX:-}" ]] && keep+=("LSB_JOBINDEX=$LSB_JOBINDEX")
  exec env -i ${keep[@]+"${keep[@]}"} "$bwrap_bin" "$@"
}

if [[ ${#ALLOW_HOSTS[@]} -gt 0 ]]; then
  # A fresh 0700 directory holds the socket and its log: nobody else on the node can reach the
  # socket (it is created 0755), and no one else's socket can stand in for ours. Node-local on
  # purpose: binding a Unix socket on NFS works here but is fragile.
  PROXY_DIR="$JOB_DIR/proxy"
  mkdir -p "$PROXY_DIR"
  PROXY_SOCK="$PROXY_DIR/proxy.sock"
  # -I: no working directory, no PYTHONPATH, no user site on the module path. The proxy uses the
  # standard library only, and it runs on the host from a directory the agent may be able to write.
  if [[ $DRY_RUN -eq 0 ]]; then
  python3 -I "$SCRIPT_DIR/allowlist_proxy.py" "$PROXY_SOCK" "${ALLOW_HOSTS[@]}" \
    > "$PROXY_DIR/proxy.log" 2>&1 &
  PROXY_PID=$!
  # Wait for the socket to actually exist before bind-mounting it, and fail closed if the
  # proxy died (bad allowlist, python missing). A fixed `sleep 1` raced a slow interpreter
  # start on a busy node, and bwrap then failed with "Can't find source path".
  wait_for_proxy_socket "$PROXY_SOCK" "$PROXY_PID" || exit 1
  fi
  BWRAP_ARGS+=(
    --ro-bind "$SCRIPT_DIR/relay.py" /opt/sandbox-relay.py
    --ro-bind "$PROXY_SOCK" /run/sandbox-proxy.sock
  )
  # The relay is waited for, not slept on: up to 5s of connect attempts to its port (bash's
  # /dev/tcp, so nothing beyond bash is needed inside), then the command runs either way -- a
  # relay that never came up shows as connection refused on the first request, as before.
  INNER_CMD=(
    /bin/bash -c
    'python3 /opt/sandbox-relay.py 127.0.0.1 '"$RELAY_PORT"' /run/sandbox-proxy.sock & for _ in $(seq 1 50); do (exec 3<>/dev/tcp/127.0.0.1/'"$RELAY_PORT"') 2>/dev/null && break; sleep 0.1; done; export http_proxy=http://127.0.0.1:'"$RELAY_PORT"' https_proxy=http://127.0.0.1:'"$RELAY_PORT"' HTTP_PROXY=http://127.0.0.1:'"$RELAY_PORT"' HTTPS_PROXY=http://127.0.0.1:'"$RELAY_PORT"' no_proxy=127.0.0.1,localhost NO_PROXY=127.0.0.1,localhost; exec "$@"'
    bash
    "${CMD[@]}"
  )
  # bwrap runs in a subshell (run_bwrap exec's it there), NOT exec'd from this shell: exec would
  # replace this script's own process image, which would skip the `trap cleanup EXIT` and leak
  # the host-side allowlist_proxy.py process. The subshell is a normal foreground child, so the
  # trap fires once it returns, and its exit code is propagated explicitly.
  if [[ $DRY_RUN -eq 1 ]]; then dry_run_print "${BWRAP_ARGS[@]}" -- "${INNER_CMD[@]}"; exit 0; fi
  (run_bwrap "${BWRAP_ARGS[@]}" -- "${INNER_CMD[@]}")
  exit $?
else
  # Same shape: the EXIT trap must run to delete the per-job config copies and the empty mask
  # file. Exit code is propagated.
  if [[ $DRY_RUN -eq 1 ]]; then dry_run_print "${BWRAP_ARGS[@]}" -- "${CMD[@]}"; exit 0; fi
  (run_bwrap "${BWRAP_ARGS[@]}" -- "${CMD[@]}")
  exit $?
fi
