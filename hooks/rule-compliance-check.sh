#!/usr/bin/env bash
# PostToolUse hook for Write/Edit.
#
# After a file write, ask claude-haiku to review the file against every rule
# in ~/.claude/CLAUDE.md, the project CLAUDE.md (if any), and every installed
# skill. If it reports violations, exit 2 so the main agent sees them as
# feedback and can fix before continuing.
#
# Disable per-session by exporting CLAUDE_SKIP_RULE_CHECK=1.

set -uo pipefail

if [ "${CLAUDE_SKIP_RULE_CHECK:-0}" = "1" ]; then
    exit 0
fi

# Hook input arrives as JSON on stdin.
hook_input=$(cat)
file_path=$(printf '%s' "$hook_input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)

# No file path means nothing to check.
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

# Skip binary files (cheap heuristic: look for NUL bytes in first 8KB).
if head -c 8192 "$file_path" 2>/dev/null | grep -q $'\x00'; then
    exit 0
fi

# `claude` CLI must be on PATH for the hook to do anything useful.
if ! command -v claude >/dev/null 2>&1; then
    exit 0
fi

# Build the rules corpus: user-global CLAUDE.md, project CLAUDE.md (if it
# exists and differs from the user one), and every installed skill's SKILL.md.
rules_file=$(mktemp)
trap 'rm -f "$rules_file"' EXIT

if [ -f "$HOME/.claude/CLAUDE.md" ]; then
    {
        printf '\n=== %s ===\n' "$HOME/.claude/CLAUDE.md"
        cat "$HOME/.claude/CLAUDE.md"
    } >> "$rules_file"
fi

project_root=$(git -C "$(dirname "$file_path")" rev-parse --show-toplevel 2>/dev/null || true)
if [ -n "$project_root" ] && [ -f "$project_root/CLAUDE.md" ] && [ "$project_root/CLAUDE.md" != "$HOME/.claude/CLAUDE.md" ]; then
    {
        printf '\n=== %s ===\n' "$project_root/CLAUDE.md"
        cat "$project_root/CLAUDE.md"
    } >> "$rules_file"
fi

for skill_file in "$HOME"/.claude/skills/*/SKILL.md; do
    if [ -f "$skill_file" ]; then
        {
            printf '\n=== %s ===\n' "$skill_file"
            cat "$skill_file"
        } >> "$rules_file"
    fi
done

# If we have no rules at all there's nothing to check against.
if [ ! -s "$rules_file" ]; then
    exit 0
fi

# Assemble the review prompt. The reviewer is told to be strict and only
# flag clear violations, to avoid spam from stylistic judgement calls.
prompt_file=$(mktemp)
trap 'rm -f "$rules_file" "$prompt_file"' EXIT

{
    cat <<'PROMPT_HEADER'
You are a strict rule-compliance reviewer for a file that was just written or
edited by another Claude Code agent. Below is a corpus of rules from
CLAUDE.md and installed skills, followed by the current content of the file.

List EVERY clear violation of a rule that appears in the file. Be strict:

- Only flag clear, objective violations of a rule that is stated in the
  rules corpus. Quote the rule you are applying.
- Do NOT flag stylistic preferences that are not stated in the rules.
- Do NOT flag judgement calls or things that "might be better".
- If you are unsure, do not flag it.
- Skill rules only apply when the skill's trigger conditions match the file
  being reviewed. Do not flag a Haskell file for violating a Reddit-posting
  skill's rules, etc.

Respond in this exact format:

- If there are no violations, respond with the single line: OK
- Otherwise, respond with one line per violation, each starting with the
  literal token "VIOLATION: " followed by a short description and the rule
  being broken in parentheses. Example:
    VIOLATION: mid-line em-dash on line 42 (Prose style rule: no `---` inside a sentence)

=== RULES ===
PROMPT_HEADER
    cat "$rules_file"
    printf '\n=== FILE: %s ===\n' "$file_path"
    head -c 40000 "$file_path"
} > "$prompt_file"

# Run the review through claude haiku in headless print mode. The 60s timeout
# protects against a hung subprocess blocking the agent indefinitely.
review_output=$(timeout 60 claude -p --model claude-haiku-4-5-20251001 < "$prompt_file" 2>/dev/null || true)

# Empty output (CLI failure, network hiccup, etc.) is treated as OK so the
# hook never blocks the agent on infrastructure problems.
if [ -z "$review_output" ]; then
    exit 0
fi

if printf '%s' "$review_output" | grep -q '^VIOLATION:'; then
    {
        printf 'Rule violations detected in %s:\n' "$file_path"
        printf '%s\n' "$review_output" | grep '^VIOLATION:'
        printf '\nFix these before continuing. Set CLAUDE_SKIP_RULE_CHECK=1 to disable this check for the session.\n'
    } >&2
    exit 2
fi

exit 0
