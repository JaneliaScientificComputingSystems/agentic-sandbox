#!/bin/bash
# test-podman.sh -- regression suite for podman-run.sh (podman backend).
#
# Run from a real GPU LSF allocation (the suite uses --gpu throughout), never on a login node,
# and ONE AT A TIME with tests/test-bwrap.sh (both drive opencode against the same sqlite
# database on NFS).
#
#   ONLY=2c,13 tests/test-podman.sh    run only those sections
#   SKIP_LLM=1 tests/test-podman.sh    skip the sections that need a model to answer (4, 5)
#
# User-agnostic: uses $USER/$HOME/$(whoami) throughout, no hardcoded account names.
# --keep-id tests require a /etc/subuid//etc/subgid range wider than the invoking account's
# real GID -- see ADMIN-NOTES.md's "--userns=keep-id, revisited" section if those fail. The
# --csub section runs only when csub-broker is on PATH and CSUB_TEST_ROOT is set. Whatever is
# skipped is counted in the summary line.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PODMAN_RUN="$SCRIPT_DIR/../scripts/podman-run.sh"

# Everything this run creates lives under $TR or is added to EXTRA_CLEANUP (the few things that
# must sit in $HOME or in the state parent); one trap removes it all, also on a kill.
TR="/scratch/$USER/test-podman-$$"
mkdir -p "$TR"
EXTRA_CLEANUP=()
cleanup_tests() { cd /; rm -rf "$TR" ${EXTRA_CLEANUP[@]+"${EXTRA_CLEANUP[@]}"}; }
trap cleanup_tests EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

PASS=0
FAIL=0
SKIP=0
check() {
  if [[ "$2" == "$3" ]]; then
    echo "PASS: $1 (got: $2)"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $1 (expected: $3, got: $2)"
    FAIL=$((FAIL + 1))
  fi
}
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }
need_llm() { [[ -z "${SKIP_LLM:-}" ]] || { skip "$1 (SKIP_LLM is set)"; return 1; }; }

# See test-bwrap.sh: "nothing left behind" is measured against the state at the start.
state_dirs() { ls -A "/scratch/$USER/.agentic-sandbox" 2>/dev/null | wc -l | tr -d ' '; }
brokers() { pgrep -u "$USER" -f 'csub.broker|csub-broker' | wc -l | tr -d ' '; }
proxies() { pgrep -u "$USER" -f allowlist_proxy.py | wc -l | tr -d ' '; }
conmons() { ps -ww -u "$USER" -o args= | grep '[/]conmon ' | grep -cF "/.agentic-sandbox/"; }
BASE_STATE=$(state_dirs)
BASE_BROKERS=$(brokers)
BASE_PROXIES=$(proxies)
TMP_SANDBOX_BEFORE=$(ls -d /tmp/podman-sandbox-* 2>/dev/null | wc -l | tr -d ' ')

CTRL_IP=$(python3 -c 'import socket; print(socket.gethostbyname("example.com"))' 2>/dev/null || true)
tcp_open() { timeout 6 bash -c "exec 3<>/dev/tcp/$1/443" 2>/dev/null; }
have_net() { [[ -n "$CTRL_IP" ]] && tcp_open "$CTRL_IP"; }

s_1() {
  echo "=== 1. Basic no-flags run (default image, root identity) ==="
  OUT=$("$PODMAN_RUN" --gpu -- bash -c 'whoami' 2>&1 | tail -1)
  check "basic run identity" "$OUT" "root"
}

s_2() {
  echo "=== 2. GPU passthrough ==="
  OUT=$("$PODMAN_RUN" --gpu -- nvidia-smi --query-gpu=name --format=csv,noheader 2>&1 | tail -1)
  if echo "$OUT" | grep -q "NVIDIA"; then
    echo "PASS: GPU passthrough ($OUT)"
    PASS=$((PASS + 1))
  else
    echo "FAIL: GPU passthrough: $OUT"
    FAIL=$((FAIL + 1))
  fi
}

