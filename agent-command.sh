# Sourced by claude.sh and by claude-code/test/system-prompt.sh, so the check
# exercises the exact command the container runs.

# Sets AGENT_COMMAND for agent $1 (claude|opencode) and vanilla flag $2 (0|1).
#
# Decision: configured Claude Code instances get an empty system prompt, which
# drops the ~6k characters of bundled directives; the identity line, tools,
# CLAUDE.md, skills and environment block are still sent (the counterpart of
# opencode/no-builtin-directives.patch). Rejected: --append-system-prompt
# (removes nothing), a trimmed copy via --system-prompt-file (drifts from
# upstream) and --bare (also drops CLAUDE.md, hooks and the OAuth login).
# --vanilla keeps the stock prompt because it exists to show stock Claude.
set_agent_command() {
    AGENT_COMMAND=("$1")
    if [ "$1" = claude ] && [ "$2" -eq 0 ]; then
        AGENT_COMMAND+=(--system-prompt "")
    fi
}
