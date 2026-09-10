#!/bin/bash
# test-podman.sh -- regression suite for podman-run.sh (podman/GPU backend).
#
# Run from a real GPU LSF allocation (needs --gpu to work at all). User-agnostic: uses
# $USER/$HOME/$(whoami) throughout, no hardcoded account names. --keep-id tests require a
# /etc/subuid//etc/subgid range wider than the invoking account's real GID -- see
# ADMIN-NOTES.md's "--userns=keep-id, revisited" section if those fail.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PODMAN_RUN="$SCRIPT_DIR/../scripts/podman-run.sh"

PASS=0
FAIL=0
check() {
  if [[ "$2" == "$3" ]]; then
    echo "PASS: $1 (got: $2)"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $1 (expected: $3, got: $2)"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== 1. Basic no-flags run (default image, root identity) ==="
OUT=$("$PODMAN_RUN" --gpu -- bash -c 'whoami' 2>&1 | tail -1)
check "basic run identity" "$OUT" "root"

echo "=== 2. GPU passthrough ==="
OUT=$("$PODMAN_RUN" --gpu -- nvidia-smi --query-gpu=name --format=csv,noheader 2>&1 | tail -1)
if echo "$OUT" | grep -q "NVIDIA"; then
  echo "PASS: GPU passthrough ($OUT)"
  PASS=$((PASS + 1))
else
  echo "FAIL: GPU passthrough: $OUT"
  FAIL=$((FAIL + 1))
fi

echo "=== 3. --scratch ==="
OUT=$("$PODMAN_RUN" --gpu --scratch -- bash -c "test -d /scratch/$USER && echo ok" 2>&1 | tail -1)
check "--scratch mounted" "$OUT" "ok"

echo "=== 4. opencode + Kimi K3 one-shot ==="
OUT=$("$PODMAN_RUN" --gpu --scratch --opencode --allow litellm.int.janelia.org -- \
  opencode run "What is 5 plus 6? Answer with just the number." --model litellm/kimi-k3 2>&1 | tail -1)
check "opencode kimi-k3 math" "$OUT" "11"

echo "=== 5. Claude Code one-shot (default root identity) ==="
OUT=$("$PODMAN_RUN" --gpu --scratch --claude \
  --allow api.anthropic.com --allow claude.ai --allow platform.claude.com -- \
  claude -p "who am i speaking to?" --model sonnet 2>&1)
# See test-bwrap.sh's comment on this same check -- don't assert on specific wording.
if echo "$OUT" | grep -qE "^(Error|error):"; then
  echo "FAIL: claude one-shot (sandbox/tool error): $OUT"
  FAIL=$((FAIL + 1))
elif [[ -n "$OUT" ]]; then
  echo "PASS: claude one-shot ($OUT)"
  PASS=$((PASS + 1))
else
  echo "FAIL: claude one-shot: empty response"
  FAIL=$((FAIL + 1))
fi

echo "=== 6. --keep-id identity ==="
OUT=$("$PODMAN_RUN" --gpu --keep-id -- bash -c 'whoami' 2>&1 | tail -1)
check "--keep-id identity" "$OUT" "$(whoami)"

echo "=== 7. --keep-id + --claude ==="
OUT=$("$PODMAN_RUN" --gpu --keep-id --claude -- bash -c 'claude --version' 2>&1 | tail -1)
if echo "$OUT" | grep -q "Claude Code"; then
  echo "PASS: keep-id claude ($OUT)"
  PASS=$((PASS + 1))
else
  echo "FAIL: keep-id claude: $OUT"
  FAIL=$((FAIL + 1))
fi

echo "=== 8. --keep-id + --opencode ==="
OUT=$("$PODMAN_RUN" --gpu --keep-id --opencode -- bash -c 'opencode --version' 2>&1 | tail -1)
if echo "$OUT" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+'; then
  echo "PASS: keep-id opencode ($OUT)"
  PASS=$((PASS + 1))
else
  echo "FAIL: keep-id opencode: $OUT"
  FAIL=$((FAIL + 1))
fi

echo "=== 9. --keep-id file ownership ==="
WORKDIR="/scratch/$USER/test-podman-keepid-$$"
mkdir -p "$WORKDIR"
"$PODMAN_RUN" --gpu --keep-id --rw "$WORKDIR" -- bash -c "echo hi > $WORKDIR/f.txt" >/dev/null 2>&1
OUT=$(stat -c '%U' "$WORKDIR/f.txt" 2>&1)
check "keep-id file ownership" "$OUT" "$(whoami)"
rm -rf "$WORKDIR"

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

echo "=== 11. Matrix: with/without --keep-id x with/without --rw \$HOME ==="

echo "--- 11a. no --keep-id, no HOME mapping ---"
OUT=$("$PODMAN_RUN" --gpu -- bash -c 'echo whoami=$(whoami); ls "$HOME" 2>&1' 2>&1 | tail -2)
echo "$OUT"

echo "--- 11b. no --keep-id, WITH --rw \$HOME: in-container identity stays root, but bind-mount"
echo "    writes ALREADY land with real ownership -- rootless podman's default mapping already"
echo "    writes bind-mounted files as your real host identity; --keep-id changes in-container"
echo "    identity (whoami/\$HOME), not this. See ADMIN-NOTES.md's keep-id section."
WORKDIR="$HOME/test-podman-nohome-$$"
mkdir -p "$WORKDIR" 2>/dev/null
"$PODMAN_RUN" --gpu --rw "$HOME" -- bash -c "echo hi > $WORKDIR/f.txt" >/dev/null 2>&1
OUT=$(stat -c '%U' "$WORKDIR/f.txt" 2>&1)
check "no-keep-id + --rw \$HOME file owner (already correct without --keep-id)" "$OUT" "$(whoami)"
rm -rf "$WORKDIR"

echo "--- 11c. WITH --keep-id, no HOME mapping: real identity, \$HOME not exposed ---"
OUT=$("$PODMAN_RUN" --gpu --keep-id -- bash -c 'echo whoami=$(whoami); ls "$HOME" 2>&1' 2>&1 | tail -2)
echo "$OUT"

echo "--- 11d. WITH --keep-id, WITH --rw \$HOME: real identity, real ownership on write ---"
WORKDIR="$HOME/test-podman-keepid-home-$$"
mkdir -p "$WORKDIR" 2>/dev/null
"$PODMAN_RUN" --gpu --keep-id --rw "$HOME" -- bash -c "echo hi > $WORKDIR/f.txt" >/dev/null 2>&1
OUT=$(stat -c '%U' "$WORKDIR/f.txt" 2>&1)
check "keep-id + --rw \$HOME file owner" "$OUT" "$(whoami)"
rm -rf "$WORKDIR"

echo "=== SUMMARY: $PASS passed, $FAIL failed ==="
exit $((FAIL > 0 ? 1 : 0))