s_2b() {
  echo "=== 2b. /dev/shm size (issue #8): 8g with --gpu, --shm-size overrides, podman default otherwise ==="
  shm_mb() { "$PODMAN_RUN" "$@" -- df -BM --output=size /dev/shm 2>/dev/null | tail -1 | tr -d ' M'; }
  check "--gpu: /dev/shm is 8g" "$(shm_mb --gpu)" "8192"
  check "--gpu --shm-size 512m" "$(shm_mb --gpu --shm-size 512m)" "512"
  # df reports podman's 64 MB default as 63M (the tmpfs is 64000k, not 64 MiB); only "not raised" matters.
  OUT=$(shm_mb); [[ "$OUT" =~ ^[0-9]+$ && "$OUT" -le 64 ]] && OUT="at-most-64"
  check "no --gpu, no flag: podman's default, not raised" "$OUT" "at-most-64"
  check "--shm-size 1g without --gpu" "$(shm_mb --shm-size 1g)" "1024"
  OUT=$("$PODMAN_RUN" --shm-size lots -- true >/dev/null 2>&1; echo $?)
  check "--shm-size with a bad value refused (rc 1)" "$OUT" "1"
  # What the issue hit: more than 64 MB written to /dev/shm.
  OUT=$("$PODMAN_RUN" --gpu -- bash -c 'dd if=/dev/zero of=/dev/shm/t bs=1M count=200 2>/dev/null && echo wrote-200M' 2>/dev/null | tail -1)
  check "--gpu: 200 MB fits in /dev/shm" "$OUT" "wrote-200M"
}

s_2c() {
  echo "=== 2c. Container output is not logged by podman, whatever containers.conf says ==="
  # The node default is log_driver=journald, which copies the container's whole pty stream (TUI
  # redraws, the conversation with the agent) into the journal and the central syslog. Force that
  # default on top of the user's own config and read the log driver off conmon's command line.
  LOGCONF="$HOME/.agentic-sandbox-test-logconf-$$"; EXTRA_CLEANUP+=("$LOGCONF")
  printf '[containers]\nlog_driver = "journald"\n' > "$LOGCONF"
  CONTAINERS_CONF_OVERRIDE="$LOGCONF" "$PODMAN_RUN" -- sleep 20 >/dev/null 2>&1 &
  LOGPID=$!
  OUT=""
  for _ in $(seq 1 90); do
    OUT=$(ps -ww -u "$USER" -o args= | grep '[/]conmon ' | grep -F "/.agentic-sandbox/" | sed -n 's/.* -l \([^ ]*\) .*/\1/p' | head -1)
    [[ -n "$OUT" ]] && break
    sleep 1
  done
  check "conmon log driver with log_driver=journald configured" "$OUT" "none"
  wait "$LOGPID"
  rm -f "$LOGCONF"
}

s_3() {
  echo "=== 3. --scratch ==="
  OUT=$("$PODMAN_RUN" --gpu --scratch -- bash -c "test -d /scratch/$USER/work && ! test -e /scratch/$USER/.agentic-sandbox && echo ok" 2>&1 | tail -1)
  check "--scratch mounted" "$OUT" "ok"
}

s_4() {
  echo "=== 4. opencode + Kimi K3 one-shot ==="
  need_llm "opencode one-shot" || return 0
  OUT=$("$PODMAN_RUN" --gpu --scratch --opencode --allow litellm.int.janelia.org -- \
    opencode run "What is 5 plus 6? Answer with just the number." --model litellm/kimi-k3 2>&1 | tail -1)
  check "opencode kimi-k3 math" "$OUT" "11"
}

