#!/usr/bin/env bash
# Stop hook: end-of-turn gate.
#
# Runs a three-phase state machine over per-turn state kept on tmpfs:
#
#   Phase 0 (dumbify / complexity canary). First, for code-touching turns only,
#   a small model (Haiku) reads the code changed this turn with no help and
#   explains it; the larger main-loop model judges whether that explanation is
#   correct. If Haiku misread or hedged, the code is too complex, so the large
#   model simplifies it (behaviour-preserving) and Haiku re-explains. Convergence
#   is observed via the edit stack: no new edits after an explanation means the
#   large model accepted it. Runs before critique so the cheap canary shapes the
#   code first and the expensive critic verifies the simplified result. Bounded
#   by CLAUDE_DUMBIFY_MAX_ROUNDS. Mirrors the dumbify-my-code skill.
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
#   edits.jsonl stack and get rule-checked by Phase A. Bounded by
#   CLAUDE_CRITIQUE_MAX_ROUNDS so the debate cannot loop forever.
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

dumbify_done_flag="$state_dir/dumbify-done"
dumbify_round_file="$state_dir/dumbify-round"
dumbify_editmark="$state_dir/dumbify-editmark"

dumbify_model="${CLAUDE_DUMBIFY_MODEL:-claude-haiku-4-5}"
dumbify_max_rounds="${CLAUDE_DUMBIFY_MAX_ROUNDS:-3}"
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
code is understandable in isolation.

For each function or section in the diffs below, explain in your own words:
- what it does,
- what its inputs mean and what it returns,
- and any concern that makes it hard to follow.

Rules:
- Judge ONLY from the code shown plus what you can read in the repository. Nobody
  will explain it to you; that is the point.
- Be honest. If something confuses you, say so plainly and say what. Do not
  pretend to understand. Hedging ("I think", "probably", "I'm not sure") is a
  signal worth stating outright.
- Do not suggest fixes. Just explain and report any confusion.
DUMBIFY_HEADER
                printf '\n=== DIFFS JUST APPLIED THIS TURN ===\n'
                render_diffs "$edits_stack" | head -c 40000
            } > "$dumbify_prompt"

            # Recursion guard: nested `claude` with every gate phase disabled.
            if [ -n "$dumbify_repo" ]; then
                dumbify_output=$(cd "$dumbify_repo" \
                    && CLAUDE_SKIP_DUMBIFY=1 CLAUDE_SKIP_CRITIQUE=1 CLAUDE_SKIP_RULE_CHECK=1 \
                       timeout "$dumbify_timeout" claude -p --model "$dumbify_model" < "$dumbify_prompt" 2>/dev/null || true)
            else
                dumbify_output=$(CLAUDE_SKIP_DUMBIFY=1 CLAUDE_SKIP_CRITIQUE=1 CLAUDE_SKIP_RULE_CHECK=1 \
                    timeout "$dumbify_timeout" claude -p --model "$dumbify_model" < "$dumbify_prompt" 2>/dev/null || true)
            fi

            rm -f "$dumbify_prompt"

            if [ -n "$dumbify_output" ]; then
                # Record the round and the stack size this explanation was based
                # on, so the next Stop can tell whether the model simplified.
                printf '%s' "$dumbify_round" > "$dumbify_round_file"
                printf '%s' "$dumbify_current_mark" > "$dumbify_editmark"

                reason="A $dumbify_model model (a small 'complexity canary') read the code you changed this turn, with no help, and explained it as follows (round $dumbify_round of $dumbify_max_rounds). You are the larger model. Judge whether its explanation is CORRECT and unconfused:
  1. If it misread the code or hedged/was confused, the code is too complex. Apply a behaviour-preserving simplification (split a large dispatch into named functions, bundle threaded parameters into a record, add a domain-bridging comment, extract a capturing where-block). Your edits trigger a re-explanation. Do NOT change behaviour.
  2. If it understood the code correctly, make no change and say so; the gate moves on.
