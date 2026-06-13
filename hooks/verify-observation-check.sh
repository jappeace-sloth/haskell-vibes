#!/usr/bin/env bash
# Stop hook: nudge the model toward external verification at end of turn.
#
# When the model finishes a turn in which it actually produced or changed
# something (Write/Edit/MultiEdit/NotebookEdit/Bash/WebFetch/WebSearch),
# block the stop and inject a generic reminder to verify the work through
# observation rather than introspection. Pure-info turns (Read/Grep/Glob
# /TodoWrite/etc.) are left alone so chat-style answers do not get
# ceremony piled on top.
#
# Recursion is prevented via the stop_hook_active flag that the harness
# sets when the previous Stop was already blocked by a hook. Without that
# guard the model would loop: verify, stop, hook fires, verify again, ...
#
# Disable per-session by exporting CLAUDE_SKIP_VERIFY_CHECK=1.

set -uo pipefail

if [ "${CLAUDE_SKIP_VERIFY_CHECK:-0}" = "1" ]; then
    exit 0
fi

hook_input=$(cat)

stop_hook_active=$(printf '%s' "$hook_input" | jq -r '.stop_hook_active // false' 2>/dev/null)
if [ "$stop_hook_active" = "true" ]; then
    exit 0
fi

transcript_path=$(printf '%s' "$hook_input" | jq -r '.transcript_path // empty' 2>/dev/null)
if [ -z "$transcript_path" ] || [ ! -f "$transcript_path" ]; then
    exit 0
fi

# Find tool names called by the assistant since the most recent real user
# message. Heuristic for "real user message": type=="user" and
# message.content is a string. Tool replies also arrive as type=="user"
# but their content is an array of tool_result objects, which is how we
# tell the two apart.
#
# Decision: scan the transcript with a single jq slurp rather than
# tac+jq-per-line. Alternatives considered: walking lines in bash
# (slow, fragile JSON quoting); reading only the last N lines (loses
# precision if the turn used many tools). The slurp is one process and
# the transcript caps at a few MB in practice.
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

touched_state=0
while IFS= read -r name; do
    case "$name" in
        Write|Edit|MultiEdit|NotebookEdit|Bash|WebFetch|WebSearch)
            touched_state=1
            break ;;
    esac
done <<< "$tool_names"

if [ "$touched_state" = "0" ]; then
    exit 0
fi

# Block the stop and feed the reminder back as a user-style message. The
# wording stays deliberately generic: the model already knows what tools
# it has, so listing them per project type would be both dated and
# limiting. The point is the contrast between "I think it works" and
# "I observed X". The recursion guard above keeps this one-shot per turn.
jq -n '{
  decision: "block",
  reason: ("Before ending this turn, verify your work through external observation, not introspection. "
    + "You have tools. Use them. Saying \"it should work\" is not verification; demonstrating \"I ran X and observed Y\" is. "
    + "If you have already done this and reported it, end the turn. "
    + "Otherwise verify now and report what you observed.")
}'