s_5() {
  echo "=== 5. Claude Code one-shot (default root identity) ==="
  need_llm "Claude Code one-shot" || return 0
  OUT=$("$PODMAN_RUN" --gpu --scratch --claude \
    --allow api.anthropic.com --allow claude.ai --allow platform.claude.com -- \
    claude -p "who am i speaking to?" --model sonnet 2>&1)
  # See test-bwrap.sh's comment on this same check -- don't assert on specific wording.
  if echo "$OUT" | grep -qE "^(Error|error):|Failed to authenticate"; then
    echo "FAIL: claude one-shot (sandbox/tool error): $OUT"
    FAIL=$((FAIL + 1))
  elif [[ -n "$OUT" ]]; then
    echo "PASS: claude one-shot ($OUT)"
    PASS=$((PASS + 1))
  else
    echo "FAIL: claude one-shot: empty response"
    FAIL=$((FAIL + 1))
  fi
}

s_6() {
  echo "=== 6. --keep-id identity ==="
  OUT=$("$PODMAN_RUN" --gpu --keep-id -- bash -c 'whoami' 2>&1 | tail -1)
  check "--keep-id identity" "$OUT" "$(whoami)"
}

s_7() {
  echo "=== 7. --keep-id + --claude ==="
  OUT=$("$PODMAN_RUN" --gpu --keep-id --claude -- bash -c 'claude --version' 2>&1 | tail -1)
  if echo "$OUT" | grep -q "Claude Code"; then
    echo "PASS: keep-id claude ($OUT)"
    PASS=$((PASS + 1))
  else
    echo "FAIL: keep-id claude: $OUT"
    FAIL=$((FAIL + 1))
  fi
}

s_8() {
  echo "=== 8. --keep-id + --opencode ==="
  OUT=$("$PODMAN_RUN" --gpu --keep-id --opencode -- bash -c 'opencode --version' 2>&1 | tail -1)
  if echo "$OUT" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+'; then
    echo "PASS: keep-id opencode ($OUT)"
    PASS=$((PASS + 1))
  else
    echo "FAIL: keep-id opencode: $OUT"
    FAIL=$((FAIL + 1))
  fi
}

s_9() {
  echo "=== 9. --keep-id file ownership ==="
  WORKDIR="$TR/keepid"
  mkdir -p "$WORKDIR"
  "$PODMAN_RUN" --gpu --keep-id --rw "$WORKDIR" -- bash -c "echo hi > $WORKDIR/f.txt" >/dev/null 2>&1
  OUT=$(stat -c '%U' "$WORKDIR/f.txt" 2>&1)
  check "keep-id file ownership" "$OUT" "$(whoami)"
  rm -rf "$WORKDIR"
}

s_10() {
  echo "=== 10. --image alternate (pytorch heavier image) ==="
  OUT=$("$PODMAN_RUN" --gpu --image ghcr.io/janeliascientificcomputingsystems/agentic-sandbox-gpu:latest -- \
    bash -c 'python3 -c "import torch; print(torch.__version__)"' 2>&1 | tail -1)
  if echo "$OUT" | grep -qE '^[0-9]+\.'; then
    echo "PASS: pytorch image ($OUT)"
    PASS=$((PASS + 1))
  else
    echo "FAIL: pytorch image: $OUT"
    FAIL=$((FAIL + 1))
  fi
}

