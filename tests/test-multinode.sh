#!/bin/bash
# test-multinode.sh -- sandbox-run.sh --job-nodes / --peers / --listen / --host-net, across two nodes.
#
# The job script of a two-node LSF job. Submit it from a directory that is on shared storage and
# outside your home directory; it needs no GPU:
#
#   cd /groups/<lab>/<some project dir>
#   bsub -q short -n 2 -R "span[ptile=1]" -W 15 -o multinode-%J.out /path/to/tests/test-multinode.sh
#
# It starts one sandbox per node with blaunch, as a multi-node launcher does, and checks that the
# two reach each other and nothing else. --ib is not covered: it needs InfiniBand nodes and a
# program that uses them.
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
command -v pasta >/dev/null || { echo "no pasta on $(hostname): --job-nodes cannot work here"; exit 2; }

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

echo "1. one sandbox per node"
cat > node.sh <<EOF
#!/bin/bash
cd "$TR" || exit 1
exec "$W" --job-nodes ${MNT[*]} -- python3 "$PROBE" "$TR" "\$1" "$ALL" "$OUTSIDER"
EOF
chmod +x node.sh
for i in "${!HOSTS[@]}"; do blaunch -z "${HOSTS[$i]}" "$TR/node.sh" "${ADDRS[$i]}" > "probe.$i.out" 2>&1 & done
wait
cat probe.*.out > probe.out
n=${#HOSTS[@]}
count() { grep -c "^$1 " probe.out || true; }
[[ "$(count PEER_OUT_OK)" -eq $((n * (n - 1))) ]] && ok "every node connects to every other node" || bad "connections to the other nodes ($(count PEER_OUT_OK) of $((n * (n - 1))))"
[[ "$(count PEER_IN_OK)" -eq $((n * (n - 1))) ]] && ok "every node accepts from every other node" || bad "connections from the other nodes ($(count PEER_IN_OK) of $((n * (n - 1))))"
[[ "$(count OUTSIDER_BLOCKED)" -eq $((2 * n)) && "$(count OUTSIDER_BAD)" -eq 0 ]] && ok "a host outside the job and the internet are unreachable" || bad "outside hosts ($(count OUTSIDER_BLOCKED) blocked, $(count OUTSIDER_BAD) reached)"
[[ "$(count DNS_BLOCKED)" -eq $n ]] && ok "no DNS" || bad "DNS"
[[ "$(count HOSTS_OK)" -eq $n ]] && ok "/etc/hosts names the other nodes" || bad "/etc/hosts"
[[ "$(count ROUTE_REFUSED)" -eq $n ]] && ok "the sandboxed process cannot add a route" || bad "route change"
[[ "$(count OWNER_OK)" -eq $n ]] && ok "files written inside belong to the user" || bad "file ownership"
[[ $FAIL -eq 0 ]] || sed 's/^/      /' probe.out

echo "2. exit status, stdin and the description for the agent"
echo "from stdin" | "$W" --job-nodes --listen 40123 -- bash -c 'read -r x; [[ "$x" == "from stdin" ]] || exit 3; grep -q "Only the other nodes of this job" "$SANDBOX_README" || exit 4; grep -q "and on 40123" "$SANDBOX_README" || exit 5; exit 7' 2>/dev/null
[[ $? -eq 7 ]] && ok "exit status, stdin and \$SANDBOX_README" || bad "exit status, stdin or \$SANDBOX_README"

rcs=""; for _ in 1 2 3 4 5 6; do "$W" --job-nodes -- bash -c 'exit 7' </dev/null >/dev/null 2>&1; rcs+="$? "; done
[[ "$rcs" == "7 7 7 7 7 7 " ]] && ok "exit status of a very short command, six times" || bad "exit status of a very short command: $rcs"

echo "3. refusals"
refuses "--allow with --job-nodes" "not with --allow" --job-nodes --allow pypi.org -- true
refuses "--csub with --job-nodes" "not with --csub" --job-nodes --csub -- true
refuses "--claude with --job-nodes" "not with --claude" --job-nodes --claude -- true
refuses "--listen without --job-nodes" "needs --job-nodes" --listen 40123 -- true
refuses "a bad --peers value" "--peers takes host names" --peers 'bad host' -- true
refuses "an unknown peer" "cannot resolve" --peers nosuchhost.invalid -- true
out="$(env -u LSB_MCPU_HOSTS "$W" --job-nodes -- true 2>&1)"; [[ $? -ne 0 && "$out" == *LSB_MCPU_HOSTS* ]] && ok "refuses --job-nodes without LSF's node list" || bad "refuses --job-nodes without LSF's node list"
if [[ $PODMAN -eq 1 ]]; then
  refuses "--keep-id with --job-nodes" "not with --keep-id" --job-nodes --keep-id -- true
else
  out="$(SANDBOX_NET_STAGE=inner "$W" --job-nodes -- true 2>&1)"; [[ $? -ne 0 && "$out" == *"not running in pasta's namespace"* ]] && ok "refuses a faked inner stage" || bad "refuses a faked inner stage"
fi
refuses "--host-net with --job-nodes" "not with --job-nodes" --host-net --job-nodes -- true
refuses "--host-net with --allow" "not with --allow" --host-net --allow pypi.org -- true
refuses "--host-net with --claude" "not with --claude" --host-net --claude -- true
refuses "--host-net with --ib" "not with --ib" --host-net --ib -- true
refuses "--peers naming a host outside the job" "not a node of this LSF job" --peers "${LSB_SUB_HOST:-login1}" -- true
refuses "--ib with --claude" "--ib: not with --claude" --ib --claude -- true
refuses "--ib with --csub" "--ib: not with --csub" --ib --csub -- true

echo "4. the other two networks"
"$W" -- bash -c "(exec 3<>/dev/tcp/$OUTSIDER/22) 2>/dev/null" 2>/dev/null && bad "default sandbox: no network" || ok "default sandbox: no network"
"$W" --host-net -- bash -c "(exec 3<>/dev/tcp/$OUTSIDER/22) 2>/dev/null && [[ ! -e \$HOME/.ssh ]]" 2>/dev/null && ok "--host-net: the node's network, home directory still hidden" || bad "--host-net"
# torchrun gives the other nodes the name this node's address reverse-resolves to.
"$W" --host-net -- python3 -c 'import socket, sys; n = socket.getfqdn(); sys.exit(0 if "containers.internal" not in n and socket.gethostbyname(n) != "127.0.0.1" else 1)' 2>/dev/null && ok "--host-net: the node's own name resolves as on the node" || bad "--host-net: the node's name inside is not the node's"

echo "5. two sandboxes on one node take different blocks of ports"
for t in A B; do "$W" --peers "$(hostname)" ${MNT[@]+"${MNT[@]}"} -- bash -c "date +%s > $TR/start.$t; sleep 25; grep -o 'on ports [0-9]*-[0-9]*' \$SANDBOX_README" > "block.$t" 2>block.$t.err & done
wait
# Both must have been running at the same time: the second does not wait for the first to end.
d=$(( $(cat start.A 2>/dev/null || echo 0) - $(cat start.B 2>/dev/null || echo 999) )); [[ ${d#-} -lt 20 ]] && ok "the two ran side by side (started ${d#-} s apart)" || bad "the second sandbox waited for the first (${d#-} s apart)"
[[ $PODMAN -eq 1 ]] && : > block.A.err && : > block.B.err   # podman reports its image check on stderr
[[ -s block.A && -s block.B && "$(cat block.A)" != "$(cat block.B)" && ! -s block.A.err && ! -s block.B.err ]] \
  && ok "different blocks, no complaints from pasta ($(cat block.A | tr -d '\n'); $(cat block.B | tr -d '\n'))" || bad "port blocks: A='$(cat block.A)' B='$(cat block.B)' $(head -2 block.A.err block.B.err)"

r="$(grep -o '[0-9]*-[0-9]*' block.A 2>/dev/null | head -1)"; [[ -n "$r" && $(( ${r#*-} - ${r%-*} )) -eq 1999 && ${r%-*} -ge 5000 ]] && ok "a block is 2000 ports, not below 5000 ($r)" || bad "block size: '$r'"

echo "6. stopping"
"$W" --job-nodes -- sleep 3221 2>/dev/null & P=$!
sleep $START; kill -TERM $P; wait $P; rc=$?
sleep 1
[[ $rc -eq 143 && -z "$(pgrep -u "$(id -u)" -f '^sleep 3221' || true)" && "$(left)" -eq 0 ]] && ok "TERM: exit 143, nothing running, nothing left" || bad "TERM (exit $rc, state dirs $(left))"
[[ -z "$(pgrep -u "$(id -u)" -x pasta || true)" ]] && ok "no pasta left running" || bad "pasta left running"
if [[ $PODMAN -eq 0 ]]; then
  # podman-run.sh has no equivalent: a container outlives a wrapper killed with -9, with or
  # without these flags, until LSF ends the job.
  "$W" --job-nodes -- sleep 3222 2>/dev/null & P=$!
  sleep 5; kill -9 $P; wait $P 2>/dev/null; sleep 3
  [[ -z "$(pgrep -u "$(id -u)" -f '^sleep 3222' || true)" && -z "$(pgrep -u "$(id -u)" -x pasta || true)" ]] && ok "kill -9 of the wrapper takes pasta and the sandbox with it" || bad "kill -9 left processes"
  rm -rf "$STATE/$LSB_JOBID-"* 2>/dev/null   # a killed run cannot clean up after itself
fi

echo "7. --dry-run with the network options"
# Prints what would run and starts nothing: no command, no pasta, no state directory, and no
# port block held (a real sandbox started right after still gets one).
dry() {  # dry "what" "text the output must contain" "text it must not contain" wrapper-args...
  local what=$1 want=$2 not=$3 out rc; shift 3
  out="$("$W" --dry-run "$@" ${MNT[@]+"${MNT[@]}"} -- touch "$TR/dry.ran" 2>&1 </dev/null)"; rc=$?
  if [[ $rc -eq 0 && "$out" == *"$want"* && ( -z "$not" || "$out" != *"$not"* ) && ! -e "$TR/dry.ran" \
        && -z "$(pgrep -u "$(id -u)" -x pasta || true)" && "$(left)" -eq 0 ]]; then
    ok "--dry-run $what"
  else
    bad "--dry-run $what (exit $rc, ran=$([[ -e "$TR/dry.ran" ]] && echo yes || echo no), state dirs $(left): ${out:0:160})"
  fi
}
dry "--job-nodes names pasta and the ports" "Ports open to the job's other nodes" "" --job-nodes --listen 40123
dry "--peers" "the network relay (pasta)" "" --peers "$(hostname)"
if [[ $PODMAN -eq 1 ]]; then
  dry "--host-net" "--network=host" "--network=none" --host-net
  dry "without a network option" "--network=none" "pasta"
else
  dry "--host-net" "no helper is started" "--unshare-net" --host-net
  dry "without a network option" "--unshare-net" "pasta"
fi
"$W" --job-nodes -- true </dev/null >/dev/null 2>&1 && ok "a sandbox starts right after the dry runs" || bad "a sandbox after the dry runs"

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
