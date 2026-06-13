#!/usr/bin/env bash
# UserPromptSubmit hook.
#
# A "turn" is one user prompt and everything the agent does to satisfy it.
# The Stop gate keeps per-turn state on tmpfs: the edits.jsonl review stack
# and the verify-done one-shot flag. Those must reset when a new user prompt
# arrives, otherwise the previous turn's leftovers would be reviewed again
# and verification would never re-fire. This hook wipes the session's state
# dir at the start of each user turn.
#
# It never blocks and emits no extra context; exit 0 always.

set -uo pipefail

hook_input=$(cat)
session_id=$(printf '%s' "$hook_input" | jq -r '.session_id // "default"' 2>/dev/null)

safe_session=$(printf '%s' "$session_id" | tr -c 'A-Za-z0-9_.-' '_')
state_dir="${TMPDIR:-/tmp}/claude-turn-state/$safe_session"

rm -rf "$state_dir" 2>/dev/null || true

exit 0
