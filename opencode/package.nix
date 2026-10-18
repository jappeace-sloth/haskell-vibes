{ pkgs }:
# Decision: patch OpenCode so a request carries only the model, the environment
# block and the user's own instructions: no bundled per-model system prompt, and
# tool descriptions reduced to how each tool works. Alternatives: an agent
# `prompt` in opencode.json (cannot be empty, so it still injects text) or a
# plugin rewriting descriptions at runtime (keeps working silently when upstream
# adds directives). A patch fails the build instead. See no-builtin-directives.md.
#
# Decision: skill-autocomplete.patch lists skills in the TUI's `/` autocomplete,
# tagged `:skill` like MCP prompts are tagged `:mcp`. Upstream skips them there
# and offers only the `/skills` selector, although `/<skill>` already runs one as
# a command. Alternative: a TUI plugin registering a slash command per skill.
# Rejected: it goes through `api.command`, which upstream marks for removal in
# v2 (tui/src/plugin/command-shim.ts), and duplicates the server's skill commands.
pkgs.opencode.overrideAttrs (old: {
  patches = (old.patches or []) ++ [ ./no-builtin-directives.patch ./skill-autocomplete.patch ];
})
