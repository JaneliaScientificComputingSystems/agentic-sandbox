#!/bin/bash
# test-array.sh -- many elements of one LSF array job, each in its own sandbox, on one node.
#
# All elements of an array share one job id, and LSF may start any number of them on the same
# node in the same second. Each must get its own state directory, its own /tmp and (with
# --allow) its own proxy, and leave nothing behind. Submit the elements and the check from a
# directory on shared storage outside your home directory, all onto ONE node (-m) so that they
# do meet:
#
#   cd /groups/<lab>/<some project dir>
#   H=<a node with 20 free slots>
#   J=$(bsub -q short -m $H -J "sbarr[1-20]" -W 15 -o array-%J-%I.out /path/to/tests/test-array.sh \
#         | grep -o '[0-9]*' | head -1)
#   bsub -q short -m $H -w "ended($J)" -W 10 -o array-check-%J.out /path/to/tests/test-array.sh check $J 20
#
# The same against podman-run.sh with SANDBOX_WRAPPER=podman-run.sh in the environment of both
# bsub commands (allow -W 30 for the elements).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd -P)"
WRAPPER="${SANDBOX_WRAPPER:-sandbox-run.sh}"
W="$SCRIPT_DIR/../scripts/$WRAPPER"
PODMAN=0; [[ "$WRAPPER" == podman-run.sh ]] && PODMAN=1
[[ -x "$W" ]] || { echo "no such wrapper: $W"; exit 2; }
STATE="/scratch/$USER/.agentic-sandbox"
HOLD=40   # seconds each element stays inside, so that the elements overlap

if [[ "${1:-}" != check ]]; then
  # ---- one element
  [[ -n "${LSB_JOBID:-}" && -n "${LSB_JOBINDEX:-}" && "$LSB_JOBINDEX" != 0 ]] || { echo "run this as an element of an LSF array job (see the header)"; exit 2; }
  TR="$PWD/.test-array-$LSB_JOBID"
  mkdir -p "$TR" && cd "$TR" || exit 2
  i=$LSB_JOBINDEX
  MNT=(); [[ $PODMAN -eq 1 ]] && MNT=(--rw "$TR")
  # Odd elements get an allowlist, and so a proxy each; even ones have no network.
  NET=(); [[ $((i % 2)) -eq 1 ]] && NET=(--allow pypi.org)
  cat > "inside.$i.sh" <<EOF
#!/bin/bash
echo "\$(date +%s)" > "$TR/in.$i"
touch /tmp/mark.$i
http=none
if [[ $((i % 2)) -eq 1 ]]; then
  http=\$(curl -s -o /dev/null -m 20 -w '%{http_code}' https://pypi.org/simple/pip/ 2>/dev/null || true)
  blocked=\$(curl -s -o /dev/null -m 10 -w '%{http_code}' https://example.com/ 2>/dev/null || true)
fi
sleep $HOLD
echo "marks=\$(ls /tmp/mark.* 2>/dev/null | wc -l) http=\$http blocked=\${blocked:-none} readme=\$([[ -s \$SANDBOX_README ]] && echo yes || echo no)" > "$TR/res.$i"
echo "\$(date +%s)" > "$TR/out.$i"
EOF
  chmod +x "inside.$i.sh"
  "$W" ${NET[@]+"${NET[@]}"} ${MNT[@]+"${MNT[@]}"} -- "$TR/inside.$i.sh"
  rc=$?
  echo "host=$(hostname -s) rc=$rc" > "el.$i"
  echo "element $i on $(hostname -s): wrapper exit $rc; $(cat "res.$i" 2>/dev/null)"
  exit $rc
fi

# ---- the check, after every element has ended
J="${2:?usage: test-array.sh check JOBID COUNT}"; N="${3:?usage: test-array.sh check JOBID COUNT}"
TR="$PWD/.test-array-$J"
cd "$TR" || { echo "no $TR: submit the check from the directory the elements were submitted from"; exit 2; }
PASS=0 FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL + 1)); }
echo "$WRAPPER, array job $J, $N elements, checked on $(hostname -s)"

