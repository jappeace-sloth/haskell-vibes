#!/usr/bin/env bash
# Stop hook: end-of-turn gate.
#
# Runs a three-phase state machine over per-turn state kept on tmpfs:
#
#   Phase 0 (dumbify / complexity canary). First, for code-touching turns only,
#   a small model (Haiku) reads the code changed this turn with no help and
#   explains it; the larger main-loop model judges whether that explanation is
#   correct. The canary is shown the diffs AND the full current contents of each
#   touched file, so "I can't see where X is defined" stops being a false
#   confusion and it can focus on whether the changed code itself is followable
#   (the same full-file-context fix the rule review got). If Haiku could not work
#   out what the code DOES (a misread or hedging about behaviour), the code is too
#   complex, so the large model simplifies it (behaviour-preserving) and Haiku
#   re-explains; a mere request for more comments when it understood is advisory.
#   Convergence is observed via the edit stack: no new edits after an explanation
#   means the large model accepted it. Runs before critique so the cheap canary
#   shapes the code first and the expensive critic verifies the simplified result.
#   Bounded by CLAUDE_DUMBIFY_MAX_ROUNDS (default 2: one full-context read, plus
#   one re-read if simplified). Mirrors the dumbify-my-code skill.
#
#   Phase 1 (adversarial critique). The full correctness guard, and the
#   replacement for the old self-verification nudge. A fresh independent critic
#   (default Opus) tries to PROVE THE WORKER WRONG about both the code it changed
#   and the claims it made this turn, by any means: writing and running tests,
#   running commands, and searching the web for authoritative sources. Evidence
#   is ranked the way the old nudge ranked it (an executed test/command is
#   strongest, an authoritative source next, opinion is not evidence) and more
#   independent counter-evidence is stronger. A substantiated challenge blocks the
#   turn so the larger model fixes the code, corrects the claim, or out-evidences
#   the critic. Running after dumbify makes the critic the last correctness gate,
#   so it verifies the canary's refactor too; its own fixes land on the
#   edits.jsonl stack and get rule-checked by Phase A. The critic is an advisor,
#   not a wall: it surfaces its challenges once, and the worker can always shrug
#   them off. Like dumbify, it converges on the edit stack (no new edits since the
#   last challenge means the worker stood by its work, so the gate moves on); only
#   a real fix re-triggers it, with CLAUDE_CRITIQUE_MAX_ROUNDS as a backstop.
#
#   Both Phase 0 and Phase 1 run a nested `claude` that may run commands, so each
#   is launched with every gate phase disabled in its environment to stop it
#   re-triggering this hook.
#
#   Phase A (rule review). Claims the edits.jsonl review stack that
#   record-edit.sh built during the turn and reviews every diff in a SINGLE
#   reviewer call (see reviewer_model) against the rules corpus. If the
#   reviewer reports violations,
#   the stop is blocked (decision:block) with the findings so the larger
#   model can fix or rebut. The model's fixes are themselves edits, recorded
#   onto a fresh stack and re-reviewed on the next Stop, so review loops
#   until the stack comes back clean.
#
# Per-turn state is reset by reset-turn-state.sh on UserPromptSubmit, so the
# per-phase done/round flags and any leftover stack clear when the next prompt
# arrives.
#
# Disable dumbify with CLAUDE_SKIP_DUMBIFY=1, critique with
# CLAUDE_SKIP_CRITIQUE=1, review with CLAUDE_SKIP_RULE_CHECK=1.
# Tune dumbify with CLAUDE_DUMBIFY_MODEL (default claude-haiku-4-5),
# CLAUDE_DUMBIFY_MAX_ROUNDS (default 3), CLAUDE_DUMBIFY_TIMEOUT (default 180).
# Tune critique with CLAUDE_CRITIQUE_MODEL (default claude-opus-4-8),
# CLAUDE_CRITIQUE_MAX_ROUNDS (default 2), CLAUDE_CRITIQUE_TIMEOUT (default 300).

set -uo pipefail

hook_input=$(cat)
session_id=$(printf '%s' "$hook_input" | jq -r '.session_id // "default"' 2>/dev/null)
transcript_path=$(printf '%s' "$hook_input" | jq -r '.transcript_path // empty' 2>/dev/null)

safe_session=$(printf '%s' "$session_id" | tr -c 'A-Za-z0-9_.-' '_')
state_dir="${TMPDIR:-/tmp}/claude-turn-state/$safe_session"
mkdir -p "$state_dir"

edits_stack="$state_dir/edits.jsonl"
claimed_edits="$state_dir/edits.processing"

# Model used for Phase A rule review. Sonnet rather than Haiku: the review
# only fires on turns that actually edited files and batches that turn's
# diffs into one call, so the cost is per-edit-turn (not per-Stop), and the
# extra reasoning catches semantic rule violations (e.g. silent failures,
# tests that assert static content) that a smaller model misses. The larger
# main-loop model is still the final judge of every finding.
reviewer_model="claude-sonnet-4-6"