s_11() {
  echo "=== 11. Matrix: with/without --keep-id x with/without a directory under \$HOME mounted ==="
  # Only a throwaway subdirectory of \$HOME is ever mounted: \$HOME itself is refused by the
  # wrapper (no credential masking under podman), which 11e checks.

  echo "--- 11a. no --keep-id, no HOME mapping ---"
  OUT=$("$PODMAN_RUN" --gpu -- bash -c "whoami; test -e '$HOME' && echo home-VISIBLE || echo home-absent" 2>/dev/null | tail -2 | tr '\n' ',')
  check "container root, and the real \$HOME does not exist inside" "$OUT" "root,home-absent,"

  echo "--- 11b. no --keep-id, WITH --rw <dir under \$HOME>: in-container identity stays root, but bind-mount"
  echo "    writes ALREADY land with real ownership -- rootless podman's default mapping already"
  echo "    writes bind-mounted files as your real host identity; --keep-id changes in-container"
  echo "    identity (whoami/\$HOME), not this. See ADMIN-NOTES.md's keep-id section."
  WORKDIR="$HOME/test-podman-nohome-$$"; EXTRA_CLEANUP+=("$WORKDIR")
  mkdir -p "$WORKDIR" 2>/dev/null
  "$PODMAN_RUN" --gpu --rw "$WORKDIR" -- bash -c "echo hi > $WORKDIR/f.txt" >/dev/null 2>&1
  OUT=$(stat -c '%U' "$WORKDIR/f.txt" 2>&1)
  check "no-keep-id + --rw under \$HOME file owner (already correct without --keep-id)" "$OUT" "$(whoami)"
  rm -rf "$WORKDIR"

  echo "--- 11c. WITH --keep-id, no HOME mapping: real identity, \$HOME not exposed ---"
  OUT=$("$PODMAN_RUN" --gpu --keep-id -- bash -c 'whoami; test -e "$HOME/.ssh" && echo ssh-VISIBLE || echo ssh-absent' 2>/dev/null | tail -2 | tr '\n' ',')
  check "--keep-id: your own name, and nothing of the real \$HOME" "$OUT" "$(whoami),ssh-absent,"

  echo "--- 11d. WITH --keep-id, WITH --rw <dir under \$HOME>: real identity, real ownership on write ---"
  WORKDIR="$HOME/test-podman-keepid-home-$$"; EXTRA_CLEANUP+=("$WORKDIR")
  mkdir -p "$WORKDIR" 2>/dev/null
  "$PODMAN_RUN" --gpu --keep-id --rw "$WORKDIR" -- bash -c "echo hi > $WORKDIR/f.txt" >/dev/null 2>&1
  OUT=$(stat -c '%U' "$WORKDIR/f.txt" 2>&1)
  check "keep-id + --rw under \$HOME file owner" "$OUT" "$(whoami)"
  rm -rf "$WORKDIR"

  echo "--- 11e. mounts with no masking to protect them are refused; usage errors are usage errors ---"
  OUT=$("$PODMAN_RUN" --rw "$HOME" -- true >/dev/null 2>&1; echo $?)
  check "--rw \$HOME refused (rc 1)" "$OUT" "1"
  OUT=$("$PODMAN_RUN" --ro "$(dirname "$HOME")" -- true >/dev/null 2>&1; echo $?)
  check "--ro on the parent of \$HOME refused (rc 1)" "$OUT" "1"
  OUT=$("$PODMAN_RUN" --rw "/scratch/$USER" -- true >/dev/null 2>&1; echo $?)
  check "--rw /scratch/\$USER refused (rc 1)" "$OUT" "1"
  OUT=$("$PODMAN_RUN" --rw 2>&1 | tail -1)
  check "option without its argument is a usage error" "$OUT" "podman-run.sh: --rw needs an argument"
  # The wrapper's own directory inside a read-write mount: mounted read-only on top.
  COPY="$TR/selfmount"; mkdir -p "$COPY"; cp -R "$SCRIPT_DIR/../scripts" "$COPY/scripts"
  OUT=$("$COPY/scripts/podman-run.sh" --gpu --rw "$COPY" -- bash -c "touch $COPY/ok && echo parent-rw; touch $COPY/scripts/x 2>/dev/null && echo scripts-WRITABLE || echo scripts-ro" 2>/dev/null | tr '\n' ',')
  check "script dir inside an --rw mount is read-only inside" "$OUT" "parent-rw,scripts-ro,"
  OUT=$("$COPY/scripts/podman-run.sh" --rw "$COPY/scripts" -- true >/dev/null 2>&1; echo $?)
  check "--rw on the script dir itself refused (rc 1)" "$OUT" "1"
  rm -rf "$COPY"
}

