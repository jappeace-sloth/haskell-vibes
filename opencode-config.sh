# shellcheck shell=bash
# Sourced by claude.sh and by opencode/test/system-prompt.js, so the check
# exercises the exact opencode.json the container gets.

# Writes opencode.json into directory $1 for MCP servers $2 (the MCP_CONFIG
# JSON of claude.sh), launch model $3 (empty keeps model discovery) and
# vanilla flag $4 (0|1).
#
# Decision: opencode's global config is derived from MCP_CONFIG with jq
# instead of being a second hand-maintained server list, so both harnesses
# always get the same MCP servers. `permission: "allow"` is opencode's
# bypassPermissions: the container is the sandbox, exactly as for claude.
# The optional --model pins the launch default: /models remembers choices under
# ~/.local/state/opencode, which is not persisted across container launches.
# Without --model, retain model discovery because ChatGPT plan access varies.
# autoupdate is off because the binary comes from nix. The file
# is written into the per-launch config snapshot and bind-mounted read-only
# like CLAUDE.md, so the agent cannot widen its own permissions.
#
# Decision: list ~/.claude/skills under skills.paths although opencode reads
# it as a Claude Code fallback. The fallback feeds only the v1 registry (the
# model's prompt and skill tool); the v2 registry behind /api/skill, which the
# TUI's skill dialog and `/` autocomplete use, reads only opencode's config
# directories and skills.paths (OpenCode 1.19.0). v1 dedupes by path, so the
# model still sees each skill once. Rejected: a second mount at
# ~/.config/opencode/skills, which v1 reports as a duplicate per skill.
write_opencode_config() {
    jq -n --argjson mcp "$2" --arg model "$3" --argjson vanilla "$4" '{
        "$schema": "https://opencode.ai/config.json",
        autoupdate: false,
        permission: "allow",
        plugin: ["file:///etc/opencode/stopgate.ts"],
        mcp: ($mcp | with_entries(.value = {
            type: "local",
            command: ([.value.command] + .value.args),
            enabled: true
        }))
    } + (if $model != "" then {model: $model} else {} end)
      + (if $vanilla == 0 then {skills: {paths: ["~/.claude/skills"]}} else {} end)' > "$1/opencode.json"
}
