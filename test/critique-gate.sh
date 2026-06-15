#!/usr/bin/env bash
# Behaviour test for the Phase 0 (dumbify), Phase 1 (critique), and Phase A
# (rule review) state machines in stop-gate.sh. It does NOT reimplement the gate:
# it drives the real hook with synthetic Stop-hook input and a stubbed `claude`,
# then asserts what the hook actually emitted and wrote to its per-turn state.
#
# The stub `claude` branches on the prompt it receives over stdin:
#   "complexity canary"        -> dumbify explainer: returns a canned explanation
#   "adversarial code critic"  -> critic: returns a canned response we control
#   "rule-compliance reviewer" -> rule reviewer: returns $reviewer_response (OK
#                                 by default) and logs the prompt it received,
#                                 so we can assert what context the gate sent it
# so each phase can be tested in isolation by skipping the others. The stub also
# logs the CLAUDE_SKIP_* it was invoked with, so we can assert the recursion
# guards.
#
# Usage: test/critique-gate.sh [path-to-stop-gate.sh]

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
dumbify_response="$work/dumbify-response.txt"
reviewer_response="$work/reviewer-response.txt"
reviewer_prompt_log="$work/reviewer-prompt.txt"
stub_log="$work/stub-invocations.log"
# When this file holds a phase keyword (dumbify|critique|review), the stub
# simulates a broken nested call for that phase: it writes to stderr and exits
# non-zero with empty stdout, so the fail-loud path can be exercised.
stub_fail_file="$work/stub-fail"
echo OK > "$critic_response"
echo OK > "$reviewer_response"
echo "This function adds two integers and returns their sum." > "$dumbify_response"
: > "$stub_fail_file"

cat > "$stub_bin/claude" <<STUB
#!/usr/bin/env bash
input=\$(cat)
echo "SKIP_CRITIQUE=\${CLAUDE_SKIP_CRITIQUE:-unset} SKIP_DUMBIFY=\${CLAUDE_SKIP_DUMBIFY:-unset}" >> "$stub_log"
fail_phase=\$(cat "$stub_fail_file" 2>/dev/null)
if printf '%s' "\$input" | grep -q 'complexity canary'; then
    if [ "\$fail_phase" = "dumbify" ]; then echo "stub: simulated dumbify failure" >&2; exit 1; fi
    cat "$dumbify_response"
elif printf '%s' "\$input" | grep -q 'adversarial correctness critic'; then
    if [ "\$fail_phase" = "critique" ]; then echo "stub: simulated critic failure" >&2; exit 1; fi
    cat "$critic_response"
elif printf '%s' "\$input" | grep -q 'rule-compliance reviewer'; then
    printf '%s' "\$input" > "$reviewer_prompt_log"
    if [ "\$fail_phase" = "review" ]; then echo "stub: simulated reviewer failure" >&2; exit 1; fi
    cat "$reviewer_response"
fi
STUB
chmod +x "$stub_bin/claude"

export PATH="$stub_bin:$PATH"
export TMPDIR="$work/tmp"
mkdir -p "$TMPDIR"
# Isolate HOME so the gate's corpus build does not read the real CLAUDE.md.
export HOME="$work/home"
mkdir -p "$HOME/.claude"
# Durable failure log at a known path so the fail-loud tests can assert on it.
export CLAUDE_GATE_FAILURE_LOG="$work/gate-failures.log"

state_dir_for() { printf '%s/claude-turn-state/%s' "$TMPDIR" "$1"; }

seed_edit() {
    # seed_edit SESSION [EXT] [COUNT]  -> COUNT recorded edits to a .EXT file.
    sess=$1; ext=${2:-hs}; count=${3:-1}
    sdir=$(state_dir_for "$sess"); mkdir -p "$sdir"
    : > "$sdir/edits.jsonl"
    i=0
    while [ "$i" -lt "$count" ]; do
        printf '{"tool":"Edit","tool_input":{"file_path":"%s/subject.%s","old_string":"a","new_string":"b"}}\n' \
            "$work" "$ext" >> "$sdir/edits.jsonl"
        i=$((i + 1))
    done
}