s_12() {
  echo "=== 12. Per-job state: siblings hidden, credentials bound through, nothing left ==="
  FAKE="/scratch/$USER/.agentic-sandbox/fake-sibling-$$"; EXTRA_CLEANUP+=("$FAKE")
  mkdir -p "$FAKE/proxy" && echo "not-yours" > "$FAKE/proxy/proxy.log"
  OUT=$("$PODMAN_RUN" --gpu --scratch -- bash -c 'test -e /scratch/$USER/.agentic-sandbox && echo visible || echo hidden' 2>&1 | tail -1)
  check "--scratch: state parent not mounted" "$OUT" "hidden"
  rm -rf "$FAKE"
  CREDS="$HOME/.claude/.credentials.json"
  if [[ -f "$CREDS" ]]; then
    SZ=$(stat -c %s "$CREDS"); B=$(md5sum < "$CREDS")
    OUT=$("$PODMAN_RUN" --gpu --keep-id --claude -- bash -c 'stat -c %s "$CLAUDE_CONFIG_DIR/.credentials.json"' 2>&1 | tail -1)
    check "keep-id --claude: real credentials file bound through (same size inside)" "$OUT" "$SZ"
    check "host credentials untouched" "$(md5sum < "$CREDS")" "$B"
  fi
  check "per-job state dirs removed on exit" "$(state_dirs)" "$BASE_STATE"
  check "no /tmp writes by the wrapper" "$(ls -d /tmp/podman-sandbox-* 2>/dev/null | wc -l | tr -d ' ')" "$TMP_SANDBOX_BEFORE"
  # Early exits must not leave the cfg/ copies (~/.claude.json) behind either: --gpu in an LSF
  # job with no GPU allocated is the common one, and a missing command the other.
  OUT=$(env -u CUDA_VISIBLE_DEVICES "$PODMAN_RUN" --gpu --claude -- true >/dev/null 2>&1; echo $?)
  check "--gpu with no GPU allocated exits 1" "$OUT" "1"
  OUT=$("$PODMAN_RUN" --claude >/dev/null 2>&1; echo $?)
  check "no command exits 1" "$OUT" "1"
  check "early exits leave no per-job state" "$(state_dirs)" "$BASE_STATE"
}

s_13() {
  echo "=== 13. --csub: sandboxed submission from inside the container (skipped without csub-broker) ==="
  if command -v csub-broker >/dev/null 2>&1 && [[ -n "${CSUB_TEST_ROOT:-}" && -d "${CSUB_TEST_ROOT:-/nonexistent}" ]]; then
    CW="$CSUB_TEST_ROOT/test-podman-csub-$$"; DECOY="$CSUB_TEST_ROOT/test-podman-decoy-$$"; EXTRA_CLEANUP+=("$CW" "$DECOY"); mkdir -p "$CW"
    OUT=$("$PODMAN_RUN" --csub --rw "$CW" -- bash -c "cd $CW && csub submit --walltime 5 --wait --name t13 -- sh -c 'echo child-ok' 2>&1 | grep -c child-ok" 2>&1 | tail -1)
    check "--csub: child job ran from inside the container" "$OUT" "1"
    check "--csub: no broker left behind" "$(brokers)" "$BASE_BROKERS"
    if csub-broker --help 2>&1 | grep -q -- --envelope-mount; then
      mkdir -p "$DECOY"
      OUT=$("$PODMAN_RUN" --csub --rw "$CW" -- bash -c "cd $CW && CSUB_MOUNTS=$CW:rw,$DECOY:rw csub submit --walltime 5 -- true >/dev/null 2>&1; echo \$?" 2>&1 | tail -1)
      check "--csub: claiming a directory the container lacks is refused (envelope, rc 3)" "$OUT" "3"
      # Nothing to put in the envelope (only /scratch mounted, no --allow): csub would read that as
      # "no envelope" and accept any claim under allowed_roots, so the wrapper must refuse to start
      # (rc 1) instead of warning. CSUB_ENVELOPE=off is the explicit way to accept a policy-only broker.
      OUT=$("$PODMAN_RUN" --csub --scratch -- true >/dev/null 2>&1; echo $?)
      check "--csub: empty envelope refused at start (rc 1)" "$OUT" "1"
      OUT=$(CSUB_ENVELOPE=off "$PODMAN_RUN" --csub --scratch -- bash -c 'csub probe >/dev/null 2>&1 && echo probe-ok' 2>/dev/null | tail -1)
      check "--csub: CSUB_ENVELOPE=off starts a policy-only broker" "$OUT" "probe-ok"
      OUT=$(CSUB_MOUNTS="$CW:rw,$DECOY:rw" "$PODMAN_RUN" --csub --rw "$CW" -- true >/dev/null 2>&1; echo $?)
      check "--csub: preset CSUB_MOUNTS wider than the container is refused (rc 1)" "$OUT" "1"
      check "--csub: no broker left behind after refusals" "$(brokers)" "$BASE_BROKERS"
      rm -rf "$DECOY"
    else
      skip "this csub has no --envelope-mount (needs csub #13)"
    fi
    rm -rf "$CW"
  else
    skip "csub-broker not on PATH or CSUB_TEST_ROOT unset"
  fi
}