n=$(ls el.* 2>/dev/null | wc -l); [[ $n -eq $N ]] && ok "all $N elements ran" || bad "$n of $N elements ran"
n=$(grep -l "rc=0$" el.* 2>/dev/null | wc -l); [[ $n -eq $N ]] && ok "every wrapper returned 0" || bad "$n of $N wrappers returned 0: $(grep -L 'rc=0$' el.* | tr '\n' ' ')"
hosts=$(sed 's/ .*//' el.* | sort -u | tr '\n' ' ')
[[ $(wc -w <<< "$hosts") -eq 1 && "$hosts" == "host=$(hostname -s) " ]] && ok "all on this node ($hosts)" || bad "elements ran on: $hosts(the check is on $(hostname -s)); submit both with the same -m"
# How many were inside at the same moment: the latest entry against the earliest exit.
last_in=$(cat in.* 2>/dev/null | sort -n | tail -1); first_out=$(cat out.* 2>/dev/null | sort -n | head -1)
together=0; for f in in.*; do [[ $(cat "$f") -le ${first_out:-0} ]] && together=$((together + 1)); done
[[ -n "$last_in" && -n "$first_out" && $together -ge $((N / 2)) ]] && ok "$together elements were inside their sandboxes at the same time" || bad "only $together elements overlapped; raise HOLD or use a node with more free slots"
n=$(grep -l "marks=1 " res.* 2>/dev/null | wc -l); [[ $n -eq $N ]] && ok "each element saw only its own /tmp" || bad "/tmp shared: $(grep -L 'marks=1 ' res.* | tr '\n' ' ')"
n=$(grep -l "readme=yes" res.* 2>/dev/null | wc -l); [[ $n -eq $N ]] && ok "each element had its \$SANDBOX_README" || bad "no README in: $(grep -L 'readme=yes' res.* | tr '\n' ' ')"
odd=$(( (N + 1) / 2 ))
n=$(grep -l "http=200 " res.* 2>/dev/null | wc -l); [[ $n -eq $odd ]] && ok "every --allow element reached its allowed host through its own proxy ($n)" || bad "$n of $odd --allow elements reached pypi.org: $(grep -h 'http=' res.* | sort | uniq -c | tr '\n' ';')"
# 000 is what curl reports when the proxy refuses the tunnel. Any other answer (a 200, but also a
# 301 or a 503 from the other host) means the request got out.
n=$(grep -l "http=200 blocked=000 " res.* 2>/dev/null | wc -l); [[ $n -eq $odd ]] && ok "no --allow element reached a host outside its list ($n refused)" || bad "only $n of $odd --allow elements were refused example.com: $(grep -ho 'blocked=[^ ]*' res.* | sort | uniq -c | tr '\n' ';')"
n=$(grep -l "http=none " res.* 2>/dev/null | wc -l); [[ $n -eq $((N - odd)) ]] && ok "the other elements had no network flag" || bad "unexpected: $n"
n=$(compgen -G "$STATE/$J-*" | wc -l); [[ $n -eq 0 ]] && ok "no state directory left for the job in $STATE" || bad "$n state directories left: $(compgen -G "$STATE/$J-*" | head -3 | tr '\n' ' ')"
# Processes of this array only: another job of yours on the node may be running its own.
ours() { local n=0 pid; for pid in $(pgrep -u "$USER" "$@"); do grep -azq "^LSB_JOBID=$J\$" "/proc/$pid/environ" 2>/dev/null && n=$((n + 1)); done; echo $n; }
n=$(ours -f 'allowlist_proxy.py'); [[ $n -eq 0 ]] && ok "no proxy of the job left running" || bad "$n proxies of the job still running"
if [[ $PODMAN -eq 1 ]]; then
  n=$(ours -x conmon); [[ $n -eq 0 ]] && ok "no container of the job left running" || bad "$n conmon processes of the job left"
fi
echo; echo "$PASS passed, $FAIL failed"
cd / && [[ $FAIL -eq 0 ]] && rm -rf "$TR"
[[ $FAIL -eq 0 ]]
