#!/bin/bash
# test-multinode.sh -- sandbox-run.sh --host-net, across two nodes.
#
# The job script of a two-node LSF job. Submit it from a directory that is on shared storage and
# outside your home directory; it needs no GPU:
#
#   cd /groups/<lab>/<some project dir>
#   bsub -q short -n 2 -R "span[ptile=1]" -W 15 -o multinode-%J.out /path/to/tests/test-multinode.sh
#
# It starts one sandbox per node with blaunch, as a multi-node launcher does, and checks that the
# two reach each other while the home directory and the environment stay hidden. --ib is not
# covered: it needs InfiniBand nodes and a program that uses them.
#
# The same checks run against podman-run.sh with SANDBOX_WRAPPER=podman-run.sh in the environment
# of the bsub command (allow -W 30: every container start checks the image).
set -uo pipefail
export SANDBOX_RECORD=off   # no per-job record in ~/.agentic-sandbox/records for a test run

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd -P)"
WRAPPER="${SANDBOX_WRAPPER:-sandbox-run.sh}"
W="$SCRIPT_DIR/../scripts/$WRAPPER"
PODMAN=0; [[ "$WRAPPER" == podman-run.sh ]] && PODMAN=1
[[ -x "$W" ]] || { echo "no such wrapper: $W"; exit 2; }
PROBE="$SCRIPT_DIR/multinode-probe.py"