# Args for the two read-only reviewers (Phase 0 canary, Phase A rule review).
# Neither uses MCP, so we skip the MCP server health-check spawns
# (hoogle/playwright/tmux registered in ~/.claude.json) that otherwise cost
# ~2.6s of cold start per call, and restrict them to read-only built-in tools.
# The JSON has no spaces, so word-splitting on the unquoted expansion yields
# exactly the three intended tokens. The Phase 1 critic is deliberately NOT
# given these: it needs full MCP and tool access to gather counter-evidence.
nomcp_args='--strict-mcp-config --mcp-config {"mcpServers":{}}'
readonly_tools='--tools Read Grep Glob'

# Durable log of nested-call failures, outside the per-turn state dir (which is
# wiped each user prompt) so failures survive for inspection. Overridable for
# tests via CLAUDE_GATE_FAILURE_LOG.
gate_failure_log="${CLAUDE_GATE_FAILURE_LOG:-$HOME/.claude/gate-failures.log}"
mkdir -p "$(dirname "$gate_failure_log")" 2>/dev/null || true

# --- nested-call failure handling ------------------------------------------
#
# Decision: the gate FAILS LOUD on a broken reviewer, it does not fail open.
# Previously every phase swallowed the nested `claude` exit code (`|| true`) and
# its stderr (`2>/dev/null`), then read empty output as "looks clean". That made
# a timed-out, crashed, or unauthenticated reviewer indistinguishable from a
# genuine pass: the phase silently did nothing and the turn ended green. We now
# capture the exit code and stderr, and treat "no usable answer" as a failure to
# surface, not a pass.

# nested_call_broken EXIT_CODE OUTPUT
# True (0) when a nested `claude -p` call returned nothing usable: killed by
# `timeout` (124), any non-zero exit, or exit 0 with empty stdout. A reviewer
# that answers "OK" exits 0 with output and is NOT broken.
nested_call_broken() {
    nested_exit_code=$1
    nested_stdout=$2
    if [ "$nested_exit_code" -ne 0 ]; then
        return 0
    fi
    if [ -z "$nested_stdout" ]; then
        return 0
    fi
    return 1
}

# surface_nested_failure PHASE MODEL EXIT_CODE OUTPUT STDERR_FILE WARN_FLAG
# Appends the failure (exit code + stderr tail) to gate_failure_log, then on the
# FIRST occurrence this turn blocks the Stop with a loud, descriptive reason and
# exits. On later occurrences it returns without blocking, so a permanently
# broken CLI surfaces once but does not wedge the turn forever.
surface_nested_failure() {
    failed_phase=$1
    failed_model=$2
    failed_exit=$3
    failed_output=$4
    failed_stderr_file=$5
    failed_warn_flag=$6

    failure_detail="exit=$failed_exit"
    if [ "$failed_exit" = "124" ]; then
        failure_detail="$failure_detail (timed out)"
    fi
    if [ -z "$failed_output" ]; then
        failure_detail="$failure_detail, empty output"
    fi

    {
        printf '=== gate nested-call failure: phase=%s model=%s %s ===\n' \
            "$failed_phase" "$failed_model" "$failure_detail"
        printf 'session=%s\n' "$session_id"
        printf '%s\n' '--- stderr (last 20 lines) ---'
        tail -n 20 "$failed_stderr_file" 2>/dev/null
        printf '\n'
    } >> "$gate_failure_log"

    if [ -f "$failed_warn_flag" ]; then
        return 0
    fi
    : > "$failed_warn_flag"

    reason="GATE INFRASTRUCTURE FAILURE in the $failed_phase phase: the nested $failed_model call returned no usable result ($failure_detail), so this turn was NOT checked by that phase. Details were appended to $gate_failure_log. Last stderr lines:
$(tail -n 20 "$failed_stderr_file" 2>/dev/null)

Find out why the reviewer could not run (timeout, auth, MCP, model error) before trusting this turn. This loud warning fires once per turn; you may continue after acknowledging it."
    jq -n --arg reason "$reason" '{decision: "block", reason: $reason}'
    exit 0
}

# --- corpus selection -------------------------------------------------------

# select_skills FILE_LIST_FILE
# Emits the skill names whose rules are relevant to the file types touched
# this turn. Most skills are task procedures (reddit-comment, vastai-gpu,
# ...) that say nothing about file content; attaching all of them was 96% of
# the old review prompt and pure latency. We attach only language skills that
# match the touched extensions. Global and project CLAUDE.md are always
# included by build_corpus regardless of this list.
select_skills() {
    file_list_file=$1
    skills=""
    while IFS= read -r touched_path; do
        case "$touched_path" in
            *.hs|*.lhs|*.hsig|*.cabal)
                skills="$skills haskell-project haskell-backpack unwitch-conversions verify-test-fails error-messages" ;;
            *.nix)
                skills="$skills nix ci-nix" ;;
        esac
    done < "$file_list_file"
    printf '%s\n' $skills | sort -u
}