run_gate() {
    # run_gate SESSION  -> stdout of the gate for a Stop with empty transcript.
    printf '{"session_id":"%s","transcript_path":""}' "$1" | bash "$gate"
}

run_gate_tx() {
    # run_gate_tx SESSION TRANSCRIPT  -> stdout of the gate with a real
    # transcript path, used to exercise the prose/claims critique path.
    printf '{"session_id":"%s","transcript_path":"%s"}' "$1" "$2" | bash "$gate"
}

challenge_block=$'CHALLENGE: off-by-one in the loop bound\nCLAIM: drops the last element\nEVIDENCE: ran `runghc /tmp/r.hs`, printed 4 items expected 5\nSEVERITY: major'

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; fails=$((fails + 1)); }
assert_contains() { case "$2" in *"$1"*) pass "$3" ;; *) fail "$3 (missing: $1)" ;; esac; }
assert_absent()   { case "$2" in *"$1"*) fail "$3 (unexpected: $1)" ;; *) pass "$3" ;; esac; }
assert_file()     { if [ -e "$1" ]; then pass "$2"; else fail "$2 (no file: $1)"; fi; }
assert_no_file()  { if [ -e "$1" ]; then fail "$2 (file exists: $1)"; else pass "$2"; fi; }
assert_eq()       { if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (want $2, got $1)"; fi; }

############################################################################
# Phase 0: dumbify (complexity canary). Critique skipped to isolate it.
############################################################################
export CLAUDE_SKIP_CRITIQUE=1

# === d1: canary explains code -> blocks for the larger model to judge =======
: > "$stub_log"
seed_edit d1 hs 1
out=$(run_gate d1)
sdir=$(state_dir_for d1)
assert_contains '"decision": "block"' "$out" "d1: a code change triggers a canary explanation block"
assert_contains 'canary explanation' "$out" "d1: block carries the canary explanation"
assert_contains 'adds two integers'  "$out" "d1: the actual explanation is forwarded"
assert_eq "$(cat "$sdir/dumbify-round" 2>/dev/null)" "1" "d1: dumbify round is 1"
assert_eq "$(cat "$sdir/dumbify-editmark" 2>/dev/null)" "1" "d1: editmark records the stack size"
assert_no_file "$sdir/dumbify-done" "d1: dumbify not marked done while explaining"
assert_contains 'SKIP_DUMBIFY=1' "$(cat "$stub_log")" "d1: recursion guard set on the nested canary"

# === d2: no new edits since last explanation -> accepted, move on ===========
seed_edit d2 hs 1
sdir=$(state_dir_for d2)
printf '1' > "$sdir/dumbify-editmark"   # equals current stack size -> accepted
printf '1' > "$sdir/dumbify-round"
out=$(run_gate d2)
assert_absent 'canary explanation' "$out" "d2: an accepted explanation does not block"
assert_file "$sdir/dumbify-done" "d2: dumbify marked done once accepted"

# === d3: new edits appeared -> canary re-explains, round advances ===========
seed_edit d3 hs 2                       # 2 edits now
sdir=$(state_dir_for d3)
printf '1' > "$sdir/dumbify-editmark"   # last explanation saw 1 edit -> simplified
printf '1' > "$sdir/dumbify-round"
out=$(run_gate d3)
assert_contains 'canary explanation' "$out" "d3: a simplification triggers re-explanation"
assert_eq "$(cat "$sdir/dumbify-round" 2>/dev/null)" "2" "d3: dumbify round advanced to 2"
assert_eq "$(cat "$sdir/dumbify-editmark" 2>/dev/null)" "2" "d3: editmark updated to new stack size"

# === d4: round cap reached -> stop canarying ================================
seed_edit d4 hs 2
sdir=$(state_dir_for d4)
printf '1' > "$sdir/dumbify-editmark"
printf '3' > "$sdir/dumbify-round"      # next would be 4, past the default cap of 3
out=$(run_gate d4)
assert_absent 'canary explanation' "$out" "d4: past the round cap the canary stops"
assert_file "$sdir/dumbify-done" "d4: dumbify marked done at the cap"

# === d5: non-code edit -> dumbify does not fire ============================
seed_edit d5 md 1
sdir=$(state_dir_for d5)
out=$(run_gate d5)
assert_absent 'canary explanation' "$out" "d5: a docs-only change does not trigger the canary"
assert_no_file "$sdir/dumbify-done" "d5: non-code leaves no dumbify state"

# === d6: skip flag disables dumbify ========================================
seed_edit d6 hs 1
sdir=$(state_dir_for d6)
out=$(CLAUDE_SKIP_DUMBIFY=1 bash "$gate" <<<'{"session_id":"d6","transcript_path":""}')
assert_absent 'canary explanation' "$out" "d6: skip flag suppresses the canary"
assert_no_file "$sdir/dumbify-done" "d6: skipped phase leaves no done flag"

unset CLAUDE_SKIP_CRITIQUE

############################################################################
# Phase 1: adversarial critique. Dumbify skipped to isolate it.
############################################################################
export CLAUDE_SKIP_DUMBIFY=1

# === c1: critique finds a demonstrable bug -> blocks the turn ===============
: > "$stub_log"
printf '%s' "$challenge_block" > "$critic_response"
seed_edit c1 hs 1
out=$(run_gate c1)
sdir=$(state_dir_for c1)
assert_contains '"decision": "block"' "$out" "c1: a demonstrable bug blocks the stop"
assert_contains 'critic challenges'   "$out" "c1: block reason carries the challenges"
assert_contains 'off-by-one'          "$out" "c1: the actual finding is forwarded"
assert_eq "$(cat "$sdir/critique-round" 2>/dev/null)" "1" "c1: round counter is 1"
assert_eq "$(cat "$sdir/critique-editmark" 2>/dev/null)" "1" "c1: editmark records the stack size the challenge saw"
assert_no_file "$sdir/critique-done" "c1: critique not marked done while bugs remain"
assert_contains 'SKIP_CRITIQUE=1' "$(cat "$stub_log")" "c1: recursion guard set on the nested critic"

# === c1b: no new edits since the challenge -> shrug accepted, no re-critique ==
# The worker rebutted in prose / stood by its work. The critic is an advisor, so
# the gate must move on rather than force another round.
seed_edit c1b hs 1
sdir=$(state_dir_for c1b)
printf '1' > "$sdir/critique-editmark"   # equals current stack size -> a shrug
printf '1' > "$sdir/critique-round"
printf '%s' "$challenge_block" > "$critic_response"
out=$(run_gate c1b)
assert_absent 'critic challenges' "$out" "c1b: a shrug (no new edits) does not re-block on the same challenge"
assert_file "$sdir/critique-done" "c1b: critique marked done once the worker stands pat"
assert_eq "$(cat "$sdir/critique-round" 2>/dev/null)" "1" "c1b: a shrug does not advance the round counter"

# === c1c: new edits since the challenge -> a real fix earns a re-critique =====
seed_edit c1c hs 2                       # 2 edits now
sdir=$(state_dir_for c1c)
printf '1' > "$sdir/critique-editmark"   # last challenge saw 1 edit -> worker fixed
printf '1' > "$sdir/critique-round"
printf '%s' "$challenge_block" > "$critic_response"
out=$(run_gate c1c)
assert_contains 'critic challenges' "$out" "c1c: new edits in response trigger a fresh critique"
assert_eq "$(cat "$sdir/critique-round" 2>/dev/null)" "2" "c1c: round advances when the worker re-edited"
assert_eq "$(cat "$sdir/critique-editmark" 2>/dev/null)" "2" "c1c: editmark updated to the new stack size"

# === c2: critic returns OK -> no critique block, phase marked done ==========
echo OK > "$critic_response"
seed_edit c2 hs 1
out=$(run_gate c2)
sdir=$(state_dir_for c2)
assert_absent 'critic challenges' "$out" "c2: a clean critique does not block"
assert_absent '"decision": "block"' "$out" "c2: rule review (stub OK) does not block either"
assert_file "$sdir/critique-done" "c2: critique marked done after a clean pass"

# === c3: round cap reached -> stop debating, fall through ===================
printf '%s' "$challenge_block" > "$critic_response"
seed_edit c3 hs 1
sdir=$(state_dir_for c3)
printf '2' > "$sdir/critique-round"   # next round would be 3, past the default cap of 2
out=$(run_gate c3)
assert_absent 'critic challenges' "$out" "c3: past the round cap the gate stops blocking"
assert_file "$sdir/critique-done" "c3: critique marked done once the cap is hit"
assert_eq "$(cat "$sdir/critique-round" 2>/dev/null)" "3" "c3: round counter advanced to 3"

# === c4: CLAUDE_SKIP_CRITIQUE disables Phase 1 entirely =====================
printf '%s' "$challenge_block" > "$critic_response"
seed_edit c4 hs 1
sdir=$(state_dir_for c4)
out=$(CLAUDE_SKIP_CRITIQUE=1 bash "$gate" <<<'{"session_id":"c4","transcript_path":""}')
assert_absent 'critic challenges' "$out" "c4: skip flag suppresses the critique block"
assert_no_file "$sdir/critique-done" "c4: skipped phase leaves no done flag"

unset CLAUDE_SKIP_DUMBIFY

############################################################################
# Phase 1 as full correctness guard: prose/claims on no-edit turns, and the
# removal of the old self-verification nudge.
############################################################################

# === pr1: a research turn (tools, no file edits) is still critiqued =========
tx="$work/tx-pr1.jsonl"
{
  printf '%s\n' '{"type":"user","message":{"content":"research X"}}'
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"I claim X is true."},{"type":"tool_use","name":"WebSearch","input":{}}]}}'
} > "$tx"
printf '%s' "$challenge_block" > "$critic_response"
out=$(run_gate_tx pr1 "$tx")
assert_contains 'critic challenges' "$out" "pr1: critique fires on a research turn with no file edits"