[[ -n "${LSB_DJOB_HOSTFILE:-}" ]] || { echo "run this as an LSF job (see the header)"; exit 2; }
mapfile -t HOSTS < <(sort -u "$LSB_DJOB_HOSTFILE")
[[ ${#HOSTS[@]} -ge 2 ]] || { echo "this job has one node; ask for two: -n 2 -R \"span[ptile=1]\""; exit 2; }

TR="$PWD/.test-multinode-$$"
mkdir "$TR" || exit 2
cd "$TR" || exit 2
STATE="/scratch/$USER/.agentic-sandbox"
cleanup() { cd /; rm -rf "$TR"; }
trap cleanup EXIT
# sandbox-run.sh binds the working directory by itself; podman-run.sh mounts only what it is told.
MNT=(--ro "$SCRIPT_DIR"); [[ $PODMAN -eq 1 ]] && MNT+=(--rw "$TR")
START=5; [[ $PODMAN -eq 1 ]] && START=45   # seconds until the sandboxed command is surely running

PASS=0 FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL + 1)); }
check() { if "${@:2}" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
refuses() {  # refuses "what" "expected text" wrapper-args...
  local what=$1 text=$2 out rc; shift 2
  out="$("$W" "$@" 2>&1)"; rc=$?
  if [[ $rc -ne 0 && "$out" == *"$text"* ]]; then ok "refuses $what"; else bad "refuses $what (exit $rc: ${out:0:120})"; fi
}
left() { compgen -G "$STATE/$LSB_JOBID-*" | wc -l; }

ADDRS=()
for h in "${HOSTS[@]}"; do ADDRS+=("$(getent ahostsv4 "$h" | awk 'NR==1{print $1}')"); done
ALL="$(IFS=,; echo "${ADDRS[*]}")"
OUTSIDER="$(getent ahostsv4 "${LSB_SUB_HOST:-$(hostname)}" | awk 'NR==1{print $1}')"
echo "$WRAPPER, job $LSB_JOBID, nodes ${HOSTS[*]} ($ALL), outsider $OUTSIDER"

# Something that exists in the home directory, which no sandbox here may show.
HIDDEN="$(find "$HOME" -mindepth 1 -maxdepth 1 2>/dev/null | head -1)"
[[ -n "$HIDDEN" && -n "$OUTSIDER" ]] || { echo "nothing in \$HOME to look for, or no outside host"; exit 2; }

echo "1. one sandbox per node"
cat > node.sh <<EOF
#!/bin/bash
cd "$TR" || exit 1
export MN_CANARY=must-not-get-in
exec "$W" --host-net ${MNT[*]} -- python3 "$PROBE" "$TR" "\$1" "$ALL" "$HIDDEN"
EOF
chmod +x node.sh
for i in "${!HOSTS[@]}"; do blaunch -z "${HOSTS[$i]}" "$TR/node.sh" "${ADDRS[$i]}" > "probe.$i.out" 2>&1 & done
wait
cat probe.*.out > probe.out
n=${#HOSTS[@]}
count() { grep -c "^$1 " probe.out || true; }
[[ "$(count PEER_OUT_OK)" -eq $((n * (n - 1))) ]] && ok "every node connects to every other node" || bad "connections to the other nodes ($(count PEER_OUT_OK) of $((n * (n - 1))))"
[[ "$(count PEER_IN_OK)" -eq $((n * (n - 1))) ]] && ok "every node accepts from every other node" || bad "connections from the other nodes ($(count PEER_IN_OK) of $((n * (n - 1))))"
[[ "$(count NAME_OK)" -eq $n ]] && ok "every node's own name resolves to its address, as on the node" || bad "the node's own name"
[[ "$(count HOME_HIDDEN)" -eq $n ]] && ok "the home directory stays hidden" || bad "the home directory is visible"
[[ "$(count ENV_HIDDEN)" -eq $n ]] && ok "the caller's environment stays out" || bad "the caller's environment came in"
# Seen from outside the sandbox: what a worker wrote belongs to the user.
[[ "$(find . -maxdepth 1 -name 'port.*' -user "$(id -u)" | wc -l)" -eq $n ]] && ok "files written inside belong to the user" || bad "file ownership: $(stat -c '%u %n' port.* 2>&1 | tr '\n' ';')"
[[ $FAIL -eq 0 ]] || sed 's/^/      /' probe.out

echo "2. exit status, stdin and the description for the agent"
echo "from stdin" | "$W" --host-net -- bash -c 'read -r x; [[ "$x" == "from stdin" ]] || exit 3; grep -q "on the node.s own network" "$SANDBOX_README" || exit 4; exit 7' 2>/dev/null
[[ $? -eq 7 ]] && ok "exit status, stdin and \$SANDBOX_README" || bad "exit status, stdin or \$SANDBOX_README"

rcs=""; for _ in 1 2 3 4 5 6; do "$W" --host-net -- bash -c 'exit 7' </dev/null >/dev/null 2>&1; rcs+="$? "; done
[[ "$rcs" == "7 7 7 7 7 7 " ]] && ok "exit status of a very short command, six times" || bad "exit status of a very short command: $rcs"

echo "3. refusals"
refuses "--host-net with --allow" "not with --allow" --host-net --allow pypi.org -- true
refuses "--host-net with --csub" "not with --csub" --host-net --csub -- true
refuses "--host-net with --claude" "not with --claude" --host-net --claude -- true
refuses "--host-net with --opencode" "not with --claude or --opencode" --host-net --opencode -- true
refuses "--claude before --host-net" "not with --claude" --claude --host-net -- true
refuses "--ib with --claude" "--ib: not with --claude" --ib --claude -- true
refuses "--ib with --csub" "--ib: not with --csub" --ib --csub -- true
refuses "--ib with --opencode" "--ib: not with --claude or --opencode" --ib --opencode -- true
refuses "--ib with --allow" "--ib: not with --allow" --ib --allow pypi.org -- true
# --host-net --ib is the pair for an InfiniBand queue: never refused as a combination. (On a node
# without InfiniBand the only complaint is the missing device.)
out="$("$W" --dry-run --host-net --ib -- true 2>&1)"; rc=$?
if [[ -d /dev/infiniband ]]; then
  [[ $rc -eq 0 && "$out" == *infiniband* ]] && ok "--host-net with --ib is accepted" || bad "--host-net with --ib (exit $rc: ${out:0:120})"
else
  [[ $rc -ne 0 && "$out" == *"has no /dev/infiniband"* && "$out" != *"not with"* ]] && ok "--host-net with --ib: only the missing device is reported" || bad "--host-net with --ib (exit $rc: ${out:0:120})"
fi

echo "4. the network, with and without --host-net"
# The command inside reports what it found, so that a wrapper that did not start cannot pass.
reach() { "$W" "$@" -- bash -c "(exec 3<>/dev/tcp/$OUTSIDER/22) 2>/dev/null && echo open || echo closed" 2>/dev/null </dev/null | tail -1; }
r="$(reach)"; [[ "$r" == closed ]] && ok "default sandbox: no network" || bad "default sandbox: no network (got '$r')"
r="$(reach --host-net)"; [[ "$r" == open ]] && ok "--host-net: a host outside the job is reachable" || bad "--host-net: a host outside the job (got '$r')"

echo "5. stopping"
# TERM to the wrapper's process group, which is what bkill and the walltime kill do.
setsid "$W" --host-net -- sleep 3221 2>/dev/null & P=$!
sleep $START; kill -TERM -- "-$P" 2>/dev/null; wait $P; rc=$?
sleep 1
[[ $rc -eq 143 && -z "$(pgrep -u "$(id -u)" -f '^sleep 3221' || true)" && "$(left)" -eq 0 ]] && ok "TERM: exit 143, nothing running, nothing left" || bad "TERM (exit $rc, state dirs $(left))"
if [[ $PODMAN -eq 0 ]]; then
  # podman-run.sh has no equivalent: a container outlives a wrapper killed with -9, with or
  # without this flag, until LSF ends the job.
  "$W" --host-net -- sleep 3222 2>/dev/null & P=$!
  sleep 5; kill -9 $P; wait $P 2>/dev/null; sleep 3
  [[ -z "$(pgrep -u "$(id -u)" -f '^sleep 3222' || true)" ]] && ok "kill -9 of the wrapper takes the sandbox with it" || bad "kill -9 left processes"
  rm -rf "$STATE/$LSB_JOBID-"* 2>/dev/null   # a killed run cannot clean up after itself
fi

echo "6. --dry-run with the network option"
# Prints what would run and starts nothing: no command, no state directory.
dry() {  # dry "what" "text the output must contain" "text it must not contain" wrapper-args...
  local what=$1 want=$2 not=$3 out rc; shift 3
  out="$("$W" --dry-run "$@" ${MNT[@]+"${MNT[@]}"} -- touch "$TR/dry.ran" 2>&1 </dev/null)"; rc=$?
  if [[ $rc -eq 0 && "$out" == *"$want"* && ( -z "$not" || "$out" != *"$not"* ) && ! -e "$TR/dry.ran" && "$(left)" -eq 0 ]]; then
    ok "--dry-run $what"
  else
    bad "--dry-run $what (exit $rc, ran=$([[ -e "$TR/dry.ran" ]] && echo yes || echo no), state dirs $(left): ${out:0:160})"
  fi
}
if [[ $PODMAN -eq 1 ]]; then
  dry "--host-net" "--network=host" "--network=none" --host-net
  dry "without a network option" "--network=none" "--network=host"
else
  dry "--host-net" "no helper is started" "--unshare-net" --host-net
  dry "without a network option" "--unshare-net" "no helper is started"
fi

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