# build_corpus OUT_FILE FILE_LIST_FILE
# Writes the rules corpus (global CLAUDE.md, project CLAUDE.md if distinct,
# and the selected skill SKILL.md files) to OUT_FILE.
build_corpus() {
    out_file=$1
    file_list_file=$2
    : > "$out_file"

    if [ -f "$HOME/.claude/CLAUDE.md" ]; then
        {
            printf '\n=== %s ===\n' "$HOME/.claude/CLAUDE.md"
            cat "$HOME/.claude/CLAUDE.md"
        } >> "$out_file"
    fi

    # Project CLAUDE.md: resolved from the git root of the first touched file.
    first_file=$(head -n 1 "$file_list_file")
    if [ -n "$first_file" ]; then
        project_root=$(git -C "$(dirname "$first_file")" rev-parse --show-toplevel 2>/dev/null || true)
        if [ -n "$project_root" ] && [ -f "$project_root/CLAUDE.md" ] && [ "$project_root/CLAUDE.md" != "$HOME/.claude/CLAUDE.md" ]; then
            {
                printf '\n=== %s ===\n' "$project_root/CLAUDE.md"
                cat "$project_root/CLAUDE.md"
            } >> "$out_file"
        fi
    fi

    while IFS= read -r skill_name; do
        [ -z "$skill_name" ] && continue
        skill_file="$HOME/.claude/skills/$skill_name/SKILL.md"
        if [ -f "$skill_file" ]; then
            {
                printf '\n=== skill: %s ===\n' "$skill_name"
                cat "$skill_file"
            } >> "$out_file"
        fi
    done < <(select_skills "$file_list_file")
}

# render_diffs EDITS_FILE
# Renders each recorded edit as a labelled diff block on stdout. Reviewing
# the diff (what changed) rather than the whole file keeps the prompt small
# and focuses the reviewer on the new text.
render_diffs() {
    jq -rs '
      .[] |
      "=== FILE: \(.tool_input.file_path // "?") (via \(.tool)) ===\n" +
      (if .tool == "Edit" then
         "--- replaced ---\n\(.tool_input.old_string // "")\n--- with ---\n\(.tool_input.new_string // "")"
       elif .tool == "MultiEdit" then
         ([.tool_input.edits[]? | "--- replaced ---\n\(.old_string // "")\n--- with ---\n\(.new_string // "")"] | join("\n"))
       elif .tool == "Write" then
         "--- new content ---\n\(.tool_input.content // "")"
       elif .tool == "NotebookEdit" then
         "--- new source ---\n\(.tool_input.new_source // "")"
       else
         (.tool_input | tostring)
       end)
      + "\n"
    ' "$1"
}