s_14() {
  echo "=== 14. In-sandbox README describes this session ==="
  OUT=$("$PODMAN_RUN" --gpu --scratch -- bash -c 'test -f "$SANDBOX_README" && echo file-ok; grep -c "no bsub, no csub" /run/sandbox/README.md; grep -c "/scratch/'"$USER"'/work (read-write)" /run/sandbox/README.md' 2>&1 | tail -3 | tr '\n' ',')
  check "README present, says no job submission, lists the --scratch mount" "$OUT" "file-ok,1,1,"
}

s_15() {
  echo "=== 15. Exit code of the sandboxed command propagates; stdout is the command's alone ==="
  OUT=$("$PODMAN_RUN" --gpu -- echo only-line 2>/dev/null)
  check "nothing but the command's output on stdout (no image ID from the pull)" "$OUT" "only-line"
  "$PODMAN_RUN" --gpu -- sh -c 'exit 7' >/dev/null 2>&1; RC=$?
  check "exit 7 propagated" "$RC" "7"
}

s_16() {
  echo "=== 16. Denied-host summary on failure, quiet on success ==="
  OUT=$({ "$PODMAN_RUN" --gpu --allow example.com -- bash -c 'curl -s --max-time 8 http://denied.invalid/ >/dev/null; exit 7'; echo "rc=$?"; } 2>&1 \
    | grep -E 'denied [0-9]+ request|^rc=' | sed 's/.*denied \([0-9]*\) request.*: \([a-z.]*\) .*/denied=\1 host=\2/' | tr '\n' ' ')
  check "summary printed and rc 7 propagated" "$OUT" "denied=1 host=denied.invalid rc=7 "
  OUT=$({ "$PODMAN_RUN" --gpu --allow example.com -- bash -c 'curl -s --max-time 8 http://denied.invalid/ >/dev/null; exit 0'; echo "rc=$?"; } 2>&1 | grep -cE 'denied [0-9]+ request')
  check "no summary when the command succeeds" "$OUT" "0"
}