# === pr2: a pure conversational turn (no tools, no edits) is not critiqued ===
tx="$work/tx-pr2.jsonl"
{
  printf '%s\n' '{"type":"user","message":{"content":"what is 2+2"}}'
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"4"}]}}'
} > "$tx"
out=$(run_gate_tx pr2 "$tx")
sdir=$(state_dir_for pr2)
assert_absent '"decision": "block"' "$out" "pr2: a pure conversational turn does not block"
assert_file "$sdir/critique-done" "pr2: critique marked done when there is nothing to refute"

# === pr3: the old self-verification nudge is gone ==========================
tx="$work/tx-pr3.jsonl"
{
  printf '%s\n' '{"type":"user","message":{"content":"run it"}}'
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"I ran it, works."},{"type":"tool_use","name":"Bash","input":{}}]}}'
} > "$tx"
echo OK > "$critic_response"
out=$(run_gate_tx pr3 "$tx")
assert_absent 'verify your work' "$out" "pr3: the removed verification nudge no longer fires"
assert_absent '"decision": "block"' "$out" "pr3: a clean critique on a tool turn ends the turn"

############################################################################
# Phase A: rule review. Dumbify and critique skipped to isolate it. Asserts
# the reviewer prompt now carries the FULL FILE CONTENTS of each touched file
# (so absence-of-required-text rules, e.g. a missing top-level type signature,
# are detectable from a diff that cannot show a missing line), and that a
# returned VIOLATION blocks the stop.
############################################################################
export CLAUDE_SKIP_DUMBIFY=1
export CLAUDE_SKIP_CRITIQUE=1

