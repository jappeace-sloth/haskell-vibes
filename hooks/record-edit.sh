#!/usr/bin/env bash
# PostToolUse hook for Write/Edit/MultiEdit/NotebookEdit.
#
# Previously the rule-compliance review ran synchronously here, spinning up
# a claude-haiku review of the whole file after every single edit. With the
# full rules corpus that blocked the main agent ~13s per write. The review
# now happens once at end of turn (see stop-gate.sh); this hook only RECORDS
# the edit onto a per-turn review stack, which is near-instant and never
# blocks the agent.
#
# Each accepted edit is appended as one JSON line to the session's
# edits.jsonl under a tmpfs state dir. The tool_input is kept verbatim so the
# Stop hook can reconstruct the diff (old_string/new_string for Edit,
# edits[] for MultiEdit, content for Write, new_source for NotebookEdit) and
# review the change rather than the entire file.
#
# Decision: record at PostToolUse, review at Stop. Alternatives considered:
# (a) keep the synchronous per-edit review (simple but ~13s latency on every
# write); (b) run the review in a detached background process from
# PostToolUse (no clean way to feed findings back as blocking feedback). The
# Stop hook already exists as the natural end-of-turn gate and can block via
# decision:block, so batching there gives one review pass per turn with no
# per-edit latency.
#
# Disable per-session by exporting CLAUDE_SKIP_RULE_CHECK=1.

set -uo pipefail

if [ "${CLAUDE_SKIP_RULE_CHECK:-0}" = "1" ]; then
    exit 0
fi

hook_input=$(cat)
file_path=$(printf '%s' "$hook_input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
tool_name=$(printf '%s' "$hook_input" | jq -r '.tool_name // empty' 2>/dev/null)
session_id=$(printf '%s' "$hook_input" | jq -r '.session_id // "default"' 2>/dev/null)

# No file path means nothing to record.
if [ -z "$file_path" ] || [ ! -f "$file_path" ]; then
    exit 0
fi

# Skip files where prose/style rules don't apply.
case "$file_path" in
    *.lock|*.json|*.csv|*.tsv|*.png|*.jpg|*.jpeg|*.gif|*.pdf|*.ico|*.svg)
        exit 0 ;;
    *.zip|*.tar|*.tar.gz|*.tgz|*.bz2|*.xz|*.7z|*.rar)
        exit 0 ;;
    *.sqlite|*.db|*.so|*.dylib|*.exe|*.bin)
        exit 0 ;;
    */node_modules/*|*/.git/*|*/dist-newstyle/*|*/result|*/result-*)
        exit 0 ;;
esac

# Skip very large files so we don't burn tokens on huge writes.
file_size=$(stat -c %s "$file_path" 2>/dev/null || stat -f %z "$file_path" 2>/dev/null || echo 0)
if [ "$file_size" -gt 50000 ]; then
    exit 0
fi

# Skip binary files (cheap heuristic: look for NUL bytes in first 8KB). `-P`
# lets grep parse the escape itself; `-a` forces text-mode on data grep may
# guess is binary; `LC_ALL=C` keeps the byte regex stable across locales.
if head -c 8192 "$file_path" 2>/dev/null | LC_ALL=C grep -aqP '\x00'; then
    exit 0
fi

# Per-session state lives on the tmpfs /tmp (cleared each container launch).
# The session id is sanitised so it is safe as a path component.
safe_session=$(printf '%s' "$session_id" | tr -c 'A-Za-z0-9_.-' '_')
state_dir="${TMPDIR:-/tmp}/claude-turn-state/$safe_session"
mkdir -p "$state_dir"

# Append the edit. Keep the full tool_input verbatim so the diff can be
# reconstructed at review time.
printf '%s' "$hook_input" \
    | jq -c --arg tool "$tool_name" '{tool: $tool, tool_input: .tool_input}' \
    >> "$state_dir/edits.jsonl" 2>/dev/null

exit 0
