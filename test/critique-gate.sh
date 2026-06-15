#!/usr/bin/env bash
# Behaviour test for the Phase 0 adversarial-critique state machine in
# stop-gate.sh. It does NOT reimplement the gate: it drives the real hook with
# synthetic Stop-hook input and a stubbed `claude`, then asserts what the hook
# actually emitted and wrote to its per-turn state.
#
# The stub `claude` branches on the prompt it receives over stdin: the critic
# prompt ("adversarial code critic") returns a canned response we control; the
# rule reviewer prompt ("rule-compliance reviewer") always returns OK so Phase A
# never interferes with what we are asserting about Phase 0. The stub also logs
# the CLAUDE_SKIP_CRITIQUE it was invoked with, so we can assert the recursion
# guard.
#
# Usage: test/critique-gate.sh [path-to-stop-gate.sh]
# Defaults to hooks/stop-gate.sh next to this test's repo root.

set -uo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
gate="${1:-$repo_root/hooks/stop-gate.sh}"

if [ ! -f "$gate" ]; then
    echo "FATAL: gate not found at $gate" >&2
    exit 2
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# --- stub claude ------------------------------------------------------------
stub_bin="$work/bin"
mkdir -p "$stub_bin"
critic_response="$work/critic-response.txt"
stub_log="$work/stub-invocations.log"

cat > "$stub_bin/claude" <<STUB
#!/usr/bin/env bash
input=\$(cat)
echo "SKIP_CRITIQUE=\${CLAUDE_SKIP_CRITIQUE:-unset}" >> "$stub_log"
if printf '%s' "\$input" | grep -q 'adversarial code critic'; then
    cat "$critic_response"
elif printf '%s' "\$input" | grep -q 'rule-compliance reviewer'; then
    echo OK
fi
STUB
chmod +x "$stub_bin/claude"

export PATH="$stub_bin:$PATH"
export TMPDIR="$work/tmp"
mkdir -p "$TMPDIR"
# Isolate HOME so the gate's corpus build does not read the real CLAUDE.md.
export HOME="$work/home"
mkdir -p "$HOME/.claude"

# state_dir mirrors stop-gate.sh's own computation.
state_dir_for() { printf '%s/claude-turn-state/%s' "$TMPDIR" "$1"; }

seed_edit() {
    # seed_edit SESSION  -> one recorded edit on the session's stack.
    sdir=$(state_dir_for "$1")
    mkdir -p "$sdir"
    printf '%s\n' \
      '{"tool":"Edit","tool_input":{"file_path":"'"$work"'/subject.hs","old_string":"a","new_string":"b"}}' \
      > "$sdir/edits.jsonl"
}

run_gate() {
    # run_gate SESSION  -> stdout of the gate for a Stop with empty transcript.
    printf '{"session_id":"%s","transcript_path":""}' "$1" | bash "$gate"
}

challenge_block=$'CHALLENGE: off-by-one in the loop bound\nCLAIM: drops the last element\nEVIDENCE: ran `runghc /tmp/r.hs`, printed 4 items expected 5\nSEVERITY: major'

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; fails=$((fails + 1)); }
assert_contains() { case "$2" in *"$1"*) pass "$3" ;; *) fail "$3 (missing: $1)" ;; esac; }
assert_absent()   { case "$2" in *"$1"*) fail "$3 (unexpected: $1)" ;; *) pass "$3" ;; esac; }
assert_file()     { if [ -e "$1" ]; then pass "$2"; else fail "$2 (no file: $1)"; fi; }
assert_no_file()  { if [ -e "$1" ]; then fail "$2 (file exists: $1)"; else pass "$2"; fi; }

# === Case 1: critique finds a demonstrable bug -> blocks the turn ===========
: > "$stub_log"
printf '%s' "$challenge_block" > "$critic_response"
seed_edit s1
out=$(run_gate s1)
sdir=$(state_dir_for s1)
assert_contains '"decision": "block"' "$out" "case1: a demonstrable bug blocks the stop"
assert_contains 'critic challenges'   "$out" "case1: block reason carries the challenges"
assert_contains 'off-by-one'          "$out" "case1: the actual finding is forwarded"
if [ "$(cat "$sdir/critique-round" 2>/dev/null)" = "1" ]; then
    pass "case1: round counter is 1"
else
    fail "case1: round counter not 1"
fi
assert_no_file "$sdir/critique-done" "case1: critique is not marked done while bugs remain"
assert_contains 'SKIP_CRITIQUE=1' "$(cat "$stub_log")" "case1: recursion guard set on the nested critic"

# === Case 2: critic returns OK -> no critique block, phase marked done ======
echo OK > "$critic_response"
seed_edit s2
out=$(run_gate s2)
sdir=$(state_dir_for s2)
assert_absent 'critic challenges' "$out" "case2: a clean critique does not block"
assert_absent '"decision": "block"' "$out" "case2: rule review (stub OK) does not block either"
assert_file "$sdir/critique-done" "case2: critique marked done after a clean pass"

# === Case 3: round cap reached -> stop debating, fall through ===============
printf '%s' "$challenge_block" > "$critic_response"
seed_edit s3
sdir=$(state_dir_for s3)
printf '2' > "$sdir/critique-round"   # next round would be 3, past the default cap of 2
out=$(run_gate s3)
assert_absent 'critic challenges' "$out" "case3: past the round cap the gate stops blocking"
assert_file "$sdir/critique-done" "case3: critique marked done once the cap is hit"
if [ "$(cat "$sdir/critique-round" 2>/dev/null)" = "3" ]; then
    pass "case3: round counter advanced to 3"
else
    fail "case3: round counter not 3"
fi

# === Case 4: CLAUDE_SKIP_CRITIQUE disables Phase 0 entirely =================
printf '%s' "$challenge_block" > "$critic_response"
seed_edit s4
sdir=$(state_dir_for s4)
out=$(CLAUDE_SKIP_CRITIQUE=1 run_gate s4)
assert_absent 'critic challenges' "$out" "case4: skip flag suppresses the critique block"
assert_no_file "$sdir/critique-done" "case4: skipped phase leaves no done flag"

echo
if [ "$fails" -eq 0 ]; then
    echo "ALL TESTS PASSED"
    exit 0
fi
echo "$fails TEST(S) FAILED"
exit 1