# === a1: rule review injects full file content and blocks on a violation ====
printf 'classify _ = "many"  -- RULEREVIEW_SUBJECT_MARKER\n' > "$work/subject.hs"
printf 'VIOLATION: missing top-level type signature\nRULE: "Always add type signatures to top level bindings"\nEVIDENCE: subject.hs: classify has no signature\nREASONING: no signature line present for classify\n' > "$reviewer_response"
: > "$reviewer_prompt_log"
seed_edit a1 hs 1
out=$(run_gate a1)
assert_contains '"decision": "block"' "$out" "a1: a rule violation blocks the stop"
assert_contains 'reviewer findings' "$out" "a1: block carries the reviewer findings"
assert_contains 'missing top-level type signature' "$out" "a1: the actual finding is forwarded"
assert_contains 'FULL FILE CONTENTS' "$(cat "$reviewer_prompt_log")" "a1: reviewer prompt carries the full-file section"
assert_contains 'RULEREVIEW_SUBJECT_MARKER' "$(cat "$reviewer_prompt_log")" "a1: reviewer prompt carries the touched file body"

# === a2: a clean rule review (OK) does not block ============================
echo OK > "$reviewer_response"
seed_edit a2 hs 1
out=$(run_gate a2)
assert_absent '"decision": "block"' "$out" "a2: a clean rule review ends the turn"

