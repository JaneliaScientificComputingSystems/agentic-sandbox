#!/bin/bash
# Tests for scripts/csub-policy.sh. Needs no cluster, no csub and no network: it runs the script
# against a stand-in for csub's sample policy (tests/fixtures/csub) and writes only under a
# temporary directory. With no csub-broker to be found, the script's own "csub loads it" check is
# skipped, so this covers the edits and the refusals, not csub's reading of the result.
#
#   bash tests/test-csub-policy.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/csub-policy.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/proj" "$T/data" "$T/venv"
OUT="$T/out/broker.toml"
PASS=0 FAIL=0

# A home with no csub in it and a PATH without csub-broker, whatever the caller has.
run() { env -i HOME="$T/home" PATH=/usr/bin:/bin "$SCRIPT" --csub "$HERE/fixtures/csub" --out "$OUT" "$@"; }
ok()  { PASS=$((PASS+1)); echo "ok    $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL  $1"; }
has()    { if grep -qF -- "$2" "$OUT"; then ok "$1"; else bad "$1 (missing: $2)"; fi; }
hasnt()  { if grep -qF -- "$2" "$OUT"; then bad "$1 (present: $2)"; else ok "$1"; fi; }
refuses() { # refuses NAME EXPECTED-TEXT args...
  local name="$1" want="$2" msg; shift 2
  rm -f "$OUT"
  if msg=$(run "$@" 2>&1); then bad "$name (was accepted)"; return; fi
  [[ "$msg" == *"$want"* ]] || { bad "$name (message: $msg)"; return; }
  [[ ! -e "$OUT" ]] || { bad "$name (wrote a policy)"; return; }
  ok "$name"
}

# --- 1. the plain policy
if run --bwrap --rw "$T/proj" >"$T/log" 2>&1; then ok "1 writes a policy"; else bad "1 writes a policy: $(cat "$T/log")"; fi
has   "1 sandbox kind"            'sandbox = "bwrap"'
has   "1 scripts directory"       "sandbox_scripts_dir = \"$(cd "$HERE/../scripts" && pwd)\""
has   "1 one read-write root"     "allowed_roots = [\"$T/proj\"]"
has   "1 no read-only roots"      'readonly_roots = []'
has   "1 no hosts"                'allowed_hosts = []'
hasnt "1 sample hosts removed"    'github.com'
hasnt "1 billing placeholder removed" 'CHANGEME'
has   "1 limits untouched"        'max_estimated_cost_usd = 200'
has   "1 queue table untouched"   'slots_per_gpu = 16'
has   "1 a queue's own max_gpus untouched" 'max_gpus = 1'
[[ "$(stat -c %a "$OUT")" == 600 ]] && ok "1 mode 600" || bad "1 mode 600"
grep -q "not checked" "$T/log" && ok "1 says csub did not check it" || bad "1 says csub did not check it"

# --- 2. an existing policy is kept unless --replace
before=$(md5sum < "$OUT")
if run --podman --rw "$T/proj" >/dev/null 2>&1; then bad "2 refuses to overwrite"; else ok "2 refuses to overwrite"; fi
[[ "$(md5sum < "$OUT")" == "$before" ]] && ok "2 left the policy alone" || bad "2 left the policy alone"

# --- 3. every option, with --replace
if run --podman --rw "$T/proj" --ro "$T/data" --ro "$T/venv" --allow pypi.org --allow files.pythonhosted.org \
       --gpus 2 --slots 32 --walltime 240 --cost 500 --pending 7 --replace >/dev/null 2>&1; then ok "3 replaces"; else bad "3 replaces"; fi
has "3 sandbox kind"     'sandbox = "podman"'
has "3 roots"            "allowed_roots = [\"$T/proj\", \"$T/data\", \"$T/venv\"]"
has "3 read-only roots"  "readonly_roots = [\"$T/data\", \"$T/venv\"]"
has "3 hosts"            'allowed_hosts = ["pypi.org", "files.pythonhosted.org"]'
has "3 gpus"             'max_gpus = 2'
has "3 slots"            'max_slots = 32'
has "3 walltime"         'max_walltime_min = 240'
has "3 cost"             'max_estimated_cost_usd = 500'
has "3 pending"          'max_pending_per_session = 7'
has "3 a queue's walltime untouched" 'max_walltime_min = 60'
has "3 a queue's own max_gpus untouched" 'max_gpus = 1'

# --- 4. one limit changes one limit
run --bwrap --rw "$T/proj" --cost 0 --replace >/dev/null 2>&1
has "4 cost set"          'max_estimated_cost_usd = 0'
has "4 slots as shipped"  'max_slots = 128'
has "4 gpus as shipped"   'max_gpus = 8'

# --- 5. a warning, not a refusal, when the slots cannot carry the GPUs
msg=$(run --bwrap --rw "$T/proj" --gpus 8 --slots 16 --replace 2>&1 >/dev/null)
[[ "$msg" == *"warning"*"64 slots"* ]] && ok "5 warns about slots" || bad "5 warns about slots ($msg)"

# --- 6. refusals, none of which writes a policy
refuses "6 no sandbox kind"      "--bwrap or --podman"   --rw "$T/proj"
refuses "6 no directory"         "at least one --rw"     --bwrap
refuses "6 relative path"        "not an absolute path"  --bwrap --rw proj
refuses "6 missing directory"    "no such directory"     --bwrap --rw "$T/nothing"
refuses "6 odd character"        "unsupported character" --bwrap --rw "$T/pr oj"
refuses "6 the home directory"   "home directory"        --bwrap --rw "$T/home"
refuses "6 above the home"       "home directory"        --bwrap --rw "$T"
refuses "6 upper-case host"      "not a hostname"        --bwrap --rw "$T/proj" --allow PyPI.org
refuses "6 host with a scheme"   "not a hostname"        --bwrap --rw "$T/proj" --allow https://pypi.org
refuses "6 limit not a number"   "not a whole number"    --bwrap --rw "$T/proj" --gpus two
refuses "6 cost not a number"    "not a number"          --bwrap --rw "$T/proj" --cost cheap
refuses "6 unknown option"       "unknown option"        --bwrap --rw "$T/proj" --frobnicate
refuses "6 no csub checkout"     "sample policy not found" --bwrap --rw "$T/proj" --csub "$T/nothing"
if [[ -d /scratch ]]; then refuses "6 /scratch" "/scratch cannot" --bwrap --rw /scratch; fi

# --- 7. a sample whose layout changed is not written through
mkdir -p "$T/csub2/deploy"
grep -v '^max_estimated_cost_usd' "$HERE/fixtures/csub/deploy/broker.janelia.toml" > "$T/csub2/deploy/broker.janelia.toml"
refuses "7 a limit missing from the sample" "sample policy has changed" --bwrap --rw "$T/proj" --csub "$T/csub2"
sed 's/^allowed_roots = .*/roots = []/' "$HERE/fixtures/csub/deploy/broker.janelia.toml" > "$T/csub2/deploy/broker.janelia.toml"
refuses "7 a key renamed in the sample" "sample policy has changed" --bwrap --rw "$T/proj" --csub "$T/csub2"

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