# turn_touched_state TRANSCRIPT
# Prints 1 if the assistant used any state-touching or research tool since the
# most recent real user message, else 0. A real user message is type=="user"
# with string content; tool replies are type=="user" with array content, which
# is how we tell them apart.
turn_touched_state() {
    names=$(jq -rs '
      ([range(length-1; -1; -1) as $i
        | if (.[$i].type == "user" and (.[$i].message.content | type == "string"))
          then $i else empty end] | .[0] // -1) as $idx
      | .[$idx+1:]
      | map(select(.type == "assistant")
            | .message.content
            | if type == "array"
              then (.[] | select(.type == "tool_use") | .name)
              else empty end)
      | unique | .[]
    ' "$1" 2>/dev/null)
    while IFS= read -r tool_name; do
        case "$tool_name" in
            Write|Edit|MultiEdit|NotebookEdit|Bash|WebFetch|WebSearch|mcp__*)
                printf '1'; return ;;
        esac
    done <<< "$names"
    printf '0'
}

# turn_assistant_text TRANSCRIPT
# The assistant's text (its claims and reasoning) since the most recent real
# user message. This is the prose the critic refutes.
turn_assistant_text() {
    jq -rs '
      ([range(length-1; -1; -1) as $i
        | if (.[$i].type == "user" and (.[$i].message.content | type == "string"))
          then $i else empty end] | .[0] // -1) as $idx
      | .[$idx+1:]
      | map(select(.type == "assistant")
            | .message.content
            | if type == "array" then (.[] | select(.type == "text") | .text)
              elif type == "string" then .
              else empty end)
      | join("\n")
    ' "$1" 2>/dev/null
}

# =====================  Phase 0: dumbify (complexity canary)  ===============
#
# Decision: dumbify runs FIRST, before critique. It is a behaviour-preserving
# refactor, so it should be shaped before the expensive critic runs (cheap Haiku
# before agentic Opus) and, by running first, its refactor is verified by the
# critic that follows rather than shipping unchecked. A small model explains the
# changed code with no help; the larger main-loop model judges the explanation.
#
# Decision: convergence is OBSERVED, not asserted. After each explanation we
# record the edit-stack size. Next Stop, if no new edits were made the large
# model accepted the explanation as correct, so we move on; if new edits appeared
# the code was simplified, so Haiku re-explains. Bounded by
# CLAUDE_DUMBIFY_MAX_ROUNDS. Fires only for code: docs/config carry no functions
# to canary.
#
# Decision: the canary reads with FULL-FILE context, and the round cap defaults
# to 2 (was 3). On isolated diffs, once the local logic was clear the only thing
# left for the canary to "not understand" was code outside the window (a helper
# defined elsewhere, the surrounding phase, the hook protocol), so later rounds
# drifted from "is this complex?" to "what else is in this file?" and pressured
# the author into comment-bloat rather than real simplification. Giving it the
# whole file removes those false confusions, and two rounds (one read, plus one
# re-read if the author actually simplified) is enough; a third mostly invites a
# manufactured nit. Override with CLAUDE_DUMBIFY_MAX_ROUNDS if needed.

dumbify_done_flag="$state_dir/dumbify-done"
dumbify_round_file="$state_dir/dumbify-round"
dumbify_editmark="$state_dir/dumbify-editmark"

dumbify_model="${CLAUDE_DUMBIFY_MODEL:-claude-haiku-4-5}"
dumbify_max_rounds="${CLAUDE_DUMBIFY_MAX_ROUNDS:-2}"
dumbify_timeout="${CLAUDE_DUMBIFY_TIMEOUT:-180}"

# True if any file on the edit stack is source code. Dumbify is about code
# comprehension, so prose and config edits do not trigger it.
dumbify_has_code=0
while IFS= read -r dumbify_path; do
    case "$dumbify_path" in
        *.hs|*.lhs|*.hsig|*.cabal|*.nix|*.sh|*.bash|*.py|*.rs|*.js|*.ts|*.tsx|*.go|*.c|*.h|*.cpp|*.hpp|*.java)
            dumbify_has_code=1; break ;;
    esac
done < <(jq -r '.tool_input.file_path // empty' "$edits_stack" 2>/dev/null)

if [ "${CLAUDE_SKIP_DUMBIFY:-0}" != "1" ] \
   && [ ! -f "$dumbify_done_flag" ] \
   && [ -s "$edits_stack" ] \
   && [ "$dumbify_has_code" = "1" ] \
   && command -v claude >/dev/null 2>&1; then

    dumbify_current_mark=$(wc -l < "$edits_stack" 2>/dev/null | tr -d ' ')

    if [ -f "$dumbify_editmark" ] && [ "$(cat "$dumbify_editmark")" = "$dumbify_current_mark" ]; then
        # No new edits since the last explanation: the larger model judged the
        # explanation correct and chose not to simplify. Accept and move on.
        : > "$dumbify_done_flag"
    else
        dumbify_round=$(cat "$dumbify_round_file" 2>/dev/null || echo 0)
        dumbify_round=$((dumbify_round + 1))

        if [ "$dumbify_round" -gt "$dumbify_max_rounds" ]; then
            # Round cap reached: stop canarying and let critique/rules proceed.
            : > "$dumbify_done_flag"
        else
            dumbify_repo=""
            dumbify_first_file=$(jq -r '.tool_input.file_path // empty' "$edits_stack" 2>/dev/null | head -n 1)
            if [ -n "$dumbify_first_file" ]; then
                dumbify_repo=$(git -C "$(dirname "$dumbify_first_file")" rev-parse --show-toplevel 2>/dev/null || true)
            fi

            dumbify_prompt=$(mktemp)
            {
                cat <<'DUMBIFY_HEADER'
You are a complexity canary. You are a small model reading code a larger agent
just wrote, with no explanation from its author. Your job is to test whether the
CHANGED code is understandable.

You are given two things below: the diffs applied this turn, and the FULL current
contents of each file they touched. Use the full file as context. A definition,
variable, or helper that the diff references but that lives elsewhere in the file
is available to you, so "I can't see where X is defined" is NOT a valid confusion
unless X is genuinely absent from the file.

For each function or section in the diffs, explain in your own words:
- what it does,
- what its inputs mean and what it returns,
- and any concern that makes it hard to follow. Label each concern:
    BLOCKS       - you could not work out what the changed code actually does.
    NICE-TO-HAVE - you understood it, but a comment or clearer name would help.

Rules:
- Judge from the diffs plus the full files shown and anything else you can read in
  the repository. Nobody will explain it to you; that is the point.
- Be honest. If something genuinely stops you understanding the behaviour, say so
  plainly and label it BLOCKS. Hedging ("I think", "probably", "I'm not sure")
  about what the code DOES is itself a BLOCKS signal worth stating outright.
- Do NOT report code outside this turn's change (untouched surrounding functions,
  the harness/hook protocol that consumes this script's output, the build system)
  as confusion. That is context, not the work under review.
- Do not suggest fixes. Just explain, and label each concern BLOCKS or NICE-TO-HAVE.
DUMBIFY_HEADER
                printf '\n=== DIFFS JUST APPLIED THIS TURN ===\n'
                render_diffs "$edits_stack" | head -c 40000
                # Full current contents of each touched file (deduped), so a
                # reference the diff makes to code defined elsewhere in the same
                # file is no longer a false "I can't see it" confusion. Mirrors
                # the full-file context the Phase A rule review already gets.
                printf '\n=== FULL CURRENT CONTENTS OF THE TOUCHED FILES (context: definitions the diffs reference live here) ===\n'
                while IFS= read -r dumbify_context_path; do
                    [ -z "$dumbify_context_path" ] && continue
                    [ -f "$dumbify_context_path" ] || continue
                    printf '\n--- %s ---\n' "$dumbify_context_path"
                    head -c 40000 "$dumbify_context_path"
                    printf '\n'
                done < <(jq -r '.tool_input.file_path // empty' "$edits_stack" 2>/dev/null | sort -u)
            } > "$dumbify_prompt"

            # Recursion guard: nested `claude` with every gate phase disabled.
            # stderr is captured (not discarded) and the exit code kept, so a
            # broken call can be explained and surfaced rather than read as clean.
            dumbify_stderr="$state_dir/dumbify.stderr"
            if [ -n "$dumbify_repo" ]; then
                dumbify_output=$(cd "$dumbify_repo" \
                    && CLAUDE_SKIP_DUMBIFY=1 CLAUDE_SKIP_CRITIQUE=1 CLAUDE_SKIP_RULE_CHECK=1 \
                       timeout "$dumbify_timeout" claude -p $nomcp_args $readonly_tools --model "$dumbify_model" < "$dumbify_prompt" 2>"$dumbify_stderr")
            else
                dumbify_output=$(CLAUDE_SKIP_DUMBIFY=1 CLAUDE_SKIP_CRITIQUE=1 CLAUDE_SKIP_RULE_CHECK=1 \
                    timeout "$dumbify_timeout" claude -p $nomcp_args $readonly_tools --model "$dumbify_model" < "$dumbify_prompt" 2>"$dumbify_stderr")
            fi
            dumbify_exit=$?

            rm -f "$dumbify_prompt"

            if nested_call_broken "$dumbify_exit" "$dumbify_output"; then
                surface_nested_failure "dumbify canary" "$dumbify_model" "$dumbify_exit" "$dumbify_output" "$dumbify_stderr" "$state_dir/dumbify-broke"
                : > "$dumbify_done_flag"
            elif [ -n "$dumbify_output" ]; then
                # Record the round and the stack size this explanation was based
                # on, so the next Stop can tell whether the model simplified.
                printf '%s' "$dumbify_round" > "$dumbify_round_file"
                printf '%s' "$dumbify_current_mark" > "$dumbify_editmark"

                reason="A $dumbify_model model (a small 'complexity canary') read the code you changed this turn, with the full files as context, and explained it as follows (round $dumbify_round of $dumbify_max_rounds). You are the larger model and the final judge. Weigh its explanation:
  1. If it could NOT work out what the changed code DOES (a BLOCKS concern, a misread, or hedging about behaviour), the code is too complex. Apply a behaviour-preserving simplification (split a large dispatch into named functions, bundle threaded parameters into a record, add a domain-bridging comment, extract a capturing where-block). Your edits trigger a re-explanation. Do NOT change behaviour.
  2. If it understood the behaviour correctly, make no change and say so; the gate moves on. A NICE-TO-HAVE request for more comments when it already understood is advisory: weigh it, but you may decline and proceed rather than pile on prose.
Set CLAUDE_SKIP_DUMBIFY=1 to disable this gate.

--- canary explanation ---
$dumbify_output
--- end canary explanation ---"

                jq -n --arg reason "$reason" '{decision: "block", reason: $reason}'
                exit 0
            fi
            # Reached only when a broken call was already surfaced once this
            # turn: mark done so the turn proceeds instead of re-blocking.
            : > "$dumbify_done_flag"
        fi
    fi
fi

# =====================  Phase 1: adversarial critique  =====================
#
# Decision: critique runs after dumbify (Phase 0) and before rule review (Phase
# A). After dumbify so the critic is the LAST correctness gate and verifies the
# canary's behaviour-preserving refactor too; a botched "simplification" would
# otherwise ship unchecked. Before rules so the fixes it triggers land on the
# edits.jsonl stack and are rule-checked by Phase A in the same turn, rather than
# escaping review until the next turn.
#
# Decision: the critic's currency is a demonstrated failure, not prose. A strong
# type-checker already kills the bugs a paragraph-level reviewer would catch; what
# survives is semantic, which is exactly what a failing test pins down. Requiring
# evidence also auto-filters confabulated "bugs": no reproducer, no finding.
#
# Decision: the critic is an ADVISOR, not a wall. The worker (the larger model)
# is the final judge and must always be able to shrug a challenge off. So, exactly
# like dumbify, convergence is OBSERVED via the edit stack rather than forced: the
# critic surfaces its challenges once, and if the worker makes NO new edits before
# the next Stop (it stood by its work, or rebutted the claims in prose) the gate
# accepts that judgement and moves on. Only a real fix (new edits, so the stack
# grows) earns a fresh critique. CLAUDE_CRITIQUE_MAX_ROUNDS stays as a backstop
# against an edit-edit-edit loop, not as a minimum number of rounds to endure.

critique_done_flag="$state_dir/critique-done"
critique_round_file="$state_dir/critique-round"
critique_prev="$state_dir/critique-prev"
# The editmark is the edit-stack size (line count) captured when a challenge
# blocks; a later Stop compares it to the current size to tell a fix (the stack
# grew) from a shrug (unchanged). Cross-Stop state lifecycle: $state_dir lives on
# tmpfs and persists across all the Stop invocations of ONE turn, and is wiped
# per user prompt by reset-turn-state.sh. That is what lets the mark written when
# a challenge blocks (see below) be read again on the next Stop.
critique_editmark="$state_dir/critique-editmark"

critique_model="${CLAUDE_CRITIQUE_MODEL:-claude-opus-4-8}"
critique_max_rounds="${CLAUDE_CRITIQUE_MAX_ROUNDS:-2}"
critique_timeout="${CLAUDE_CRITIQUE_TIMEOUT:-300}"

if [ "${CLAUDE_SKIP_CRITIQUE:-0}" != "1" ] \
   && [ ! -f "$critique_done_flag" ] \
   && command -v claude >/dev/null 2>&1; then

    # The critic refutes BOTH the code changed and the claims the worker made
    # this turn. Claims come from the transcript; the diff from the edit stack
    # (which may be empty on a research/ops turn that only ran tools).
    critique_claims=""
    critique_touched=0
    if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
        critique_touched=$(turn_touched_state "$transcript_path")
        critique_claims=$(turn_assistant_text "$transcript_path" | head -c 16000)
    fi
    critique_has_edits=0
    [ -s "$edits_stack" ] && critique_has_edits=1

    # The stack size a previous challenge this turn was based on, used to detect a
    # shrug. Same basis as dumbify's editmark: the hook only reads the stack here
    # (Phase A claims it later), so the count is stable across a Stop on which the
    # critic blocked. A missing or empty stack (a research/conversational turn)
    # counts as 0.
    critique_current_mark=0
    [ -s "$edits_stack" ] && critique_current_mark=$(wc -l < "$edits_stack" | tr -d ' ')

    if [ "$critique_has_edits" = "0" ] && [ "$critique_touched" = "0" ]; then
        # A pure conversational turn touched nothing and ran no tools: there is
        # no action or claim grounded in work to refute. Nothing to do.
        : > "$critique_done_flag"
    elif [ -f "$critique_editmark" ] \
         && [ "$(cat "$critique_editmark")" = "$critique_current_mark" ]; then
        # The critic already challenged this turn and the worker has made NO new
        # edits since: it stood by its work, or rebutted the claims in prose. The
        # critic is an advisor, not a wall, so a shrug ends the debate. Only new
        # edits (a real fix) would have grown the stack and earned a re-critique.
        : > "$critique_done_flag"
    else
        # First critique this turn, or the worker made new edits in response that
        # warrant a fresh look.
        # Resolve a repo so the critic can run tests and read code. Prefer the
        # first edited file's root; otherwise the gate's working directory.
        critique_first_file=$(jq -r '.tool_input.file_path // empty' "$edits_stack" 2>/dev/null | head -n 1)
        if [ -n "$critique_first_file" ]; then
            critique_repo=$(git -C "$(dirname "$critique_first_file")" rev-parse --show-toplevel 2>/dev/null || true)
        else
            critique_repo=$(git rev-parse --show-toplevel 2>/dev/null || true)
        fi

        critique_prompt=$(mktemp)

        {
            cat <<'CRITIQUE_HEADER'
You are an adversarial correctness critic. A different, larger Claude Code agent
just finished a turn. Below are the code changes it made (possibly none) and the
claims it made about what it did or found. Your single job is to PROVE THE WORKER
WRONG, by any means necessary. Assume both the code and the claims are wrong until
you have evidence otherwise.

Use every tool you have to gather counter-evidence:

- For code: write and run tests, run the type-checker/build, run a one-off
  command. Look for logic errors that still typecheck (wrong boundaries, inverted
  conditions, unhandled cases, off-by-one, broken invariants, missing coverage)
  and ways the change breaks the rest of the codebase.
- For prose/claims: check them against reality. Run the command the worker says
  it ran. Search the web and read authoritative sources to contradict a factual
  claim. A claim of "I verified X" that was never actually demonstrated is itself
  suspect.

Rank your counter-evidence by authority, and gather as much as you can:

- Strongest: a failing test, a non-zero exit code, a command you ran and its
  output. A machine cannot misreport these.
- Good: an authoritative external source (documentation, a standard, a primary
  source) that contradicts the claim. Cite the URL and quote the line.
- More independent counter-evidence is stronger than one: a test AND a source
  beats either alone.
- Not evidence: your own opinion or doubt. If you cannot substantiate a challenge
  with a test, a command, or a cited source, DROP it.

Do not add files to the repository under review; use /tmp for scratch
reproducers. Do not flag style, naming, or "could be cleaner".

Response format, no markdown:

- If you cannot prove anything wrong: respond with the single line OK.
- Otherwise, one block per refuted item:

    CHALLENGE: <one-sentence summary of what is wrong>
    CLAIM: <the worker claim or code behaviour you are refuting>
    EVIDENCE: <the test/command you ran and its output, and/or a source URL with
              the contradicting quote. Concrete and reproducible.>
    SEVERITY: blocker | major | minor

Separate blocks with a blank line.
CRITIQUE_HEADER

            # On a rebuttal round, show the critic what it claimed last time so
            # it can concede points the worker has since answered.
            if [ -f "$critique_prev" ]; then
                printf '\n=== YOUR PREVIOUS CHALLENGES (the worker has since responded and may have changed code or claims; only re-raise what still holds and you can still substantiate) ===\n'
                cat "$critique_prev"
            fi

            printf '\n=== WHAT THE WORKER CLAIMS THIS TURN ===\n'
            if [ -n "$critique_claims" ]; then
                printf '%s\n' "$critique_claims"
            else
                printf '(no transcript claims available)\n'
            fi

            printf '\n=== CODE CHANGES THIS TURN (may be empty) ===\n'
            if [ "$critique_has_edits" = "1" ]; then
                render_diffs "$edits_stack" | head -c 40000
            else
                printf '(no file edits this turn)\n'
            fi
        } > "$critique_prompt"

        # Recursion guard: the critic is a nested `claude` that runs commands and
        # web searches, whose own hooks would otherwise re-enter this gate. Every
        # gate phase is disabled in its environment. Run it in the repo when known.
        # stderr captured and exit code kept so a broken critic is explained,
        # not silently read as a clean pass.
        critique_stderr="$state_dir/critique.stderr"
        if [ -n "$critique_repo" ]; then
            critique_output=$(cd "$critique_repo" \
                && CLAUDE_SKIP_DUMBIFY=1 CLAUDE_SKIP_CRITIQUE=1 CLAUDE_SKIP_RULE_CHECK=1 \
                   timeout "$critique_timeout" claude -p --model "$critique_model" < "$critique_prompt" 2>"$critique_stderr")
        else
            critique_output=$(CLAUDE_SKIP_DUMBIFY=1 CLAUDE_SKIP_CRITIQUE=1 CLAUDE_SKIP_RULE_CHECK=1 \
                timeout "$critique_timeout" claude -p --model "$critique_model" < "$critique_prompt" 2>"$critique_stderr")
        fi
        critique_exit=$?

        rm -f "$critique_prompt"

        # A broken nested call (timeout/crash/empty) is surfaced loudly rather
        # than read as clean. Otherwise a CHALLENGE block means substantiated
        # counter-evidence; clean "OK" falls through to mark the phase done.
        if nested_call_broken "$critique_exit" "$critique_output"; then
            surface_nested_failure critique "$critique_model" "$critique_exit" "$critique_output" "$critique_stderr" "$state_dir/critique-broke"
            : > "$critique_done_flag"
        elif printf '%s' "$critique_output" | grep -q '^CHALLENGE:'; then
            critique_round=$(cat "$critique_round_file" 2>/dev/null || echo 0)
            critique_round=$((critique_round + 1))
            printf '%s' "$critique_round" > "$critique_round_file"

            if [ "$critique_round" -le "$critique_max_rounds" ]; then
                printf '%s' "$critique_output" > "$critique_prev"
                # Record the stack size this challenge was based on. If the worker
                # makes no new edits before the next Stop, the editmark short
                # circuit above reads it as a shrug and ends the debate; new edits
                # grow the stack past this mark and earn a fresh critique.
                printf '%s' "$critique_current_mark" > "$critique_editmark"

                reason="A fresh adversarial $critique_model critic tried to prove your work wrong this turn, using tests and sources, and produced the counter-evidence below (round $critique_round of $critique_max_rounds). This critic is an advisor, not a wall: you are the final judge. For each challenge, either:
  1. Agree: fix the code, or correct the claim. Code fixes are re-critiqued and rule-checked automatically.
  2. Disagree: rebut it with STRONGER evidence than the critic brought (run the test yourself, cite a better source), or simply stand by your work. Do not just assert.
Engage every challenge, then decide. If you make no further edits, the gate takes that as your considered judgement and moves on (a shrug is allowed); it does not re-litigate. Set CLAUDE_SKIP_CRITIQUE=1 to disable this gate.

--- critic challenges ---
$critique_output
--- end critic challenges ---"

                jq -n --arg reason "$reason" '{decision: "block", reason: $reason}'
                exit 0
            fi
            # Round cap reached: the worker kept editing through every allowed
            # round, so the stack grew each Stop and never read as a shrug. Stop
            # debating and fall through; remaining suspicions are left for the
            # human reviewer rather than looping forever.
        fi

        # Clean (OK / empty output / round cap reached): critique is done. The
        # stack is left intact for Phase A to claim and rule-check.
        : > "$critique_done_flag"
    fi
fi

# =====================  Phase A: rule review  ==============================

if [ "${CLAUDE_SKIP_RULE_CHECK:-0}" != "1" ] \
   && [ -s "$edits_stack" ] \
   && command -v claude >/dev/null 2>&1; then

    # Claim the stack atomically so any edit recorded after this point lands
    # on a fresh stack and is reviewed on the next Stop rather than lost.
    mv "$edits_stack" "$claimed_edits" 2>/dev/null || true

    if [ -s "$claimed_edits" ]; then
        file_list=$(mktemp)
        corpus=$(mktemp)
        prompt_file=$(mktemp)
        trap 'rm -f "$file_list" "$corpus" "$prompt_file"' EXIT

        jq -r '.tool_input.file_path // empty' "$claimed_edits" 2>/dev/null | sort -u > "$file_list"
        build_corpus "$corpus" "$file_list"

        {
            cat <<'PROMPT_HEADER'
You are a rule-compliance reviewer. Another Claude Code agent (a larger model
than you) just finished a turn in which it made the edits shown below. You are
reviewing the DIFFS of those edits, not whole files. Your output is fed back to
that larger model, which then decides whether to fix the file or rebut your
finding. Give it enough evidence to judge, not just a label.

Below is a corpus of rules from CLAUDE.md and the relevant skills, followed by
the diffs that were just applied.

Be strict about what counts as a violation:

- Only flag clear, objective violations of a rule stated in the rules corpus.
  Quote the rule you are applying.
- Only flag text that appears in a "--- with ---", "--- new content ---" or
  "--- new source ---" section: that is what the agent actually wrote. Do not
  flag text in a "--- replaced ---" section; that is the old text being removed.
- A violation can also be the ABSENCE of required text. For rules of the form
  "always do X" / "every Y must have Z" (e.g. "always add a top-level type
  signature to every top-level binding"), a diff fragment cannot show a missing
  line. So for any top-level definition that appears in the diffs (added or
  modified this turn), consult the FULL FILE CONTENTS section below to check
  whether the required element is present; if it is missing, flag it. Apply this
  ONLY to definitions that appear in the diffs, never to untouched code.
- Do NOT flag stylistic preferences that are not stated in the rules.
- Do NOT flag judgement calls or things that "might be better".
- If you are unsure, do not flag it.
- Skill rules only apply when the skill's trigger conditions match the file
  being reviewed.

Response format:

- If there are no violations: respond with the single line `OK`.
- Otherwise: one block per violation, no markdown, with these labelled lines:

    VIOLATION: <one-sentence summary>
    RULE: "<verbatim quote of the rule, including which file/skill it came from>"
    EVIDENCE: <file path>: <the offending text, copied verbatim from a newly
              written section>
    REASONING: <one or two sentences naming the concrete mechanism by which the
               text breaks the rule. Note any borderline-ness so the larger
               model can decide whether to fix or rebut.>

Separate blocks with a blank line.

=== RULES ===
PROMPT_HEADER
            cat "$corpus"
            printf '\n=== DIFFS JUST APPLIED ===\n'
            render_diffs "$claimed_edits" | head -c 40000
            # Full current contents of each touched file, so the reviewer can
            # judge the ABSENCE of required elements (e.g. a missing top-level
            # type signature) that a diff fragment alone cannot reveal.
            printf '\n=== FULL FILE CONTENTS (context; judge presence/absence of required elements only for definitions that appear in the diffs above) ===\n'
            while IFS= read -r context_path; do
                [ -z "$context_path" ] && continue
                [ -f "$context_path" ] || continue
                printf '\n--- %s ---\n' "$context_path"
                head -c 40000 "$context_path"
                printf '\n'
            done < "$file_list"
        } > "$prompt_file"

        # The 60s timeout protects against a hung subprocess. stderr captured and
        # exit code kept so a broken reviewer is surfaced, not read as clean.
        review_stderr="$state_dir/review.stderr"
        review_output=$(CLAUDE_SKIP_DUMBIFY=1 CLAUDE_SKIP_CRITIQUE=1 CLAUDE_SKIP_RULE_CHECK=1 \
            timeout 60 claude -p $nomcp_args $readonly_tools --model "$reviewer_model" < "$prompt_file" 2>"$review_stderr")
        review_exit=$?

        if nested_call_broken "$review_exit" "$review_output"; then
            # Do not lose the diffs: return them to the stack so the next Stop
            # re-reviews once the reviewer works again, then surface the failure.
            cat "$claimed_edits" >> "$edits_stack" 2>/dev/null
            rm -f "$claimed_edits"
            surface_nested_failure "rule review" "$reviewer_model" "$review_exit" "$review_output" "$review_stderr" "$state_dir/review-broke"
        else
            rm -f "$claimed_edits"
            # Non-empty output containing a VIOLATION block means findings to fix.
            if printf '%s' "$review_output" | grep -q '^VIOLATION:'; then
                reason="A $reviewer_model reviewer flagged possible rule violations in the diffs you just applied.
You are the larger model and the final judge. For each finding, either:
  1. Agree: edit the file to fix it (the fix is re-reviewed automatically), or
  2. Disagree: explain to the user why the finding is wrong (the reviewer misread
     the rule, the rule does not apply to this file type, evidence out of context)
     and proceed without fixing.
Do not silently ignore findings. Set CLAUDE_SKIP_RULE_CHECK=1 to disable.

--- reviewer findings ---
$review_output
--- end reviewer findings ---"

                jq -n --arg reason "$reason" '{decision: "block", reason: $reason}'
                exit 0
            fi
        fi
    fi
fi