unset CLAUDE_SKIP_DUMBIFY
unset CLAUDE_SKIP_CRITIQUE

############################################################################
# Fail-loud: a broken nested call (non-zero exit, empty output) must be
# surfaced, not read as a clean pass. Covers the reviewer and the critic.
############################################################################

# === f1: a broken rule reviewer blocks loudly, logs, and keeps the edits =====
export CLAUDE_SKIP_DUMBIFY=1
export CLAUDE_SKIP_CRITIQUE=1
: > "$CLAUDE_GATE_FAILURE_LOG"
echo review > "$stub_fail_file"          # reviewer exits 1 with empty stdout
seed_edit f1 hs 1
sdir=$(state_dir_for f1)
out=$(run_gate f1)
assert_contains '"decision": "block"' "$out" "f1: a broken reviewer blocks the stop"
assert_contains 'GATE INFRASTRUCTURE FAILURE' "$out" "f1: the block names it an infrastructure failure"
assert_contains 'simulated reviewer failure' "$out" "f1: the captured stderr is forwarded"
assert_contains 'gate nested-call failure' "$(cat "$CLAUDE_GATE_FAILURE_LOG" 2>/dev/null)" "f1: the failure is written to the durable log"
assert_file "$sdir/edits.jsonl" "f1: the diffs are returned to the stack for re-review, not lost"
: > "$stub_fail_file"

# === f2: the loud warning fires once per turn, then lets the turn proceed =====
echo review > "$stub_fail_file"
sdir=$(state_dir_for f2)
mkdir -p "$sdir"; : > "$sdir/review-broke"   # already surfaced this turn
seed_edit f2 hs 1
out=$(run_gate f2)
assert_absent '"decision": "block"' "$out" "f2: an already-surfaced failure does not re-block"
: > "$stub_fail_file"

# === f3: a broken critic is surfaced loudly too =============================
export CLAUDE_SKIP_DUMBIFY=1
unset CLAUDE_SKIP_CRITIQUE
: > "$CLAUDE_GATE_FAILURE_LOG"
echo critique > "$stub_fail_file"        # critic exits 1 with empty stdout
seed_edit f3 hs 1
out=$(run_gate f3)
assert_contains 'GATE INFRASTRUCTURE FAILURE' "$out" "f3: a broken critic blocks loudly"
assert_contains 'critique' "$out" "f3: the block names the critique phase"
: > "$stub_fail_file"
unset CLAUDE_SKIP_DUMBIFY
unset CLAUDE_SKIP_CRITIQUE

echo
if [ "$fails" -eq 0 ]; then
    echo "ALL TESTS PASSED"
    exit 0
fi
echo "$fails TEST(S) FAILED"
exit 1