Set CLAUDE_SKIP_DUMBIFY=1 to disable this gate.

--- canary explanation ---
$dumbify_output
--- end canary explanation ---"

                jq -n --arg reason "$reason" '{decision: "block", reason: $reason}'
                exit 0
            fi
            # Empty output (CLI failure, network hiccup): treat the code as
            # understandable so infrastructure problems never wedge the turn.
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

critique_done_flag="$state_dir/critique-done"
critique_round_file="$state_dir/critique-round"
critique_prev="$state_dir/critique-prev"

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

    if [ "$critique_has_edits" = "0" ] && [ "$critique_touched" = "0" ]; then
        # A pure conversational turn touched nothing and ran no tools: there is
        # no action or claim grounded in work to refute. Nothing to do.
        : > "$critique_done_flag"
    else
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
        if [ -n "$critique_repo" ]; then
            critique_output=$(cd "$critique_repo" \
                && CLAUDE_SKIP_DUMBIFY=1 CLAUDE_SKIP_CRITIQUE=1 CLAUDE_SKIP_RULE_CHECK=1 \
                   timeout "$critique_timeout" claude -p --model "$critique_model" < "$critique_prompt" 2>/dev/null || true)
        else
            critique_output=$(CLAUDE_SKIP_DUMBIFY=1 CLAUDE_SKIP_CRITIQUE=1 CLAUDE_SKIP_RULE_CHECK=1 \
                timeout "$critique_timeout" claude -p --model "$critique_model" < "$critique_prompt" 2>/dev/null || true)
        fi

        rm -f "$critique_prompt"

        # A CHALLENGE block means substantiated counter-evidence. Empty output
        # (CLI failure, network hiccup) is treated as clean so infrastructure
        # problems never wedge the turn.
        if [ -n "$critique_output" ] && printf '%s' "$critique_output" | grep -q '^CHALLENGE:'; then
            critique_round=$(cat "$critique_round_file" 2>/dev/null || echo 0)
            critique_round=$((critique_round + 1))
            printf '%s' "$critique_round" > "$critique_round_file"

            if [ "$critique_round" -le "$critique_max_rounds" ]; then
                printf '%s' "$critique_output" > "$critique_prev"

                reason="A fresh adversarial $critique_model critic tried to prove your work wrong this turn, using tests and sources, and produced the counter-evidence below (round $critique_round of $critique_max_rounds). For each challenge, either:
  1. Agree: fix the code, or correct the claim. Code fixes are re-critiqued and rule-checked automatically.
  2. Disagree: rebut it with STRONGER evidence than the critic brought (run the test yourself, cite a better source). Out-evidence it; do not just assert.
Do not silently ignore a challenge. Set CLAUDE_SKIP_CRITIQUE=1 to disable this gate.

--- critic challenges ---
$critique_output
--- end critic challenges ---"

                jq -n --arg reason "$reason" '{decision: "block", reason: $reason}'
                exit 0
            fi
            # Round cap reached: the model has engaged rounds 1..max. Stop
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
        } > "$prompt_file"

        # The 60s timeout protects against a hung subprocess blocking the turn.
        # Skip envs so the nested reviewer never re-triggers this hook on itself.
        review_output=$(CLAUDE_SKIP_DUMBIFY=1 CLAUDE_SKIP_CRITIQUE=1 CLAUDE_SKIP_RULE_CHECK=1 \
            timeout 60 claude -p --model "$reviewer_model" < "$prompt_file" 2>/dev/null || true)

        rm -f "$claimed_edits"

        # Non-empty output containing a VIOLATION block means findings to fix.
        # Empty output (CLI failure, network hiccup) is treated as clean so the
        # gate never blocks the turn on infrastructure problems.
        if [ -n "$review_output" ] && printf '%s' "$review_output" | grep -q '^VIOLATION:'; then
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
