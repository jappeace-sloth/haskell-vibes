#!/usr/bin/env bash
# Stop hook: end-of-turn gate.
#
# Runs a two-phase state machine over per-turn state kept on tmpfs:
#
#   Phase A (rule review). Claims the edits.jsonl review stack that
#   record-edit.sh built during the turn and reviews every diff in a SINGLE
#   claude-haiku call against the rules corpus. If haiku reports violations,
#   the stop is blocked (decision:block) with the findings so the larger
#   model can fix or rebut. The model's fixes are themselves edits, recorded
#   onto a fresh stack and re-reviewed on the next Stop, so review loops
#   until the stack comes back clean.
#
#   Phase B (verification). Only once review is clean does the gate ask the
#   model to verify its work through external observation, and only if the
#   turn actually touched state. This is the FINAL prompt of the turn: we
#   review first, then verify. A verify-done flag makes it one-shot.
#
# Per-turn state is reset by reset-turn-state.sh on UserPromptSubmit, so the
# verify-done flag and any leftover stack clear when the next prompt arrives.
#
# Disable review with CLAUDE_SKIP_RULE_CHECK=1, verification with
# CLAUDE_SKIP_VERIFY_CHECK=1.

set -uo pipefail

hook_input=$(cat)
session_id=$(printf '%s' "$hook_input" | jq -r '.session_id // "default"' 2>/dev/null)
transcript_path=$(printf '%s' "$hook_input" | jq -r '.transcript_path // empty' 2>/dev/null)

safe_session=$(printf '%s' "$session_id" | tr -c 'A-Za-z0-9_.-' '_')
state_dir="${TMPDIR:-/tmp}/claude-turn-state/$safe_session"
mkdir -p "$state_dir"

verify_done_flag="$state_dir/verify-done"
edits_stack="$state_dir/edits.jsonl"
claimed_edits="$state_dir/edits.processing"

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
# and focuses haiku on the new text.
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
        review_output=$(timeout 60 claude -p --model claude-haiku-4-5-20251001 < "$prompt_file" 2>/dev/null || true)

        rm -f "$claimed_edits"

        # Non-empty output containing a VIOLATION block means findings to fix.
        # Empty output (CLI failure, network hiccup) is treated as clean so the
        # gate never blocks the turn on infrastructure problems.
        if [ -n "$review_output" ] && printf '%s' "$review_output" | grep -q '^VIOLATION:'; then
            # New fixes are coming, so re-arm verification to run after them.
            rm -f "$verify_done_flag"

            reason="A claude-haiku-4-5 reviewer flagged possible rule violations in the diffs you just applied.
You are the larger model and the final judge. For each finding, either:
  1. Agree: edit the file to fix it (the fix is re-reviewed automatically), or
  2. Disagree: explain to the user why the finding is wrong (haiku misread the
     rule, the rule does not apply to this file type, evidence out of context)
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

# =====================  Phase B: verification  =============================

if [ "${CLAUDE_SKIP_VERIFY_CHECK:-0}" = "1" ]; then
    exit 0
fi

# One-shot per turn: if we already asked for verification, let the turn end.
if [ -f "$verify_done_flag" ]; then
    exit 0
fi

if [ -z "$transcript_path" ] || [ ! -f "$transcript_path" ]; then
    exit 0
fi

# Find tool names the assistant called since the most recent real user
# message (type=="user" with a string content; tool replies are type=="user"
# with an array content, which is how we tell them apart). A single jq slurp
# rather than tac+jq-per-line: one process, transcript is a few MB at most.
tool_names=$(jq -rs '
  ([range(length-1; -1; -1) as $i
    | if (.[$i].type == "user" and (.[$i].message.content | type == "string"))
      then $i else empty end] | .[0] // -1) as $idx
  | .[$idx+1:]
  | map(select(.type == "assistant")
        | .message.content
        | if type == "array"
          then (.[] | select(.type == "tool_use") | .name)
          else empty end)
  | unique
  | .[]
' "$transcript_path" 2>/dev/null)

# Any state-touching or research tool warrants the "report what you observed"
# nudge. MCP tools (mcp__*) are side-effecting or research-style, both of
# which qualify.
touched_state=0
while IFS= read -r name; do
    case "$name" in
        Write|Edit|MultiEdit|NotebookEdit|Bash|WebFetch|WebSearch|mcp__*)
            touched_state=1
            break ;;
    esac
done <<< "$tool_names"

if [ "$touched_state" = "0" ]; then
    exit 0
fi

# Arm the one-shot and ask for verification. This is the final prompt of the
# turn: review has already passed by the time we reach here.
: > "$verify_done_flag"

jq -n '{
  decision: "block",
  reason: ("Before ending this turn, verify your work through external observation, not introspection. "
    + "You have tools. Use them. Saying \"it should work\" is not verification; demonstrating \"I ran X and observed Y\" is. "
    + "If you have already done this and reported it, end the turn. "
    + "Otherwise verify now and report what you observed.")
}'