s_17() {
  echo "=== 17. Network: none without --allow; with it, the proxy is the only way out ==="
  if ! have_net; then skip "network sections: example.com:443 is not reachable from this node"; return 0; fi
  OUT=$("$PODMAN_RUN" -- bash -c "curl -s -m 6 -o /dev/null -w '%{http_code}\n' https://example.com; timeout 6 bash -c 'exec 3<>/dev/tcp/$CTRL_IP/443' 2>/dev/null && echo tcp-OPEN || echo tcp-closed" 2>/dev/null | tail -2 | tr '\n' ',')
  check "no --allow: HTTPS fails and a raw TCP connect fails" "$OUT" "000,tcp-closed,"
  OUT=$("$PODMAN_RUN" --allow example.com -- bash -c "
    curl -s -m 15 -o /dev/null -w '%{http_code}\n' https://example.com
    curl -s -m 6 --noproxy '*' -o /dev/null -w '%{http_code}\n' https://example.com
    curl -s -m 6 --noproxy '*' -k -o /dev/null -w '%{http_code}\n' https://$CTRL_IP/
    env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY curl -s -m 6 -o /dev/null -w '%{http_code}\n' https://example.com
    timeout 6 bash -c 'exec 3<>/dev/tcp/$CTRL_IP/443' 2>/dev/null && echo tcp-OPEN || echo tcp-closed
    curl -s -m 10 -o /dev/null -w '%{http_code}\n' https://example.org" 2>/dev/null | tail -6 | tr '\n' ',')
  check "--allow: listed host 200; no proxy, by address, raw TCP and another host all fail" "$OUT" "200,000,000,000,tcp-closed,000,"
}

s_18() {
  echo "=== 18. No host environment, nothing of the host outside the mounts ==="
  OUT=$(SANDBOX_TEST_SECRET=leaked "$PODMAN_RUN" -- bash -c "echo \"\${SANDBOX_TEST_SECRET:-unset}\"; test -e '$HOME' && echo home-VISIBLE || echo home-absent; test -e /scratch/$USER && echo scratch-VISIBLE || echo scratch-absent" 2>/dev/null | tail -3 | tr '\n' ',')
  check "exported variable not forwarded; \$HOME and /scratch/\$USER absent" "$OUT" "unset,home-absent,scratch-absent,"
}

s_19() {
  echo "=== 19. TERM to the wrapper's process group cleans up (the bkill/walltime path) ==="
  setsid "$PODMAN_RUN" --allow example.com -- sleep 300 >/dev/null 2>&1 &
  local wp=$! i rc
  for i in $(seq 1 120); do [[ "$(conmons)" -ge 1 ]] && break; sleep 1; done
  check "container is running before the signal" "$(conmons)" "1"
  kill -TERM -- "-$wp" 2>/dev/null
  wait "$wp" 2>/dev/null; rc=$?
  for i in $(seq 1 30); do [[ "$(state_dirs)" == "$BASE_STATE" && "$(conmons)" == 0 ]] && break; sleep 1; done
  check "wrapper exits 143 after TERM" "$rc" "143"
  check "no container, no proxy, no state dir left" "$(conmons),$(proxies),$(state_dirs)" "0,$BASE_PROXIES,$BASE_STATE"
}

s_20() {
  echo "=== 20. Two containers at once on one node ==="
  "$PODMAN_RUN" -- echo first > "$TR/p1" 2>/dev/null &
  "$PODMAN_RUN" -- echo second > "$TR/p2" 2>/dev/null &
  wait
  check "both ran" "$(cat "$TR/p1") $(cat "$TR/p2")" "first second"
  check "both cleaned up" "$(state_dirs)" "$BASE_STATE"
}

ALL_SECTIONS=(1 2 2b 2c 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20)
if [[ -n "${ONLY:-}" ]]; then IFS=',' read -ra RUN <<< "$ONLY"; else RUN=("${ALL_SECTIONS[@]}"); fi
for id in "${RUN[@]}"; do
  declare -F "s_$id" >/dev/null || { echo "test-podman.sh: no section '$id' (sections: ${ALL_SECTIONS[*]})" >&2; exit 2; }
  "s_$id"
done

echo "=== SUMMARY: $PASS passed, $FAIL failed, $SKIP skipped ==="
exit $((FAIL > 0 ? 1 : 0))
